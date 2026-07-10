(** Well -- full-stack OCaml web framework. HTTP server, routing, middleware, sessions, and more. *)

let version = "1.3.0"

(* ── Types ─────────────────────────────────────────────────────────── *)

include Types

(* ── Re-exports: Routing ─────────────────────────────────────────── *)

(** Register a global middleware applied to all routes. *)
let use = Router.use

(** Mount a directory for static file serving at the given URL prefix. *)
let static = Router.static

(** Group routes under a shared URL prefix with optional scoped middleware. *)
let scope = Router.scope

(** Register a GET route handler. Path supports [:param] segments and [*wildcard]. *)
let get = Router.get

(** Register a POST route handler. *)
let post = Router.post

(** Register a PUT route handler. *)
let put = Router.put

(** Register a DELETE route handler. *)
let delete = Router.delete

(** Register a WebSocket route handler. *)
let ws = Router.ws

(** Declarative admin registries backed by SQLite. *)
module Registry = Registry

(* ── Re-exports: Middleware ──────────────────────────────────────── *)

(** Request logging middleware. Logs method, path, status, and latency. *)
let logger = Middleware.logger

(** CORS middleware. Configurable allowed origins, methods, headers, and max age. *)
let cors = Middleware.cors

(** CSRF protection middleware. Validates tokens on state-changing requests. *)
let csrf = Middleware.csrf

(** Get the CSRF token for the current request. *)
let csrf_token = Middleware.csrf_token

(** Rate limiting middleware. Limits requests per client IP within a sliding time window. *)
let rate_limit = Middleware.rate_limit

(** Get the current user ID from the session. Returns [None] if not authenticated. *)
let current_user = Middleware.current_user

(** Authentication middleware. Redirects unauthenticated users to [login_path]. *)
let require_auth = Middleware.require_auth

(** HTTP Basic Auth middleware. *)
let basic_auth = Middleware.basic_auth

(** Host whitelist middleware. *)
let allowed_hosts = Middleware.allowed_hosts

(** Security headers middleware. *)
let secure_headers = Middleware.secure_headers

(** Enable or disable dev mode. When enabled, error pages show backtraces and request details. *)
let dev_mode = Middleware.dev_mode

(** Set a custom error handler invoked when a route handler raises an exception. *)
let on_error = Middleware.on_error

(** Error handler middleware. Catches exceptions and renders error pages. *)
let error_handler = Middleware.error_handler

(* ── Re-exports: URL ─────────────────────────────────────────────── *)

(** URL-encode (percent-encode) a string. *)
let url_encode = Url.encode

(** Decode a URL-encoded (percent-encoded) string. *)
let url_decode = Url.decode

(** Map a file extension (without dot) to its MIME type. *)
let ext_to_mime = Url.ext_to_mime

(** Map a MIME type to its canonical file extension. *)
let mime_to_ext = Url.mime_to_ext

(** Check whether a URL path is safe (no traversal or null bytes). *)
let is_safe_path = Url.is_safe_path

(** Parse an HTTP Range header. Returns [Some (start, end)] or [None]. *)
let parse_range_header = Static_serve.parse_range_header

(* ── Re-exports: Fetch ───────────────────────────────────────────── *)

(** HTTP client response from [fetch]. *)
type fetch_response = Fetch.fetch_response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

(** Make an HTTP request. Supports HTTP and HTTPS with system CA certificates. Must be called within [Well.run]. *)
let fetch = Fetch.fetch

(** Make an HTTP request with an explicit [net] handle. Does not require [Well.run]. *)
let fetch_with_net = Fetch.fetch_with_net

(** Make a streaming HTTP request with an explicit [net] handle. Body delivered via callback. *)
let fetch_stream_with_net = Fetch.fetch_stream_with_net

(* ── Re-exports: Channel ─────────────────────────────────────────── *)

(** Result of a successful channel join: topics to subscribe and optional initial state. *)
type join_result = Channel.join_result = {
  subscribe : string list;
  initial_state : Yojson.Safe.t option;
}

(** Result of a push handler: optional reply to sender and optional broadcast. *)
type push_result = Channel.push_result = {
  reply : Yojson.Safe.t option;
  broadcast : (string * Yojson.Safe.t) option;
}

(** Register a channel with a topic pattern and join authorization callback. *)
let channel = Channel.channel

(* Wire up LiveView + Channel WS route registration *)
let () = Liveview._register_ws_route := Router.ws
let () = Channel._register_ws_route := Router.ws

(* ── Session config ───────────────────────────────────────────────── *)

let _session_lifetime = ref 86400.0

(* ── Session cookie ───────────────────────────────────────────────── *)

open struct
  let generate_session_id () =
    let bytes = Mirage_crypto_rng.generate 32 in
    let buf = Buffer.create 64 in
    String.iter (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) bytes;
    Buffer.contents buf

  let parse_session_id headers =
    match List.assoc_opt "cookie" headers with
    | None -> None
    | Some cookie_str ->
        let cookies = String.split_on_char ';' cookie_str in
        List.find_map
          (fun cookie ->
            let cookie = String.trim cookie in
            match String.index_opt cookie '=' with
            | None -> None
            | Some i ->
                let k = String.sub cookie 0 i in
                let v = String.sub cookie (i + 1) (String.length cookie - i - 1) in
                if k = "well_session" then Some v else None)
          cookies
end

(* ── Flash context ───────────────────────────────────────────────── *)

module Flash_ctx = Context(struct
  type t = (string * string) list
  let empty = []
end)

(* ── Session middleware ───────────────────────────────────────────── *)

let _tls_active = ref false
let _flash_prefix = "_flash:"

open struct
  let parse_session_id_from_header headers =
    match List.assoc_opt "authorization" headers with
    | Some auth_value ->
      let prefix = "Bearer " in
      let plen = String.length prefix in
      if String.length auth_value > plen
         && String.sub auth_value 0 plen = prefix then
        Some (String.sub auth_value plen (String.length auth_value - plen))
      else
        List.assoc_opt "x-session-id" headers
    | None ->
      List.assoc_opt "x-session-id" headers
end

let session_middleware : middleware = fun next req ->
  let existing =
    match parse_session_id req.headers with
    | Some _ as s -> s
    | None -> parse_session_id_from_header req.headers
  in
  let session_id, new_session =
    match existing with
    | Some sid -> (sid, false)
    | None -> (generate_session_id (), true)
  in
  let flash_entries =
    Session_store.get_all_with_prefix ~session_id ~prefix:_flash_prefix
  in
  if flash_entries <> [] then
    Session_store.delete_all_with_prefix ~session_id ~prefix:_flash_prefix;
  let req = Flash_ctx.set flash_entries { req with session_id } in
  let resp = next req in
  if new_session then
    let secure = if !_tls_active then "; Secure" else "" in
    let max_age = int_of_float !_session_lifetime in
    header "Set-Cookie"
      (Printf.sprintf "well_session=%s; HttpOnly; SameSite=Lax; Path=/; Max-Age=%d%s"
         session_id max_age secure)
      resp
  else resp

(* ── Session API ─────────────────────────────────────────────────── *)

(** Generate a cryptographically random session ID. *)
let generate_session_id () = generate_session_id ()

