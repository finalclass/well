let version = "1.3.0"

(* ── Types ─────────────────────────────────────────────────────────── *)

include Types

type stream_config = {
  stream_status : int;
  stream_content_type : string;
  stream_headers : (string * string) list;
  stream_fn : (string -> unit) -> unit;
}

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
  | `Stream of stream_config
  ]

(* ── Response constructors ─────────────────────────────────────────── *)

let html s : response = `Html s
let text s : response = `Text s
let json (j : Yojson.Safe.t) : response = (j :> response)
let redirect url : response = `Redirect url

let stream ?(content_type = "application/octet-stream") ?(status = 200)
    ?(headers = []) fn : response =
  `Stream { stream_status = status; stream_content_type = content_type;
            stream_headers = headers; stream_fn = fn }

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

type segment = Static of string | Param of string | Wildcard of string

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
  (* Inline percent-decode to detect %2e%2e traversal *)
  let hex c =
    if c >= '0' && c <= '9' then Char.code c - 48
    else if c >= 'a' && c <= 'f' then Char.code c - 87
    else if c >= 'A' && c <= 'F' then Char.code c - 55
    else -1
  in
  let len = String.length path in
  let buf = Buffer.create len in
  let i = ref 0 in
  while !i < len do
    if path.[!i] = '%' && !i + 2 < len then begin
      let h = hex path.[!i + 1] and l = hex path.[!i + 2] in
      if h >= 0 && l >= 0 then begin
        Buffer.add_char buf (Char.chr (h * 16 + l)); i := !i + 3
      end else begin
        Buffer.add_char buf path.[!i]; incr i
      end
    end else begin
      Buffer.add_char buf path.[!i]; incr i
    end
  done;
  let decoded = Buffer.contents buf in
  let segments = String.split_on_char '/' decoded in
  not (List.exists (fun seg -> seg = ".." || seg = ".") segments)
  && not (String.contains decoded '\000')

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

(* ── Cap routes (bypass global middleware) ─────────────────────────── *)

let cap_routes : route list ref = ref []

let register_cap meth path handler =
  let segments = parse_segments (split_path path) in
  cap_routes := { meth; segments; handler } :: !cap_routes

let match_cap_route meth path =
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
        | rest, [ Wildcard name ] ->
            Some (List.rev ((name, String.concat "/" rest) :: acc))
        | _ -> None
      in
      go parts r.segments []
  in
  let candidates = List.rev !cap_routes in
  let rec find = function
    | [] -> None
    | r :: rest -> (
        match try_route r with
        | Some params -> Some (r, params)
        | None -> find rest)
  in
  find candidates

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
      | rest, [ Wildcard name ] ->
          Some (List.rev ((name, String.concat "/" rest) :: acc))
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

(* Wire up LiveView + Channel WS route registration *)
let () = Liveview._register_ws_route := ws
let () = Channel._register_ws_route := ws


(* ── Session config ───────────────────────────────────────────────── *)

let _session_lifetime = ref 86400 (* seconds, default 24h *)

(* ── Session cookie ───────────────────────────────────────────────── *)

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

(* ── Flash context ───────────────────────────────────────────────── *)

module Flash_ctx = Context(struct
  type t = (string * string) list
  let empty = []
end)

(* ── Session middleware ───────────────────────────────────────────── *)

let _tls_active = ref false
let _flash_prefix = "_flash:"

let parse_session_id_from_header headers =
  (* Try Authorization: Bearer <session_id> *)
  match List.assoc_opt "authorization" headers with
  | Some auth_value ->
    let prefix = "Bearer " in
    let plen = String.length prefix in
    if String.length auth_value > plen
       && String.sub auth_value 0 plen = prefix then
      Some (String.sub auth_value plen (String.length auth_value - plen))
    else
      (* Try X-Session-Id header *)
      List.assoc_opt "x-session-id" headers
  | None ->
    List.assoc_opt "x-session-id" headers

let session_middleware : middleware = fun next req ->
  (* Priority: cookie > Authorization: Bearer > X-Session-Id > new session *)
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
  (* Load flash from session store, then delete consumed entries *)
  let flash_entries =
    Session_store.get_all_with_prefix ~session_id ~prefix:_flash_prefix
  in
  if flash_entries <> [] then
    Session_store.delete_all_with_prefix ~session_id ~prefix:_flash_prefix;
  let req = Flash_ctx.set flash_entries { req with session_id } in
  let resp = next req in
  if new_session then
    let secure = if !_tls_active then "; Secure" else "" in
    header "Set-Cookie"
      (Printf.sprintf "well_session=%s; HttpOnly; SameSite=Lax; Path=/%s"
         session_id secure)
      resp
  else resp

(* ── Session API ─────────────────────────────────────────────────── *)

let session_get req key =
  Session_store.get ~session_id:req.session_id ~key

let session_set req key value =
  Session_store.set ~session_id:req.session_id ~key ~value

let session_delete req key =
  Session_store.delete ~session_id:req.session_id ~key

let session_clear req =
  Session_store.clear ~session_id:req.session_id

(* Programmatic session API — no HTTP context required *)
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

let session_lifetime seconds = _session_lifetime := seconds

(* Wire Auth session forward refs *)
let () =
  Auth._session_get_ref := (fun sid key -> Session_store.get ~session_id:sid ~key);
  Auth._session_set_ref := (fun sid key value -> Session_store.set ~session_id:sid ~key ~value);
  Auth._session_delete_ref := (fun sid key -> Session_store.delete ~session_id:sid ~key)

let _session_regenerate_hook : (string -> string -> unit) ref = ref (fun _ _ -> ())

let session_regenerate req =
  let old_sid = req.session_id in
  let new_sid = generate_session_id () in
  Session_store.copy_and_delete ~old_session_id:old_sid ~new_session_id:new_sid;
  !_session_regenerate_hook old_sid new_sid;
  let new_req = { req with session_id = new_sid } in
  let secure = if !_tls_active then "; Secure" else "" in
  let set_cookie resp =
    header "Set-Cookie"
      (Printf.sprintf "well_session=%s; HttpOnly; SameSite=Lax; Path=/%s"
         new_sid secure)
      resp
  in
  (new_req, set_cookie)

(* Wire OAuth route handler — uses session_regenerate for post-login *)
let () = Oauth._handle_get_ref := (fun path handler ->
  get path (fun req ->
    match handler req with
    | Oauth.ORedirect url -> (`Redirect url :> response)
    | Oauth.OHtml (body, code) -> (status code (`Html body) :> response)
    | Oauth.ORedirectWithRegenerate url ->
      let (_new_req, set_cookie) = session_regenerate req in
      (set_cookie (`Redirect url) :> response)))

