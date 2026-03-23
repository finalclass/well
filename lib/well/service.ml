(* Service — Concurrent, stateless RPC dispatch with fiber-per-request *)

(* ── Types ─────────────────────────────────────────────────────────── *)

type param_info = { pname : string; ptype : string; poptional : bool }
type rpc_info = { rname : string; params : param_info list; returns : param_info list; returns_name : string }

type spec = {
  name : string;
  handler : string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t;
  set_ref : (string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t) -> unit;
  rpcs : rpc_info list;
}

(* ── Unified dispatch table ───────────────────────────────────────── *)
(* Both Service (direct) and Actor (via mailbox) register here.
   HTTP routes, socket, health — all dispatch through this table. *)

type handler_entry = {
  dispatch : string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t;
  rpcs : rpc_info list;
  kind : [ `Service | `Actor ];
}

let handlers : (string, handler_entry) Hashtbl.t = Hashtbl.create 8
let exposed_services : string list ref = ref []

(* Forward ref — set by well.ml
   Takes: POST path, handler (request -> response_json_string) *)
let _register_post_json :
  (string -> (Types.request -> string) -> unit) ref =
  ref (fun _path _handler -> ())

(* Forward ref — set by well.ml, builds rpc_ctx JSON from request *)
let _build_rpc_ctx : (Types.request -> Yojson.Safe.t) ref =
  ref (fun _ -> `Null)

let _cast_sw : Eio.Switch.t option ref = ref None

(* Forward ref — ws rate limit (messages per second), set by well.ml *)
let _ws_rate_limit : float ref = ref 100.0

(* ── Registration (at module init time) ──────────────────────────── *)

let pending_specs : spec list ref = ref []

let register spec =
  pending_specs := spec :: !pending_specs

let expose name =
  exposed_services := name :: !exposed_services

(* Register a handler entry — used by both Service and Actor *)
let register_handler name entry =
  Hashtbl.replace handlers name entry

(* ── Dispatch ─────────────────────────────────────────────────────── *)

let dispatch_by_name name rpc ctx payload =
  match Hashtbl.find_opt handlers name with
  | None -> `Assoc [("error", `String (name ^ " is not registered"))]
  | Some entry -> entry.dispatch rpc ctx payload

(* ── Expose service over HTTP ─────────────────────────────────────── *)

let pascal_to_kebab s =
  let buf = Buffer.create (String.length s + 4) in
  String.iteri (fun i c ->
    if Char.uppercase_ascii c = c && Char.lowercase_ascii c <> c then begin
      if i > 0 then Buffer.add_char buf '-';
      Buffer.add_char buf (Char.lowercase_ascii c)
    end else
      Buffer.add_char buf c
  ) s;
  Buffer.contents buf

let expose_http_routes () =
  List.iter (fun name ->
    match Hashtbl.find_opt handlers name with
    | None ->
      Log.log ~level:"warn" "cannot expose service '%s' — not registered" name
    | Some entry ->
      let kebab_name = pascal_to_kebab name in
      List.iter (fun (rpc : rpc_info) ->
        let path = Printf.sprintf "/%s/rpc/%s" kebab_name rpc.rname in
        !_register_post_json path (fun req ->
          let ctx = !_build_rpc_ctx req in
          let payload =
            if req.body = "" then `Null
            else Yojson.Safe.from_string req.body
          in
          let result = dispatch_by_name name rpc.rname ctx payload in
          Yojson.Safe.to_string result)
      ) entry.rpcs
  ) !exposed_services

(* ── Start all services (called by Well.run) ──────────────────────── *)

