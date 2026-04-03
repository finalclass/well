(** HTTP client (fetch) with TLS support. *)

(* ── Types ────────────────────────────────────────────────────────── *)

(** HTTP client response from [fetch]. *)
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

(* ── URL parsing ──────────────────────────────────────────────────── *)

let parse_url url =
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

(* ── TLS config ───────────────────────────────────────────────────── *)

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

let tls_config () =
  let cas = Lazy.force system_cas in
  let time () = Ptime.of_float_s (Unix.gettimeofday ()) in
  let authenticator = X509.Authenticator.chain_of_trust ~time cas in
  match Tls.Config.client ~authenticator () with
  | Ok cfg -> cfg
  | Error (`Msg m) -> failwith ("Well.fetch TLS error: " ^ m)

(* ── DNS resolution ───────────────────────────────────────────────── *)

let resolve net host port =
  match Eio.Net.getaddrinfo_stream net host ~service:(string_of_int port) with
  | addr :: _ -> addr
  | [] -> failwith ("Well.fetch: could not resolve: " ^ host)

(* ── Request building ─────────────────────────────────────────────── *)

let build_request ~method_ ~host ~port ~path ~headers ~body =
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

(* ── Response parsing ─────────────────────────────────────────────── *)

let read_line_crlf reader =
  let line = Eio.Buf_read.line reader in
  if String.length line > 0 && line.[String.length line - 1] = '\r' then
    String.sub line 0 (String.length line - 1)
  else line

let parse_status reader =
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

let read_body ~method_ reader hdrs =
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
        let buf = Buffer.create 4096 in
        (try
           while true do
             Buffer.add_char buf (Eio.Buf_read.any_char reader)
           done;
           assert false
         with End_of_file | Eio.Io _ -> Buffer.contents buf)

(* ── Forward ref (wired by Well.run to capture EIO net) ──────────── *)

let _impl =
  ref
    (fun ~method_:(_ : string) ~headers:(_ : (string * string) list)
         ~body:(_ : string) (_ : string) : fetch_response ->
      failwith "Well.fetch: must be called within Well.run")

(** Make an HTTP request with an explicit [net] handle. Does not require [Well.run]. *)
let fetch_with_net ~net ?(method_ = "GET") ?(headers = []) ?(body = "") url =
  let parsed = parse_url url in
  let req_str =
    build_request ~method_ ~host:parsed.p_host ~port:parsed.p_port
      ~path:parsed.p_path ~headers ~body
  in
  let addr = resolve net parsed.p_host parsed.p_port in
  Eio.Switch.run @@ fun sw ->
  let tcp_flow = Eio.Net.connect ~sw net addr in
  let send_and_receive flow =
    Eio.Flow.copy_string req_str flow;
    let reader = Eio.Buf_read.of_flow ~max_size:(10 * 1024 * 1024) flow in
    let status = parse_status reader in
    let resp_hdrs = parse_headers reader in
    let body = read_body ~method_ reader resp_hdrs in
    { status; headers = resp_hdrs; body }
  in
  if parsed.p_scheme = "https" then (
    let tls_cfg = tls_config () in
    let host =
      Option.bind
        (Domain_name.of_string parsed.p_host |> Result.to_option)
        (fun dn -> Domain_name.host dn |> Result.to_option)
    in
    let tls_flow = Tls_eio.client_of_flow ?host tls_cfg tcp_flow in
    send_and_receive tls_flow)
  else send_and_receive tcp_flow

(** Make a streaming HTTP request with an explicit [net] handle.
    Body chunks are delivered via [on_data] callback as they arrive.
    Returns [(status, headers)]. Does not require [Well.run]. *)
let fetch_stream_with_net ~net ?(method_ = "POST") ?(headers = []) ?(body = "")
    ~on_data url =
  let parsed = parse_url url in
  let req_str =
    build_request ~method_ ~host:parsed.p_host ~port:parsed.p_port
      ~path:parsed.p_path ~headers ~body
  in
  let addr = resolve net parsed.p_host parsed.p_port in
  Eio.Switch.run @@ fun sw ->
  let tcp_flow = Eio.Net.connect ~sw net addr in
  let send_and_stream flow =
    Eio.Flow.copy_string req_str flow;
    let reader = Eio.Buf_read.of_flow ~max_size:(10 * 1024 * 1024) flow in
    let status = parse_status reader in
    let resp_hdrs = parse_headers reader in
    let is_chunked =
      match List.assoc_opt "transfer-encoding" resp_hdrs with
      | Some v -> String.lowercase_ascii (String.trim v) = "chunked"
      | None -> false
    in
    if is_chunked then begin
      let rec loop () =
        let line = read_line_crlf reader in
        let size_str =
          match String.index_opt line ';' with
          | Some i -> String.sub line 0 i
          | None -> line
        in
        match int_of_string_opt ("0x" ^ String.trim size_str) with
        | None | Some 0 -> ()
        | Some n ->
          let chunk = Eio.Buf_read.take n reader in
          on_data chunk;
          (try ignore (read_line_crlf reader) with _ -> ());
          loop ()
      in
      loop ()
    end else begin
      (try
        while true do
          let c = Eio.Buf_read.any_char reader in
          let buf = Buffer.create 4096 in
          Buffer.add_char buf c;
          (try
            let avail = Eio.Buf_read.buffered_bytes reader in
            if avail > 0 then
              Buffer.add_string buf (Eio.Buf_read.take avail reader)
          with _ -> ());
          on_data (Buffer.contents buf)
        done
      with End_of_file | Eio.Io _ -> ())
    end;
    (status, resp_hdrs)
  in
  if parsed.p_scheme = "https" then (
    let tls_cfg = tls_config () in
    let host =
      Option.bind
        (Domain_name.of_string parsed.p_host |> Result.to_option)
        (fun dn -> Domain_name.host dn |> Result.to_option)
    in
    let tls_flow = Tls_eio.client_of_flow ?host tls_cfg tcp_flow in
    send_and_stream tls_flow)
  else send_and_stream tcp_flow

(** Make an HTTP request. Supports HTTP and HTTPS with system CA certificates. Must be called within [Well.run]. *)
let fetch ?(method_ = "GET") ?(headers = []) ?(body = "") url =
  !_impl ~method_ ~headers ~body url
