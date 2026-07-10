(** Built-in middleware: logging, CORS, CSRF, rate limiting, auth, security headers. *)

open Types

(* ── Forward refs (wired by well.ml) ─────────────────────────────── *)

let _form_params_fn : (request -> (string * string) list) ref =
  ref (fun _ -> [])

(* ── Request context for logging ──────────────────────────────────── *)

let _current_request_id : string option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let req_ctx (req : request) =
  let ctx = [("sid", String.sub req.session_id 0 (min 8 (String.length req.session_id)));
             ("meth", req.meth); ("path", req.path)] in
  let ctx = match Domain.DLS.get _current_request_id with
    | Some rid -> ("rid", rid) :: ctx | None -> ctx in
  let ctx = match Session_store.get ~session_id:req.session_id ~key:"user_id" with
    | Some uid -> ("uid", uid) :: ctx | None -> ctx in
  ctx

(* ── Logger ───────────────────────────────────────────────────────── *)

(** Request logging middleware. Logs method, path, status, and latency. *)
let logger : middleware = fun next req ->
  let t0 = Unix.gettimeofday () in
  let resp = next req in
  let dt = (Unix.gettimeofday () -. t0) *. 1000.0 in
  let st = response_status resp in
  Log.log ~ctx:(req_ctx req) "%s %s -> %d (%.1fms)" req.meth req.path st dt;
  resp

(* ── CORS ─────────────────────────────────────────────────────────── *)