(** Programmatic session API. Use session IDs directly. *)
module Session = struct
  let create () = generate_session_id ()
  let get = Session_store.get
  let set = Session_store.set
  let delete = Session_store.delete
  let clear = Session_store.clear
  let get_all = Session_store.get_all
  let find_sessions = Session_store.find_sessions
  let delete_by_value = Session_store.delete_by_value
end

(** Set session lifetime in seconds. Default is 86400.0 (24 hours). *)
let session_lifetime seconds =
  if seconds < 0.0 then invalid_arg "Well.session_lifetime: must be non-negative";
  _session_lifetime := seconds

(* Wire Auth session forward refs *)
let () =
  Auth._session_get_ref := (fun sid key -> Session_store.get ~session_id:sid ~key);
  Auth._session_set_ref := (fun sid key value -> Session_store.set ~session_id:sid ~key ~value);
  Auth._session_delete_ref := (fun sid key -> Session_store.delete ~session_id:sid ~key)

let _session_regenerate_hook : (string -> string -> unit) ref = ref (fun _ _ -> ())

(** Regenerate the session ID for CSRF protection. Returns [(new_request, set_cookie_fn)]. *)
let session_regenerate req =
  let old_sid = req.session_id in
  let new_sid = generate_session_id () in
  Session_store.copy_and_delete ~old_session_id:old_sid ~new_session_id:new_sid;
  !_session_regenerate_hook old_sid new_sid;
  let new_req = { req with session_id = new_sid } in
  let secure = if !_tls_active then "; Secure" else "" in
  let max_age = int_of_float !_session_lifetime in
  let set_cookie resp =
    header "Set-Cookie"
      (Printf.sprintf "well_session=%s; HttpOnly; SameSite=Lax; Path=/; Max-Age=%d%s"
         new_sid max_age secure)
      resp
  in
  (new_req, set_cookie)

(* Wire session_regenerate to migrate CSRF tokens *)
let () = _session_regenerate_hook := Middleware.migrate_csrf_token

(* Wire OAuth route handler — uses session_regenerate for post-login *)
let () = Oauth._handle_get_ref := (fun path handler ->
  Router.get path (fun req ->
    match handler req with
    | Oauth.ORedirect url -> (`Redirect url :> response)
    | Oauth.OHtml (body, code) -> (status code (Html.raw body :> response) :> response)
    | Oauth.ORedirectWithRegenerate url ->
      let (_new_req, set_cookie) = session_regenerate req in
      (set_cookie (`Redirect url) :> response)))

(* ── RPC context ─────────────────────────────────────────────────── *)

(** RPC context for cross-service calls. Carries session, user, and locale information. *)
type rpc_ctx = {
  session_id : string;
  request_id : string;
  user_id : string option;
  user_name : string option;
  locale : string;
  session_data : (string * string) list;
}

let rpc_ctx_to_wire (ctx : rpc_ctx) : Yojson.Safe.t =
  `List [
    `String ctx.session_id;
    `String ctx.request_id;
    (match ctx.user_id with Some s -> `String s | None -> `Null);
    (match ctx.user_name with Some s -> `String s | None -> `Null);
    `String ctx.locale;
    `Assoc (List.map (fun (k, v) -> (k, `String v)) ctx.session_data);
  ]

let rpc_ctx_of_wire (wire : Yojson.Safe.t) : rpc_ctx =
  match wire with
  | `List [ sid; rid; uid; uname; loc ] ->
    { session_id = (match sid with `String s -> s | _ -> "");
      request_id = (match rid with `String s -> s | _ -> "");
      user_id = (match uid with `String s -> Some s | _ -> None);
      user_name = (match uname with `String s -> Some s | _ -> None);
      locale = (match loc with `String s -> s | _ -> "en");
      session_data = [];
    }
  | `List ( sid :: rid :: uid :: uname :: loc :: rest ) ->
    let session_data = match rest with
      | `Assoc pairs :: _ ->
        List.filter_map (fun (k, v) ->
          match v with `String s -> Some (k, s) | _ -> None) pairs
      | _ -> []
    in
    { session_id = (match sid with `String s -> s | _ -> "");
      request_id = (match rid with `String s -> s | _ -> "");
      user_id = (match uid with `String s -> Some s | _ -> None);
      user_name = (match uname with `String s -> Some s | _ -> None);
      locale = (match loc with `String s -> s | _ -> "en");
      session_data;
    }
  | _ ->
    { session_id = ""; request_id = ""; user_id = None;
      user_name = None; locale = "en"; session_data = [] }

let _rpc_request_id_counter = ref 0

(** Build an RPC context from the current HTTP request, including session data and locale. *)
let rpc_ctx (req : request) : rpc_ctx =
  incr _rpc_request_id_counter;
  let request_id =
    Printf.sprintf "%s-%d-%f" req.session_id !_rpc_request_id_counter
      (Unix.gettimeofday ())
    |> Digestif.SHA1.(fun s -> digest_string s |> to_hex)
  in
  let all_data = Session_store.get_all ~session_id:req.session_id in
  let user_id = List.assoc_opt "user_id" all_data in
  let user_name = List.assoc_opt "user_name" all_data in
  let locale =
    match List.assoc_opt "locale" all_data with
    | Some l -> l
    | None ->
      match List.assoc_opt "accept-language" req.headers with
      | Some v ->
        (match String.split_on_char ',' v with
         | lang :: _ ->
           let lang = String.trim lang in
           (match String.index_opt lang ';' with
            | Some i -> String.sub lang 0 i
            | None -> lang)
         | [] -> "en")
      | None -> "en"
  in
  let session_data = List.filter (fun (k, _) ->
    not (String.length k > 7 && String.sub k 0 7 = "_flash:")) all_data
  in
  { session_id = req.session_id; request_id; user_id; user_name; locale; session_data }

(* ── Flash API ───────────────────────────────────────────────────── *)

(** Store a flash message in the session. Available on the next request only. *)
let put_flash (req : request) kind message =
  Session_store.set ~session_id:req.session_id
    ~key:(_flash_prefix ^ kind) ~value:message

(** Retrieve a flash message by kind. Returns [None] if not set. *)
let get_flash req kind =
  let key = _flash_prefix ^ kind in
  let entries = Flash_ctx.get req in
  List.assoc_opt key entries

(* ── Query string parsing ──────────────────────────────────────────── *)

let parse_query path =
  match String.index_opt path '?' with
  | None -> []
  | Some i ->
      let qs = String.sub path (i + 1) (String.length path - i - 1) in
      String.split_on_char '&' qs
      |> List.filter_map (fun pair ->
             match String.index_opt pair '=' with
             | None ->
                 if pair <> "" then Some (pair, "") else None
             | Some j ->
                 let k = String.sub pair 0 j in
                 let v =
                   String.sub pair (j + 1)
                     (String.length pair - j - 1)
                 in
                 Some (k, v))

(* ── Body size config ─────────────────────────────────────────────── *)

let _max_body_size = ref (10 * 1024 * 1024)

(** Set the maximum request body size in bytes. Default is 10 MB. *)
let max_body_size n =
  if n < 0 then invalid_arg "Well.max_body_size: must be non-negative";
  _max_body_size := n

exception Body_too_large = Http_parse.Body_too_large

(* ── Multipart parsing (delegated to Multipart module) ────────────── *)

type uploaded_file = Multipart.uploaded_file = {
  filename : string;
  content_type : string;
  size : int;
  data : string;
}

type multipart_data = Multipart.multipart_data = {
  fields : (string * string) list;
  files : (string * uploaded_file) list;
}

