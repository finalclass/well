let version = "0.1.0-dev"

(* ── Types ─────────────────────────────────────────────────────────── *)

include Types

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
  | `Html of string
  | `Text of string
  | `Redirect of string
  | `Custom of custom
  ]

(* ── Response constructors ─────────────────────────────────────────── *)

let html s : response = `Html s
let text s : response = `Text s
let json (j : Yojson.Safe.t) : response = (j :> response)
let redirect url : response = `Redirect url

(* ── Response transformers ─────────────────────────────────────────── *)

let status code (resp : response) : response =
  match resp with
  | `Custom c -> `Custom { c with status = Some code }
  | _ -> `Custom { status = Some code; headers = []; body = resp }

let header name value (resp : response) : response =
  match resp with
  | `Custom c -> `Custom { c with headers = (name, value) :: c.headers }
  | _ -> `Custom { status = None; headers = [ (name, value) ]; body = resp }

(* ── Request helpers ───────────────────────────────────────────────── *)

let param req key =
  match List.assoc_opt key req.params with
  | Some v -> v
  | None -> ""

let query req key = List.assoc_opt key req.query

(* ── Middleware types ─────────────────────────────────────────────── *)

type handler = request -> response
type middleware = handler -> handler

(* ── Context funktor ─────────────────────────────────────────────── *)

let _next_context_id = ref 0

module type CONTEXT = sig
  type t
  val empty : t
end

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

(* ── Middleware registry ─────────────────────────────────────────── *)

let global_middlewares : middleware list ref = ref []

let use mw = global_middlewares := mw :: !global_middlewares

let apply_middlewares middlewares handler =
  List.fold_right (fun mw h -> mw h) middlewares handler

(* ── Route internals ───────────────────────────────────────────────── *)

type segment = Static of string | Param of string

type route = {
  meth : string;
  segments : segment list;
  handler : request -> response;
}

let routes : route list ref = ref []

(* ── Static file mount ────────────────────────────────────────────── *)

type static_mount = { prefix : string; dir : string }

let static_mounts : static_mount list ref = ref []

let static prefix dir =
  let prefix =
    if String.length prefix > 0 && prefix.[String.length prefix - 1] = '/' then
      String.sub prefix 0 (String.length prefix - 1)
    else prefix
  in
  static_mounts := { prefix; dir } :: !static_mounts

(* ── MIME types ───────────────────────────────────────────────────── *)

let ext_to_mime ext =
  match String.lowercase_ascii ext with
  (* Text *)
  | "html" | "htm" -> "text/html"
  | "css" -> "text/css"
  | "csv" -> "text/csv"
  | "ics" -> "text/calendar"
  | "js" | "mjs" -> "text/javascript"
  | "json" -> "application/json"
  | "jsonld" -> "application/ld+json"
  | "md" -> "text/markdown"
  | "txt" -> "text/plain"
  | "xml" -> "application/xml"
  | "xhtml" -> "application/xhtml+xml"
  (* Images *)
  | "apng" -> "image/apng"
  | "avif" -> "image/avif"
  | "bmp" -> "image/bmp"
  | "gif" -> "image/gif"
  | "ico" -> "image/vnd.microsoft.icon"
  | "jpg" | "jpeg" -> "image/jpeg"
  | "png" -> "image/png"
  | "svg" -> "image/svg+xml"
  | "tif" | "tiff" -> "image/tiff"
  | "webp" -> "image/webp"
  (* Audio *)
  | "aac" -> "audio/aac"
  | "mid" | "midi" -> "audio/midi"
  | "mp3" -> "audio/mpeg"
  | "oga" | "opus" -> "audio/ogg"
  | "wav" -> "audio/wav"
  | "weba" -> "audio/webm"
  (* Video *)
  | "avi" -> "video/x-msvideo"
  | "mp4" -> "video/mp4"
  | "mpeg" -> "video/mpeg"
  | "ogv" -> "video/ogg"
  | "webm" -> "video/webm"
  | "3gp" -> "video/3gpp"
  | "3g2" -> "video/3gpp2"
  (* Fonts *)
  | "eot" -> "application/vnd.ms-fontobject"
  | "otf" -> "font/otf"
  | "ttf" -> "font/ttf"
  | "woff" -> "font/woff"
  | "woff2" -> "font/woff2"
  (* Archives *)
  | "bz" -> "application/x-bzip"
  | "bz2" -> "application/x-bzip2"
  | "gz" -> "application/gzip"
  | "rar" -> "application/vnd.rar"
  | "tar" -> "application/x-tar"
  | "zip" -> "application/zip"
  | "7z" -> "application/x-7z-compressed"
  (* Documents *)
  | "doc" -> "application/msword"
  | "docx" ->
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  | "epub" -> "application/epub+zip"
  | "odp" -> "application/vnd.oasis.opendocument.presentation"
  | "ods" -> "application/vnd.oasis.opendocument.spreadsheet"
  | "odt" -> "application/vnd.oasis.opendocument.text"
  | "pdf" -> "application/pdf"
  | "ppt" -> "application/vnd.ms-powerpoint"
  | "pptx" ->
      "application/vnd.openxmlformats-officedocument.presentationml.presentation"
  | "rtf" -> "application/rtf"
  | "xls" -> "application/vnd.ms-excel"
  | "xlsx" ->
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  (* Other *)
  | "bin" -> "application/octet-stream"
  | "jar" -> "application/java-archive"
  | "map" -> "application/json"
  | "ogx" -> "application/ogg"
  | "sh" -> "application/x-sh"
  | "wasm" -> "application/wasm"
  | "webmanifest" -> "application/manifest+json"
  | _ -> "application/octet-stream"

let mime_to_ext mime =
  match String.lowercase_ascii mime with
  | "text/html" -> "html"
  | "text/css" -> "css"
  | "text/csv" -> "csv"
  | "text/calendar" -> "ics"
  | "text/javascript" -> "js"
  | "text/markdown" -> "md"
  | "text/plain" -> "txt"
  | "application/json" -> "json"
  | "application/ld+json" -> "jsonld"
  | "application/xml" -> "xml"
  | "application/xhtml+xml" -> "xhtml"
  | "image/apng" -> "apng"
  | "image/avif" -> "avif"
  | "image/bmp" -> "bmp"
  | "image/gif" -> "gif"
  | "image/vnd.microsoft.icon" -> "ico"
  | "image/jpeg" -> "jpg"
  | "image/png" -> "png"
  | "image/svg+xml" -> "svg"
  | "image/tiff" -> "tiff"
  | "image/webp" -> "webp"
  | "audio/aac" -> "aac"
  | "audio/midi" -> "midi"
  | "audio/mpeg" -> "mp3"
  | "audio/ogg" -> "oga"
  | "audio/wav" -> "wav"
  | "audio/webm" -> "weba"
  | "video/x-msvideo" -> "avi"
  | "video/mp4" -> "mp4"
  | "video/mpeg" -> "mpeg"
  | "video/ogg" -> "ogv"
  | "video/webm" -> "webm"
  | "video/3gpp" -> "3gp"
  | "video/3gpp2" -> "3g2"
  | "application/vnd.ms-fontobject" -> "eot"
  | "font/otf" -> "otf"
  | "font/ttf" -> "ttf"
  | "font/woff" -> "woff"
  | "font/woff2" -> "woff2"
  | "application/x-bzip" -> "bz"
  | "application/x-bzip2" -> "bz2"
  | "application/gzip" -> "gz"
  | "application/vnd.rar" -> "rar"
  | "application/x-tar" -> "tar"
  | "application/zip" -> "zip"
  | "application/x-7z-compressed" -> "7z"
  | "application/msword" -> "doc"
  | "application/epub+zip" -> "epub"
  | "application/pdf" -> "pdf"
  | "application/rtf" -> "rtf"
  | "application/octet-stream" -> "bin"
  | "application/java-archive" -> "jar"
  | "application/ogg" -> "ogx"
  | "application/x-sh" -> "sh"
  | "application/wasm" -> "wasm"
  | "application/manifest+json" -> "webmanifest"
  | _ -> "bin"

(* ── Path safety ──────────────────────────────────────────────────── *)

let is_safe_path path =
  let segments = String.split_on_char '/' path in
  not (List.exists (fun seg -> seg = ".." || seg = ".") segments)

let file_ext path =
  match String.rindex_opt path '.' with
  | Some i -> String.sub path (i + 1) (String.length path - i - 1)
  | None -> ""

let file_etag (stat : Unix.stats) =
  Printf.sprintf "\"%x-%x\""
    (int_of_float (stat.Unix.st_mtime *. 1000.))
    stat.Unix.st_size

let is_text_mime mime =
  let open String in
  let m = lowercase_ascii mime in
  (length m >= 5 && sub m 0 5 = "text/")
  || m = "application/json"
  || m = "application/xml"
  || m = "application/xhtml+xml"
  || m = "application/ld+json"
  || m = "application/manifest+json"
  || m = "image/svg+xml"
  || m = "application/javascript"


let split_path path =
  let path =
    match String.index_opt path '?' with
    | Some i -> String.sub path 0 i
    | None -> path
  in
  String.split_on_char '/' path
  |> List.filter (fun s -> s <> "")

let parse_segments parts =
  List.map
    (fun part ->
      if String.length part > 0 && part.[0] = ':' then
        Param (String.sub part 1 (String.length part - 1))
      else Static part)
    parts

(* ── Scope support ────────────────────────────────────────────────── *)

type scope_ctx = { prefix : string; scope_middlewares : middleware list }

let scope_stack : scope_ctx list ref = ref []

let current_prefix () =
  List.fold_left (fun acc s -> s.prefix ^ acc) "" !scope_stack

let current_scope_middlewares () =
  List.concat_map (fun s -> s.scope_middlewares) (List.rev !scope_stack)

let scope ?(middleware = []) prefix f =
  scope_stack := { prefix; scope_middlewares = middleware } :: !scope_stack;
  f ();
  scope_stack := List.tl !scope_stack

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

(* ── Route registration ────────────────────────────────────────────── *)

let get ?middleware path handler =
  register ?middleware "GET" path (fun req -> (handler req :> response))

let post ?middleware path handler =
  register ?middleware "POST" path (fun req -> (handler req :> response))

let put ?middleware path handler =
  register ?middleware "PUT" path (fun req -> (handler req :> response))

let delete ?middleware path handler =
  register ?middleware "DELETE" path (fun req -> (handler req :> response))

(* ── WebSocket route registration ─────────────────────────────────── *)

type ws_route = {
  ws_segments : segment list;
  ws_handler : request -> Websocket.t -> unit;
}

let ws_routes : ws_route list ref = ref []

let ws path handler =
  let segments = parse_segments (split_path path) in
  ws_routes := { ws_segments = segments; ws_handler = handler } :: !ws_routes

let match_ws_route path =
  let parts = split_path path in
  let try_route r =
    let rec go parts segs acc =
      match (parts, segs) with
      | [], [] -> Some (List.rev acc)
      | p :: ps, Static s :: ss ->
          if p = s then go ps ss acc else None
      | p :: ps, Param name :: ss ->
          go ps ss ((name, p) :: acc)
      | _ -> None
    in
    go parts r.ws_segments []
  in
  let candidates = List.rev !ws_routes in
  let rec find = function
    | [] -> None
    | r :: rest -> (
        match try_route r with
        | Some params -> Some (r, params)
        | None -> find rest)
  in
  find candidates

(* Wire up LiveView WS route registration *)
let () = Liveview._register_ws_route := ws

(* ── Session cookie ───────────────────────────────────────────────── *)

let generate_session_id () =
  let data = Printf.sprintf "%f-%d" (Unix.gettimeofday ()) (Random.bits ()) in
  Digestif.SHA1.(digest_string data |> to_hex)

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

(* ── Session middleware ───────────────────────────────────────────── *)

let session_middleware : middleware = fun next req ->
  let existing = parse_session_id req.headers in
  let session_id, new_session =
    match existing with
    | Some sid -> (sid, false)
    | None -> (generate_session_id (), true)
  in
  let resp = next { req with session_id } in
  if new_session then
    header "Set-Cookie"
      (Printf.sprintf "well_session=%s; HttpOnly; SameSite=Strict; Path=/"
         session_id)
      resp
  else resp

(* ── Route matching ────────────────────────────────────────────────── *)

let match_route meth path =
  let parts = split_path path in
  let try_route r =
    if r.meth <> meth then None
    else
      let rec go parts segs acc =
        match (parts, segs) with
        | [], [] -> Some (List.rev acc)
        | p :: ps, Static s :: ss ->
            if p = s then go ps ss acc else None
        | p :: ps, Param name :: ss ->
            go ps ss ((name, p) :: acc)
        | _ -> None
      in
      go parts r.segments []
  in
  let candidates = List.rev !routes in
  let rec find = function
    | [] -> None
    | r :: rest -> (
        match try_route r with
        | Some params -> Some (r, params)
        | None -> find rest)
  in
  find candidates

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

(* ── URL decoding ──────────────────────────────────────────────────── *)

let url_decode s =
  let buf = Buffer.create (String.length s) in
  let len = String.length s in
  let i = ref 0 in
  while !i < len do
    (match s.[!i] with
    | '+' -> Buffer.add_char buf ' '
    | '%' when !i + 2 < len -> (
        let hex = String.sub s (!i + 1) 2 in
        match int_of_string_opt ("0x" ^ hex) with
        | Some c ->
            Buffer.add_char buf (Char.chr c);
            i := !i + 2
        | None -> Buffer.add_char buf '%')
    | c -> Buffer.add_char buf c);
    incr i
  done;
  Buffer.contents buf

(* ── Form body parsing ────────────────────────────────────────────── *)

let form_params (req : request) =
  String.split_on_char '&' req.body
  |> List.filter_map (fun pair ->
         match String.index_opt pair '=' with
         | None ->
             if pair <> "" then Some (url_decode pair, "") else None
         | Some j ->
             let k = String.sub pair 0 j in
             let v =
               String.sub pair (j + 1) (String.length pair - j - 1)
             in
             Some (url_decode k, url_decode v))

let form req key =
  match List.assoc_opt key (form_params req) with
  | Some v -> v
  | None -> ""

(* ── Raw HTTP/1.1 parsing ─────────────────────────────────────────── *)

let read_line_crlf reader =
  let line = Eio.Buf_read.line reader in
  if String.length line > 0 && line.[String.length line - 1] = '\r' then
    String.sub line 0 (String.length line - 1)
  else line

let parse_request_line reader =
  let line = read_line_crlf reader in
  match String.split_on_char ' ' line with
  | [ meth; path; _version ] -> (meth, path)
  | _ -> ("GET", "/")

let parse_headers reader =
  let rec go acc =
    let line = read_line_crlf reader in
    if line = "" then List.rev acc
    else
      match String.index_opt line ':' with
      | None -> go acc
      | Some i ->
          let name = String.sub line 0 i |> String.lowercase_ascii in
          let value =
            String.sub line (i + 1) (String.length line - i - 1)
            |> String.trim
          in
          go ((name, value) :: acc)
  in
  go []

let read_body reader headers =
  match List.assoc_opt "content-length" headers with
  | None -> ""
  | Some len_str -> (
      match int_of_string_opt len_str with
      | None -> ""
      | Some len ->
          if len <= 0 then ""
          else Eio.Buf_read.take len reader)

(* ── Response resolution ───────────────────────────────────────────── *)

type resolved = {
  r_status : int;
  r_headers : (string * string) list;
  r_body : string;
}

let rec resolve (resp : response) : resolved =
  match resp with
  | ( `Null | `Bool _ | `Int _ | `Float _ | `String _ | `Intlit _
    | `List _ | `Assoc _ ) as json ->
      { r_status = 200;
        r_headers = [ ("Content-Type", "application/json") ];
        r_body = Yojson.Safe.to_string (json :> Yojson.Safe.t) }
  | `Html s ->
      { r_status = 200;
        r_headers = [ ("Content-Type", "text/html; charset=utf-8") ];
        r_body = s }
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
      { r_status = final_status;
        r_headers = c.headers @ inner.r_headers;
        r_body = inner.r_body }

