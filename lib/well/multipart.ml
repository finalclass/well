(** Multipart form-data parsing: boundary extraction, part splitting, file upload handling. *)

(* ── Types ─────────────────────────────────────────────────────────── *)

(** An uploaded file from a multipart form submission. *)
type uploaded_file = {
  filename : string;
  content_type : string;
  size : int;
  data : string;
}

(** Parsed multipart form data containing fields and uploaded files. *)
type multipart_data = {
  fields : (string * string) list;
  files : (string * uploaded_file) list;
}

(* ── Helpers ─────────────────────────────────────────────────────── *)

open struct
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
end

(* ── Public API ──────────────────────────────────────────────────── *)

(** Extract the boundary string from a multipart/form-data Content-Type header. *)
let extract_boundary content_type =
  let ct = String.lowercase_ascii content_type in
  if not (try ignore (Str.search_forward (Str.regexp_string "multipart/form-data") ct 0); true
          with Not_found -> false)
  then None
  else
    match Str.search_forward (Str.regexp_case_fold {|boundary=\([^ ;]*\)|}) content_type 0 with
    | _ -> Some (Str.matched_group 1 content_type)
    | exception Not_found -> None

(** Check whether the request headers indicate multipart/form-data. *)
let is_multipart headers =
  match List.assoc_opt "content-type" headers with
  | Some ct -> extract_boundary ct <> None
  | None -> false

(** Parse a multipart/form-data body given the boundary string. *)
let parse boundary body =
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
