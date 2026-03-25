(** HTTP/1.1 request parsing and response writing. *)

open Types

(* ── Exceptions ──────────────────────────────────────────────────── *)

(** Raised when a request body exceeds the configured maximum size. *)
exception Body_too_large

(** Raised when request headers exceed the allowed count or byte size. *)
exception Headers_too_large

(* ── Request parsing ─────────────────────────────────────────────── *)

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

let _max_header_count = 100
let _max_header_bytes = 64 * 1024

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

let read_chunked_body ~max_body_size reader =
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
        if !total > max_body_size then raise Body_too_large;
        Buffer.add_string buf (Eio.Buf_read.take n reader);
        (try ignore (read_line_crlf reader) with _ -> ());
        loop ()
  in
  loop ()

let read_body ~max_body_size reader headers =
  let is_chunked =
    match List.assoc_opt "transfer-encoding" headers with
    | Some v -> String.lowercase_ascii (String.trim v) = "chunked"
    | None -> false
  in
  if is_chunked then read_chunked_body ~max_body_size reader
  else
    match List.assoc_opt "content-length" headers with
    | None -> ""
    | Some len_str -> (
        match int_of_string_opt len_str with
        | None -> ""
        | Some len ->
            if len <= 0 then ""
            else if len > max_body_size then raise Body_too_large
            else Eio.Buf_read.take len reader)

(* ── Response writing ────────────────────────────────────────────── *)

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
  Buffer.add_string buf "Connection: close\r\n";
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