let rec response_status (resp : response) : int =
  match resp with
  | `Custom c ->
      (match c.status with Some s -> s | None -> response_status c.body)
  | `Redirect _ -> 302
  | _ -> 200

(* ── Static file serving ──────────────────────────────────────────── *)

let try_serve_static meth path headers =
  if meth <> "GET" && meth <> "HEAD" then None
  else
    let rec try_mounts = function
      | [] -> None
      | (mount : static_mount) :: rest ->
          let plen = String.length mount.prefix in
          if String.length path >= plen
             && String.sub path 0 plen = mount.prefix
          then
            let rel =
              if String.length path = plen then ""
              else String.sub path (plen + 1) (String.length path - plen - 1)
            in
            if rel = "" || not (is_safe_path rel) then try_mounts rest
            else
              let file_path = Filename.concat mount.dir rel in
              (try
                 let stat = Unix.stat file_path in
                 if stat.Unix.st_kind <> Unix.S_REG then try_mounts rest
                 else
                   let etag = file_etag stat in
                   let client_etag =
                     List.assoc_opt "if-none-match" headers
                   in
                   if client_etag = Some etag then
                     Some
                       {
                         r_status = 304;
                         r_headers = [ ("ETag", etag) ];
                         r_body = "";
                       }
                   else
                     let ext = file_ext file_path in
                     let mime = ext_to_mime ext in
                     let content_type =
                       if is_text_mime mime then mime ^ "; charset=utf-8"
                       else mime
                     in
                     let body =
                       if meth = "HEAD" then ""
                       else
                         let ic = open_in_bin file_path in
                         let len = in_channel_length ic in
                         let buf = Bytes.create len in
                         really_input ic buf 0 len;
                         close_in ic;
                         Bytes.unsafe_to_string buf
                     in
                     Some
                       {
                         r_status = 200;
                         r_headers =
                           [
                             ("Content-Type", content_type);
                             ("ETag", etag);
                             ("Cache-Control", "public, max-age=3600");
                           ];
                         r_body = body;
                       }
               with
              | Unix.Unix_error (Unix.ENOENT, _, _) -> try_mounts rest
              | Unix.Unix_error (Unix.EACCES, _, _) ->
                  Some
                    {
                      r_status = 403;
                      r_headers =
                        [
                          ("Content-Type", "text/plain; charset=utf-8");
                        ];
                      r_body = "Forbidden";
                    })
          else try_mounts rest
    in
    try_mounts !static_mounts

