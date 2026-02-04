(* Blossom - EIO-based HTTP framework *)
open Base
open Cohttp_eio

(* Raw request - used to build user's custom request type *)
module Raw = struct
  type t =
    { req: Http.Request.t
    ; body: Cohttp_eio.Body.t
    ; socket: Server.conn  [@warning "-69"]
    ; params: (string, string) Hashtbl.t
    ; env: Eio_unix.Stdenv.base  [@warning "-69"]
    ; sw: Eio.Switch.t  [@warning "-69"] }

  let read_cookies (req : t) : (string, string) List.Assoc.t =
    req.req
    |> Http.Request.headers
    |> (fun h -> Http.Header.get h "cookie")
    |> Option.value ~default:""
    |> String.split ~on:';'
    |> List.filter ~f:(fun s -> String.contains s '=')
    |> List.map ~f:(fun s -> String.strip s)
    |> List.map ~f:(fun s -> String.split s ~on:'=')
    |> List.map ~f:(fun l -> (List.hd_exn l, List.nth_exn l 1))

  let param (req : t) (key : string) : string =
    Hashtbl.find req.params key |> Option.value ~default:""

  let query (req : t) (key : string) : string option =
    let resource = Http.Request.resource req.req in
    let uri = Uri.of_string resource in
    Uri.get_query_param uri key

  let header (req : t) (key : string) : string option =
    req.req
    |> Http.Request.headers
    |> (fun h -> Http.Header.get h key)
end

(* Response body - polymorphic variant for automatic content-type detection *)
type response_body =
  [ `Html of string
  | `Text of string
  | `Redirect of string
  | `Status of int * response_body
  | `Headers of (string * string) list * response_body
  | Yojson.Safe.t
  ]

(* Helper functions for setting status and headers *)
let status code (body : [< response_body]) : response_body = `Status (code, (body :> response_body))
let headers hdrs (body : [< response_body]) : response_body = `Headers (hdrs, (body :> response_body))

(* Body parsing utilities *)
module Body = struct
  type t = (string * string list) list

  let parse_json (req : Raw.t) =
    try Ok (req.body |> Eio.Flow.read_all |> Yojson.Safe.from_string) with
    | Yojson.Json_error err -> Error err

  let parse_body (req : Raw.t) =
    req.body |> Eio.Flow.read_all |> Uri.query_of_encoded

  let get_strings (body : t) (key : string) : string list =
    body
    |> List.filter ~f:(fun (k, _) -> String.equal k key)
    |> List.fold ~init:[] ~f:(fun acc (_, vals) -> acc @ vals)

  let get_string (body : t) (key : string) : string =
    get_strings body key |> List.hd |> Option.value ~default:""
end

(* Internal route types *)
type 'req route_handler = 'req -> response_body

module Part = struct
  type t = Static of string | Dynamic of string
end

module Route = struct
  type 'req t =
    { meth: Http.Method.t
    ; handler: 'req route_handler
    ; path_split: Part.t list }

  let build_path_split path =
    String.split path ~on:'/'
    |> List.map ~f:(fun part ->
        if String.length part > 0 && Char.equal (String.get part 0) ':'
        then Part.Dynamic (String.sub part ~pos:1 ~len:(String.length part - 1))
        else Part.Static part)

  let build meth path handler = {meth; handler; path_split= build_path_split path}

  let is_matching meth path route =
    let split = String.split path ~on:'/' in
    if not Http.Method.(String.equal (to_string meth) (to_string route.meth))
    then false
    else
      match List.for_all2 split route.path_split ~f:(fun s p ->
          match p with Part.Static x -> String.equal x s | Part.Dynamic _ -> true)
      with Ok b -> b | Unequal_lengths -> false

  let to_args r path =
    let split = String.split path ~on:'/' in
    let args = Hashtbl.create ~growth_allowed:true ~size:0 (module String) in
    let _ = List.fold2 split r.path_split ~init:args ~f:(fun acc s p ->
        match p with
        | Part.Static _ -> acc
        | Part.Dynamic name -> Hashtbl.add_exn acc ~key:name ~data:s; acc)
    in args
end

(* Blossom application *)
type 'req t =
  { routes: 'req Route.t list
  ; make_req: Raw.t -> 'req }

(* Private internals *)
open struct
  module Response = struct
    type raw = Server.response
    type t = { headers: (string * string) list; status: int; body: [`String of string] }

    let make = {headers= []; status= 200; body= `String ""}
    let status code resp = {resp with status= code}

    (* Replace existing header if present, otherwise add *)
    let header name value resp =
      let headers = List.filter resp.headers ~f:(fun (k, _) ->
          not (String.Caseless.equal k name)) in
      {resp with headers= (name, value) :: headers}

    let set_string_body str resp = {resp with body= `String str}

    let send resp =
      Cohttp_eio.Server.respond
        ~status:(`Code resp.status)
        ~headers:(Http.Header.of_list resp.headers)
        ~body:(Cohttp_eio.Body.of_string (match resp.body with `String b -> b))
        ()
  end

  let send_body (body : response_body) : Response.raw =
    let rec collect ~status_code ~hdrs body =
      match body with
      | `Status (code, inner) -> collect ~status_code:(Some code) ~hdrs inner
      | `Headers (h, inner) -> collect ~status_code ~hdrs:(h @ hdrs) inner
      | other -> (status_code, hdrs, other)
    in
    let (status_code, extra_headers, inner_body) = collect ~status_code:None ~hdrs:[] body in
    let base = Response.make in
    let base = match status_code with Some c -> Response.status c base | None -> base in
    let base = List.fold extra_headers ~init:base ~f:(fun r (k, v) -> Response.header k v r) in

    (* Check if content-type is already set in extra_headers *)
    let has_content_type = List.exists extra_headers ~f:(fun (k, _) ->
        String.Caseless.equal k "content-type") in

    match inner_body with
    | `Html html ->
        let resp = if has_content_type then base else Response.header "content-type" "text/html" base in
        resp |> Response.set_string_body html |> Response.send
    | `Text text ->
        let resp = if has_content_type then base else Response.header "content-type" "text/plain" base in
        resp |> Response.set_string_body text |> Response.send
    | `Redirect url ->
        Cohttp_eio.Server.respond
          ~status:(match status_code with Some c -> `Code c | None -> `Found)
          ~headers:(Http.Header.of_list (("location", url) :: extra_headers))
          ~body:(Cohttp_eio.Body.of_string "") ()
    | `Null | `Bool _ | `Int _ | `Float _ | `String _ | `Assoc _ | `List _ | `Intlit _ as json ->
        base |> Response.header "content-type" "application/json"
        |> Response.set_string_body (Yojson.Safe.to_string json) |> Response.send
    | `Status _ | `Headers _ ->
        Cohttp_eio.Server.respond ~status:`Internal_server_error
          ~body:(Cohttp_eio.Body.of_string "Invalid response structure") ()

  let make_verb verb path handler app =
    let meth = Http.Method.of_string (String.uppercase verb) in
    {app with routes= Route.build meth path handler :: app.routes}

  let request_handler ~app ~env ~sw socket request body =
    let resource = Http.Request.resource request in
    let resource = match String.rsplit2 resource ~on:'?' with None -> resource | Some (l, _) -> l in
    let meth = Http.Request.meth request in
    match List.find app.routes ~f:(fun r -> Route.is_matching meth resource r) with
    | None -> Cohttp_eio.Server.respond ~status:`Not_found ~body:(Cohttp_eio.Body.of_string "Not found") ()
    | Some r ->
        let raw : Raw.t = {body; req= request; socket; params= Route.to_args r resource; env; sw} in
        send_body (r.handler (app.make_req raw))
end

(* Public API *)
let create make_req = {routes= []; make_req}

let get path handler app =
  make_verb "get" path (fun req -> (handler req :> response_body)) app

let post path handler app =
  make_verb "post" path (fun req -> (handler req :> response_body)) app

let put path handler app =
  make_verb "put" path (fun req -> (handler req :> response_body)) app

let delete path handler app =
  make_verb "delete" path (fun req -> (handler req :> response_body)) app

let listen_unix ~socket_path ~env ~sw app =
  (try Unix.unlink socket_path with Unix.Unix_error _ -> ());
  let socket = Eio.Net.listen env#net ~sw ~backlog:128 ~reuse_addr:true (`Unix socket_path) in
  let server = Cohttp_eio.Server.make
      ~callback:(fun conn req body ->
        try request_handler ~app ~env ~sw conn req body with exn ->
          let open Stdlib in
          Printf.printf "Exception: %s\n%s\n" (Printexc.to_string exn) (Printexc.get_backtrace ());
          Cohttp_eio.Server.respond ~status:`Internal_server_error
            ~body:(Cohttp_eio.Body.of_string "Internal Server Error") ())
      ()
  in
  Stdlib.print_endline ("GatewayClientV2 listening on: " ^ socket_path);
  Unix.chmod socket_path 0o777;
  Cohttp_eio.Server.run socket server ~on_error:raise
