(** Shared types, response constructors, and request helpers for the well framework. *)

(* ── Request type ─────────────────────────────────────────────────── *)

(** An HTTP request with parsed method, path, headers, body, route params, and query string. *)
type request = {
  meth : string;
  path : string;
  headers : (string * string) list;
  body : string;
  params : (string * string) list;
  query : (string * string) list;
  session_id : string;
  _context : (int * Obj.t) list;
}

(* ── Response types ───────────────────────────────────────────────── *)

type stream_config = {
  stream_status : int;
  stream_content_type : string;
  stream_headers : (string * string) list;
  stream_fn : (string -> unit) -> unit;
}

(** Polymorphic variant response type. Superset of [Yojson.Safe.t] with HTML, text, redirect, streaming, and custom status/header variants. *)
type custom = {
  status : int option;
  headers : (string * string) list;
  body : response;
}

and response =
  [ `Null
  | `Bool of bool
  | `Int of int
  | `Float of float
  | `String of string
  | `Intlit of string
  | `List of Yojson.Safe.t list
  | `Assoc of (string * Yojson.Safe.t) list
  | `Html of unit Html.vdom
  | `Text of string
  | `Redirect of string
  | `Custom of custom
  | `Stream of stream_config
  ]

(** A server-side vdom node carried in a response. Instantiated at [unit]:
    server-rendered nodes never carry handlers, so ['msg] is always [unit] at
    the response boundary. MLX-produced ['a vdom] widens to this via covariance. *)
type html_node = unit Html.vdom

(** Request handler function type. *)
type handler = request -> response

(** Middleware function type. Wraps a handler, can modify request/response. *)
type middleware = handler -> handler

(** Static file mount definition. *)
type static_mount = { prefix : string; dir : string }

(** Resolved response ready for wire output. *)
type resolved = {
  r_status : int;
  r_headers : (string * string) list;
  r_body : string;
}

(* ── Response constructors ─────────────────────────────────────────── *)

(** Create an HTML response from a raw HTML string. The string is emitted
    verbatim; for escaping use [Html.txt] and the [Html] tag helpers. *)
let html s : response = (Html.raw s :> response)

(** Create a plain text response with [text/plain] content type. *)
let text s : response = `Text s

(** Create a JSON response from a [Yojson.Safe.t] value. *)
let json (j : Yojson.Safe.t) : response = (j :> response)

(** Create a 302 redirect response to the given URL. *)
let redirect url : response = `Redirect url

(** Create a streaming response with chunked transfer encoding. *)
let stream ?(content_type = "application/octet-stream") ?(status = 200)
    ?(headers = []) fn : response =
  `Stream { stream_status = status; stream_content_type = content_type;
            stream_headers = headers; stream_fn = fn }

(* ── Response transformers ─────────────────────────────────────────── *)

(** Set the HTTP status code on a response. Wraps in [`Custom] variant. Pipeable: [html s |> status 201]. *)
let status code (resp : response) : response =
  match resp with
  | `Custom c -> `Custom { c with status = Some code }
  | _ -> `Custom { status = Some code; headers = []; body = resp }

(** Add a response header. Pipeable: [html s |> header "X-Custom" "value"]. *)
let header name value (resp : response) : response =
  match resp with
  | `Custom c -> `Custom { c with headers = (name, value) :: c.headers }
  | _ -> `Custom { status = None; headers = [ (name, value) ]; body = resp }

(* ── Request helpers ───────────────────────────────────────────────── *)

(** Get a path parameter by name. Returns [None] if not found. *)
let param req key = List.assoc_opt key req.params

(** Get a query string parameter by name. Returns [None] if not found. *)
let query req key = List.assoc_opt key req.query

(* ── Response resolution ───────────────────────────────────────────── *)

(** Resolve a polymorphic variant response into status, headers, and body. *)
let rec resolve (resp : response) : resolved =
  match resp with
  | ( `Null | `Bool _ | `Int _ | `Float _ | `String _ | `Intlit _
    | `List _ | `Assoc _ ) as json ->
      { r_status = 200;
        r_headers = [ ("Content-Type", "application/json") ];
        r_body = Yojson.Safe.to_string (json :> Yojson.Safe.t) }
  | `Html v ->
      { r_status = 200;
        r_headers = [ ("Content-Type", "text/html; charset=utf-8") ];
        r_body = Html.element_to_string (`Html v) }
  | `Text s ->
      { r_status = 200;
        r_headers = [ ("Content-Type", "text/plain; charset=utf-8") ];
        r_body = s }
  | `Redirect url ->
      { r_status = 302;
        r_headers = [ ("Location", url) ];
        r_body = "" }
  | `Custom c ->
      let inner = resolve c.body in
      let final_status =
        match c.status with Some s -> s | None -> inner.r_status
      in
      let outer_keys =
        List.map (fun (k, _) -> String.lowercase_ascii k) c.headers
      in
      let filtered_inner =
        List.filter
          (fun (k, _) ->
            not (List.mem (String.lowercase_ascii k) outer_keys))
          inner.r_headers
      in
      { r_status = final_status;
        r_headers = c.headers @ filtered_inner;
        r_body = inner.r_body }
  | `Stream cfg ->
      { r_status = cfg.stream_status;
        r_headers = [ ("Content-Type", cfg.stream_content_type) ];
        r_body = "" }

(** Get the HTTP status code from a response without full resolution. *)
let rec response_status (resp : response) : int =
  match resp with
  | `Custom c ->
      (match c.status with Some s -> s | None -> response_status c.body)
  | `Redirect _ -> 302
  | `Stream cfg -> cfg.stream_status
  | _ -> 200

(** Extract a stream config from a response, unwrapping [`Custom] wrappers. *)
let rec extract_stream (resp : response) =
  match resp with
  | `Stream cfg -> Some (cfg, [])
  | `Custom c ->
      (match extract_stream c.body with
       | Some (cfg, inner_hdrs) ->
           let merged_status =
             match c.status with
             | Some s -> { cfg with stream_status = s }
             | None -> cfg
           in
           Some (merged_status, c.headers @ inner_hdrs)
       | None -> None)
  | _ -> None

(* ── Context functor ─────────────────────────────────────────────── *)

open struct
  let _next_context_id = ref 0
end

module type CONTEXT = sig
  type t
  val empty : t
end

(** Type-safe request context functor. Create a typed slot on the request for passing data through middleware. *)
module Context (C : CONTEXT) : sig
  val get : request -> C.t
  val set : C.t -> request -> request
  val update : (C.t -> C.t) -> request -> request
end = struct
  let key_id = incr _next_context_id; !_next_context_id

  let get req =
    match List.assoc_opt key_id req._context with
    | Some v -> (Obj.obj v : C.t)
    | None -> C.empty

  let set ctx req =
    { req with _context =
        (key_id, Obj.repr ctx) ::
        (List.filter (fun (k, _) -> k <> key_id) req._context) }

  let update f req = set (f (get req)) req
end

(** Apply a list of middlewares to a handler (right fold). *)
let apply_middlewares middlewares handler =
  List.fold_right (fun mw h -> mw h) middlewares handler
