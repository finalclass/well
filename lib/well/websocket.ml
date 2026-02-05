(* WebSocket implementation — RFC 6455 *)
(* Ported from reference websocket.ml, Base→stdlib *)

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

module Frame = struct
  type t = {
    fin : bool;
    opcode : Opcode.t;
    payload : string;
  }

  let text payload = { fin = true; opcode = Text; payload }
  let close () = { fin = true; opcode = Close; payload = "" }
  let pong payload = { fin = true; opcode = Pong; payload }
end

type t = {
  flow : Eio.Flow.two_way_ty Eio.Resource.t;
  reader : Eio.Buf_read.t;
  mutable closed : bool;
}

(* Private helpers *)
open struct
  let ws_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  let compute_accept_key key =
    let combined = key ^ ws_magic in
    let sha1 = Digestif.SHA1.digest_string combined in
    Base64.encode_exn (Digestif.SHA1.to_raw_string sha1)

  let read_byte reader =
    try Some (Eio.Buf_read.any_char reader |> Char.code)
    with End_of_file -> None

  let read_bytes reader n =
    Eio.Buf_read.take n reader

  let write_bytes flow str =
    Eio.Flow.write flow [ Cstruct.of_string str ]

  let unmask payload mask_key =
    let len = String.length payload in
    let result = Bytes.create len in
    for i = 0 to len - 1 do
      let masked = Char.code payload.[i] in
      let key_byte = Char.code mask_key.[i mod 4] in
      Bytes.set result i (Char.chr (masked lxor key_byte))
    done;
    Bytes.to_string result

  let make_header first_byte len =
    let buf = Buffer.create 10 in
    Buffer.add_char buf (Char.chr first_byte);
    if len < 126 then
      Buffer.add_char buf (Char.chr len)
    else if len < 65536 then begin
      Buffer.add_char buf (Char.chr 126);
      Buffer.add_char buf (Char.chr ((len lsr 8) land 0xFF));
      Buffer.add_char buf (Char.chr (len land 0xFF))
    end else begin
      Buffer.add_char buf (Char.chr 127);
      Buffer.add_char buf (Char.chr 0);
      Buffer.add_char buf (Char.chr 0);
      Buffer.add_char buf (Char.chr 0);
      Buffer.add_char buf (Char.chr 0);
      Buffer.add_char buf (Char.chr ((len lsr 24) land 0xFF));
      Buffer.add_char buf (Char.chr ((len lsr 16) land 0xFF));
      Buffer.add_char buf (Char.chr ((len lsr 8) land 0xFF));
      Buffer.add_char buf (Char.chr (len land 0xFF))
    end;
    Buffer.contents buf
end

let read_frame ws =
  if ws.closed then None
  else
    match read_byte ws.reader with
    | None ->
        ws.closed <- true;
        None
    | Some first_byte ->
        let fin = (first_byte land 0x80) <> 0 in
        let opcode = Opcode.of_int (first_byte land 0x0F) in
        (match read_byte ws.reader with
         | None ->
             ws.closed <- true;
             None
         | Some second_byte ->
             let masked = (second_byte land 0x80) <> 0 in
             let payload_len = second_byte land 0x7F in
             let payload_len =
               if payload_len = 126 then
                 let bytes = read_bytes ws.reader 2 in
                 (Char.code bytes.[0] lsl 8) lor Char.code bytes.[1]
               else if payload_len = 127 then
                 let bytes = read_bytes ws.reader 8 in
                 (Char.code bytes.[4] lsl 24)
                 lor (Char.code bytes.[5] lsl 16)
                 lor (Char.code bytes.[6] lsl 8)
                 lor Char.code bytes.[7]
               else payload_len
             in
             let mask_key =
               if masked then Some (read_bytes ws.reader 4) else None
             in
             let payload =
               if payload_len > 0 then read_bytes ws.reader payload_len
               else ""
             in
             let payload =
               match mask_key with
               | Some key -> unmask payload key
               | None -> payload
             in
             Some Frame.{ fin; opcode; payload })

let write_frame ws frame =
  if ws.closed then ()
  else
    let Frame.{ fin; opcode; payload } = frame in
    let len = String.length payload in
    let first_byte = (if fin then 0x80 else 0) lor Opcode.to_int opcode in
    let header = make_header first_byte len in
    write_bytes ws.flow (header ^ payload)

let send ws text =
  write_frame ws (Frame.text text)

let send_json ws json =
  send ws (Yojson.Safe.to_string json)

let close ws =
  if not ws.closed then begin
    write_frame ws (Frame.close ());
    ws.closed <- true
  end

let is_open ws = not ws.closed

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
         | Opcode.Continuation -> loop ()
         | Opcode.Unknown _ -> loop ())
  in
  loop ()

let receive_json ws =
  match receive ws with
  | None -> None
  | Some text ->
      (try Some (Yojson.Safe.from_string text)
       with Yojson.Json_error _ -> None)

let handshake headers flow reader =
  let find_header name =
    List.find_map
      (fun (k, v) ->
        if String.lowercase_ascii k = String.lowercase_ascii name then Some v
        else None)
      headers
  in
  match find_header "sec-websocket-key" with
  | None -> Error "Missing Sec-WebSocket-Key header"
  | Some key ->
      let accept = compute_accept_key key in
      let response =
        "HTTP/1.1 101 Switching Protocols\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Accept: " ^ accept ^ "\r\n\r\n"
      in
      write_bytes flow response;
      Ok { flow; reader; closed = false }
