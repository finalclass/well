(** Well.S3 — S3 client with AWS Signature V4 signing.
    Uses Well.fetch as HTTP transport. No Cohttp dependency. *)

(* ── Forward refs (wired by well.ml) ────────────────────────────── *)

let _fetch_ref :
  (method_:string -> headers:(string * string) list -> body:string ->
   string -> int * (string * string) list * string) ref =
  ref (fun ~method_:_ ~headers:_ ~body:_ _ ->
    failwith "S3._fetch_ref not wired — must be called within Well.run")

let _mime_ref : (string -> string) ref =
  ref (fun _ -> "application/octet-stream")

(* ── Config type ─────────────────────────────────────────────────── *)

(** S3 client configuration: endpoint, region, credentials, and bucket. *)
type t = {
  endpoint_url : string;
  region : string;
  access_key_id : string;
  secret_access_key : string;
  bucket : string;
}

let getenv_opt key = try Some (Sys.getenv key) with Not_found -> None
let getenv_or key default = match getenv_opt key with Some v -> v | None -> default

(** Create an S3 client. Falls back to [AWS_*] env vars for missing parameters. *)
let connect
    ?endpoint_url ?region ?access_key_id ?secret_access_key ?bucket () =
  {
    endpoint_url =
      (match endpoint_url with Some v -> v
       | None -> getenv_or "AWS_ENDPOINT_URL" "");
    region =
      (match region with Some v -> v
       | None -> getenv_or "AWS_REGION" "us-east-1");
    access_key_id =
      (match access_key_id with Some v -> v
       | None -> getenv_or "AWS_ACCESS_KEY_ID" "");
    secret_access_key =
      (match secret_access_key with Some v -> v
       | None -> getenv_or "AWS_SECRET_ACCESS_KEY" "");
    bucket =
      (match bucket with Some v -> v
       | None -> getenv_or "S3_BUCKET" "");
  }

(* ── AWS Signature V4 helpers ────────────────────────────────────── *)

let hmac_sha256 ~key data =
  Digestif.SHA256.hmac_string ~key data |> Digestif.SHA256.to_raw_string

let sha256_hex str =
  Digestif.SHA256.digest_string str |> Digestif.SHA256.to_hex

let uri_encode ?(encode_slash = true) str =
  let buf = Buffer.create (String.length str * 3) in
  String.iter (fun c ->
    match c with
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '~' | '.' ->
      Buffer.add_char buf c
    | '/' when not encode_slash -> Buffer.add_char buf c
    | _ -> Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c))
  ) str;
  Buffer.contents buf

let format_iso8601 time =
  let tm = Unix.gmtime time in
  Printf.sprintf "%04d%02d%02dT%02d%02d%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let format_date time =
  let tm = Unix.gmtime time in
  Printf.sprintf "%04d%02d%02d"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday

let get_signing_key ~secret_key ~date_stamp ~region ~service =
  let k_date = hmac_sha256 ~key:("AWS4" ^ secret_key) date_stamp in
  let k_region = hmac_sha256 ~key:k_date region in
  let k_service = hmac_sha256 ~key:k_region service in
  hmac_sha256 ~key:k_service "aws4_request"

let parse_host url =
  let url =
    if String.length url > 8 && String.sub url 0 8 = "https://" then
      String.sub url 8 (String.length url - 8)
    else if String.length url > 7 && String.sub url 0 7 = "http://" then
      String.sub url 7 (String.length url - 7)
    else url
  in
  (* Strip trailing slashes *)
  let len = ref (String.length url) in
  while !len > 0 && url.[!len - 1] = '/' do decr len done;
  String.sub url 0 !len

let hex_encode s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) s;
  Buffer.contents buf

let file_ext path =
  match String.rindex_opt path '.' with
  | Some i -> String.sub path (i + 1) (String.length path - i - 1)
  | None -> ""

(* ── Signing ─────────────────────────────────────────────────────── *)

let sign_request t ~meth ~path ?(query = "") ~headers ~payload_hash () =
  let now = Unix.gettimeofday () in
  let amz_date = format_iso8601 now in
  let date_stamp = format_date now in
  let service = "s3" in
  let host = parse_host t.endpoint_url in

  let credential_scope =
    String.concat "/" [date_stamp; t.region; service; "aws4_request"]
  in

  let all_headers =
    ("host", host)
    :: ("x-amz-date", amz_date)
    :: ("x-amz-content-sha256", payload_hash)
    :: headers
  in

  let sorted_headers =
    List.sort (fun (k1, _) (k2, _) ->
      String.compare (String.lowercase_ascii k1) (String.lowercase_ascii k2))
      all_headers
  in

  let canonical_headers =
    String.concat "\n"
      (List.map (fun (k, v) -> String.lowercase_ascii k ^ ":" ^ String.trim v)
         sorted_headers)
  in

  let signed_headers =
    String.concat ";"
      (List.map (fun (k, _) -> String.lowercase_ascii k) sorted_headers)
  in

  let canonical_request =
    String.concat "\n"
      [ meth; path; query;
        canonical_headers ^ "\n";
        signed_headers;
        payload_hash ]
  in

  let string_to_sign =
    String.concat "\n"
      [ "AWS4-HMAC-SHA256"; amz_date; credential_scope;
        sha256_hex canonical_request ]
  in

  let signing_key =
    get_signing_key ~secret_key:t.secret_access_key
      ~date_stamp ~region:t.region ~service
  in
  let signature = hex_encode (hmac_sha256 ~key:signing_key string_to_sign) in

  let auth_header =
    Printf.sprintf "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s"
      t.access_key_id credential_scope signed_headers signature
  in

  [ ("Authorization", auth_header);
    ("x-amz-date", amz_date);
    ("x-amz-content-sha256", payload_hash) ]
  @ headers

