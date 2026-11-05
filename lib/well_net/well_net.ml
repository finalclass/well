type fetch_response = Well.fetch_response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

module S3 = Well.S3
module Cdp = Well.Cdp

let fetch = Well.fetch
let fetch_with_net = Well.fetch_with_net
let fetch_stream_with_net = Well.fetch_stream_with_net
let open_http_stream = Well.open_http_stream
let env = Well.env
let net = Well.net
let cwd = Well.cwd
let fs = Well.fs