(* ── RPC context ─────────────────────────────────────────────────── *)

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

let _request_id_counter = ref 0

let rpc_ctx (req : request) : rpc_ctx =
  incr _request_id_counter;
  let request_id =
    Printf.sprintf "%s-%d-%f" req.session_id !_request_id_counter
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
  (* Filter out internal keys like _flash:kind from session_data *)
  let session_data = List.filter (fun (k, _) ->
    not (String.length k > 7 && String.sub k 0 7 = "_flash:")) all_data
  in
  { session_id = req.session_id; request_id; user_id; user_name; locale; session_data }

(* ── Flash API ───────────────────────────────────────────────────── *)

let put_flash (req : request) kind message =
  Session_store.set ~session_id:req.session_id
    ~key:(_flash_prefix ^ kind) ~value:message

let get_flash req kind =
  let key = _flash_prefix ^ kind in
  let entries = Flash_ctx.get req in
  List.assoc_opt key entries

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
        | rest, [ Wildcard name ] ->
            Some (List.rev ((name, String.concat "/" rest) :: acc))
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

(* ── Body size config ─────────────────────────────────────────────── *)

let _max_body_size = ref (10 * 1024 * 1024) (* 10 MB *)
let max_body_size n = _max_body_size := n

exception Body_too_large

(* ── Multipart parsing ───────────────────────────────────────────── *)

type uploaded_file = {
  filename : string;
  content_type : string;
  size : int;
  data : string;
}

type multipart_data = {
  fields : (string * string) list;
  files : (string * uploaded_file) list;
}

let extract_boundary content_type =
  let ct = String.lowercase_ascii content_type in
  if not (try ignore (Str.search_forward (Str.regexp_string "multipart/form-data") ct 0); true
          with Not_found -> false)
  then None
  else
    match Str.search_forward (Str.regexp_case_fold {|boundary=\([^ ;]*\)|}) content_type 0 with
    | _ -> Some (Str.matched_group 1 content_type)
    | exception Not_found -> None

let is_multipart headers =
  match List.assoc_opt "content-type" headers with
  | Some ct -> extract_boundary ct <> None
  | None -> false

let find_substring ~needle haystack start =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 then Some start
  else
    let limit = hlen - nlen in
    let rec search i =
      if i > limit then None
      else if String.sub haystack i nlen = needle then Some i
      else search (i + 1)
    in
    search start

let parse_disposition header_val =
  let name =
    match Str.search_forward (Str.regexp {|name="\([^"]*\)"|}) header_val 0 with
    | _ -> Some (Str.matched_group 1 header_val)
    | exception Not_found -> None
  in
  let filename =
    match Str.search_forward (Str.regexp {|filename="\([^"]*\)"|}) header_val 0 with
    | _ -> Some (Str.matched_group 1 header_val)
    | exception Not_found -> None
  in
  (name, filename)

let parse_multipart boundary body =
  let delim = "--" ^ boundary in
  let fields = ref [] in
  let files = ref [] in
  let start =
    match find_substring ~needle:delim body 0 with
    | Some i -> i + String.length delim
    | None -> String.length body
  in
  let close_delim = "\r\n" ^ delim in
  let rec process pos =
    if pos >= String.length body then ()
    else
      let pos =
        if pos + 2 <= String.length body && String.sub body pos 2 = "\r\n"
        then pos + 2
        else pos
      in
      if pos + 2 <= String.length body && String.sub body pos 2 = "--"
      then ()
      else
        match find_substring ~needle:"\r\n\r\n" body pos with
        | None -> ()
        | Some hdr_end ->
            let headers_str = String.sub body pos (hdr_end - pos) in
            let part_body_start = hdr_end + 4 in
            let part_body_end =
              match find_substring ~needle:close_delim body part_body_start with
              | Some i -> i
              | None -> String.length body
            in
            let part_body = String.sub body part_body_start (part_body_end - part_body_start) in
            let part_headers =
              String.split_on_char '\n' headers_str
              |> List.filter_map (fun line ->
                     let line = String.trim line in
                     match String.index_opt line ':' with
                     | None -> None
                     | Some i ->
                         let k = String.sub line 0 i |> String.lowercase_ascii in
                         let v = String.sub line (i + 1) (String.length line - i - 1)
                                 |> String.trim in
                         Some (k, v))
            in
            (match List.assoc_opt "content-disposition" part_headers with
             | Some disp ->
                 let name, filename = parse_disposition disp in
                 (match name, filename with
                  | Some n, Some fn ->
                      let ct =
                        match List.assoc_opt "content-type" part_headers with
                        | Some v -> v
                        | None -> "application/octet-stream"
                      in
                      files := (n, { filename = fn; content_type = ct;
                                     size = String.length part_body;
                                     data = part_body }) :: !files
                  | Some n, None ->
                      fields := (n, part_body) :: !fields
                  | _ -> ())
             | None -> ());
            let next = part_body_end + String.length close_delim in
            process next
  in
  process start;
  { fields = List.rev !fields; files = List.rev !files }

module Multipart_ctx = Context(struct
  type t = multipart_data option
  let empty = None
end)

let get_multipart req =
  match Multipart_ctx.get req with
  | Some d -> d
  | None ->
      match List.assoc_opt "content-type" req.headers with
      | Some ct ->
          (match extract_boundary ct with
           | Some b -> parse_multipart b req.body
           | None -> { fields = []; files = [] })
      | None -> { fields = []; files = [] }

let file req name =
  let data = get_multipart req in
  List.assoc_opt name data.files

let files req name =
  let data = get_multipart req in
  List.filter_map
    (fun (k, v) -> if k = name then Some v else None)
    data.files

let all_files req =
  let data = get_multipart req in
  data.files

(* ── Form body parsing ────────────────────────────────────────────── *)

let parse_urlencoded body =
  String.split_on_char '&' body
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