(* ── Response writing ──────────────────────────────────────────────── *)

let status_text = function
  | 200 -> "OK"
  | 201 -> "Created"
  | 204 -> "No Content"
  | 301 -> "Moved Permanently"
  | 302 -> "Found"
  | 304 -> "Not Modified"
  | 400 -> "Bad Request"
  | 401 -> "Unauthorized"
  | 403 -> "Forbidden"
  | 404 -> "Not Found"
  | 405 -> "Method Not Allowed"
  | 429 -> "Too Many Requests"
  | 500 -> "Internal Server Error"
  | code -> string_of_int code

let write_response flow resolved =
  let buf = Buffer.create 256 in
  Buffer.add_string buf
    (Printf.sprintf "HTTP/1.1 %d %s\r\n" resolved.r_status
       (status_text resolved.r_status));
  List.iter
    (fun (k, v) ->
      Buffer.add_string buf (Printf.sprintf "%s: %s\r\n" k v))
    resolved.r_headers;
  Buffer.add_string buf
    (Printf.sprintf "Content-Length: %d\r\n"
       (String.length resolved.r_body));
  Buffer.add_string buf "Connection: close\r\n";
  Buffer.add_string buf "\r\n";
  Buffer.add_string buf resolved.r_body;
  Eio.Flow.copy_string (Buffer.contents buf) flow

