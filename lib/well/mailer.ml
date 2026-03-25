(** Well.Mailer -- pluggable email sending with Log, SMTP, Resend, Zeptomail, and SES adapters. *)

(* ── Forward refs (wired by well.ml) ────────────────────────────── *)

let _fetch_ref :
  (method_:string -> headers:(string * string) list -> body:string ->
   string -> int * (string * string) list * string) ref =
  ref (fun ~method_:_ ~headers:_ ~body:_ _ ->
    failwith "Mailer._fetch_ref not wired — must be called within Well.run")

(* Net for SMTP — uses global Env *)
let _set_net (_ : _ Eio.Net.t) = () (* deprecated, kept for compat *)
let _get_net () = Env.net ()
let _tls_config_fn : (unit -> Tls.Config.client) ref =
  ref (fun () -> failwith "Mailer._tls_config_fn not wired")

(* ── Config types ──────────────────────────────────────────────── *)

(** SMTP connection settings (host, port, username, password). *)
type smtp_config = {
  host : string;
  port : int;
  username : string;
  password : string;
}

(** Resend API configuration. *)
type resend_config = { api_key : string }

(** Zeptomail (Zoho) API configuration. *)
type zeptomail_config = {
  api_url : string;
  token : string;
}

(** AWS SES configuration (region + credentials). *)
type ses_config = {
  region : string;
  access_key_id : string;
  secret_access_key : string;
}

(** Email delivery adapter. [Log] prints to stdout, others send via network. *)
type adapter =
  | Log
  | SMTP of smtp_config
  | Resend of resend_config
  | Zeptomail of zeptomail_config
  | SES of ses_config

(** Mailer configuration: sender identity and delivery adapter. *)
type config = {
  from_email : string;
  from_name : string;
  adapter : adapter;
}

(** An email message with recipients, subject, HTML body, and plain text fallback. *)
type mail = {
  to_ : (string * string) list;  (* (name, email) pairs *)
  subject : string;
  html : string;
  text : string;
}

(* ── Global config ─────────────────────────────────────────────── *)

let _config : config option ref = ref None

(** Configure the mailer with sender info and delivery adapter. Must be called before [send]. *)
let setup cfg = _config := Some cfg

let get_config () =
  match !_config with
  | Some c -> c
  | None -> failwith "Well.Mailer: not configured — call Well.Mailer.setup first"

(* ── AWS Sig V4 helpers for SES (duplicated from s3.ml) ────────── *)

let hmac_sha256 ~key data =
  Digestif.SHA256.hmac_string ~key data |> Digestif.SHA256.to_raw_string

let sha256_hex str =
  Digestif.SHA256.digest_string str |> Digestif.SHA256.to_hex

let hex_encode s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter (fun c ->
    Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) s;
  Buffer.contents buf

let uri_encode str =
  let buf = Buffer.create (String.length str * 3) in
  String.iter (fun c ->
    match c with
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '~' | '.' ->
      Buffer.add_char buf c
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

let sign_ses ~cfg ~body =
  let now = Unix.gettimeofday () in
  let amz_date = format_iso8601 now in
  let date_stamp = format_date now in
  let service = "ses" in
  let host = Printf.sprintf "email.%s.amazonaws.com" cfg.region in
  let path = "/v2/email/outbound-emails" in
  let credential_scope =
    String.concat "/" [date_stamp; cfg.region; service; "aws4_request"] in
  let payload_hash = sha256_hex body in
  let headers = [
    ("content-type", "application/json");
    ("host", host);
    ("x-amz-content-sha256", payload_hash);
    ("x-amz-date", amz_date);
  ] in
  let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) headers in
  let canonical_headers =
    String.concat "\n"
      (List.map (fun (k, v) -> k ^ ":" ^ String.trim v) sorted) in
  let signed_headers =
    String.concat ";" (List.map fst sorted) in
  let canonical_request =
    String.concat "\n"
      ["POST"; path; ""; canonical_headers ^ "\n"; signed_headers; payload_hash] in
  let string_to_sign =
    String.concat "\n"
      ["AWS4-HMAC-SHA256"; amz_date; credential_scope; sha256_hex canonical_request] in
  let signing_key =
    get_signing_key ~secret_key:cfg.secret_access_key
      ~date_stamp ~region:cfg.region ~service in
  let signature = hex_encode (hmac_sha256 ~key:signing_key string_to_sign) in
  let auth_header =
    Printf.sprintf "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s"
      cfg.access_key_id credential_scope signed_headers signature in
  [("Authorization", auth_header);
   ("Content-Type", "application/json");
   ("x-amz-date", amz_date);
   ("x-amz-content-sha256", payload_hash)]