let form_params (req : request) =
  if is_multipart req.headers then
    let data =
      match Multipart_ctx.get req with
      | Some d -> d
      | None ->
          match List.assoc_opt "content-type" req.headers with
          | Some ct ->
              (match extract_boundary ct with
               | Some b -> parse_multipart b req.body
               | None -> { fields = []; files = [] })
          | None -> { fields = []; files = [] }
    in
    data.fields
  else
    parse_urlencoded req.body

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

exception Headers_too_large

let _max_header_count = 100
let _max_header_bytes = 64 * 1024  (* 64 KB total *)

let parse_headers reader =
  let rec go acc count total_bytes =
    let line = read_line_crlf reader in
    if line = "" then List.rev acc
    else
      let total_bytes = total_bytes + String.length line + 2 in
      let count = count + 1 in
      if count > _max_header_count || total_bytes > _max_header_bytes then
        raise Headers_too_large
      else
        match String.index_opt line ':' with
        | None -> go acc count total_bytes
        | Some i ->
            let name = String.sub line 0 i |> String.lowercase_ascii in
            let value =
              String.sub line (i + 1) (String.length line - i - 1)
              |> String.trim
            in
            go ((name, value) :: acc) count total_bytes
  in
  go [] 0 0

let read_chunked_body reader =
  let buf = Buffer.create 4096 in
  let total = ref 0 in
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
        total := !total + n;
        if !total > !_max_body_size then raise Body_too_large;
        Buffer.add_string buf (Eio.Buf_read.take n reader);
        (try ignore (read_line_crlf reader) with _ -> ());
        loop ()
  in
  loop ()