(* ── Built-in middleware ─────────────────────────────────────────── *)

let logger : middleware = fun next req ->
  let t0 = Unix.gettimeofday () in
  let resp = next req in
  let dt = (Unix.gettimeofday () -. t0) *. 1000.0 in
  Printf.printf "[well] %s %s -> %d (%.1fms)\n%!"
    req.meth req.path (response_status resp) dt;
  resp

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

(* ── Error handler middleware ────────────────────────────────────── *)

let _dev_mode = ref true
let _custom_error_handler : (exn -> request -> response) option ref = ref None

let dev_mode b = _dev_mode := b

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

let error_handler : middleware = fun next req ->
  try next req
  with exn ->
    let bt = Printexc.get_raw_backtrace () in
    Printf.eprintf "[well] %s %s ERROR: %s\n%s\n%!" req.meth req.path
      (Printexc.to_string exn) (Printexc.raw_backtrace_to_string bt);
    match !_custom_error_handler with
    | Some h ->
        (try h exn req with _ -> `Text "Internal Server Error" |> status 500)
    | None ->
        if !_dev_mode then
          `Html (dev_error_page exn bt req) |> status 500
        else
          `Text "Internal Server Error" |> status 500

(* ── CSRF middleware ─────────────────────────────────────────────── *)

let _csrf_tokens : (string, string) Hashtbl.t = Hashtbl.create 64

module Csrf_ctx = Context(struct type t = string let empty = "" end)

let generate_csrf_token () =
  let data = Printf.sprintf "csrf-%f-%d" (Unix.gettimeofday ()) (Random.bits ()) in
  Digestif.SHA1.(digest_string data |> to_hex)

let csrf_token req = Csrf_ctx.get req

let csrf : middleware = fun next req ->
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
          match List.assoc_opt "_csrf_token" (form_params req) with
          | Some t -> t
          | None -> ""
        in
        if from_form <> "" then from_form
        else
          match List.assoc_opt "x-csrf-token" req.headers with
          | Some t -> t
          | None -> ""
      in
      if submitted = token then next req
      else `Text "Forbidden — invalid CSRF token" |> status 403

(* ── Rate limiting middleware ────────────────────────────────────── *)

let _rate_limit_store : (string, float list) Hashtbl.t = Hashtbl.create 256
let _rate_limit_counter = ref 0

let rate_limit ~max_requests ~window_ms () : middleware = fun next req ->
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
  (* Cleanup stale entries every 100 requests *)
  incr _rate_limit_counter;
  if !_rate_limit_counter >= 100 then begin
    _rate_limit_counter := 0;
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
  if List.length timestamps >= max_requests then
    let retry_after = int_of_float (window /. 1000.0) in
    `Text "Too Many Requests" |> status 429
    |> header "Retry-After" (string_of_int retry_after)
  else begin
    Hashtbl.replace _rate_limit_store client_key (now :: timestamps);
    next req
  end

(* ── Auth middleware ──────────────────────────────────────────────── *)

let _auth_store : (string, string) Hashtbl.t = Hashtbl.create 64

module Auth_ctx = Context(struct type t = string option let empty = None end)

let login req user_id =
  Hashtbl.replace _auth_store req.session_id user_id

let logout req =
  Hashtbl.remove _auth_store req.session_id

let current_user req =
  match Auth_ctx.get req with
  | Some _ as v -> v
  | None -> Hashtbl.find_opt _auth_store req.session_id

let require_auth ?(login_path = "/login") () : middleware = fun next req ->
  let user = Hashtbl.find_opt _auth_store req.session_id in
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
        `Redirect (login_path ^ "?return_to=" ^ req.path)
      else
        `Text "Unauthorized" |> status 401

(* ── Fetch (HTTP client) ───────────────────────────────────────────── *)

type fetch_response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

type parsed_url = {
  p_scheme : string;
  p_host : string;
  p_port : int;
  p_path : string;
}

let parse_fetch_url url =
  let url = String.trim url in
  let lower = String.lowercase_ascii url in
  let scheme, rest =
    if String.length lower > 8 && String.sub lower 0 8 = "https://" then
      ("https", String.sub url 8 (String.length url - 8))
    else if String.length lower > 7 && String.sub lower 0 7 = "http://" then
      ("http", String.sub url 7 (String.length url - 7))
    else ("https", url)
  in
  let host_port, path =
    match String.index_opt rest '/' with
    | Some i -> (String.sub rest 0 i, String.sub rest i (String.length rest - i))
    | None -> (rest, "/")
  in
  let host, port =
    match String.rindex_opt host_port ':' with
    | Some i ->
        let h = String.sub host_port 0 i in
        let p = String.sub host_port (i + 1) (String.length host_port - i - 1) in
        (match int_of_string_opt p with
        | Some port -> (h, port)
        | None -> (host_port, if scheme = "https" then 443 else 80))
    | None -> (host_port, if scheme = "https" then 443 else 80)
  in
  { p_scheme = scheme; p_host = host; p_port = port; p_path = path }

(* System CA certificates — loaded once, cached *)
let system_cas =
  lazy
    (let paths =
       [
         "/etc/ssl/certs/ca-certificates.crt";
         "/etc/pki/tls/certs/ca-bundle.crt";
         "/etc/ssl/cert.pem";
         "/etc/ssl/ca-bundle.pem";
       ]
     in
     let rec try_load = function
       | [] -> failwith "Well.fetch: could not find system CA certificates"
       | p :: rest ->
           if Sys.file_exists p then (
             let ic = open_in_bin p in
             let data = really_input_string ic (in_channel_length ic) in
             close_in ic;
             match X509.Certificate.decode_pem_multiple data with
             | Ok certs when certs <> [] -> certs
             | _ -> try_load rest)
           else try_load rest
     in
     try_load paths)

let fetch_tls_config () =
  let cas = Lazy.force system_cas in
  let time () = Ptime.of_float_s (Unix.gettimeofday ()) in
  let authenticator = X509.Authenticator.chain_of_trust ~time cas in
  match Tls.Config.client ~authenticator () with
  | Ok cfg -> cfg
  | Error (`Msg m) -> failwith ("Well.fetch TLS error: " ^ m)

