(** Gzip response compression: encoding detection, content-type filtering, transparent compression. *)

open Types

(* ── Gzip implementation ─────────────────────────────────────────── *)

let gzip_compress data =
  let len = String.length data in
  let buf = Buffer.create (len / 2) in
  Buffer.add_string buf "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03";
  let pos = ref 0 in
  Zlib.compress ~level:6 ~header:false
    (fun zbuf ->
      let n = min (Bytes.length zbuf) (len - !pos) in
      if n > 0 then Bytes.blit_string data !pos zbuf 0 n;
      pos := !pos + n;
      n)
    (fun zbuf zlen ->
      Buffer.add_subbytes buf zbuf 0 zlen);
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

(* ── Encoding detection ──────────────────────────────────────────── *)

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
  Url.is_text_mime base_mime

(* ── Public API ──────────────────────────────────────────────────── *)

(** Conditionally gzip-compress a resolved response based on request Accept-Encoding
    and response content-type. Skips 206/304 responses and small bodies (<860 bytes). *)
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