module Multipart_ctx = Context(struct
  type t = multipart_data option
  let empty = None
end)

(** Parse multipart form data from the request. Cached after first call. *)
let get_multipart req =
  match Multipart_ctx.get req with
  | Some d -> d
  | None ->
      match List.assoc_opt "content-type" req.headers with
      | Some ct ->
          (match Multipart.extract_boundary ct with
           | Some b -> Multipart.parse b req.body
           | None -> { fields = []; files = [] })
      | None -> { fields = []; files = [] }

(** Get a single uploaded file by form field name. Returns [None] if not found. *)
let file req name =
  let data = get_multipart req in
  List.assoc_opt name data.files

(** Get all uploaded files with the given form field name. *)
let files req name =
  let data = get_multipart req in
  List.filter_map
    (fun (k, v) -> if k = name then Some v else None)
    data.files

(** Get all uploaded files from the request as [(name, file)] pairs. *)
let all_files req =
  let data = get_multipart req in
  data.files

(* ── Form body parsing ────────────────────────────────────────────── *)

open struct
  let parse_urlencoded body =
    String.split_on_char '&' body
    |> List.filter_map (fun pair ->
           match String.index_opt pair '=' with
           | None ->
               if pair <> "" then Some (Url.decode pair, "") else None
           | Some j ->
               let k = String.sub pair 0 j in
               let v =
                 String.sub pair (j + 1) (String.length pair - j - 1)
               in
               Some (Url.decode k, Url.decode v))
end

(** Get all form parameters as [(key, value)] pairs. Handles both URL-encoded and multipart forms. *)
let form_params (req : request) =
  if Multipart.is_multipart req.headers then
    let data =
      match Multipart_ctx.get req with
      | Some d -> d
      | None ->
          match List.assoc_opt "content-type" req.headers with
          | Some ct ->
              (match Multipart.extract_boundary ct with
               | Some b -> Multipart.parse b req.body
               | None -> { fields = []; files = [] })
          | None -> { fields = []; files = [] }
    in
    data.fields
  else
    parse_urlencoded req.body

(** Get a form field value by name. Returns [None] if not found. *)
let form req key = List.assoc_opt key (form_params req)

(** Extract the boundary string from a multipart/form-data Content-Type header. *)
let extract_boundary = Multipart.extract_boundary

(** Parse a multipart/form-data body given the boundary string. *)
let parse_multipart = Multipart.parse

(* Wire middleware form_params forward ref *)
let () = Middleware._form_params_fn := form_params

(* ── HTTP parsing & writing (delegated to Http_parse module) ──────── *)

exception Headers_too_large = Http_parse.Headers_too_large

let parse_request_line = Http_parse.parse_request_line
let parse_headers = Http_parse.parse_headers
let read_body reader headers = Http_parse.read_body ~max_body_size:!_max_body_size reader headers
let write_response = Http_parse.write_response
let write_stream_response = Http_parse.write_stream_response

(* ── Request ID ───────────────────────────────────────────────────── *)

let _request_id_counter = Atomic.make 0

let generate_request_id () =
  let n = Atomic.fetch_and_add _request_id_counter 1 in
  let t = int_of_float (Unix.gettimeofday () *. 1000.0) in
  Printf.sprintf "%08x%08x" (t land 0xFFFFFFFF) (n land 0xFFFFFFFF)

(** Get the unique request ID from the [X-Request-ID] header. Returns [""] if not set. *)
let request_id (req : request) =
  match List.assoc_opt "x-request-id" req.headers with
  | Some id -> id
  | None -> ""

(* ── Connection config (with validation) ─────────────────────────── *)

exception Keep_alive_timeout

let _with_ka_timeout t f = Env.with_timeout t f
let _keep_alive_timeout = ref 5.0
let _request_timeout = ref 30.0

(** Set the keep-alive timeout in seconds between requests on the same connection. Default is 5.0. *)
let keep_alive_timeout n =
  if n < 0.0 then invalid_arg "Well.keep_alive_timeout: must be non-negative";
  _keep_alive_timeout := n

(** Set the request processing timeout in seconds. Default is 30.0. *)
let request_timeout n =
  if n < 0.0 then invalid_arg "Well.request_timeout: must be non-negative";
  _request_timeout := n

let _ws_rate_limit = ref 100.0

(** Set the WebSocket message rate limit (messages per second). Default is 100. *)
let ws_rate_limit n =
  if n <= 0.0 then invalid_arg "Well.ws_rate_limit: must be positive";
  _ws_rate_limit := n

(** Set the maximum WebSocket frame size in bytes. *)
let ws_max_frame_size n =
  if n < 1 then invalid_arg "Well.ws_max_frame_size: must be positive";
  Websocket._max_frame_size := n

(** Set the maximum LiveView file upload size in bytes. *)
let max_upload_size n =
  if n < 0 then invalid_arg "Well.max_upload_size: must be non-negative";
  Liveview._max_upload_size := n

(* ── Connection limits ────────────────────────────────────────────── *)

let _max_connections = ref 10_000
let _max_connections_per_ip = ref 100
let _max_requests_per_connection = ref 1_000

(** Set the maximum number of concurrent connections. Default is 10,000. *)
let max_connections n =
  if n < 1 then invalid_arg "Well.max_connections: must be positive";
  _max_connections := n

(** Set the maximum number of concurrent connections per IP address. Default is 100. *)
let max_connections_per_ip n =
  if n < 1 then invalid_arg "Well.max_connections_per_ip: must be positive";
  _max_connections_per_ip := n

(** Set the maximum number of requests per keep-alive connection. Default is 1,000. *)
let max_requests_per_connection n =
  if n < 1 then invalid_arg "Well.max_requests_per_connection: must be positive";
  _max_requests_per_connection := n

let _conn_count = Atomic.make 0
let _ip_conn_store : (string, int) Hashtbl.t = Hashtbl.create 256
let _ip_conn_mu = Mutex.create ()