let fetch_resolve net host port =
  match Eio.Net.getaddrinfo_stream net host ~service:(string_of_int port) with
  | addr :: _ -> addr
  | [] -> failwith ("Well.fetch: could not resolve: " ^ host)

let build_fetch_request ~method_ ~host ~port ~path ~headers ~body =
  let buf = Buffer.create 256 in
  Buffer.add_string buf (method_ ^ " " ^ path ^ " HTTP/1.1\r\n");
  let host_val =
    if port = 80 || port = 443 then host else host ^ ":" ^ string_of_int port
  in
  Buffer.add_string buf ("Host: " ^ host_val ^ "\r\n");
  let has name =
    List.exists (fun (k, _) -> String.lowercase_ascii k = name) headers
  in
  List.iter
    (fun (k, v) -> Buffer.add_string buf (k ^ ": " ^ v ^ "\r\n"))
    headers;
  if body <> "" && not (has "content-length") then
    Buffer.add_string buf
      ("Content-Length: " ^ string_of_int (String.length body) ^ "\r\n");
  if not (has "connection") then
    Buffer.add_string buf "Connection: close\r\n";
  if not (has "user-agent") then
    Buffer.add_string buf "User-Agent: well/0.1\r\n";
  Buffer.add_string buf "\r\n";
  Buffer.add_string buf body;
  Buffer.contents buf