let read_body reader headers =
  let is_chunked =
    match List.assoc_opt "transfer-encoding" headers with
    | Some v -> String.lowercase_ascii (String.trim v) = "chunked"
    | None -> false
  in
  if is_chunked then read_chunked_body reader
  else
    match List.assoc_opt "content-length" headers with
    | None -> ""
    | Some len_str -> (
        match int_of_string_opt len_str with
        | None -> ""
        | Some len ->
            if len <= 0 then ""
            else if len > !_max_body_size then raise Body_too_large
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
      (* Outer headers override inner headers with the same key *)
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

let rec response_status (resp : response) : int =
  match resp with
  | `Custom c ->
      (match c.status with Some s -> s | None -> response_status c.body)
  | `Redirect _ -> 302
  | `Stream cfg -> cfg.stream_status
  | _ -> 200

(* ── Static file serving ──────────────────────────────────────────── *)

let parse_range_header headers total_size =
  match List.assoc_opt "range" headers with
  | None -> None
  | Some v ->
      let v = String.trim v in
      if String.length v > 6 && String.sub v 0 6 = "bytes=" then
        let range_spec = String.sub v 6 (String.length v - 6) in
        (* Only support single range, no multipart *)
        if String.contains range_spec ',' then None
        else
          match String.index_opt range_spec '-' with
          | None -> None
          | Some dash ->
              let start_s = String.sub range_spec 0 dash in
              let end_s = String.sub range_spec (dash + 1) (String.length range_spec - dash - 1) in
              let start_byte =
                if start_s = "" then None
                else (try Some (int_of_string start_s) with _ -> None)
              in
              let end_byte =
                if end_s = "" then None
                else (try Some (int_of_string end_s) with _ -> None)
              in
              (match start_byte, end_byte with
               | Some s, Some e when s >= 0 && e >= s && s < total_size ->
                   Some (s, min e (total_size - 1))
               | Some s, None when s >= 0 && s < total_size ->
                   Some (s, total_size - 1)
               | None, Some suffix when suffix > 0 ->
                   let s = max 0 (total_size - suffix) in
                   Some (s, total_size - 1)
               | _ -> Some (-1, -1))  (* invalid range sentinel *)
      else None

let _static_stream_threshold = 1024 * 1024 (* 1 MB — stream files larger than this *)

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
              let file_path = Filename.concat mount.dir (url_decode rel) in
              (try
                 let stat = Unix.stat file_path in
                 if stat.Unix.st_kind <> Unix.S_REG then try_mounts rest
                 else
                   let total_size = stat.Unix.st_size in
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
                     let range = parse_range_header headers total_size in
                     (match range with
                      | Some (-1, -1) ->
                          (* Invalid range *)
                          Some {
                            r_status = 416;
                            r_headers = [
                              ("Content-Range", Printf.sprintf "bytes */%d" total_size);
                              ("Accept-Ranges", "bytes");
                            ];
                            r_body = "Range Not Satisfiable";
                          }
                      | Some (start_byte, end_byte) when meth <> "HEAD" ->
                          let len = end_byte - start_byte + 1 in
                          let ic = open_in_bin file_path in
                          let buf =
                            (try
                               seek_in ic start_byte;
                               let b = Bytes.create len in
                               really_input ic b 0 len;
                               close_in ic;
                               b
                             with exn -> close_in_noerr ic; raise exn)
                          in
                          Some {
                            r_status = 206;
                            r_headers = [
                              ("Content-Type", content_type);
                              ("Content-Range", Printf.sprintf "bytes %d-%d/%d" start_byte end_byte total_size);
                              ("Accept-Ranges", "bytes");
                              ("ETag", etag);
                              ("Cache-Control", "public, max-age=3600");
                            ];
                            r_body = Bytes.unsafe_to_string buf;
                          }
                      | Some _ (* HEAD with range *) ->
                          Some {
                            r_status = 206;
                            r_headers = [
                              ("Content-Type", content_type);
                              ("Accept-Ranges", "bytes");
                              ("ETag", etag);
                              ("Cache-Control", "public, max-age=3600");
                            ];
                            r_body = "";
                          }
                      | None ->
                          (* Normal request — full file *)
                          if meth = "HEAD" then
                            Some
                              {
                                r_status = 200;
                                r_headers =
                                  [
                                    ("Content-Type", content_type);
                                    ("Content-Length", string_of_int total_size);
                                    ("Accept-Ranges", "bytes");
                                    ("ETag", etag);
                                    ("Cache-Control", "public, max-age=3600");
                                  ];
                                r_body = "";
                              }
                          else if total_size > _static_stream_threshold then
                            (* Large file — mark for streaming by caller *)
                            Some
                              {
                                r_status = -1;  (* sentinel: stream this file *)
                                r_headers =
                                  [
                                    ("Content-Type", content_type);
                                    ("Accept-Ranges", "bytes");
                                    ("ETag", etag);
                                    ("Cache-Control", "public, max-age=3600");
                                    ("_stream_path", file_path);
                                  ];
                                r_body = "";
                              }
                          else
                            let ic = open_in_bin file_path in
                            let buf =
                              (try
                                 let b = Bytes.create total_size in
                                 really_input ic b 0 total_size;
                                 close_in ic;
                                 b
                               with exn -> close_in_noerr ic; raise exn)
                            in
                            Some
                              {
                                r_status = 200;
                                r_headers =
                                  [
                                    ("Content-Type", content_type);
                                    ("Accept-Ranges", "bytes");
                                    ("ETag", etag);
                                    ("Cache-Control", "public, max-age=3600");
                                  ];
                                r_body = Bytes.unsafe_to_string buf;
                              })
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

(* ── Gzip compression ─────────────────────────────────────────────── *)

let gzip_compress data =
  let len = String.length data in
  let buf = Buffer.create (len / 2) in
  (* Gzip header: magic, method=deflate, flags=0, mtime=0, xfl=0, OS=Unix *)
  Buffer.add_string buf "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03";
  (* Raw deflate (no zlib wrapper) *)
  let pos = ref 0 in
  Zlib.compress ~level:6 ~header:false
    (fun zbuf ->
      let n = min (Bytes.length zbuf) (len - !pos) in
      if n > 0 then Bytes.blit_string data !pos zbuf 0 n;
      pos := !pos + n;
      n)
    (fun zbuf zlen ->
      Buffer.add_subbytes buf zbuf 0 zlen);
  (* CRC32 + uncompressed size, little-endian *)
  let crc = Zlib.update_crc_string 0l data 0 len in
  let add_le32 v =
    Buffer.add_char buf (Char.chr (Int32.to_int v land 0xff));
    Buffer.add_char buf (Char.chr (Int32.to_int (Int32.shift_right_logical v 8) land 0xff));
    Buffer.add_char buf (Char.chr (Int32.to_int (Int32.shift_right_logical v 16) land 0xff));
    Buffer.add_char buf (Char.chr (Int32.to_int (Int32.shift_right_logical v 24) land 0xff))
  in
  add_le32 crc;
  add_le32 (Int32.of_int (len land 0xffffffff));
  Buffer.contents buf

let accepts_gzip headers =
  match List.assoc_opt "accept-encoding" headers with
  | None -> false
  | Some v ->
      String.split_on_char ',' v
      |> List.exists (fun p ->
             let p = String.trim p in
             let enc =
               match String.index_opt p ';' with
               | Some i -> String.trim (String.sub p 0 i)
               | None -> p
             in
             String.lowercase_ascii enc = "gzip")

let should_compress content_type body_len =
  body_len >= 860
  &&
  let base_mime =
    match String.index_opt content_type ';' with
    | Some i -> String.trim (String.sub content_type 0 i)
    | None -> content_type
  in
  is_text_mime base_mime

let maybe_compress headers resolved =
  if resolved.r_body = "" then resolved
  else if resolved.r_status = 206 || resolved.r_status = 304 then resolved
  else if not (accepts_gzip headers) then resolved
  else
    let ct =
      match List.assoc_opt "Content-Type" resolved.r_headers with
      | Some v -> v
      | None -> ""
    in
    if not (should_compress ct (String.length resolved.r_body)) then resolved
    else
      let compressed = gzip_compress resolved.r_body in
      { resolved with
        r_body = compressed;
        r_headers =
          ("Content-Encoding", "gzip")
          :: ("Vary", "Accept-Encoding")
          :: resolved.r_headers;
      }

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
  | 206 -> "Partial Content"
  | 405 -> "Method Not Allowed"
  | 408 -> "Request Timeout"
  | 413 -> "Payload Too Large"
  | 416 -> "Range Not Satisfiable"
  | 429 -> "Too Many Requests"
  | 431 -> "Request Header Fields Too Large"
  | 500 -> "Internal Server Error"
  | code -> string_of_int code

let write_response ?(keep_alive=false) ?(head=false) flow resolved =
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
  if keep_alive then
    Buffer.add_string buf "Connection: keep-alive\r\n"
  else
    Buffer.add_string buf "Connection: close\r\n";
  Buffer.add_string buf "\r\n";
  if not head then Buffer.add_string buf resolved.r_body;
  Eio.Flow.copy_string (Buffer.contents buf) flow

let write_stream_response flow cfg extra_headers =
  let buf = Buffer.create 256 in
  Buffer.add_string buf
    (Printf.sprintf "HTTP/1.1 %d %s\r\n" cfg.stream_status
       (status_text cfg.stream_status));
  Buffer.add_string buf
    (Printf.sprintf "Content-Type: %s\r\n" cfg.stream_content_type);
  Buffer.add_string buf "Transfer-Encoding: chunked\r\n";
  List.iter
    (fun (k, v) ->
      Buffer.add_string buf (Printf.sprintf "%s: %s\r\n" k v))
    (cfg.stream_headers @ extra_headers);
  Buffer.add_string buf "Connection: close\r\n";  (* streams always close *)
  Buffer.add_string buf "\r\n";
  Eio.Flow.copy_string (Buffer.contents buf) flow;
  let write_chunk data =
    if String.length data > 0 then begin
      let chunk =
        Printf.sprintf "%x\r\n%s\r\n" (String.length data) data
      in
      Eio.Flow.copy_string chunk flow
    end
  in
  cfg.stream_fn write_chunk;
  Eio.Flow.copy_string "0\r\n\r\n" flow

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

(* ── Built-in middleware ─────────────────────────────────────────── *)

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

let logger : middleware = fun next req ->
  let t0 = Unix.gettimeofday () in
  let resp = next req in
  let dt = (Unix.gettimeofday () -. t0) *. 1000.0 in
  let st = response_status resp in
  Log.log ~ctx:(req_ctx req) "%s %s -> %d (%.1fms)" req.meth req.path st dt;
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
          `Html (dev_error_page exn bt req) |> status 500
        else
          `Text "Internal Server Error" |> status 500

(* ── CSRF middleware ─────────────────────────────────────────────── *)

let _csrf_tokens : (string, string) Hashtbl.t = Hashtbl.create 64

(* Wire session_regenerate to migrate CSRF tokens *)
let () = _session_regenerate_hook := (fun old_sid new_sid ->
  match Hashtbl.find_opt _csrf_tokens old_sid with
  | Some t -> Hashtbl.replace _csrf_tokens new_sid t; Hashtbl.remove _csrf_tokens old_sid
  | None -> ())

module Csrf_ctx = Context(struct type t = string let empty = "" end)

let generate_csrf_token () =
  let bytes = Mirage_crypto_rng.generate 32 in
  let buf = Buffer.create 64 in
  String.iter (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) bytes;
  Buffer.contents buf

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
      (* Constant-time comparison to prevent timing side-channel *)
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

(* ── Rate limiting middleware ────────────────────────────────────── *)

let _rate_limit_store : (string, float list) Hashtbl.t = Hashtbl.create 256
let _rate_limit_mu = Mutex.create ()
let _rate_limit_counter = ref 0

let rate_limit ~max_requests ~window_ms () : middleware = fun next req ->
  (* Skip rate limiting for static file requests *)
  let is_static =
    List.exists (fun (mount : static_mount) ->
      let plen = String.length mount.prefix in
      String.length req.path >= plen
      && String.sub req.path 0 plen = mount.prefix)
      !static_mounts
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

let current_user req =
  match Auth_ctx.get req with
  | Some _ as v -> v
  | None -> Session_store.get ~session_id:req.session_id ~key:_auth_key

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
        (* Validate return_to is a relative path (no scheme, no //) *)
        let safe_path =
          let p = req.path in
          if String.length p >= 2 && String.sub p 0 2 = "//" then "/"
          else if String.length p >= 1 && p.[0] = '/' then p
          else "/"
        in
        `Redirect (login_path ^ "?return_to=" ^ safe_path)
      else
        `Text "Unauthorized" |> status 401

(* ── Basic Auth middleware ──────────────────────────────────────────── *)

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

let allowed_hosts ~hosts () : middleware = fun next req ->
  let host =
    match List.assoc_opt "host" req.headers with
    | Some h ->
        (* Strip port if present *)
        (match String.index_opt h ':' with
         | Some i -> String.sub h 0 i
         | None -> h)
    | None -> ""
  in
  if host = "" || List.mem host hosts then next req
  else
    `Text "Forbidden — invalid Host header" |> status 403

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

(* ── Security headers middleware ──────────────────────────────────── *)

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

let read_fetch_body ~method_ reader hdrs =
  if method_ = "HEAD" then ""
  else
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

(* ── File operations (via Env) ────────────────────────────────────── *)

let write_file path data =
  Eio.Path.save ~create:(`Or_truncate 0o644) Eio.Path.(Env.cwd () / path) data

let read_file path =
  Eio.Path.load Eio.Path.(Env.cwd () / path)

let file_exists path =
  try ignore (Eio.Path.stat ~follow:true Eio.Path.(Env.cwd () / path)); true
  with Eio.Io _ -> false

let mkdir path =
  try Eio.Path.mkdir ~perm:0o755 Eio.Path.(Env.cwd () / path)
  with Eio.Io _ -> ()

let list_dir path =
  try Eio.Path.read_dir Eio.Path.(Env.cwd () / path) |> List.sort String.compare
  with Eio.Io _ -> []

let stream_file ?(content_type = "application/octet-stream") ?(headers = []) path : response =
  stream ~content_type ~headers (fun write_chunk ->
    let data = read_file path in
    let len = String.length data in
    let chunk_size = 8192 in
    let rec loop off =
      if off < len then begin
        let n = min chunk_size (len - off) in
        write_chunk (String.sub data off n);
        loop (off + n)
      end
    in
    loop 0)

(* ── Request ID ───────────────────────────────────────────────────── *)

let _request_id_counter = Atomic.make 0

let generate_request_id () =
  let n = Atomic.fetch_and_add _request_id_counter 1 in
  let t = int_of_float (Unix.gettimeofday () *. 1000.0) in
  Printf.sprintf "%08x%08x" (t land 0xFFFFFFFF) (n land 0xFFFFFFFF)

let request_id (req : request) =
  match List.assoc_opt "x-request-id" req.headers with
  | Some id -> id
  | None -> ""

(* ── Connection config ─────────────────────────────────────────────── *)

exception Keep_alive_timeout

let _with_ka_timeout t f = Env.with_timeout t f
let _keep_alive_timeout = ref 5.0
let _request_timeout = ref 30.0
let keep_alive_timeout n = _keep_alive_timeout := n
let request_timeout n = _request_timeout := n
let _ws_rate_limit = ref 100.0
let ws_rate_limit n = _ws_rate_limit := n
let ws_max_frame_size n = Websocket._max_frame_size := n
let max_upload_size n = Liveview._max_upload_size := n

(* ── Connection limits ────────────────────────────────────────────── *)

let _max_connections = ref 10_000
let _max_connections_per_ip = ref 100
let _max_requests_per_connection = ref 1_000
let max_connections n = _max_connections := n
let max_connections_per_ip n = _max_connections_per_ip := n
let max_requests_per_connection n = _max_requests_per_connection := n

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
  (* Parse incoming request line + headers (fast, no timeout needed) *)
  let parse_incoming () =
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
    let is_upgrade =
      match List.assoc_opt "upgrade" hdrs with
      | Some v -> String.lowercase_ascii v = "websocket"
      | None -> false
    in
    (meth, path, hdrs, query_params, is_upgrade)
  in
  (* WebSocket upgrade — runs WITHOUT request timeout (WS connections are long-lived) *)
  let handle_ws_upgrade meth path hdrs query_params =
    Log.log "ws upgrade: %s" path;
    let existing_session = parse_session_id hdrs in
    let session_id =
      match existing_session with
      | Some sid -> sid
      | None -> generate_session_id ()
    in
    Telemetry.incr_active_ws ();
    (match match_ws_route path with
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
    `Close  (* WS always closes after *)
  in
  (* Regular HTTP request handler *)
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
        (* Check cap routes first (bypass global middleware) *)
        match (if is_cap_path then match_cap_route req.meth req.path
               else None) with
        | Some (route, params) ->
            (try route.handler { req with params }
             with exn -> safe_500 exn "cap handler")
        | None ->
        (* Auto-HEAD: if HEAD request and no HEAD route, try GET handler *)
        let effective_meth =
          if req.meth = "HEAD" then
            match match_route "HEAD" req.path with
            | Some _ -> "HEAD"
            | None -> "GET"
          else req.meth
        in
        match match_route effective_meth req.path with
        | Some (route, params) ->
            route.handler { req with params }
        | None ->
            (match try_serve_static req.meth req.path req.headers with
             | Some r when r.r_status = -1 ->
                 (* Large file — stream via chunked transfer *)
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
                 (* 405 check: does path match any method? *)
                 let all_methods = ["GET"; "POST"; "PUT"; "DELETE"; "HEAD"] in
                 let matching =
                   List.filter (fun m -> match_route m req.path <> None) all_methods
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
            (apply_middlewares (List.rev !global_middlewares) base_handler)
      in
      let req_id =
        match List.assoc_opt "x-request-id" hdrs with
        | Some id -> id
        | None -> generate_request_id ()
      in
      Domain.DLS.set _current_request_id (Some req_id);
      let req =
        { meth; path; headers = hdrs; body; params = [];
          query = query_params; session_id = ""; _context = [] }
      in
      let resp =
        try pipeline req
        with exn -> safe_500 exn "handler"
      in
      Domain.DLS.set _current_request_id None;
      Telemetry.incr_requests ();
      let dt_us = int_of_float ((Unix.gettimeofday () -. t0) *. 1e6) in
      Telemetry.add_latency_us dt_us;
      let wants_close = client_wants_close hdrs in
      match extract_stream resp with
      | Some (cfg, extra_hdrs) ->
          write_stream_response flow cfg (("X-Request-ID", req_id) :: extra_hdrs);
          `Close  (* stream responses always close *)
      | None ->
          let resolved = maybe_compress hdrs (resolve resp) in
          let resolved = { resolved with r_headers = ("X-Request-ID", req_id) :: resolved.r_headers } in
          if resolved.r_status >= 500 then Telemetry.incr_errors ();
          let ka = not wants_close in
          write_response ~keep_alive:ka ~head:(meth = "HEAD") flow resolved;
          if wants_close then `Close else `KeepAlive
  in
  (* HTTP request with timeout — WS requests bypass this *)
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
  (* Dispatch: parse request, then handle WS (no timeout) or HTTP (with timeout) *)
  let dispatch_request () =
    let (meth, path, hdrs, query_params, is_upgrade) = parse_incoming () in
    if is_upgrade then
      handle_ws_upgrade meth path hdrs query_params
    else
      timed_http_request meth path hdrs query_params
  in
  (* Keep-alive loop with max requests per connection *)
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

let run ?(port = 4000) ?(workers = 0) ?cert ?key ?domain
    ?(acme_staging = false) ?(disable_cap = false) () =
  Printexc.record_backtrace true;
  let acme_mode = domain <> None in
  (* Validate: ~domain and ~cert/~key are mutually exclusive *)
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
  (* Auto-switch port when ~domain is given and port is default *)
  let port = if acme_mode && port = 4000 then 443 else port in
  (* Warn if ~domain with non-443 port *)
  if acme_mode && port <> 443 then
    Log.log ~level:"warn" "~domain given but port is %d (not 443) — ACME validation may fail" port;
  Eio_main.run @@ fun env ->
  Env.set env;
  let net = Env.net () in
  Service._ws_rate_limit := !_ws_rate_limit;
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
        let body = read_fetch_body ~method_ reader resp_hdrs in
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
  (* Wire Acme._fetch_ref — converts fetch_response to Acme.http_response *)
  Acme._fetch_ref :=
    (fun ~method_ ~headers ~body url ->
      let r = !_fetch_impl ~method_ ~headers ~body url in
      { Acme.http_status = r.status;
        http_headers = r.headers;
        http_body = r.body });
  (* Wire S3._fetch_ref — converts fetch_response to (status, headers, body) tuple *)
  S3._fetch_ref :=
    (fun ~method_ ~headers ~body url ->
      let r = !_fetch_impl ~method_ ~headers ~body url in
      (r.status, r.headers, r.body));
  S3._mime_ref := ext_to_mime;
  (* Wire Mailer forward refs *)
  Mailer._fetch_ref :=
    (fun ~method_ ~headers ~body url ->
      let r = !_fetch_impl ~method_ ~headers ~body url in
      (r.status, r.headers, r.body));
  Mailer._set_net net;
  Mailer._tls_config_fn := (fun () -> fetch_tls_config ());
  (* Wire OAuth forward refs *)
  Oauth._fetch_ref :=
    (fun ~method_ ~headers ~body url ->
      let r = !_fetch_impl ~method_ ~headers ~body url in
      (r.status, r.headers, r.body));
  Oauth._session_get_ref := (fun sid key -> Session_store.get ~session_id:sid ~key);
  Oauth._session_set_ref := (fun sid key value -> Session_store.set ~session_id:sid ~key ~value);
  Oauth._session_delete_ref := (fun sid key -> Session_store.delete ~session_id:sid ~key);
  Oauth._put_flash_ref := put_flash;
  Oauth._log_ref := (fun msg -> Log.log "%s" msg);
  (* Wire OAuthProvider forward refs *)
  Oauth_provider._session_get_ref := (fun sid key -> Session_store.get ~session_id:sid ~key);
  Oauth_provider._session_set_ref := (fun sid key value -> Session_store.set ~session_id:sid ~key ~value);
  Oauth_provider._session_delete_ref := (fun sid key -> Session_store.delete ~session_id:sid ~key);
  Oauth_provider._session_clear_ref := (fun sid -> Session_store.clear ~session_id:sid);
  Oauth_provider._login_ref := Auth.login;
  Oauth_provider._current_user_ref := current_user;
  Oauth_provider._register_get_ref := (fun path handler ->
    get path (fun req -> (handler req :> response)));
  Oauth_provider._register_post_ref := (fun path handler ->
    post path (fun req -> (handler req :> response)));
  Oauth_provider._log_ref := (fun msg -> Log.log "%s" msg);
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
    (* Wire up Service forward refs *)
    Service._register_post_json :=
      (fun path handler ->
        register "POST" path (fun req ->
          let result_json = handler req in
          `Custom { status = Some 200;
                    headers = [("Content-Type", "application/json")];
                    body = `Text result_json }));
    Service._build_rpc_ctx :=
      (fun req -> rpc_ctx_to_wire (rpc_ctx req));
    Service._cast_sw := Some sw;
    (* Start all registered services, actors, and periodic tasks *)
    Service.start_all ~sw;
    Actor.start_all ~sw;
    _start_every ~sw;
    (* Unix socket for local IPC *)
    (try Unix.mkdir "data" 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    Service.start_socket ~sw ~net "data/well.sock";
    (* MessageBus + Channel *)
    Message_bus.init ();
    Channel.ensure_ws_route ();
    (* Health endpoint *)
    get "/health" (fun _req ->
      let statuses = Service.full_health () in
      `Assoc (List.map (fun (name, st) -> (name, `String st)) statuses));
    (* Readiness probe *)
    get "/ready" (fun _req ->
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
    (* Prometheus metrics *)
    get "/metrics" (fun _req ->
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
      |> header "Content-Type" "text/plain; version=0.0.4; charset=utf-8");
    (* Session + CSRF auto-cleanup fiber *)
    Eio.Fiber.fork ~sw (fun () ->
      let rec cleanup_loop () =
        Env.sleep 3600.0;
        (try
           let max_age_days =
             max 1 ((!_session_lifetime + 86399) / 86400)
           in
           Session_store.cleanup ~max_age_days () with _ -> ());
        (try Liveview.cleanup_sessions () with _ -> ());
        (try Liveview.cleanup_uploads () with _ -> ());
        (* Prune CSRF tokens for sessions no longer in the store *)
        (try
           let to_remove = ref [] in
           Hashtbl.iter (fun sid _token ->
             if Session_store.get ~session_id:sid ~key:"__exists" = None
             && Session_store.get_all_with_prefix ~session_id:sid ~prefix:"" = []
             then to_remove := sid :: !to_remove
           ) _csrf_tokens;
           List.iter (Hashtbl.remove _csrf_tokens) !to_remove
         with _ -> ());
        cleanup_loop ()
      in
      cleanup_loop ());
    (* Cap *)
    if not disable_cap then begin
      Cap_hook._register_cap_get := (fun path handler ->
        register_cap "GET" path (fun req ->
          match handler req with
          | Cap_hook.CRHtml s -> `Html s
          | Cap_hook.CRRedirect url -> `Redirect url
          | Cap_hook.CRJson s ->
              `Text s |> header "content-type" "application/json"
          | Cap_hook.CRJs s ->
              `Text s |> header "content-type" "application/javascript"));
      Cap_hook._register_cap_post := (fun path handler ->
        register_cap "POST" path (fun req ->
          match handler req with
          | Cap_hook.CRHtml s -> `Html s
          | Cap_hook.CRRedirect url -> `Redirect url
          | Cap_hook.CRJson _ | Cap_hook.CRJs _ ->
              `Text "Method Not Allowed" |> status 405));
      !Cap_hook._cap_init ()
    end;
    (* ── TLS config: ACME auto-TLS / manual TLS / plain ────────── *)
    let tls_cfg =
      match domain with
      | Some dom when port = 443 ->
          (* ACME mode: provision cert, start port 80 listener *)
          (* Start port 80 first — needed for ACME HTTP-01 validation *)
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
          (* Provision or load certificate *)
          let cert_pem, domain_key =
            Acme.ensure_certificate ~staging:acme_staging dom
          in
          let cfg = Acme.build_tls_config cert_pem domain_key in
          Acme._tls_config := Some cfg;
          (* Fork renewal fiber *)
          Eio.Fiber.fork ~sw (fun () ->
            Acme.renewal_fiber ~staging:acme_staging dom);
          Some cfg
      | Some _ ->
          (* ~domain with non-443 port — skip ACME, plain HTTP *)
          None
      | None ->
          if tls_enabled then
            Some (load_tls_config
                    ~cert:(Option.get cert) ~key:(Option.get key))
          else None
    in
    (* Bind address: 0.0.0.0 for ACME (external access needed), loopback otherwise *)
    let bind_addr =
      if acme_mode then Eio.Net.Ipaddr.V4.any
      else Eio.Net.Ipaddr.V4.loopback
    in
    let addr = `Tcp (bind_addr, port) in
    let socket =
      Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true addr
    in
    _tls_active := tls_cfg <> None;
    let scheme = if !_tls_active then "https" else "http" in
    let host = if acme_mode then "0.0.0.0" else "localhost" in
    Log.log "listening on %s://%s:%d%s" scheme host port
      (if workers > 0 then Printf.sprintf " (%d workers)" workers else "");
    let inner_handler =
      match domain with
      | Some _ ->
          (* ACME mode: read TLS config from mutable ref for hot-reload *)
          (fun flow addr ->
            match !(Acme._tls_config) with
            | Some cfg -> handle_tls_connection cfg flow addr
            | None -> Eio.Flow.close flow)
      | None ->
          (match tls_cfg with
           | Some cfg -> handle_tls_connection cfg
           | None -> handle_connection)
    in
    (* Wrap with connection limits *)
    let handler flow addr =
      let ip = ip_of_addr addr in
      if conn_acquire ip then
        (try inner_handler flow addr; conn_release ip
         with exn -> conn_release ip; raise exn)
      else begin
        (* Over limit — send 503 and close *)
        (try
           let r = resolve (`Text "Service Unavailable" |> status 503) in
           let flow = (flow :> Eio.Flow.two_way_ty Eio.Resource.t) in
           write_response flow r
         with _ -> ());
        Eio.Flow.close flow
      end
    in
    (* Fork accept loop *)
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
    (* Main fiber: await shutdown signal *)
    Eio.Promise.await shutdown_p;
    Log.log "shutting down...";
    Env.sleep 0.5;
    Db.close_well_db ();
    Log.log "stopped.";
    Log.close ();
    (* Raise to exit switch — cancels accept loop + all connection fibers *)
    raise Shutdown
  in
  Mirage_crypto_rng_unix.use_default ();
  (try start_server () with
   | Shutdown -> ()
   | Eio.Exn.Multiple exns ->
       (* Shutdown + cleanup exceptions from cancelled fibers — ignore *)
       let dominated_by_shutdown =
         List.exists (fun (exn, _bt) -> exn = Shutdown) exns in
       if not dominated_by_shutdown then
         raise (Eio.Exn.Multiple exns))

(* ── Test server ──────────────────────────────────────────────────── *)

let with_test_server ?(port = 0) ?(disable_cap = false) f =
  Random.self_init ();
  let test_port = if port > 0 then port else 40000 + Random.int 20000 in
  Eio_main.run @@ fun env ->
  Env.set env;
  let net = Env.net () in
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
        let body = read_fetch_body ~method_ reader resp_hdrs in
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
  S3._fetch_ref :=
    (fun ~method_ ~headers ~body url ->
      let r = !_fetch_impl ~method_ ~headers ~body url in
      (r.status, r.headers, r.body));
  S3._mime_ref := ext_to_mime;
  (* Wire Mailer forward refs for test server *)
  Mailer._fetch_ref :=
    (fun ~method_ ~headers ~body url ->
      let r = !_fetch_impl ~method_ ~headers ~body url in
      (r.status, r.headers, r.body));
  Mailer._set_net net;
  Mailer._tls_config_fn := (fun () -> fetch_tls_config ());
  (* Wire OAuth forward refs for test server *)
  Oauth._fetch_ref :=
    (fun ~method_ ~headers ~body url ->
      let r = !_fetch_impl ~method_ ~headers ~body url in
      (r.status, r.headers, r.body));
  Oauth._session_get_ref := (fun sid key -> Session_store.get ~session_id:sid ~key);
  Oauth._session_set_ref := (fun sid key value -> Session_store.set ~session_id:sid ~key ~value);
  Oauth._session_delete_ref := (fun sid key -> Session_store.delete ~session_id:sid ~key);
  Oauth._put_flash_ref := put_flash;
  Oauth._log_ref := (fun msg -> Log.log "%s" msg);
  Mirage_crypto_rng_unix.use_default ();
  Eio.Switch.run @@ fun sw ->
  Service._register_post_json :=
    (fun path handler ->
      register "POST" path (fun req ->
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
  get "/health" (fun _req ->
    let statuses = Service.full_health () in
    `Assoc (List.map (fun (name, st) -> (name, `String st)) statuses));
  get "/ready" (fun _req ->
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
  get "/metrics" (fun _req ->
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
    |> header "Content-Type" "text/plain; version=0.0.4; charset=utf-8");
  if not disable_cap then begin
    Cap_hook._register_cap_get := (fun path handler ->
      register_cap "GET" path (fun req ->
        match handler req with
        | Cap_hook.CRHtml s -> `Html s
        | Cap_hook.CRRedirect url -> `Redirect url
        | Cap_hook.CRJson s ->
            `Text s |> header "content-type" "application/json"
        | Cap_hook.CRJs s ->
            `Text s |> header "content-type" "application/javascript"));
    Cap_hook._register_cap_post := (fun path handler ->
      register_cap "POST" path (fun req ->
        match handler req with
        | Cap_hook.CRHtml s -> `Html s
        | Cap_hook.CRRedirect url -> `Redirect url
        | Cap_hook.CRJson _ | Cap_hook.CRJs _ ->
            `Text "Method Not Allowed" |> status 405));
    !Cap_hook._cap_init ()
  end;
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

(* ── Route introspection ───────────────────────────────────────────── *)

let list_routes () =
  let seg_to_string = function Static s -> s | Param p -> ":" ^ p | Wildcard w -> "*" ^ w in
  let build_path segs = "/" ^ String.concat "/" (List.map seg_to_string segs) in
  let lv_endpoints =
    let acc = ref [] in
    Hashtbl.iter (fun ep _ -> acc := ep :: !acc) Liveview.view_registry;
    !acc
  in
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
  let ws = List.rev_map (fun r ->
    ("WS", build_path r.ws_segments, "websocket")
  ) !ws_routes in
  app_routes @ cap @ ws

(* ── LiveView registration ─────────────────────────────────────────── *)

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
    |> List.map (fun (k, v) -> (url_decode k, url_decode v))
  in
  match match_route "GET" path with
  | Some (route, params) ->
      let nav_req = { req with meth = "GET"; path; params;
                       query = query_params } in
      let pipeline =
        apply_middlewares (List.rev !global_middlewares)
          (fun r -> route.handler { r with params })
      in
      let resp = pipeline nav_req in
      let resolved = resolve resp in
      if resolved.r_status >= 200 && resolved.r_status < 400 then
        Some resolved.r_body
      else None
  | None -> None
)

(* ── Re-export submodules ─────────────────────────────────────────── *)

module Env = Env
module Log = Log
module Acme = Acme
module Cap_hook = Cap_hook
module Db = Db
module Form = Form
module Websocket = Websocket
module LiveView = Liveview
module Service = Service
module Actor = Actor
module MessageBus = Message_bus
module Channel = Channel
module Auth = Auth
module OAuth = Oauth
module OAuthProvider = Oauth_provider
module Mailer = Mailer
module S3 = S3
module Telemetry = Telemetry

(* ── URL encoding ──────────────────────────────────────────────── *)

let url_encode str =
  let buf = Buffer.create (String.length str * 3) in
  String.iter (fun c ->
    match c with
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '~' | '.' ->
      Buffer.add_char buf c
    | _ -> Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c))
  ) str;
  Buffer.contents buf

(* ── Typed pub/sub ────────────────────────────────────────────────── *)

(* ── Env convenience re-exports ───────────────────────────────────── *)

let env = Env.get
let net = Env.net
let clock = Env.clock
let cwd = Env.cwd
let fs = Env.fs
let sleep = Env.sleep

type 'a topic = 'a Message_bus.topic
type 'a event = 'a Message_bus.typed_event = { id : int; value : 'a; created_at : float }

let topic = Message_bus.make_topic
let log = Log.log

let topic_name (t : _ topic) = t.Message_bus.t_channel
let publish ?ephemeral t v = ignore (Message_bus.publish_typed ?ephemeral t v)
let subscribe ?live_only t f = Message_bus.subscribe_typed ?live_only t f
let is_replaying = Message_bus.is_replaying
let replay ?since_id t f = Message_bus.replay_typed ?since_id t f
let prune = Message_bus.prune

(* ── Keyed pub/sub (channel:key) ─────────────────────────────────── *)

type 'a keyed_event = 'a Message_bus.keyed_event = {
  key : string;
  event : 'a event;
}

let publish_keyed ?ephemeral t ~key v =
  ignore (Message_bus.publish_keyed_typed ?ephemeral t ~key v)

let subscribe_keyed ?live_only t f =
  Message_bus.subscribe_keyed_typed ?live_only t f

(* ── Request/reply over bus ──────────────────────────────────────── *)

exception Request_timeout

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
