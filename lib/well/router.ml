(** Route registration, matching, scoping, and introspection. *)

open Types

(* ── Route types ──────────────────────────────────────────────────── *)

type segment = Static of string | Param of string | Wildcard of string

type route = {
  meth : string;
  segments : segment list;
  handler : request -> response;
}

type ws_route = {
  ws_segments : segment list;
  ws_handler : request -> Websocket.t -> unit;
}

(* ── Registries ───────────────────────────────────────────────────── *)

let routes : route list ref = ref []
let ws_routes : ws_route list ref = ref []
let cap_routes : route list ref = ref []
let static_mounts : static_mount list ref = ref []
let global_middlewares : middleware list ref = ref []

(* ── Middleware registration ──────────────────────────────────────── *)

(** Register a global middleware applied to all routes. *)
let use mw = global_middlewares := mw :: !global_middlewares

(* ── Static mount ─────────────────────────────────────────────────── *)

(** Mount a directory for static file serving at the given URL prefix. *)
let static prefix dir =
  let prefix =
    if String.length prefix > 0 && prefix.[String.length prefix - 1] = '/' then
      String.sub prefix 0 (String.length prefix - 1)
    else prefix
  in
  static_mounts := { prefix; dir } :: !static_mounts

(* ── Path parsing ─────────────────────────────────────────────────── *)

let split_path path =
  let path =
    match String.index_opt path '?' with
    | Some i -> String.sub path 0 i
    | None -> path
  in
  String.split_on_char '/' path
  |> List.filter (fun s -> s <> "")

let parse_segments parts =
  let rec go = function
    | [] -> []
    | [ part ] when String.length part > 0 && part.[0] = '*' ->
        [ Wildcard (String.sub part 1 (String.length part - 1)) ]
    | part :: _ when String.length part > 0 && part.[0] = '*' ->
        failwith ("Wildcard *" ^ String.sub part 1 (String.length part - 1) ^ " must be the last segment")
    | part :: rest ->
        (if String.length part > 0 && part.[0] = ':' then
           Param (String.sub part 1 (String.length part - 1))
         else Static part)
        :: go rest
  in
  go parts

(* ── Scope support ────────────────────────────────────────────────── *)

type scope_ctx = { prefix : string; scope_middlewares : middleware list }

let scope_stack : scope_ctx list ref = ref []

let current_prefix () =
  List.fold_left (fun acc s -> s.prefix ^ acc) "" !scope_stack

let current_scope_middlewares () =
  List.concat_map (fun s -> s.scope_middlewares) (List.rev !scope_stack)

(** Group routes under a shared URL prefix with optional scoped middleware. *)
let scope ?(middleware = []) prefix f =
  scope_stack := { prefix; scope_middlewares = middleware } :: !scope_stack;
  f ();
  scope_stack := List.tl !scope_stack

(* ── Route registration ───────────────────────────────────────────── *)

let register ?middleware meth path handler =
  let full_path = current_prefix () ^ path in
  let segments = parse_segments (split_path full_path) in
  let scope_mws = current_scope_middlewares () in
  let per_route = match middleware with Some mws -> mws | None -> [] in
  let all_mw = scope_mws @ per_route in
  let wrapped =
    if all_mw = [] then handler
    else apply_middlewares all_mw handler
  in
  routes := { meth; segments; handler = wrapped } :: !routes

let register_cap meth path handler =
  let segments = parse_segments (split_path path) in
  cap_routes := { meth; segments; handler } :: !cap_routes

(** Register a GET route handler. Path supports [:param] segments and [*wildcard]. *)
let get ?middleware path handler =
  register ?middleware "GET" path (fun req -> (handler req :> response))

(** Register a POST route handler. *)
let post ?middleware path handler =
  register ?middleware "POST" path (fun req -> (handler req :> response))

(** Register a PUT route handler. *)
let put ?middleware path handler =
  register ?middleware "PUT" path (fun req -> (handler req :> response))

(** Register a DELETE route handler. *)
let delete ?middleware path handler =
  register ?middleware "DELETE" path (fun req -> (handler req :> response))

(** Register a WebSocket route handler. *)
let ws path handler =
  let segments = parse_segments (split_path path) in
  ws_routes := { ws_segments = segments; ws_handler = handler } :: !ws_routes

(* ── Route matching ───────────────────────────────────────────────── *)

let try_match_segments parts segments =
  let rec go parts segs acc =
    match (parts, segs) with
    | [], [] -> Some (List.rev acc)
    | p :: ps, Static s :: ss ->
        if p = s then go ps ss acc else None
    | p :: ps, Param name :: ss ->
        go ps ss ((name, p) :: acc)
    | rest, [ Wildcard name ] ->
        Some (List.rev ((name, String.concat "/" rest) :: acc))
    | _ -> None
  in
  go parts segments []

let match_route meth path =
  let parts = split_path path in
  let candidates = List.rev !routes in
  let rec find = function
    | [] -> None
    | r :: rest ->
        if r.meth <> meth then find rest
        else
          match try_match_segments parts r.segments with
          | Some params -> Some (r, params)
          | None -> find rest
  in
  find candidates

let match_ws_route path =
  let parts = split_path path in
  let candidates = List.rev !ws_routes in
  let rec find = function
    | [] -> None
    | r :: rest ->
        match try_match_segments parts r.ws_segments with
        | Some params -> Some (r, params)
        | None -> find rest
  in
  find candidates

let match_cap_route meth path =
  let parts = split_path path in
  let candidates = List.rev !cap_routes in
  let rec find = function
    | [] -> None
    | r :: rest ->
        if r.meth <> meth then find rest
        else
          match try_match_segments parts r.segments with
          | Some params -> Some (r, params)
          | None -> find rest
  in
  find candidates

(* ── Route introspection ──────────────────────────────────────────── *)

(** List all registered routes as [(method, path, kind)] triples. *)
let list_routes ?(lv_endpoints = []) () =
  let seg_to_string = function Static s -> s | Param p -> ":" ^ p | Wildcard w -> "*" ^ w in
  let build_path segs = "/" ^ String.concat "/" (List.map seg_to_string segs) in
  let app_routes =
    List.rev_map (fun r ->
      let path = build_path r.segments in
      let kind =
        if List.mem ("/live" ^ path) lv_endpoints then "liveview"
        else "handler"
      in
      (r.meth, path, kind)
    ) !routes
  in
  let cap = List.rev_map (fun r ->
    (r.meth, build_path r.segments, "cap")
  ) !cap_routes in
  let wsr = List.rev_map (fun r ->
    ("WS", build_path r.ws_segments, "websocket")
  ) !ws_routes in
  app_routes @ cap @ wsr