let parse_fetch_status reader =
  let line = read_line_crlf reader in
  match String.index_opt line ' ' with
  | None -> 0
  | Some i ->
      let rest = String.sub line (i + 1) (String.length line - i - 1) in
      (match String.index_opt rest ' ' with
      | None -> Option.value ~default:0 (int_of_string_opt rest)
      | Some j ->
          Option.value ~default:0
            (int_of_string_opt (String.sub rest 0 j)))

let read_chunked_body reader =
  let buf = Buffer.create 4096 in
  let rec loop () =
    let line = read_line_crlf reader in
    let size_str =
      match String.index_opt line ';' with
      | Some i -> String.sub line 0 i
      | None -> line
    in
    match int_of_string_opt ("0x" ^ String.trim size_str) with
    | None | Some 0 -> Buffer.contents buf
    | Some n ->
        Buffer.add_string buf (Eio.Buf_read.take n reader);
        (try ignore (read_line_crlf reader) with _ -> ());
        loop ()
  in
  loop ()

let read_fetch_body reader hdrs =
  let is_chunked =
    match List.assoc_opt "transfer-encoding" hdrs with
    | Some v -> String.lowercase_ascii (String.trim v) = "chunked"
    | None -> false
  in
  if is_chunked then read_chunked_body reader
  else
    match List.assoc_opt "content-length" hdrs with
    | Some s -> (
        match int_of_string_opt s with
        | Some n when n > 0 -> Eio.Buf_read.take n reader
        | _ -> "")
    | None ->
        (* Read until EOF (Connection: close) *)
        let buf = Buffer.create 4096 in
        (try
           while true do
             Buffer.add_char buf (Eio.Buf_read.any_char reader)
           done;
           assert false
         with End_of_file | Eio.Io _ -> Buffer.contents buf)

