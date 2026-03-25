(** Static file serving with ETag caching, range requests, and large file streaming. *)

open Types

(* ── Range header parsing ─────────────────────────────────────────── *)

let parse_range_header headers total_size =
  match List.assoc_opt "range" headers with
  | None -> None
  | Some v ->
      let v = String.trim v in
      if String.length v > 6 && String.sub v 0 6 = "bytes=" then
        let range_spec = String.sub v 6 (String.length v - 6) in
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
               | _ -> Some (-1, -1))
      else None

(* ── Static file serving ──────────────────────────────────────────── *)

let _static_stream_threshold = 1024 * 1024

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
            if rel = "" || not (Url.is_safe_path rel) then try_mounts rest
            else
              let file_path = Filename.concat mount.dir (Url.decode rel) in
              (try
                 let stat = Unix.stat file_path in
                 if stat.Unix.st_kind <> Unix.S_REG then try_mounts rest
                 else
                   let total_size = stat.Unix.st_size in
                   let etag = Url.file_etag stat in
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
                     let ext = Url.file_ext file_path in
                     let mime = Url.ext_to_mime ext in
                     let content_type =
                       if Url.is_text_mime mime then mime ^ "; charset=utf-8"
                       else mime
                     in
                     let range = parse_range_header headers total_size in
                     (match range with
                      | Some (-1, -1) ->
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
                              ("Cache-Control", "no-cache");
                            ];
                            r_body = Bytes.unsafe_to_string buf;
                          }
                      | Some _ ->
                          Some {
                            r_status = 206;
                            r_headers = [
                              ("Content-Type", content_type);
                              ("Accept-Ranges", "bytes");
                              ("ETag", etag);
                              ("Cache-Control", "no-cache");
                            ];
                            r_body = "";
                          }
                      | None ->
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
                                    ("Cache-Control", "no-cache");
                                  ];
                                r_body = "";
                              }
                          else if total_size > _static_stream_threshold then
                            Some
                              {
                                r_status = -1;
                                r_headers =
                                  [
                                    ("Content-Type", content_type);
                                    ("Accept-Ranges", "bytes");
                                    ("ETag", etag);
                                    ("Cache-Control", "no-cache");
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
                                    ("Cache-Control", "no-cache");
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
    try_mounts !(Router.static_mounts)
