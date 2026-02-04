(* WebSocket implementation for Blossom/EIO - RFC 6455 *)
open Base

(* Frame opcodes *)
module Opcode = struct
  type t =
    | Continuation
    | Text
    | Binary
    | Close
    | Ping
    | Pong
    | Unknown of int

  let of_int = function
    | 0 -> Continuation
    | 1 -> Text
    | 2 -> Binary
    | 8 -> Close
    | 9 -> Ping
    | 10 -> Pong
    | n -> Unknown n

  let to_int = function
    | Continuation -> 0
    | Text -> 1
    | Binary -> 2
    | Close -> 8
    | Ping -> 9
    | Pong -> 10
    | Unknown n -> n
end

(* WebSocket frame *)
module Frame = struct
  type t =
    { fin : bool
    ; opcode : Opcode.t
    ; payload : string
    }

  let text payload = { fin = true; opcode = Text; payload }
  let close () = { fin = true; opcode = Close; payload = "" }
  let pong payload = { fin = true; opcode = Pong; payload }
end

(* WebSocket connection state *)
type t =
  { flow : Eio.Flow.two_way_ty Eio.Resource.t
  ; reader : Eio.Buf_read.t
  ; mutable closed : bool
  }

(* Private helpers *)
open struct
  let ws_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  let compute_accept_key key =
    let combined = key ^ ws_magic in
    let sha1 = Digestif.SHA1.digest_string combined in
    Base64.encode_exn (Digestif.SHA1.to_raw_string sha1)

  let read_byte_from_reader reader =
    try Some (Eio.Buf_read.any_char reader |> Char.to_int)
    with End_of_file -> None

  let read_bytes_from_reader reader n =
    Eio.Buf_read.take n reader

  let write_bytes flow str =
    Eio.Flow.write flow [ Cstruct.of_string str ]

  let unmask payload mask_key =
    let len = String.length payload in
    let result = Bytes.create len in
    for i = 0 to len - 1 do
      let masked = Char.to_int (String.get payload i) in
      let key_byte = Char.to_int (String.get mask_key (i % 4)) in
      Bytes.set result i (Char.of_int_exn (masked lxor key_byte))
    done;
    Bytes.to_string result
end

(* Read a WebSocket frame *)
let read_frame ws =
  if ws.closed then None
  else
    match read_byte_from_reader ws.reader with
    | None ->
        ws.closed <- true;
        None
    | Some first_byte ->
        let fin = (first_byte land 0x80) <> 0 in
        let opcode = Opcode.of_int (first_byte land 0x0F) in

        (match read_byte_from_reader ws.reader with
         | None ->
             ws.closed <- true;
             None
         | Some second_byte ->
             let masked = (second_byte land 0x80) <> 0 in
             let payload_len = second_byte land 0x7F in

             (* Extended payload length *)
             let payload_len =
               if payload_len = 126 then
                 let bytes = read_bytes_from_reader ws.reader 2 in
                 (Char.to_int (String.get bytes 0) lsl 8) lor Char.to_int (String.get bytes 1)
               else if payload_len = 127 then
                 let bytes = read_bytes_from_reader ws.reader 8 in
                 (* Simplified: only use lower 32 bits *)
                 (Char.to_int (String.get bytes 4) lsl 24)
                 lor (Char.to_int (String.get bytes 5) lsl 16)
                 lor (Char.to_int (String.get bytes 6) lsl 8)
                 lor Char.to_int (String.get bytes 7)
               else payload_len
             in

             (* Mask key (if masked) *)
             let mask_key = if masked then Some (read_bytes_from_reader ws.reader 4) else None in

             (* Payload *)
             let payload =
               if payload_len > 0 then read_bytes_from_reader ws.reader payload_len else ""
             in
             let payload =
               match mask_key with
               | Some key -> unmask payload key
               | None -> payload
             in

             Some Frame.{ fin; opcode; payload })

(* Write a WebSocket frame *)
let write_frame ws frame =
  if ws.closed then ()
  else
    let Frame.{ fin; opcode; payload } = frame in
    let len = String.length payload in

    (* First byte: FIN + opcode *)
    let first_byte = (if fin then 0x80 else 0) lor Opcode.to_int opcode in

    (* Build header *)
    let header =
      if len < 126 then
        String.of_char_list
          [ Char.of_int_exn first_byte; Char.of_int_exn len ]
      else if len < 65536 then
        String.of_char_list
          [ Char.of_int_exn first_byte
          ; Char.of_int_exn 126
          ; Char.of_int_exn ((len lsr 8) land 0xFF)
          ; Char.of_int_exn (len land 0xFF)
          ]
      else
        String.of_char_list
          [ Char.of_int_exn first_byte
          ; Char.of_int_exn 127
          ; Char.of_int_exn 0
          ; Char.of_int_exn 0
          ; Char.of_int_exn 0
          ; Char.of_int_exn 0
          ; Char.of_int_exn ((len lsr 24) land 0xFF)
          ; Char.of_int_exn ((len lsr 16) land 0xFF)
          ; Char.of_int_exn ((len lsr 8) land 0xFF)
          ; Char.of_int_exn (len land 0xFF)
          ]
    in
    write_bytes ws.flow (header ^ payload)

(* Send text message *)
let send ws text =
  write_frame ws (Frame.text text)

(* Send JSON *)
let send_json ws json =
  send ws (Yojson.Safe.to_string json)