let start_all ~sw:_ =
  let specs = List.rev !pending_specs in
  pending_specs := [];
  List.iter (fun spec ->
    let entry = {
      dispatch = (fun rpc ctx payload ->
        try spec.handler rpc ctx payload
        with exn ->
          Log.log ~level:"error" "service %s rpc %s error: %s"
            spec.name rpc (Printexc.to_string exn);
          `Assoc [("error", `String (Printexc.to_string exn))]);
      rpcs = spec.rpcs;
      kind = `Service;
    } in
    register_handler spec.name entry;
    spec.set_ref (dispatch_by_name spec.name)
  ) specs;
  expose_http_routes ()

(* ── Health ────────────────────────────────────────────────────────── *)

let health () =
  let result = ref [] in
  Hashtbl.iter (fun name entry ->
    let st = match entry.kind with
      | `Service -> "running"
      | `Actor -> "running"  (* Actor overrides via actor_health *)
    in
    result := (name, st) :: !result
  ) handlers;
  List.sort (fun (a, _) (b, _) -> String.compare a b) !result

(* Actor can override health entries *)
let _actor_health : (unit -> (string * string) list) ref = ref (fun () -> [])

let full_health () =
  let base = health () in
  let actor_statuses = !_actor_health () in
  (* Override base health with actor-specific statuses *)
  List.map (fun (name, base_st) ->
    match List.assoc_opt name actor_statuses with
    | Some st -> (name, st)
    | None -> (name, base_st)
  ) base

(* ── Unix socket transport (local IPC) ────────────────────────────── *)

let list_services () =
  let result = ref [] in
  Hashtbl.iter (fun name entry ->
    let rpc_names = List.map (fun (r : rpc_info) -> r.rname) entry.rpcs in
    result := (name, rpc_names) :: !result
  ) handlers;
  List.sort (fun (a, _) (b, _) -> String.compare a b) !result

let describe_services () =
  let result = ref [] in
  Hashtbl.iter (fun name entry ->
    let rpcs_json = `Assoc (List.map (fun (rpc : rpc_info) ->
      let param_to_json p =
        `Assoc [("name", `String p.pname);
                ("type", `String p.ptype);
                ("optional", `Bool p.poptional)]
      in
      (rpc.rname, `Assoc [
        ("params", `List (List.map param_to_json rpc.params));
        ("returns", `List (List.map param_to_json rpc.returns));
        ("returns_name", `String rpc.returns_name)])
    ) entry.rpcs) in
    result := (name, rpcs_json) :: !result
  ) handlers;
  `Assoc (List.sort (fun (a, _) (b, _) -> String.compare a b) !result)

let handle_socket_line line =
  try
    let json = Yojson.Safe.from_string line in
    let service = match json with
      | `Assoc l -> (match List.assoc_opt "service" l with
          | Some (`String s) -> s | _ -> "")
      | _ -> ""
    in
    let rpc = match json with
      | `Assoc l -> (match List.assoc_opt "rpc" l with
          | Some (`String s) -> s | _ -> "")
      | _ -> ""
    in
    let payload = match json with
      | `Assoc l -> (match List.assoc_opt "payload" l with
          | Some p -> p | None -> `Null)
      | _ -> `Null
    in
    if service = "_system" && rpc = "db_diff" then
      let db_path = match payload with
        | `String s -> s
        | _ -> "data/app.sqlite"
      in
      (* Restrict to paths under data/ to prevent information disclosure *)
      let safe_path =
        String.length db_path >= 5
        && String.sub db_path 0 5 = "data/"
        && not (String.contains db_path '\000')
        && (let decoded = db_path in
            let segs = String.split_on_char '/' decoded in
            not (List.exists (fun s -> s = ".." || s = ".") segs))
      in
      if not safe_path then
        Yojson.Safe.to_string (`Assoc [("error", `String "invalid db path")])
      else
      let db = Sqlite3.db_open db_path in
      let entries = Db.diff db in
      ignore (Sqlite3.db_close db);
      let result = `List (List.map Db.diff_entry_to_json entries) in
      Yojson.Safe.to_string (`Assoc [("result", result)])
    else if service = "_system" && rpc = "describe" then
      let result = describe_services () in
      Yojson.Safe.to_string (`Assoc [("result", result)])
    else if service = "_system" && rpc = "list" then
      let services = list_services () in
      let result = `Assoc (List.map (fun (name, rpcs) ->
        (name, `List (List.map (fun r -> `String r) rpcs))
      ) services) in
      Yojson.Safe.to_string (`Assoc [("result", result)])
    else if service = "_system" && rpc = "health" then
      let statuses = full_health () in
      let result = `Assoc (List.map (fun (name, st) ->
        (name, `String st)
      ) statuses) in
      Yojson.Safe.to_string (`Assoc [("result", result)])
    else
      let result = dispatch_by_name service rpc `Null payload in
      Yojson.Safe.to_string (`Assoc [("result", result)])
  with exn ->
    Yojson.Safe.to_string
      (`Assoc [("error", `String (Printexc.to_string exn))])

let handle_socket_client flow _addr =
  let reader = Eio.Buf_read.of_flow ~max_size:(10 * 1024 * 1024) flow in
  (try
     while true do
       let line = Eio.Buf_read.line reader in
       let line =
         if String.length line > 0 && line.[String.length line - 1] = '\r'
         then String.sub line 0 (String.length line - 1)
         else line
       in
       if line <> "" then begin
         let response = handle_socket_line line in
         Eio.Flow.copy_string (response ^ "\n") flow
       end
     done
   with
   | End_of_file | Eio.Io _ -> ());
  Eio.Flow.close flow

let start_socket ~sw ~net path =
  (try Unix.unlink path with Unix.Unix_error _ -> ());
  let socket = Eio.Net.listen net ~sw ~backlog:16 ~reuse_addr:true
    (`Unix path) in
  Unix.chmod path 0o770;
  Log.log "socket on %s" path;
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect ~finally:(fun () ->
      try Unix.unlink path with Unix.Unix_error _ -> ())
    (fun () ->
      let rec accept_loop () =
        Eio.Net.accept_fork socket ~sw
          ~on_error:(fun exn ->
            match exn with
            | Eio.Cancel.Cancelled _ -> ()
            | _ ->
              Log.log ~level:"error" "socket error: %s"
                (Printexc.to_string exn))
          handle_socket_client;
        accept_loop ()
      in
      try accept_loop ()
      with Eio.Cancel.Cancelled _ -> ()))

(* ── Cast (fire-and-forget) ──────────────────────────────────────── *)

let cast f =
  match !_cast_sw with
  | Some sw ->
    Eio.Fiber.fork ~sw (fun () ->
      try f ()
      with exn ->
        Log.log ~level:"error" "cast error: %s" (Printexc.to_string exn))
  | None ->
    Log.log ~level:"warn" "cast called outside Well.run";
    f ()