(* Forward ref — set by Well.run, captures EIO net capability *)
let _fetch_impl =
  ref
    (fun ~method_:(_ : string) ~headers:(_ : (string * string) list)
         ~body:(_ : string) (_ : string) : fetch_response ->
      failwith "Well.fetch: must be called within Well.run")

let fetch ?(method_ = "GET") ?(headers = []) ?(body = "") url =
  !_fetch_impl ~method_ ~headers ~body url

(* ── Server ────────────────────────────────────────────────────────── *)

let handle_connection flow _addr =
  let close_flow () = Eio.Flow.close flow in
  let flow = (flow :> Eio.Flow.two_way_ty Eio.Resource.t) in
  let reader =
    Eio.Buf_read.of_flow ~max_size:(64 * 1024) flow
  in
  (try
     let meth, raw_path = parse_request_line reader in
     let hdrs = parse_headers reader in
     let query_params =
       parse_query raw_path
       |> List.map (fun (k, v) -> (url_decode k, url_decode v))
     in
     let path =
       match String.index_opt raw_path '?' with
       | Some i -> String.sub raw_path 0 i
       | None -> raw_path
     in
     (* Check for WebSocket upgrade — bypasses middleware *)
     let is_upgrade =
       match List.assoc_opt "upgrade" hdrs with
       | Some v -> String.lowercase_ascii v = "websocket"
       | None -> false
     in
     if is_upgrade then begin
       let existing_session = parse_session_id hdrs in
       let session_id =
         match existing_session with
         | Some sid -> sid
         | None -> generate_session_id ()
       in
       match match_ws_route path with
       | Some (route, params) ->
           (match Websocket.handshake hdrs flow reader with
            | Ok ws ->
                let body = read_body reader hdrs in
                let req =
                  { meth; path; headers = hdrs; body; params;
                    query = query_params; session_id; _context = [] }
                in
                (try route.ws_handler req ws
                 with exn ->
                   Printf.eprintf "[well] ws handler error: %s\n%!"
                     (Printexc.to_string exn));
                Websocket.close ws
            | Error msg ->
                Printf.eprintf "[well] ws handshake error: %s\n%!" msg;
                let r = resolve (`Text "Bad Request" |> status 400) in
                write_response flow r;
                close_flow ())
       | None ->
           let r = resolve (`Text "Not Found" |> status 404) in
           write_response flow r;
           close_flow ()
     end else begin
       let body = read_body reader hdrs in
       let base_handler (req : request) =
         match match_route req.meth req.path with
         | Some (route, params) ->
             (try route.handler { req with params }
              with exn ->
                let msg = Printexc.to_string exn in
                Printf.eprintf "[well] handler error: %s\n%!" msg;
                `Text ("Internal Server Error: " ^ msg) |> status 500)
         | None ->
             (match try_serve_static req.meth req.path req.headers with
              | Some r ->
                  `Custom { status = Some r.r_status;
                            headers = r.r_headers; body = `Text r.r_body }
              | None -> `Text "Not Found" |> status 404)
       in
       let pipeline =
         session_middleware
           (apply_middlewares (List.rev !global_middlewares) base_handler)
       in
       let req =
         { meth; path; headers = hdrs; body; params = [];
           query = query_params; session_id = ""; _context = [] }
       in
       let resp = pipeline req in
       let resolved = resolve resp in
       write_response flow resolved;
       close_flow ()
     end
   with
  | Eio.Io _ -> (try close_flow () with _ -> ())
  | End_of_file -> (try close_flow () with _ -> ())
  | exn ->
      Printf.eprintf "[well] connection error: %s\n%!"
        (Printexc.to_string exn);
      (try close_flow () with _ -> ()))

(* ── TLS support ──────────────────────────────────────────────────── *)

let handle_tls_connection tls_cfg flow addr =
  let tls_flow =
    try Some (Tls_eio.server_of_flow tls_cfg flow)
    with
    | Tls_eio.Tls_alert a ->
        Printf.eprintf "[well] TLS alert: %s\n%!"
          (Tls.Packet.alert_type_to_string a);
        None
    | Tls_eio.Tls_failure f ->
        Printf.eprintf "[well] TLS failure: %s\n%!"
          (Tls.Engine.string_of_failure f);
        None
  in
  match tls_flow with
  | None -> Eio.Flow.close flow
  | Some tls -> handle_connection tls addr

let load_tls_config ~env ~cert ~key =
  let fs = Eio.Stdenv.fs env in
  let cert_path = Eio.Path.(fs / cert) in
  let key_path = Eio.Path.(fs / key) in
  let certificate = X509_eio.private_of_pems ~cert:cert_path ~priv_key:key_path in
  match Tls.Config.server ~certificates:(`Single certificate) () with
  | Ok cfg -> cfg
  | Error (`Msg msg) -> failwith ("TLS config error: " ^ msg)

let run ?(port = 4000) ?cert ?key () =
  Printexc.record_backtrace true;
  let tls_enabled =
    match (cert, key) with
    | Some _, Some _ -> true
    | None, None -> false
    | _ -> failwith "Both ~cert and ~key must be provided for TLS"
  in
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  _fetch_impl :=
    (fun ~method_ ~headers ~body url ->
      let parsed = parse_fetch_url url in
      let req_str =
        build_fetch_request ~method_ ~host:parsed.p_host ~port:parsed.p_port
          ~path:parsed.p_path ~headers ~body
      in
      let addr = fetch_resolve net parsed.p_host parsed.p_port in
      Eio.Switch.run @@ fun sw ->
      let tcp_flow = Eio.Net.connect ~sw net addr in
      let send_and_receive flow =
        Eio.Flow.copy_string req_str flow;
        let reader = Eio.Buf_read.of_flow ~max_size:(10 * 1024 * 1024) flow in
        let status = parse_fetch_status reader in
        let resp_hdrs = parse_headers reader in
        let body = read_fetch_body reader resp_hdrs in
        { status; headers = resp_hdrs; body }
      in
      if parsed.p_scheme = "https" then (
        let tls_cfg = fetch_tls_config () in
        let host =
          Option.bind
            (Domain_name.of_string parsed.p_host |> Result.to_option)
            (fun dn -> Domain_name.host dn |> Result.to_option)
        in
        let tls_flow = Tls_eio.client_of_flow ?host tls_cfg tcp_flow in
        send_and_receive tls_flow)
      else send_and_receive tcp_flow);
  let start_server () =
    Eio.Switch.run @@ fun sw ->
    let tls_cfg =
      if tls_enabled then
        Some (load_tls_config ~env
                ~cert:(Option.get cert) ~key:(Option.get key))
      else None
    in
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
    let socket =
      Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true addr
    in
    let scheme = if tls_enabled then "https" else "http" in
    Printf.printf "[well] listening on %s://localhost:%d\n%!" scheme port;
    let handler =
      match tls_cfg with
      | Some cfg -> handle_tls_connection cfg
      | None -> handle_connection
    in
    let rec accept_loop () =
      Eio.Net.accept_fork socket ~sw
        ~on_error:(fun exn ->
          Printf.eprintf "[well] accept error: %s\n%!"
            (Printexc.to_string exn))
        handler;
      accept_loop ()
    in
    accept_loop ()
  in
  Mirage_crypto_rng_unix.use_default ();
  start_server ()

(* ── LiveView registration ─────────────────────────────────────────── *)

let live path (module View : Liveview.VIEW) =
  let endpoint = "/live" ^ path in
  Liveview.register endpoint (module View)

(* ── Re-export submodules ─────────────────────────────────────────── *)

module Websocket = Websocket
module LiveView = Liveview