(* Close connection *)
let close ws =
  if not ws.closed then begin
    write_frame ws (Frame.close ());
    ws.closed <- true
  end

(* Check if open *)
let is_open ws = not ws.closed

(* Receive next text message (handles ping/pong internally) *)
let receive ws =
  let rec loop () =
    match read_frame ws with
    | None -> None
    | Some frame ->
        (match frame.opcode with
         | Opcode.Text -> Some frame.payload
         | Opcode.Binary -> Some frame.payload
         | Opcode.Ping ->
             write_frame ws (Frame.pong frame.payload);
             loop ()
         | Opcode.Pong -> loop ()
         | Opcode.Close ->
             close ws;
             None
         | Opcode.Continuation -> loop () (* Simplified: ignore continuations *)
         | Opcode.Unknown _ -> loop ())
  in
  loop ()

(* Receive JSON *)
let receive_json ws =
  match receive ws with
  | None -> None
  | Some text ->
      (try Some (Yojson.Safe.from_string text)
       with Yojson.Json_error _ -> None)

(* Perform WebSocket handshake from raw HTTP request *)
let handshake_from_request request_line headers flow reader =
  match List.Assoc.find headers ~equal:String.Caseless.equal "Sec-WebSocket-Key" with
  | None -> Error "Missing Sec-WebSocket-Key header"
  | Some key ->
      let _ = request_line in
      let accept = compute_accept_key key in
      let response =
        "HTTP/1.1 101 Switching Protocols\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Accept: " ^ accept ^ "\r\n\r\n"
      in
      write_bytes flow response;
      Ok { flow; reader; closed = false }

(* Parse HTTP request line and headers from raw bytes *)
let parse_http_request flow =
  try
    let reader = Eio.Buf_read.of_flow ~max_size:65536 flow in
    let rec read_headers acc =
      let line = Eio.Buf_read.line reader in
      if String.is_empty line then acc
      else read_headers (line :: acc)
    in
    let lines = List.rev (read_headers []) in
    match lines with
    | [] -> None
    | request_line :: header_lines ->
        let headers =
          List.filter_map header_lines ~f:(fun line ->
              match String.lsplit2 line ~on:':' with
              | Some (k, v) -> Some (String.strip k, String.strip v)
              | None -> None)
        in
        Some (request_line, headers, reader)
  with
  | End_of_file -> None
  | _ -> None

(* Extract path from request line *)
let path_of_request_line request_line =
  match String.split request_line ~on:' ' with
  | _ :: path :: _ ->
      (match String.lsplit2 path ~on:'?' with
       | Some (p, _) -> p
       | None -> path)
  | _ -> "/"

(* Parse session_id from Cookie header *)
let parse_session_id headers =
  let cookie_header = List.Assoc.find headers ~equal:String.Caseless.equal "Cookie" in
  Stdlib.print_endline ("[LiveView] Cookie header: " ^
    Option.value cookie_header ~default:"<none>");
  match cookie_header with
  | None -> None
  | Some cookie_str ->
      (* Parse "session_id=abc123; other=value" *)
      let cookies = String.split cookie_str ~on:';' in
      let result = List.find_map cookies ~f:(fun cookie ->
          let cookie = String.strip cookie in
          match String.lsplit2 cookie ~on:'=' with
          | Some ("session_id", value) -> Some value
          | _ -> None) in
      Stdlib.print_endline ("[LiveView] Parsed session_id: " ^
        Option.value result ~default:"<none>");
      result

(* WebSocket route handler *)
type 'ctx handler = path:string -> session_id:string option -> 'ctx -> t -> unit

(* WebSocket server *)
type 'ctx server =
  { handlers : (string * 'ctx handler) list
  ; make_ctx : unit -> 'ctx
  }

let create_server ~make_ctx handlers =
  { handlers; make_ctx }

(* Handle a single WebSocket connection *)
let handle_connection server flow =
  match parse_http_request flow with
  | None -> ()
  | Some (request_line, headers, reader) ->
      let path = path_of_request_line request_line in
      let session_id = parse_session_id headers in
      (match List.find server.handlers ~f:(fun (p, _) -> String.is_prefix path ~prefix:p) with
       | None ->
           let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n" in
           write_bytes flow response
       | Some (_, handler) ->
           (match handshake_from_request request_line headers flow reader with
            | Error _ ->
                let response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n" in
                write_bytes flow response
            | Ok ws ->
                let ctx = server.make_ctx () in
                (try handler ~path ~session_id ctx ws with _ -> ());
                close ws))

(* Listen for WebSocket connections *)
let listen ~env ~sw ~socket_path server =
  (try Unix.unlink socket_path with Unix.Unix_error _ -> ());
  let socket = Eio.Net.listen env#net ~sw ~backlog:128 ~reuse_addr:true (`Unix socket_path) in
  Unix.chmod socket_path 0o777;
  Stdlib.print_endline ("WebSocket server listening on: " ^ socket_path);
  Stdlib.flush Stdlib.stdout;
  let rec accept_loop () =
    Eio.Net.accept_fork socket ~sw
      ~on_error:(fun _ -> ())
      (fun flow _addr ->
         Stdlib.print_endline "[WS] New connection";
         Stdlib.flush Stdlib.stdout;
         try
           let flow = (flow :> Eio.Flow.two_way_ty Eio.Resource.t) in
           handle_connection server flow
         with _ -> ());
    accept_loop ()
  in
  accept_loop ()