(* ── Shared helpers ────────────────────────────────────────────── *)

let escape_json s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c -> match c with
    | '"' -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | c when Char.code c < 0x20 ->
      Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char buf c) s;
  Buffer.contents buf

(* Validate email for SMTP — reject control chars and newlines to prevent injection *)
let validate_smtp_email email =
  String.length email > 0
  && String.length email <= 254
  && not (String.exists (fun c -> c < ' ' || c = '\127') email)

(* ── SMTP adapter ──────────────────────────────────────────────── *)

let base64_encode s = Base64.encode_exn s

let build_mime_message ~from_email ~from_name ~to_ ~subject ~text ~html =
  let to_header = String.concat ", "
    (List.map (fun (name, email) ->
      if name = "" then email
      else Printf.sprintf "%s <%s>" name email) to_) in
  let from_header =
    if from_name = "" then from_email
    else Printf.sprintf "%s <%s>" from_name from_email in
  (* Crypto-random boundary to prevent MIME boundary injection *)
  let boundary_bytes = Mirage_crypto_rng.generate 16 in
  let boundary_buf = Buffer.create 40 in
  Buffer.add_string boundary_buf "----well";
  String.iter (fun c ->
    Buffer.add_string boundary_buf (Printf.sprintf "%02x" (Char.code c))) boundary_bytes;
  let boundary = Buffer.contents boundary_buf in
  String.concat "\r\n" [
    "From: " ^ from_header;
    "To: " ^ to_header;
    "Subject: " ^ subject;
    "MIME-Version: 1.0";
    Printf.sprintf "Content-Type: multipart/alternative; boundary=\"%s\"" boundary;
    "";
    "--" ^ boundary;
    "Content-Type: text/plain; charset=UTF-8";
    "";
    text;
    "";
    "--" ^ boundary;
    "Content-Type: text/html; charset=UTF-8";
    "";
    html;
    "";
    "--" ^ boundary ^ "--";
    ".";
  ]

let smtp_session ~send ~read_line ~cfg ~from_email ~from_name mail =
  (* Validate all emails to prevent SMTP injection via \r\n *)
  if not (validate_smtp_email from_email) then
    failwith "SMTP: invalid from_email";
  List.iter (fun (_name, email) ->
    if not (validate_smtp_email email) then
      failwith ("SMTP: invalid recipient email: " ^ email)) mail.to_;
  let expect_code expected =
    let line = read_line () in
    let code = try int_of_string (String.sub line 0 3) with _ -> 0 in
    if code <> expected then
      failwith (Printf.sprintf "SMTP: expected %d, got: %s" expected line)
  in
  let rec read_ehlo () =
    let line = read_line () in
    if String.length line >= 4 && line.[3] = '-' then read_ehlo ()
  in
  send ("EHLO " ^ cfg.host);
  read_ehlo ();
  let auth_str = base64_encode ("\x00" ^ cfg.username ^ "\x00" ^ cfg.password) in
  send ("AUTH PLAIN " ^ auth_str);
  expect_code 235;
  send (Printf.sprintf "MAIL FROM:<%s>" from_email);
  expect_code 250;
  List.iter (fun (_name, email) ->
    send (Printf.sprintf "RCPT TO:<%s>" email);
    expect_code 250) mail.to_;
  send "DATA";
  expect_code 354;
  let msg = build_mime_message ~from_email ~from_name
    ~to_:mail.to_ ~subject:mail.subject ~text:mail.text ~html:mail.html in
  send msg;
  expect_code 250;
  send "QUIT"