(** CORS middleware. Configurable allowed origins, methods, headers, and max age. *)
let cors ?(origins = ["*"])
    ?(methods = ["GET"; "POST"; "PUT"; "DELETE"; "OPTIONS"])
    ?(headers = ["Content-Type"; "Authorization"])
    ?(max_age = 86400) () : middleware =
  fun next req ->
    let origin =
      match List.assoc_opt "origin" req.headers with
      | Some o -> o
      | None -> ""
    in
    let allowed =
      List.mem "*" origins || List.mem origin origins
    in
    let add_cors resp =
      if not allowed then resp
      else
        resp
        |> header "Access-Control-Allow-Origin"
             (if List.mem "*" origins then "*" else origin)
        |> header "Access-Control-Allow-Methods"
             (String.concat ", " methods)
        |> header "Access-Control-Allow-Headers"
             (String.concat ", " headers)
    in
    if req.meth = "OPTIONS" then
      add_cors (`Text "" |> status 204)
      |> header "Access-Control-Max-Age" (string_of_int max_age)
    else
      add_cors (next req)

(* ── Error handler ────────────────────────────────────────────────── *)

let _dev_mode = ref true
let _custom_error_handler : (exn -> request -> response) option ref = ref None

(** Enable or disable dev mode. When enabled, error pages show backtraces and request details. *)
let dev_mode b = _dev_mode := b

(** Set a custom error handler invoked when a route handler raises an exception. *)
let on_error fn = _custom_error_handler := Some fn

let dev_error_page exn bt (req : request) =
  let esc = Html.escape_html in
  let exn_str = esc (Printexc.to_string exn) in
  let bt_str = esc (Printexc.raw_backtrace_to_string bt) in
  let headers_str =
    req.headers
    |> List.map (fun (k, v) ->
           Printf.sprintf "<tr><td>%s</td><td>%s</td></tr>" (esc k) (esc v))
    |> String.concat "\n"
  in
  Printf.sprintf
    {|<!DOCTYPE html>
<html>
<head><title>500 — %s</title>
<style>
body{font-family:system-ui,sans-serif;margin:2rem;color:#1a1a1a}
h1{color:#dc2626}
pre{background:#f3f4f6;padding:1rem;overflow-x:auto;border-radius:4px}
table{border-collapse:collapse;margin-top:0.5rem}
td{padding:0.25rem 0.75rem;border:1px solid #e5e7eb;font-family:monospace;font-size:0.85rem}
.section{margin-top:1.5rem}
</style></head>
<body>
<h1>500 — Internal Server Error</h1>
<div class="section"><h2>Exception</h2><pre>%s</pre></div>
<div class="section"><h2>Backtrace</h2><pre>%s</pre></div>
<div class="section"><h2>Request</h2>
<p><strong>%s %s</strong></p>
<table>%s</table></div>
</body></html>|}
    exn_str exn_str bt_str (esc req.meth) (esc req.path) headers_str

(** Error handler middleware. Catches exceptions and renders error pages. *)
let error_handler : middleware = fun next req ->
  try next req
  with
  | Auth.Auth_denied (code, msg) ->
    `Text msg |> status code
  | exn ->
    let bt = Printexc.get_raw_backtrace () in
    Log.log ~level:"error" ~ctx:(req_ctx req) "%s %s ERROR: %s\n%s" req.meth req.path
      (Printexc.to_string exn) (Printexc.raw_backtrace_to_string bt);
    match !_custom_error_handler with
    | Some h ->
        (try h exn req with _ -> `Text "Internal Server Error" |> status 500)
    | None ->
        if !_dev_mode then
          (Html.raw (dev_error_page exn bt req) :> Types.response) |> status 500
        else
          `Text "Internal Server Error" |> status 500

(* ── CSRF ─────────────────────────────────────────────────────────── *)

let _csrf_tokens : (string, string) Hashtbl.t = Hashtbl.create 64

let migrate_csrf_token old_sid new_sid =
  match Hashtbl.find_opt _csrf_tokens old_sid with
  | Some t -> Hashtbl.replace _csrf_tokens new_sid t; Hashtbl.remove _csrf_tokens old_sid
  | None -> ()

module Csrf_ctx = Context(struct type t = string let empty = "" end)

let generate_csrf_token () =
  let bytes = Mirage_crypto_rng.generate 32 in
  let buf = Buffer.create 64 in
  String.iter (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) bytes;
  Buffer.contents buf

(** Get the CSRF token for the current request. *)
let csrf_token req = Csrf_ctx.get req

let _csrf_warned_no_session = Atomic.make false

(** CSRF protection middleware. Validates tokens on state-changing requests (POST, PUT, DELETE). *)
let csrf : middleware = fun next req ->
  if req.session_id = "" && not (Atomic.get _csrf_warned_no_session) then begin
    Atomic.set _csrf_warned_no_session true;
    Log.log ~level:"warn" "CSRF middleware: request has no session_id. \
      Make sure session middleware (Well.use session_middleware or equivalent) \
      is registered BEFORE Well.use Well.csrf."
  end;
  let token =
    match Hashtbl.find_opt _csrf_tokens req.session_id with
    | Some t -> t
    | None ->
        let t = generate_csrf_token () in
        Hashtbl.replace _csrf_tokens req.session_id t;
        t
  in
  let req = Csrf_ctx.set token req in
  let safe_method =
    req.meth = "GET" || req.meth = "HEAD" || req.meth = "OPTIONS"
  in
  if safe_method then next req
  else
    let is_xhr =
      match List.assoc_opt "x-requested-with" req.headers with
      | Some v -> String.lowercase_ascii v = "xmlhttprequest"
      | None -> false
    in
    if is_xhr then next req
    else
      let submitted =
        let from_form =
          match List.assoc_opt "_csrf_token" (!_form_params_fn req) with
          | Some t -> t
          | None -> ""
        in
        if from_form <> "" then from_form
        else
          match List.assoc_opt "x-csrf-token" req.headers with
          | Some t -> t
          | None -> ""
      in
      let ct_equal a b =
        let la = String.length a and lb = String.length b in
        let r = ref (la lxor lb) in
        for i = 0 to min la lb - 1 do
          r := !r lor (Char.code a.[i] lxor Char.code b.[i])
        done;
        !r = 0
      in
      if ct_equal submitted token then next req
      else `Text "Forbidden — invalid CSRF token" |> status 403

(** Prune CSRF tokens for sessions no longer in the store. *)
let cleanup_csrf_tokens () =
  let to_remove = ref [] in
  Hashtbl.iter (fun sid _token ->
    if Session_store.get ~session_id:sid ~key:"__exists" = None
    && Session_store.get_all_with_prefix ~session_id:sid ~prefix:"" = []
    then to_remove := sid :: !to_remove
  ) _csrf_tokens;
  List.iter (Hashtbl.remove _csrf_tokens) !to_remove

(* ── Rate limiting ────────────────────────────────────────────────── *)

let _rate_limit_store : (string, float list) Hashtbl.t = Hashtbl.create 256
let _rate_limit_mu = Mutex.create ()
let _rate_limit_counter = Atomic.make 0

(** Rate limiting middleware. Limits requests per client IP within a sliding time window. *)
let rate_limit ~max_requests ~window_ms () : middleware = fun next req ->
  let is_static =
    List.exists (fun (mount : static_mount) ->
      let plen = String.length mount.prefix in
      String.length req.path >= plen
      && String.sub req.path 0 plen = mount.prefix)
      !(Router.static_mounts)
  in
  if is_static then next req
  else
  let now = Unix.gettimeofday () *. 1000.0 in
  let window = float_of_int window_ms in
  let client_key =
    match List.assoc_opt "x-forwarded-for" req.headers with
    | Some ip -> ip
    | None ->
        match List.assoc_opt "x-real-ip" req.headers with
        | Some ip -> ip
        | None -> req.session_id
  in
  let allowed =
    Mutex.lock _rate_limit_mu;
    Fun.protect ~finally:(fun () -> Mutex.unlock _rate_limit_mu) (fun () ->
      let count = Atomic.fetch_and_add _rate_limit_counter 1 in
      if count >= 99 then begin
        Atomic.set _rate_limit_counter 0;
        let cutoff = now -. window in
        Hashtbl.filter_map_inplace
          (fun _k timestamps ->
            let filtered = List.filter (fun t -> t > cutoff) timestamps in
            if filtered = [] then None else Some filtered)
          _rate_limit_store
      end;
      let timestamps =
        match Hashtbl.find_opt _rate_limit_store client_key with
        | Some ts -> List.filter (fun t -> t > now -. window) ts
        | None -> []
      in
      if List.length timestamps >= max_requests then false
      else begin
        Hashtbl.replace _rate_limit_store client_key (now :: timestamps);
        true
      end)
  in
  if allowed then next req
  else
    let retry_after = int_of_float (window /. 1000.0) in
    `Text "Too Many Requests" |> status 429
    |> header "Retry-After" (string_of_int retry_after)

(* ── Auth middleware ──────────────────────────────────────────────── *)

let _auth_key = "user_id"

module Auth_ctx = Context(struct type t = string option let empty = None end)

(** Get the current user ID from the session. Returns [None] if not authenticated. *)
let current_user req =
  match Auth_ctx.get req with
  | Some _ as v -> v
  | None -> Session_store.get ~session_id:req.session_id ~key:_auth_key

(** Authentication middleware. Redirects unauthenticated users to [login_path]. *)
let require_auth ?(login_path = "/login") () : middleware = fun next req ->
  let user = Session_store.get ~session_id:req.session_id ~key:_auth_key in
  match user with
  | Some uid ->
      let req = Auth_ctx.set (Some uid) req in
      next req
  | None ->
      let accepts_html =
        match List.assoc_opt "accept" req.headers with
        | Some v -> String.lowercase_ascii v |> fun s ->
            (try ignore (Str.search_forward (Str.regexp_string "text/html") s 0); true
             with Not_found -> false)
        | None -> true
      in
      if accepts_html then
        let safe_path =
          let p = req.path in
          if String.length p >= 2 && String.sub p 0 2 = "//" then "/"
          else if String.length p >= 1 && p.[0] = '/' then p
          else "/"
        in
        `Redirect (login_path ^ "?return_to=" ^ safe_path)
      else
        `Text "Unauthorized" |> status 401

(* ── Basic Auth ───────────────────────────────────────────────────── *)

open struct
  let _base64_decode s =
    let tbl = Array.make 256 (-1) in
    String.iteri (fun i c -> tbl.(Char.code c) <- i)
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let len = String.length s in
    let buf = Buffer.create (len * 3 / 4) in
    let acc = ref 0 and bits = ref 0 in
    for i = 0 to len - 1 do
      let v = tbl.(Char.code s.[i]) in
      if v >= 0 then begin
        acc := !acc lsl 6 lor v;
        bits := !bits + 6;
        if !bits >= 8 then begin
          bits := !bits - 8;
          Buffer.add_char buf (Char.chr ((!acc lsr !bits) land 0xff));
        end
      end
    done;
    Buffer.contents buf
end

(** Host whitelist middleware. Rejects requests with disallowed Host headers. *)
let allowed_hosts ~hosts () : middleware = fun next req ->
  let host =
    match List.assoc_opt "host" req.headers with
    | Some h ->
        (match String.index_opt h ':' with
         | Some i -> String.sub h 0 i
         | None -> h)
    | None -> ""
  in
  if host = "" || List.mem host hosts then next req
  else
    `Text "Forbidden — invalid Host header" |> status 403

(** HTTP Basic Auth middleware. Calls [check username password] to validate credentials. *)
let basic_auth ~check ?(realm = "Restricted") () : middleware = fun next req ->
  let authorized =
    match List.assoc_opt "authorization" req.headers with
    | Some v ->
      let v = String.trim v in
      if String.length v > 6
         && String.lowercase_ascii (String.sub v 0 6) = "basic " then
        let encoded = String.trim (String.sub v 6 (String.length v - 6)) in
        let decoded = _base64_decode encoded in
        (match String.index_opt decoded ':' with
         | Some i ->
           let user = String.sub decoded 0 i in
           let pass = String.sub decoded (i + 1) (String.length decoded - i - 1) in
           check user pass
         | None -> false)
      else false
    | None -> false
  in
  if authorized then next req
  else
    `Text "Unauthorized"
    |> status 401
    |> header "WWW-Authenticate" (Printf.sprintf "Basic realm=\"%s\"" realm)

(* ── Security headers ─────────────────────────────────────────────── *)

(** Security headers middleware. Adds CSP, X-Frame-Options, HSTS, and other security headers. *)
let secure_headers
    ?(csp = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:")
    ?(frame_options = "DENY")
    ?(content_type_options = "nosniff")
    ?(referrer_policy = "strict-origin-when-cross-origin")
    ?(hsts = "max-age=31536000; includeSubDomains")
    () : middleware = fun next req ->
  let resp = next req in
  resp
  |> header "Content-Security-Policy" csp
  |> header "X-Frame-Options" frame_options
  |> header "X-Content-Type-Options" content_type_options
  |> header "Referrer-Policy" referrer_policy
  |> header "Strict-Transport-Security" hsts