let ip_of_addr addr =
  match addr with
  | `Tcp (ip, _port) -> Eio.Net.Ipaddr.pp Format.str_formatter ip; Format.flush_str_formatter ()
  | _ -> "unknown"

let conn_acquire ip =
  if Atomic.get _conn_count >= !_max_connections then false
  else begin
    Mutex.lock _ip_conn_mu;
    let allowed = Fun.protect ~finally:(fun () -> Mutex.unlock _ip_conn_mu) (fun () ->
      let cur = match Hashtbl.find_opt _ip_conn_store ip with Some n -> n | None -> 0 in
      if cur >= !_max_connections_per_ip then false
      else begin
        Hashtbl.replace _ip_conn_store ip (cur + 1);
        true
      end)
    in
    if allowed then (ignore (Atomic.fetch_and_add _conn_count 1); true)
    else false
  end

let conn_release ip =
  ignore (Atomic.fetch_and_add _conn_count (-1));
  Mutex.lock _ip_conn_mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock _ip_conn_mu) (fun () ->
    match Hashtbl.find_opt _ip_conn_store ip with
    | Some n when n <= 1 -> Hashtbl.remove _ip_conn_store ip
    | Some n -> Hashtbl.replace _ip_conn_store ip (n - 1)
    | None -> ())

(* ── Periodic tasks (Well.every) ───────────────────────────────────── *)

let _pending_every : (string * float * (unit -> unit)) list ref = ref []

(** Run a function periodically on a background fiber. Starts when [Well.run] is called. *)
let every ~name ~sleep fn =
  _pending_every := (name, sleep, fn) :: !_pending_every

let _start_every ~sw =
  let specs = List.rev !_pending_every in
  _pending_every := [];
  List.iter (fun (name, sleep_s, fn) ->
    Eio.Fiber.fork ~sw (fun () ->
      Log.log "periodic %s started (sleep %.1fs)" name sleep_s;
      let rec loop () =
        (try fn ()
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           Log.log ~level:"error" "periodic %s: %s" name (Printexc.to_string exn));
        Env.sleep sleep_s;
        loop ()
      in
      loop ())
  ) specs

(* ── Shutdown state ────────────────────────────────────────────────── *)

(** Raised internally for graceful server shutdown. *)
exception Shutdown
let _shutting_down = Atomic.make false

(* ── Server ────────────────────────────────────────────────────────── *)

let client_wants_close hdrs =
  match List.assoc_opt "connection" hdrs with
  | Some v -> String.lowercase_ascii v = "close"
  | None -> false

let handle_connection flow _addr =
  let close_flow () = Eio.Flow.close flow in
  let flow = (flow :> Eio.Flow.two_way_ty Eio.Resource.t) in
  let reader =
    Eio.Buf_read.of_flow ~max_size:(!_max_body_size + 4096) flow
  in
  Telemetry.incr_active_connections ();
  let do_close () =
    Telemetry.decr_active_connections ();
    close_flow ()
  in
  let parse_incoming () =
    let meth, raw_path = parse_request_line reader in
    let hdrs = parse_headers reader in
    let query_params =
      parse_query raw_path
      |> List.map (fun (k, v) -> (Url.decode k, Url.decode v))
    in
    let path =
      match String.index_opt raw_path '?' with
      | Some i -> String.sub raw_path 0 i
      | None -> raw_path
    in
    let is_upgrade =
      match List.assoc_opt "upgrade" hdrs with
      | Some v -> String.lowercase_ascii v = "websocket"
      | None -> false
    in
    (meth, path, hdrs, query_params, is_upgrade)
  in
  let handle_ws_upgrade meth path hdrs query_params =
    Log.log "ws upgrade: %s" path;
    let existing_session = parse_session_id hdrs in
    let session_id =
      match existing_session with
      | Some sid -> sid
      | None -> generate_session_id ()
    in
    Telemetry.incr_active_ws ();
    (match Router.match_ws_route path with
     | Some (route, params) ->
         (match Websocket.handshake hdrs flow reader with
          | Ok ws ->
              let body = read_body reader hdrs in
              let req =
                { meth; path; headers = hdrs; body; params;
                  query = query_params; session_id; _context = [] }
              in
              (try route.ws_handler req ws
               with
               | Eio.Cancel.Cancelled _ -> ()
               | exn ->
                 Log.log ~level:"error" "ws handler error: %s"
                   (Printexc.to_string exn));
              Websocket.close ws
          | Error msg ->
              Log.log ~level:"error" "ws handshake error: %s" msg;
              let r = resolve (`Text "Bad Request" |> status 400) in
              write_response flow r)
     | None ->
         let r = resolve (`Text "Not Found" |> status 404) in
         write_response flow r);
    Telemetry.decr_active_ws ();
    `Close
  in
  let handle_http_request meth path hdrs query_params =
      let t0 = Unix.gettimeofday () in
      let body = read_body reader hdrs in
      let is_cap_path =
        let p = path in
        String.length p >= 6 && String.sub p 0 6 = "/_cap/"
        || p = "/_cap"
      in
      let safe_500 exn label =
        let msg = Printexc.to_string exn in
        Log.log ~level:"error" "%s error: %s" label msg;
        `Text "Internal Server Error" |> status 500
      in
      let base_handler (req : request) =
        match (if is_cap_path then Router.match_cap_route req.meth req.path
               else None) with
        | Some (route, params) ->
            (try route.handler { req with params }
             with exn -> safe_500 exn "cap handler")
        | None ->
        let effective_meth =
          if req.meth = "HEAD" then
            match Router.match_route "HEAD" req.path with
            | Some _ -> "HEAD"
            | None -> "GET"
          else req.meth
        in
        match Router.match_route effective_meth req.path with
        | Some (route, params) ->
            route.handler { req with params }
        | None ->
            (match Static_serve.try_serve_static req.meth req.path req.headers with
             | Some r when r.r_status = -1 ->
                 let file_path = List.assoc "_stream_path" r.r_headers in
                 let hdrs = List.filter (fun (k, _) -> k <> "_stream_path" && k <> "Content-Type") r.r_headers in
                 let ct = match List.assoc_opt "Content-Type" r.r_headers with
                   | Some v -> v | None -> "application/octet-stream" in
                 stream ~content_type:ct ~headers:hdrs (fun write_chunk ->
                   let ic = open_in_bin file_path in
                   (try
                      let chunk_size = 65536 in
                      let tmp = Bytes.create chunk_size in
                      let rec loop () =
                        let n = input ic tmp 0 chunk_size in
                        if n > 0 then begin
                          write_chunk (Bytes.sub_string tmp 0 n);
                          loop ()
                        end
                      in
                      loop ();
                      close_in ic
                    with exn -> close_in_noerr ic; raise exn))
             | Some r ->
                 `Custom { status = Some r.r_status;
                           headers = r.r_headers; body = `Text r.r_body }
             | None ->
                 let all_methods = ["GET"; "POST"; "PUT"; "DELETE"; "HEAD"] in
                 let matching =
                   List.filter (fun m -> Router.match_route m req.path <> None) all_methods
                 in
                 if matching <> [] then
                   `Text "Method Not Allowed" |> status 405
                   |> header "Allow" (String.concat ", " matching)
                 else
                   `Text "Not Found" |> status 404)
      in
      let pipeline =
        if is_cap_path then
          session_middleware base_handler
        else
          session_middleware
            (apply_middlewares (List.rev !(Router.global_middlewares)) base_handler)
      in
      let req_id =
        match List.assoc_opt "x-request-id" hdrs with
        | Some id -> id
        | None -> generate_request_id ()
      in
      Domain.DLS.set Middleware._current_request_id (Some req_id);
      let req =
        { meth; path; headers = hdrs; body; params = [];
          query = query_params; session_id = ""; _context = [] }
      in
      let resp =
        try pipeline req
        with exn -> safe_500 exn "handler"
      in
      Domain.DLS.set Middleware._current_request_id None;
      Telemetry.incr_requests ();
      let dt_us = int_of_float ((Unix.gettimeofday () -. t0) *. 1e6) in
      Telemetry.add_latency_us dt_us;
      let wants_close = client_wants_close hdrs in
      match extract_stream resp with
      | Some (cfg, extra_hdrs) ->
          write_stream_response flow cfg (("X-Request-ID", req_id) :: extra_hdrs);
          `Close
      | None ->
          let resolved = Compress.maybe_compress hdrs (resolve resp) in
          let resolved = { resolved with r_headers = ("X-Request-ID", req_id) :: resolved.r_headers } in
          if resolved.r_status >= 500 then Telemetry.incr_errors ();
          let ka = not wants_close in
          write_response ~keep_alive:ka ~head:(meth = "HEAD") flow resolved;
          if wants_close then `Close else `KeepAlive
  in
  let timed_http_request meth path hdrs query_params =
    let result = ref `Close in
    (try
       _with_ka_timeout !_request_timeout (fun () ->
         result := handle_http_request meth path hdrs query_params)
     with
     | Keep_alive_timeout | Eio__Time.Timeout ->
         let r = resolve (`Text "Request Timeout" |> status 408) in
         (try write_response flow r with _ -> ());
         result := `Close);
    !result
  in
  let dispatch_request () =
    let (meth, path, hdrs, query_params, is_upgrade) = parse_incoming () in
    if is_upgrade then
      handle_ws_upgrade meth path hdrs query_params
    else
      timed_http_request meth path hdrs query_params
  in
  let req_count = ref 0 in
  let max_reqs = !_max_requests_per_connection in
  let rec ka_loop first =
    if first then begin
      incr req_count;
      match dispatch_request () with
      | `Close -> do_close ()
      | `KeepAlive ->
          if !req_count >= max_reqs then do_close ()
          else ka_loop false
    end else begin
      let got_data =
        try
          _with_ka_timeout !_keep_alive_timeout (fun () ->
            ignore (Eio.Buf_read.peek reader));
          true
        with _ -> false
      in
      if got_data then begin
        incr req_count;
        match dispatch_request () with
        | `Close -> do_close ()
        | `KeepAlive ->
            if !req_count >= max_reqs then do_close ()
            else ka_loop false
      end else
        do_close ()
    end
  in
  (try ka_loop true
   with
  | Body_too_large ->
      (try
         let r = resolve (`Text "Payload Too Large" |> status 413) in
         write_response flow r;
         do_close ()
       with _ -> (try do_close () with _ -> ()))
  | Headers_too_large ->
      (try
         let r = resolve (`Text "Request Header Fields Too Large" |> status 431) in
         write_response flow r;
         do_close ()
       with _ -> (try do_close () with _ -> ()))
  | Eio.Io _ -> (try do_close () with _ -> ())
  | End_of_file -> (try do_close () with _ -> ())
  | Eio.Cancel.Cancelled _ | Eio__Time.Timeout -> (try do_close () with _ -> ())
  | exn ->
      Log.log ~level:"error" "connection error: %s"
        (Printexc.to_string exn);
      (try do_close () with _ -> ()))

(* ── TLS support ──────────────────────────────────────────────────── *)

let handle_tls_connection tls_cfg flow addr =
  let tls_flow =
    try Some (Tls_eio.server_of_flow tls_cfg flow)
    with
    | Tls_eio.Tls_alert a ->
        Log.log ~level:"warn" "TLS alert: %s"
          (Tls.Packet.alert_type_to_string a);
        None
    | Tls_eio.Tls_failure f ->
        Log.log ~level:"error" "TLS failure: %s"
          (Tls.Engine.string_of_failure f);
        None
  in
  match tls_flow with
  | None -> Eio.Flow.close flow
  | Some tls -> handle_connection tls addr

let load_tls_config ~cert ~key =
  let fs = Env.fs () in
  let cert_path = Eio.Path.(fs / cert) in
  let key_path = Eio.Path.(fs / key) in
  let certificate = X509_eio.private_of_pems ~cert:cert_path ~priv_key:key_path in
  match Tls.Config.server ~certificates:(`Single certificate) () with
  | Ok cfg -> cfg
  | Error (`Msg msg) -> failwith ("TLS config error: " ^ msg)

(* ── Port 80 HTTP handler (ACME challenges + HTTPS redirect) ───── *)

let handle_http80 ~domain flow _addr =
  let close_flow () = Eio.Flow.close flow in
  let flow = (flow :> Eio.Flow.two_way_ty Eio.Resource.t) in
  let reader =
    Eio.Buf_read.of_flow ~max_size:4096 flow
  in
  (try
    let _meth, raw_path = parse_request_line reader in
    let _hdrs = parse_headers reader in
    let path =
      match String.index_opt raw_path '?' with
      | Some i -> String.sub raw_path 0 i
      | None -> raw_path
    in
    let acme_prefix = "/.well-known/acme-challenge/" in
    let acme_plen = String.length acme_prefix in
    if String.length path > acme_plen
       && String.sub path 0 acme_plen = acme_prefix then begin
      let token = String.sub path acme_plen (String.length path - acme_plen) in
      match Acme.serve_challenge token with
      | Some key_authz ->
          let resolved = {
            r_status = 200;
            r_headers = [("Content-Type", "text/plain")];
            r_body = key_authz;
          } in
          write_response flow resolved;
          close_flow ()
      | None ->
          let resolved = {
            r_status = 404;
            r_headers = [("Content-Type", "text/plain")];
            r_body = "Not Found";
          } in
          write_response flow resolved;
          close_flow ()
    end else begin
      let location = Printf.sprintf "https://%s%s" domain raw_path in
      let resolved = {
        r_status = 301;
        r_headers = [("Location", location)];
        r_body = "";
      } in
      write_response flow resolved;
      close_flow ()
    end
  with
  | Eio.Io _ -> (try close_flow () with _ -> ())
  | End_of_file -> (try close_flow () with _ -> ())
  | _ -> (try close_flow () with _ -> ()))

(* ── Fetch wiring helper ──────────────────────────────────────────── *)

open struct
  let wire_fetch_impl net =
    Fetch._impl :=
      (fun ~method_ ~headers ~body url ->
        let parsed = Fetch.parse_url url in
        let req_str =
          Fetch.build_request ~method_ ~host:parsed.p_host ~port:parsed.p_port
            ~path:parsed.p_path ~headers ~body
        in
        let addr = Fetch.resolve net parsed.p_host parsed.p_port in
        Eio.Switch.run @@ fun sw ->
        let tcp_flow = Eio.Net.connect ~sw net addr in
        let send_and_receive flow =
          Eio.Flow.copy_string req_str flow;
          let reader = Eio.Buf_read.of_flow ~max_size:(10 * 1024 * 1024) flow in
          let status = Fetch.parse_status reader in
          let resp_hdrs = Fetch.parse_headers reader in
          let body = Fetch.read_body ~method_ reader resp_hdrs in
          { Fetch.status; headers = resp_hdrs; body }
        in
        if parsed.p_scheme = "https" then (
          let tls_cfg = Fetch.tls_config () in
          let host =
            Option.bind
              (Domain_name.of_string parsed.p_host |> Result.to_option)
              (fun dn -> Domain_name.host dn |> Result.to_option)
          in
          let tls_flow = Tls_eio.client_of_flow ?host tls_cfg tcp_flow in
          send_and_receive tls_flow)
        else send_and_receive tcp_flow)

  let wire_forward_refs net =
    wire_fetch_impl net;
    Acme._fetch_ref :=
      (fun ~method_ ~headers ~body url ->
        let r = !(Fetch._impl) ~method_ ~headers ~body url in
        { Acme.http_status = r.Fetch.status;
          http_headers = r.Fetch.headers;
          http_body = r.Fetch.body });
    S3._fetch_ref :=
      (fun ~method_ ~headers ~body url ->
        let r = !(Fetch._impl) ~method_ ~headers ~body url in
        (r.Fetch.status, r.Fetch.headers, r.Fetch.body));
    S3._mime_ref := Url.ext_to_mime;
    Mailer._fetch_ref :=
      (fun ~method_ ~headers ~body url ->
        let r = !(Fetch._impl) ~method_ ~headers ~body url in
        (r.Fetch.status, r.Fetch.headers, r.Fetch.body));
    Mailer._set_net net;
    Mailer._tls_config_fn := (fun () -> Fetch.tls_config ());
    Oauth._fetch_ref :=
      (fun ~method_ ~headers ~body url ->
        let r = !(Fetch._impl) ~method_ ~headers ~body url in
        (r.Fetch.status, r.Fetch.headers, r.Fetch.body));
    Oauth._session_get_ref := (fun sid key -> Session_store.get ~session_id:sid ~key);
    Oauth._session_set_ref := (fun sid key value -> Session_store.set ~session_id:sid ~key ~value);
    Oauth._session_delete_ref := (fun sid key -> Session_store.delete ~session_id:sid ~key);
    Oauth._put_flash_ref := put_flash;
    Oauth._log_ref := (fun msg -> Log.log "%s" msg);
    Oauth_provider._session_get_ref := (fun sid key -> Session_store.get ~session_id:sid ~key);
    Oauth_provider._session_set_ref := (fun sid key value -> Session_store.set ~session_id:sid ~key ~value);
    Oauth_provider._session_delete_ref := (fun sid key -> Session_store.delete ~session_id:sid ~key);
    Oauth_provider._session_clear_ref := (fun sid -> Session_store.clear ~session_id:sid);
    Oauth_provider._login_ref := Auth.login;
    Oauth_provider._current_user_ref := current_user;
    Oauth_provider._register_get_ref := (fun path handler ->
      Router.get path (fun req -> (handler req :> response)));
    Oauth_provider._register_post_ref := (fun path handler ->
      Router.post path (fun req -> (handler req :> response)));
    Oauth_provider._log_ref := (fun msg -> Log.log "%s" msg)

  let register_health_routes () =
    Router.get "/health" (fun _req ->
      let statuses = Service.full_health () in
      `Assoc (List.map (fun (name, st) -> (name, `String st)) statuses));
    Router.get "/ready" (fun _req ->
      let service_statuses = Service.full_health () in
      let all_running = List.for_all (fun (_, st) -> st = "running") service_statuses in
      let db_ok = Session_store.check () in
      if all_running && db_ok then
        `Assoc [("status", `String "ready")]
      else
        `Assoc [("status", `String "not_ready");
                ("services", `Assoc (List.map (fun (n, s) -> (n, `String s)) service_statuses));
                ("db", `Bool db_ok)]
        |> status 503);
    Router.get "/metrics" (fun _req ->
      let cs = Telemetry.snapshot_counters () in
      let sys = Telemetry.system_snapshot () in
      let rps = Telemetry.requests_per_sec () in
      let buf = Buffer.create 1024 in
      let line fmt = Printf.ksprintf (fun s -> Buffer.add_string buf s; Buffer.add_char buf '\n') fmt in
      line "# HELP well_http_requests_total Total HTTP requests";
      line "# TYPE well_http_requests_total counter";
      line "well_http_requests_total %d" cs.total_requests;
      line "# HELP well_http_errors_5xx_total Total 5xx errors";
      line "# TYPE well_http_errors_5xx_total counter";
      line "well_http_errors_5xx_total %d" cs.errors_5xx;
      line "# HELP well_http_latency_avg_us Average request latency in microseconds";
      line "# TYPE well_http_latency_avg_us gauge";
      line "well_http_latency_avg_us %d" cs.avg_latency_us;
      line "# HELP well_http_requests_per_second Current requests per second";
      line "# TYPE well_http_requests_per_second gauge";
      line "well_http_requests_per_second %.2f" rps;
      line "# HELP well_ws_messages_total Total WebSocket messages received";
      line "# TYPE well_ws_messages_total counter";
      line "well_ws_messages_total %d" cs.ws_messages;
      line "# HELP well_bus_events_total Total MessageBus events published";
      line "# TYPE well_bus_events_total counter";
      line "well_bus_events_total %d" cs.bus_events;
      line "# HELP well_active_connections Current active connections";
      line "# TYPE well_active_connections gauge";
      line "well_active_connections %d" (Atomic.get Telemetry.active_connections);
      line "# HELP well_active_ws_connections Current active WebSocket connections";
      line "# TYPE well_active_ws_connections gauge";
      line "well_active_ws_connections %d" (Atomic.get Telemetry.active_ws_connections);
      line "# HELP well_process_cpu_percent Process CPU usage percent";
      line "# TYPE well_process_cpu_percent gauge";
      line "well_process_cpu_percent %.2f" sys.cpu_pct;
      line "# HELP well_process_rss_bytes Process RSS in bytes";
      line "# TYPE well_process_rss_bytes gauge";
      line "well_process_rss_bytes %.0f" (sys.rss_mb *. 1048576.0);
      line "# HELP well_gc_major_collections_total GC major collections";
      line "# TYPE well_gc_major_collections_total counter";
      line "well_gc_major_collections_total %d" sys.gc_major;
      line "# HELP well_uptime_seconds Process uptime in seconds";
      line "# TYPE well_uptime_seconds gauge";
      line "well_uptime_seconds %.0f" sys.uptime_s;
      `Text (Buffer.contents buf)
      |> header "Content-Type" "text/plain; version=0.0.4; charset=utf-8")

  let init_services ~sw =
    Service._register_post_json :=
      (fun path handler ->
        Router.register "POST" path (fun req ->
          let result_json = handler req in
          `Custom { status = Some 200;
                    headers = [("Content-Type", "application/json")];
                    body = `Text result_json }));
    Service._build_rpc_ctx :=
      (fun req -> rpc_ctx_to_wire (rpc_ctx req));
    Service._cast_sw := Some sw;
    Service.start_all ~sw;
    Actor.start_all ~sw;
    Message_bus.init ();
    Channel.ensure_ws_route ();
    register_health_routes ()

  let wire_cap ~disable_cap =
    if not disable_cap then begin
      Cap_hook._register_cap_get := (fun path handler ->
        Router.register_cap "GET" path (fun req ->
          match handler req with
          | Cap_hook.CRHtml s -> (Html.raw s :> Types.response)
          | Cap_hook.CRRedirect url -> `Redirect url
          | Cap_hook.CRJson s ->
              `Text s |> header "content-type" "application/json"
          | Cap_hook.CRJs s ->
              `Text s |> header "content-type" "application/javascript"));
      Cap_hook._register_cap_post := (fun path handler ->
        Router.register_cap "POST" path (fun req ->
          match handler req with
          | Cap_hook.CRHtml s -> (Html.raw s :> Types.response)
          | Cap_hook.CRRedirect url -> `Redirect url
          | Cap_hook.CRJson _ | Cap_hook.CRJs _ ->
              `Text "Method Not Allowed" |> status 405));
      !Cap_hook._cap_init ()
    end

  let start_cleanup_fiber ~sw =
    Eio.Fiber.fork ~sw (fun () ->
      let rec cleanup_loop () =
        Env.sleep 3600.0;
        (try
           let max_age_days =
             max 1 (int_of_float (ceil (!_session_lifetime /. 86400.0)))
           in
           Session_store.cleanup ~max_age_days () with _ -> ());
        (try Liveview.cleanup_sessions () with _ -> ());
        (try Liveview.cleanup_uploads () with _ -> ());
        (try Middleware.cleanup_csrf_tokens () with _ -> ());
        cleanup_loop ()
      in
      cleanup_loop ())
end

(** Start the HTTP server. Blocks until shutdown signal (SIGTERM/SIGINT). Supports TLS via [~cert]/[~key] or auto-TLS via [~domain]. *)
let run ?port ?(workers = 0) ?cert ?key ?domain ?host
    ?(acme_staging = false) ?(disable_cap = false) () =
  let port = match port with
    | Some p -> p
    | None -> Config.get_int ~default:4000 "well.port"
  in
  let host = match host with
    | Some _ -> host
    | None -> Config.get_string_opt "well.host"
  in
  Printexc.record_backtrace true;
  let acme_mode = domain <> None in
  (match domain, cert, key with
   | Some _, Some _, _ | Some _, _, Some _ ->
       failwith "~domain (auto-TLS) and ~cert/~key (manual TLS) cannot be used together"
   | _ -> ());
  let tls_enabled =
    match (cert, key) with
    | Some _, Some _ -> true
    | None, None -> false
    | _ -> failwith "Both ~cert and ~key must be provided for TLS"
  in
  let port = if acme_mode && port = 4000 then 443 else port in
  if acme_mode && port <> 443 then
    Log.log ~level:"warn" "~domain given but port is %d (not 443) — ACME validation may fail" port;
  Eio_main.run @@ fun env ->
  Env.set env;
  let net = Env.net () in
  Service._ws_rate_limit := !_ws_rate_limit;
  wire_forward_refs net;
  Oauth_provider._register_routes ();
  Log.init ();
  let start_server () =
    Eio.Switch.run @@ fun sw ->
    let shutdown_p, shutdown_r = Eio.Promise.create () in
    let signal_handler _signum =
      if not (Atomic.exchange _shutting_down true) then
        Eio.Promise.resolve shutdown_r ()
    in
    Sys.set_signal Sys.sigterm (Sys.Signal_handle signal_handler);
    Sys.set_signal Sys.sigint (Sys.Signal_handle signal_handler);
    init_services ~sw;
    wire_cap ~disable_cap;
    _start_every ~sw;
    (try Unix.mkdir "data" 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    Service.start_socket ~sw ~net "data/well.sock";
    start_cleanup_fiber ~sw;
    let tls_cfg =
      match domain with
      | Some dom when port = 443 ->
          let http80_addr = `Tcp (Eio.Net.Ipaddr.V4.any, 80) in
          let http80_socket =
            Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true http80_addr
          in
          Eio.Fiber.fork ~sw (fun () ->
            let rec accept_loop () =
              Eio.Net.accept_fork http80_socket ~sw
                ~on_error:(fun _ -> ())
                (handle_http80 ~domain:dom);
              accept_loop ()
            in
            accept_loop ());
          Log.log "HTTP on :80 (ACME challenges + redirect)";
          let cert_pem, domain_key =
            Acme.ensure_certificate ~staging:acme_staging dom
          in
          let cfg = Acme.build_tls_config cert_pem domain_key in
          Acme._tls_config := Some cfg;
          Eio.Fiber.fork ~sw (fun () ->
            Acme.renewal_fiber ~staging:acme_staging dom);
          Some cfg
      | Some _ ->
          None
      | None ->
          if tls_enabled then
            Some (load_tls_config
                    ~cert:(Option.get cert) ~key:(Option.get key))
          else None
    in
    let bind_addr =
      match host with
      | Some ("0.0.0.0" | "0") -> Eio.Net.Ipaddr.V4.any
      | Some ("localhost" | "127.0.0.1") -> Eio.Net.Ipaddr.V4.loopback
      | Some h -> failwith (Printf.sprintf "Unsupported host: %s (use \"0.0.0.0\" or \"localhost\")" h)
      | None ->
        if acme_mode then Eio.Net.Ipaddr.V4.any
        else Eio.Net.Ipaddr.V4.loopback
    in
    let addr = `Tcp (bind_addr, port) in
    let socket =
      Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true addr
    in
    _tls_active := tls_cfg <> None;
    let scheme = if !_tls_active then "https" else "http" in
    let host_str = match host with
      | Some h -> h
      | None -> if acme_mode then "0.0.0.0" else "localhost"
    in
    Log.log "listening on %s://%s:%d%s" scheme host_str port
      (if workers > 0 then Printf.sprintf " (%d workers)" workers else "");
    let inner_handler =
      match domain with
      | Some _ ->
          (fun flow addr ->
            match !(Acme._tls_config) with
            | Some cfg -> handle_tls_connection cfg flow addr
            | None -> Eio.Flow.close flow)
      | None ->
          (match tls_cfg with
           | Some cfg -> handle_tls_connection cfg
           | None -> handle_connection)
    in
    let handler flow addr =
      let ip = ip_of_addr addr in
      if conn_acquire ip then
        (try inner_handler flow addr; conn_release ip
         with exn -> conn_release ip; raise exn)
      else begin
        (try
           let r = resolve (`Text "Service Unavailable" |> status 503) in
           let flow = (flow :> Eio.Flow.two_way_ty Eio.Resource.t) in
           write_response flow r
         with _ -> ());
        Eio.Flow.close flow
      end
    in
    Eio.Fiber.fork ~sw (fun () ->
      if workers > 0 then begin
        let pool =
          Eio.Executor_pool.create ~sw ~domain_count:workers
            (Env.domain_mgr ())
        in
        let rec accept_loop () =
          let flow, addr = Eio.Net.accept ~sw socket in
          ignore (Eio.Executor_pool.submit_fork ~sw pool ~weight:0.1
            (fun () ->
              try handler flow addr
              with exn ->
                Log.log ~level:"error" "worker error: %s"
                  (Printexc.to_string exn)));
          accept_loop ()
        in
        accept_loop ()
      end else begin
        let rec accept_loop () =
          Eio.Net.accept_fork socket ~sw
            ~on_error:(fun exn ->
              Log.log ~level:"error" "accept error: %s"
                (Printexc.to_string exn))
            handler;
          accept_loop ()
        in
        accept_loop ()
      end);
    Eio.Promise.await shutdown_p;
    Log.log "shutting down...";
    Env.sleep 0.5;
    Db.close_well_db ();
    Log.log "stopped.";
    Log.close ();
    raise Shutdown
  in
  Mirage_crypto_rng_unix.use_default ();
  (try start_server () with
   | Shutdown -> ()
   | Eio.Exn.Multiple exns ->
       let dominated_by_shutdown =
         List.exists (fun (exn, _bt) -> exn = Shutdown) exns in
       if not dominated_by_shutdown then
         raise (Eio.Exn.Multiple exns))

(* ── Test server ──────────────────────────────────────────────────── *)

(** Start a test server on a random port. Calls [f port] with the actual port number. *)
let with_test_server ?(port = 0) ?(disable_cap = false) f =
  Random.self_init ();
  let test_port = if port > 0 then port else 40000 + Random.int 20000 in
  Eio_main.run @@ fun env ->
  Env.set env;
  let net = Env.net () in
  wire_forward_refs net;
  Mirage_crypto_rng_unix.use_default ();
  Eio.Switch.run @@ fun sw ->
  init_services ~sw;
  wire_cap ~disable_cap;
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, test_port) in
  let socket =
    Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true addr
  in
  Eio.Fiber.fork ~sw (fun () ->
    let rec accept_loop () =
      Eio.Net.accept_fork socket ~sw
        ~on_error:(fun _ -> ())
        handle_connection;
      accept_loop ()
    in
    accept_loop ());
  f test_port

(* ── LiveView registration ─────────────────────────────────────────── *)

(** Register a LiveView page at the given path. Handles both HTTP GET and WebSocket connections. *)
let live path (module View : Liveview.VIEW) =
  let endpoint = "/live" ^ path in
  Liveview.register endpoint (module View)

(* ── Wire up LiveView live navigation route resolution ────────────── *)

let () = Liveview._resolve_route := (fun req url ->
  let path =
    match String.index_opt url '?' with
    | Some i -> String.sub url 0 i
    | None -> url
  in
  let query_params =
    parse_query url
    |> List.map (fun (k, v) -> (Url.decode k, Url.decode v))
  in
  match Router.match_route "GET" path with
  | Some (route, params) ->
      let nav_req = { req with meth = "GET"; path; params;
                       query = query_params } in
      let pipeline =
        apply_middlewares (List.rev !(Router.global_middlewares))
          (fun r -> route.handler { r with params })
      in
      let resp = pipeline nav_req in
      let resolved = resolve resp in
      if resolved.r_status >= 200 && resolved.r_status < 400 then
        Some resolved.r_body
      else None
  | None -> None
)

(* ── Route introspection ──────────────────────────────────────────── *)

(** List all registered routes as [(method, path, kind)] triples. *)
let list_routes () =
  let lv_endpoints =
    let acc = ref [] in
    Hashtbl.iter (fun ep _ -> acc := ep :: !acc) Liveview.view_registry;
    !acc
  in
  Router.list_routes ~lv_endpoints ()

(* ── Re-export submodules ─────────────────────────────────────────── *)

(** EIO environment access (net, fs, clock, cwd). *)
module Env = Env

(** Structured logging with context. *)
module Log = Log

(** ACME (Let's Encrypt) automatic TLS certificate provisioning. *)
module Acme = Acme

(** Cap admin panel hooks. *)
module Cap_hook = Cap_hook

(** SQLite database with auto-migration and schema registry. *)
module Db = Db

(** Form builder with validation and CSRF protection. *)
module Form = Form

(** RFC 6455 WebSocket implementation. *)
module Websocket = Websocket

(** LiveView server-side reactive UI engine. *)
module LiveView = Liveview

(** Background service registry with health checks and supervision. *)
module Service = Service

(** Supervised stateful actors with message passing. *)
module Actor = Actor

(** SQLite-backed persistent pub/sub with typed topics. *)
module MessageBus = Message_bus

(** WebSocket channel authorization gateway. *)
module Channel = Channel

(** User authentication (login, logout, registration). *)
module Auth = Auth

(** OAuth client for third-party login (Google, GitHub, etc.). *)
module OAuth = Oauth

(** OAuth provider -- issue tokens and authorize third-party apps. *)
module OAuthProvider = Oauth_provider

(** Email sending via SMTP and HTTP APIs. *)
module Mailer = Mailer

(** S3-compatible object storage client. *)
module S3 = S3

(** Server telemetry and Prometheus metrics. *)
module Telemetry = Telemetry

(** Configuration from [well.toml] with environment variable overrides. *)
module Config = Config

(** TOML file reader and writer. *)
module Toml = Toml

(** Chrome DevTools Protocol client for end-to-end testing. *)
module Cdp = Cdp

(* ── Env convenience re-exports ───────────────────────────────────── *)

(** Get the EIO environment. Must be called within [Well.run]. *)
let env = Env.get
let net = Env.net
let clock = Env.clock
let cwd = Env.cwd
let fs = Env.fs
let sleep = Env.sleep

(* ── Typed pub/sub ────────────────────────────────────────────────── *)

(** Typed pub/sub topic. Phantom type ensures type-safe publish/subscribe. *)
type 'a topic = 'a Message_bus.topic

(** A typed event received from a topic subscription. *)
type 'a event = 'a Message_bus.typed_event = { id : int; value : 'a; created_at : float }

(** Create a typed pub/sub topic with channel name and serialization functions. *)
let topic = Message_bus.topic

(** Log a message. Alias for [Well.Log.log]. *)
let log = Log.log

(** Get the channel name string of a topic. *)
let topic_name (t : _ topic) = t.Message_bus.t_channel

(** Publish a typed value to a topic. Use [~ephemeral:true] to skip SQLite persistence. *)
let publish ?ephemeral t v = ignore (Message_bus.publish_typed ?ephemeral t v)

(** Subscribe to a typed topic. Returns a subscription ID. *)
let subscribe ?live_only t f = Message_bus.subscribe_typed ?live_only t f

(** Check if the MessageBus is currently replaying events. *)
let is_replaying = Message_bus.is_replaying

(** Replay persisted events from a topic, optionally since a given event ID. *)
let replay ?since_id t f = Message_bus.replay_typed ?since_id t f

(** Prune old events from the MessageBus SQLite log. *)
let prune = Message_bus.prune

(* ── Keyed pub/sub (channel:key) ─────────────────────────────────── *)

(** A keyed event includes the key that was used to publish, along with the event data. *)
type 'a keyed_event = 'a Message_bus.keyed_event = {
  key : string;
  event : 'a event;
}

(** Publish a typed value to a keyed topic ([channel:key]). *)
let publish_keyed ?ephemeral t ~key v =
  ignore (Message_bus.publish_keyed_typed ?ephemeral t ~key v)

(** Subscribe to all keys of a keyed topic. Callback receives [keyed_event] with the key. *)
let subscribe_keyed ?live_only t f =
  Message_bus.subscribe_keyed_typed ?live_only t f

(* ── Request/reply over bus ──────────────────────────────────────── *)

(** Raised when a [request] call exceeds its timeout. *)
exception Request_timeout

(** Request/reply pattern over the message bus. Publishes a command and blocks until a response arrives or timeout. *)
let request ~cmd ~reply ~key ?(timeout = 5.0) value =
  let result = Atomic.make None in
  let reply_channel = reply.Message_bus.t_channel ^ ":" ^ key in
  let sub_id = Message_bus.once reply_channel (fun event ->
    match reply.Message_bus.of_yojson event.Message_bus.payload with
    | Ok v -> Atomic.set result (Some v)
    | Error _ -> ()) in
  ignore (Message_bus.publish_keyed_typed cmd ~key value);
  let deadline = Unix.gettimeofday () +. timeout in
  let rec wait () =
    match Atomic.get result with
    | Some v -> v
    | None ->
      if Unix.gettimeofday () >= deadline then begin
        Message_bus.unsubscribe sub_id;
        raise Request_timeout
      end;
      Env.sleep 0.005;
      wait ()
  in
  wait ()

(* ── stream_file (fixed: actually streams from disk) ─────────────── *)

(** Stream a file as a chunked HTTP response. Reads in chunks from disk, not loading the entire file into memory. *)
let stream_file ?(content_type = "application/octet-stream") ?(headers = []) path : response =
  stream ~content_type ~headers (fun write_chunk ->
    let p = Eio.Path.(Env.cwd () / path) in
    Eio.Path.with_open_in p (fun flow ->
      let buf = Cstruct.create 65536 in
      let rec loop () =
        match Eio.Flow.single_read flow buf with
        | got ->
          write_chunk (Cstruct.to_string buf ~len:got);
          loop ()
        | exception End_of_file -> ()
      in
      loop ()))