(* ── Internal request helper ─────────────────────────────────────── *)

let do_request t ~meth ~key ?(query = "") ?(extra_headers = []) ~body () =
  let path = "/" ^ t.bucket ^ "/" ^ uri_encode ~encode_slash:false key in
  let payload_hash = sha256_hex body in
  let signed_headers =
    sign_request t ~meth ~path ~query ~headers:extra_headers ~payload_hash ()
  in
  let url =
    if query = "" then t.endpoint_url ^ path
    else t.endpoint_url ^ path ^ "?" ^ query
  in
  !_fetch_ref ~method_:meth ~headers:signed_headers ~body url

let do_bucket_request t ~meth ?(query = "") ?(extra_headers = []) ~body () =
  let path = "/" ^ t.bucket in
  let payload_hash = sha256_hex body in
  let signed_headers =
    sign_request t ~meth ~path ~query ~headers:extra_headers ~payload_hash ()
  in
  let url =
    if query = "" then t.endpoint_url ^ path
    else t.endpoint_url ^ path ^ "?" ^ query
  in
  !_fetch_ref ~method_:meth ~headers:signed_headers ~body url

(* ── Public API ──────────────────────────────────────────────────── *)

(** Upload an object. Content-type is auto-detected from file extension if not specified. *)
let put t ~key ?(content_type = "") body =
  let ct =
    if content_type <> "" then content_type
    else !_mime_ref (file_ext key)
  in
  let extra_headers = [("Content-Type", ct)] in
  let (status, _headers, _body) =
    do_request t ~meth:"PUT" ~key ~extra_headers ~body ()
  in
  if status >= 200 && status < 300 then Ok ()
  else Error (Printf.sprintf "S3 PUT failed with status %d" status)

(** Download an object, returning its body as a string. *)
let get t ~key =
  let (status, _headers, body) =
    do_request t ~meth:"GET" ~key ~body:"" ()
  in
  if status >= 200 && status < 300 then Ok body
  else Error (Printf.sprintf "S3 GET failed with status %d" status)

(** Delete an object by key. *)
let delete t ~key =
  let (status, _headers, _body) =
    do_request t ~meth:"DELETE" ~key ~body:"" ()
  in
  if status >= 200 && status < 300 then Ok ()
  else Error (Printf.sprintf "S3 DELETE failed with status %d" status)

(** Copy an object from [src] key to [dst] key within the same bucket. *)
let copy t ~src ~dst =
  let copy_source =
    "/" ^ t.bucket ^ "/" ^ uri_encode ~encode_slash:false src
  in
  let extra_headers = [("x-amz-copy-source", copy_source)] in
  let (status, _headers, _body) =
    do_request t ~meth:"PUT" ~key:dst ~extra_headers ~body:"" ()
  in
  if status >= 200 && status < 300 then Ok ()
  else Error (Printf.sprintf "S3 COPY failed with status %d" status)

(** Retrieve object metadata (status and headers) without downloading the body. *)
let head t ~key =
  let (status, headers, _body) =
    do_request t ~meth:"HEAD" ~key ~body:"" ()
  in
  if status >= 200 && status < 300 then Ok (status, headers)
  else Error (Printf.sprintf "S3 HEAD failed with status %d" status)

(** Create the configured bucket. Returns [Ok ()] if already exists. *)
let create_bucket t =
  let (status, _headers, _body) =
    do_bucket_request t ~meth:"PUT" ~body:"" ()
  in
  if status >= 200 && status < 300 then Ok ()
  else if status = 409 then Ok ()  (* BucketAlreadyOwnedByYou *)
  else Error (Printf.sprintf "S3 CreateBucket failed with status %d" status)

(* ── Presigned URLs ──────────────────────────────────────────────── *)

(** Generate a presigned GET URL valid for [expires_in] seconds (default 24h). *)
let presigned_url t ~key ?(expires_in = 86400) () =
  let now = Unix.gettimeofday () in
  let amz_date = format_iso8601 now in
  let date_stamp = format_date now in
  let service = "s3" in
  let encoded_key = uri_encode ~encode_slash:false key in
  let host = parse_host t.endpoint_url in

  let credential_scope =
    String.concat "/" [date_stamp; t.region; service; "aws4_request"]
  in
  let credential = t.access_key_id ^ "/" ^ credential_scope in

  let query_params =
    [ ("X-Amz-Algorithm", "AWS4-HMAC-SHA256");
      ("X-Amz-Credential", uri_encode credential);
      ("X-Amz-Date", amz_date);
      ("X-Amz-Expires", string_of_int expires_in);
      ("X-Amz-SignedHeaders", "host") ]
  in
  let canonical_query_string =
    String.concat "&"
      (List.map (fun (k, v) -> k ^ "=" ^ v) query_params)
  in

  let canonical_headers = "host:" ^ host ^ "\n" in
  let signed_headers = "host" in

  let canonical_request =
    String.concat "\n"
      [ "GET";
        "/" ^ t.bucket ^ "/" ^ encoded_key;
        canonical_query_string;
        canonical_headers;
        signed_headers;
        "UNSIGNED-PAYLOAD" ]
  in

  let string_to_sign =
    String.concat "\n"
      [ "AWS4-HMAC-SHA256"; amz_date; credential_scope;
        sha256_hex canonical_request ]
  in

  let signing_key =
    get_signing_key ~secret_key:t.secret_access_key
      ~date_stamp ~region:t.region ~service
  in
  let signature = hex_encode (hmac_sha256 ~key:signing_key string_to_sign) in

  Printf.sprintf "%s/%s/%s?%s&X-Amz-Signature=%s"
    t.endpoint_url t.bucket encoded_key canonical_query_string signature