let send_smtp cfg ~from_email ~from_name mail =
  let net = _get_net () in
  let addr =
    let addrs = Eio.Net.getaddrinfo_stream net cfg.host
      ~service:(string_of_int cfg.port) in
    match addrs with
    | a :: _ -> a
    | [] -> failwith ("Mailer: cannot resolve SMTP host: " ^ cfg.host)
  in
  let tls_host () =
    Option.bind
      (Domain_name.of_string cfg.host |> Result.to_option)
      (fun dn -> Domain_name.host dn |> Result.to_option) in
  Eio.Switch.run @@ fun sw ->
  let tcp_flow = Eio.Net.connect ~sw net addr in
  if cfg.port = 465 then begin
    (* Implicit TLS *)
    let tls_cfg = !_tls_config_fn () in
    let tls_flow = Tls_eio.client_of_flow ?host:(tls_host ()) tls_cfg tcp_flow in
    let reader = Eio.Buf_read.of_flow ~max_size:(64 * 1024) tls_flow in
    let read_line () = Eio.Buf_read.line reader in
    let send s = Eio.Flow.copy_string (s ^ "\r\n") tls_flow in
    let line = read_line () in
    let code = try int_of_string (String.sub line 0 3) with _ -> 0 in
    if code <> 220 then failwith (Printf.sprintf "SMTP: expected 220, got: %s" line);
    smtp_session ~send ~read_line ~cfg ~from_email ~from_name mail
  end else if cfg.port = 587 then begin
    (* STARTTLS *)
    let reader = Eio.Buf_read.of_flow ~max_size:(64 * 1024) tcp_flow in
    let read_line () = Eio.Buf_read.line reader in
    let send s = Eio.Flow.copy_string (s ^ "\r\n") tcp_flow in
    let line = read_line () in
    let code = try int_of_string (String.sub line 0 3) with _ -> 0 in
    if code <> 220 then failwith (Printf.sprintf "SMTP: expected 220, got: %s" line);
    send ("EHLO " ^ cfg.host);
    let rec skip_ehlo () =
      let line = read_line () in
      if String.length line >= 4 && line.[3] = '-' then skip_ehlo () in
    skip_ehlo ();
    send "STARTTLS";
    let starttls_line = read_line () in
    let starttls_code = try int_of_string (String.sub starttls_line 0 3) with _ -> 0 in
    if starttls_code <> 220 then
      failwith (Printf.sprintf "SMTP: STARTTLS expected 220, got: %s" starttls_line);
    (* Upgrade to TLS on the original tcp_flow *)
    let tls_cfg = !_tls_config_fn () in
    let tls_flow = Tls_eio.client_of_flow ?host:(tls_host ()) tls_cfg tcp_flow in
    let tls_reader = Eio.Buf_read.of_flow ~max_size:(64 * 1024) tls_flow in
    let tls_read_line () = Eio.Buf_read.line tls_reader in
    let tls_send s = Eio.Flow.copy_string (s ^ "\r\n") tls_flow in
    smtp_session ~send:tls_send ~read_line:tls_read_line ~cfg ~from_email ~from_name mail
  end else begin
    (* Plain SMTP (port 25) *)
    let reader = Eio.Buf_read.of_flow ~max_size:(64 * 1024) tcp_flow in
    let read_line () = Eio.Buf_read.line reader in
    let send s = Eio.Flow.copy_string (s ^ "\r\n") tcp_flow in
    let line = read_line () in
    let code = try int_of_string (String.sub line 0 3) with _ -> 0 in
    if code <> 220 then failwith (Printf.sprintf "SMTP: expected 220, got: %s" line);
    smtp_session ~send ~read_line ~cfg ~from_email ~from_name mail
  end;
  Ok ()

(* ── Resend adapter ────────────────────────────────────────────── *)

let send_resend cfg ~from_email ~from_name mail =
  let from = if from_name = "" then from_email
    else Printf.sprintf "%s <%s>" from_name from_email in
  let to_list = List.map (fun (name, email) ->
    if name = "" then Printf.sprintf {|{"email":"%s"}|} (escape_json email)
    else Printf.sprintf {|{"name":"%s","email":"%s"}|} (escape_json name) (escape_json email)) mail.to_ in
  let body = Printf.sprintf
    {|{"from":"%s","to":[%s],"subject":"%s","html":"%s","text":"%s"}|}
    (escape_json from) (String.concat "," to_list)
    (escape_json mail.subject) (escape_json mail.html) (escape_json mail.text) in
  let headers = [
    ("Authorization", "Bearer " ^ cfg.api_key);
    ("Content-Type", "application/json");
  ] in
  let (status, _hdrs, resp_body) =
    !_fetch_ref ~method_:"POST" ~headers ~body "https://api.resend.com/emails" in
  if status >= 200 && status < 300 then Ok ()
  else Error (Printf.sprintf "Resend: %d — %s" status resp_body)

