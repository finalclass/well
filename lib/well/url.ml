(** URL utilities: encoding, decoding, MIME types, path safety, file helpers. *)

(* ── URL encoding ──────────────────────────────────────────────────── *)

(** URL-encode (percent-encode) a string. *)
let encode str =
  let buf = Buffer.create (String.length str * 3) in
  String.iter (fun c ->
    match c with
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '~' | '.' ->
      Buffer.add_char buf c
    | _ -> Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c))
  ) str;
  Buffer.contents buf

(** Decode a URL-encoded (percent-encoded) string. Handles [+] as space. *)
let decode s =
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

(* ── MIME types ───────────────────────────────────────────────────── *)

(** Map a file extension (without dot) to its MIME type. Returns ["application/octet-stream"] for unknown extensions. *)
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

(** Map a MIME type to its canonical file extension. Returns ["bin"] for unknown types. *)
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

(** Check whether a URL path is safe (no directory traversal or null bytes). *)
let is_safe_path path =
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

(* ── File helpers ─────────────────────────────────────────────────── *)

(** Extract file extension (without dot) from a path. *)
let file_ext path =
  match String.rindex_opt path '.' with
  | Some i -> String.sub path (i + 1) (String.length path - i - 1)
  | None -> ""

(** Generate an HTTP ETag from file stats (mtime + size). *)
let file_etag (stat : Unix.stats) =
  Printf.sprintf "\"%x-%x\""
    (int_of_float (stat.Unix.st_mtime *. 1000.))
    stat.Unix.st_size

(** Check whether a MIME type represents text content (compressible). *)
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
