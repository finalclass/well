include Well.Types

type api_token_identity = Well.api_token_identity = {
  user_id : string;
  session_data : (string * string) list;
}

type uploaded_file = Well.uploaded_file = {
  filename : string;
  content_type : string;
  size : int;
  data : string;
}

type multipart_data = Well.multipart_data = {
  fields : (string * string) list;
  files : (string * uploaded_file) list;
}

type join_result = Well.join_result = {
  subscribe : string list;
  initial_state : Yojson.Safe.t option;
}

type push_result = Well.push_result = {
  reply : Yojson.Safe.t option;
  broadcast : (string * Yojson.Safe.t) option;
}

exception Body_too_large = Well.Body_too_large

module Session = Well.Session
module Middleware = Well.Middleware
module Form = Well.Form
module Websocket = Well.Websocket
module Login_navigation = Well.Login_navigation

let use = Well.use
let static = Well.static
let scope = Well.scope
let get = Well.get
let post = Well.post
let put = Well.put
let delete = Well.delete
let ws = Well.ws
let channel = Well.channel
let logger = Well.logger
let cors = Well.cors
let csrf = Well.csrf
let csrf_token = Well.csrf_token
let rate_limit = Well.rate_limit
let current_user = Well.current_user
let require_auth = Well.require_auth
let basic_auth = Well.basic_auth
let allowed_hosts = Well.allowed_hosts
let secure_headers = Well.secure_headers
let dev_mode = Well.dev_mode
let on_error = Well.on_error
let error_handler = Well.error_handler
let url_encode = Well.url_encode
let url_decode = Well.url_decode
let ext_to_mime = Well.ext_to_mime
let mime_to_ext = Well.mime_to_ext
let is_safe_path = Well.is_safe_path
let parse_range_header = Well.parse_range_header
let api_token_auth = Well.api_token_auth
let api_token_authenticated = Well.api_token_authenticated
let cookie_session_middleware = Well.cookie_session_middleware
let session_middleware = Well.session_middleware
let generate_session_id = Well.generate_session_id
let session_lifetime = Well.session_lifetime
let session_regenerate = Well.session_regenerate
let rpc_ctx = Well.rpc_ctx
let put_flash = Well.put_flash
let get_flash = Well.get_flash
let parse_query = Well.parse_query
let max_body_size = Well.max_body_size
let get_multipart = Well.get_multipart
let file = Well.file
let files = Well.files
let all_files = Well.all_files
let form_params = Well.form_params
let form = Well.form
let request_id = Well.request_id
let generate_request_id = Well.generate_request_id
let request_timeout = Well.request_timeout
let stream_file = Well.stream_file
let list_routes = Well.list_routes