(* ── Zeptomail adapter ─────────────────────────────────────────── *)

let send_zeptomail cfg ~from_email ~from_name mail =
  let to_list = List.map (fun (name, email) ->
    if name = "" then
      Printf.sprintf {|{"email_address":{"address":"%s"}}|} (escape_json email)
    else
      Printf.sprintf {|{"email_address":{"address":"%s","name":"%s"}}|}
        (escape_json email) (escape_json name)) mail.to_ in
  let body = Printf.sprintf
    {|{"from":{"address":"%s","name":"%s"},"to":[%s],"subject":"%s","htmlbody":"%s","textbody":"%s"}|}
    (escape_json from_email) (escape_json from_name) (String.concat "," to_list)
    (escape_json mail.subject) (escape_json mail.html) (escape_json mail.text) in
  let url = Printf.sprintf "https://%s/v1.1/email" cfg.api_url in
  let headers = [
    ("Authorization", "Zoho-enczapikey " ^ cfg.token);
    ("Content-Type", "application/json");
  ] in
  let (status, _hdrs, resp_body) =
    !_fetch_ref ~method_:"POST" ~headers ~body url in
  if status >= 200 && status < 300 then Ok ()
  else Error (Printf.sprintf "Zeptomail: %d — %s" status resp_body)

(* ── SES adapter ───────────────────────────────────────────────── *)

let send_ses cfg ~from_email ~from_name mail =
  let to_list = List.map (fun (_name, email) ->
    Printf.sprintf {|"%s"|} (escape_json email)) mail.to_ in
  let from = if from_name = "" then from_email
    else Printf.sprintf "%s <%s>" from_name from_email in
  let body = Printf.sprintf
    {|{"Content":{"Simple":{"Subject":{"Data":"%s"},"Body":{"Text":{"Data":"%s"},"Html":{"Data":"%s"}}}},"Destination":{"ToAddresses":[%s]},"FromEmailAddress":"%s"}|}
    (escape_json mail.subject) (escape_json mail.text) (escape_json mail.html)
    (String.concat "," to_list) (escape_json from) in
  let signed_headers = sign_ses ~cfg ~body in
  let url = Printf.sprintf "https://email.%s.amazonaws.com/v2/email/outbound-emails"
    cfg.region in
  let (status, _hdrs, resp_body) =
    !_fetch_ref ~method_:"POST" ~headers:signed_headers ~body url in
  if status >= 200 && status < 300 then Ok ()
  else Error (Printf.sprintf "SES: %d — %s" status resp_body)

(* ── Log adapter ───────────────────────────────────────────────── *)

let send_log ~from_email ~from_name mail =
  let to_str = String.concat ", "
    (List.map (fun (name, email) ->
      if name = "" then email
      else Printf.sprintf "%s <%s>" name email) mail.to_) in
  Printf.printf "[Mailer:Log] From: %s <%s>\n  To: %s\n  Subject: %s\n  Text: %s\n%!"
    from_name from_email to_str mail.subject
    (if String.length mail.text > 200 then String.sub mail.text 0 200 ^ "..."
     else mail.text);
  Ok ()

(* ── Public API ────────────────────────────────────────────────── *)

(** Send an email using the configured adapter. Returns [Ok ()] or [Error msg]. *)
let send mail =
  let cfg = get_config () in
  match cfg.adapter with
  | Log -> send_log ~from_email:cfg.from_email ~from_name:cfg.from_name mail
  | SMTP smtp ->
    (try send_smtp smtp ~from_email:cfg.from_email ~from_name:cfg.from_name mail
     with exn -> Error (Printf.sprintf "SMTP error: %s" (Printexc.to_string exn)))
  | Resend resend ->
    (try send_resend resend ~from_email:cfg.from_email ~from_name:cfg.from_name mail
     with exn -> Error (Printf.sprintf "Resend error: %s" (Printexc.to_string exn)))
  | Zeptomail zm ->
    (try send_zeptomail zm ~from_email:cfg.from_email ~from_name:cfg.from_name mail
     with exn -> Error (Printf.sprintf "Zeptomail error: %s" (Printexc.to_string exn)))
  | SES ses ->
    (try send_ses ses ~from_email:cfg.from_email ~from_name:cfg.from_name mail
     with exn -> Error (Printf.sprintf "SES error: %s" (Printexc.to_string exn)))
