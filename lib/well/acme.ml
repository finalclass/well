(* acme.ml — ACME HTTP-01 (RFC 8555) auto-TLS provisioning
   Implements Let's Encrypt certificate provisioning without external deps.
   Uses mirage-crypto-pk for RS256, x509 for CSR/cert, Well.fetch for HTTPS. *)

(* ── Forward refs (wired by well.ml) ────────────────────────────── *)

let _sleep_ref : (float -> unit) ref = ref (fun s -> Unix.sleepf s)

type http_response = {
  http_status : int;
  http_headers : (string * string) list;
  http_body : string;
}

let _fetch_ref :
  (method_:string -> headers:(string * string) list -> body:string ->
   string -> http_response) ref =
  ref (fun ~method_:_ ~headers:_ ~body:_ _ ->
    failwith "Acme._fetch_ref not wired")

(* ── TLS config for hot-reload ──────────────────────────────────── *)

let _tls_config : Tls.Config.server option ref = ref None

(* ── Challenge token store ──────────────────────────────────────── *)

let _challenges : (string, string) Hashtbl.t = Hashtbl.create 4

let serve_challenge token =
  Hashtbl.find_opt _challenges token

(* ── Base64url ──────────────────────────────────────────────────── *)

let base64url s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

(* ── Z.t → big-endian unsigned byte string ──────────────────────── *)

let z_to_be z =
  if Z.equal z Z.zero then "\x00"
  else
    (* Z.to_bits gives little-endian binary representation *)
    let bits = Z.to_bits z in
    let len = String.length bits in
    (* Find last non-zero byte (trim LE trailing zeros) *)
    let last = ref (len - 1) in
    while !last > 0 && Char.code bits.[!last] = 0 do decr last done;
    let n = !last + 1 in
    let be = Bytes.create n in
    for i = 0 to n - 1 do
      Bytes.set be i bits.[n - 1 - i]
    done;
    Bytes.unsafe_to_string be

(* ── File helpers (stdlib — runs at startup, blocking is fine) ──── *)

let ensure_dir path =
  try Unix.mkdir path 0o755
  with Unix.Unix_error (Unix.EEXIST, _, _) -> ()

let read_pem path =
  let ic = open_in_bin path in
  let data = really_input_string ic (in_channel_length ic) in
  close_in ic;
  data

let write_pem path data =
  let oc = open_out_bin path in
  output_string oc data;
  close_out oc

(* ── Cert storage paths ─────────────────────────────────────────── *)

let cert_dir = "data/certs"
let account_key_file = Filename.concat cert_dir "account_key.pem"
let cert_file domain = Filename.concat cert_dir (domain ^ ".cert.pem")
let key_file domain = Filename.concat cert_dir (domain ^ ".key.pem")

(* ── ACME directory ─────────────────────────────────────────────── *)

let le_production = "https://acme-v02.api.letsencrypt.org/directory"
let le_staging = "https://acme-staging-v02.api.letsencrypt.org/directory"

type directory = {
  new_nonce : string;
  new_account : string;
  new_order : string;
}

let str_field key json =
  match Yojson.Safe.Util.member key json with
  | `String s -> s
  | _ -> failwith ("ACME: directory missing field: " ^ key)

let get_directory ~staging =
  let url = if staging then le_staging else le_production in
  let resp = !_fetch_ref ~method_:"GET" ~headers:[] ~body:"" url in
  let json = Yojson.Safe.from_string resp.http_body in
  {
    new_nonce = str_field "newNonce" json;
    new_account = str_field "newAccount" json;
    new_order = str_field "newOrder" json;
  }

(* ── Account key management ─────────────────────────────────────── *)

let load_or_create_account_key () =
  ensure_dir "data";
  ensure_dir cert_dir;
  if Sys.file_exists account_key_file then begin
    let pem = read_pem account_key_file in
    match X509.Private_key.decode_pem pem with
    | Ok (`RSA priv) -> priv
    | Ok _ -> failwith "ACME: account key is not RSA"
    | Error (`Msg m) -> failwith ("ACME: cannot decode account key: " ^ m)
  end else begin
    let priv = Mirage_crypto_pk.Rsa.generate ~bits:2048 () in
    let x509_key : X509.Private_key.t = `RSA priv in
    write_pem account_key_file (X509.Private_key.encode_pem x509_key);
    Log.log "ACME: generated new account key";
    priv
  end

(* ── JWK (JSON Web Key) — RSA public key ────────────────────────── *)

let jwk_of_rsa (pub : Mirage_crypto_pk.Rsa.pub) : Yojson.Safe.t =
  `Assoc [
    ("e", `String (base64url (z_to_be pub.e)));
    ("kty", `String "RSA");
    ("n", `String (base64url (z_to_be pub.n)));
  ]

(* ── JWK Thumbprint (RFC 7638) ──────────────────────────────────── *)

let jwk_thumbprint (pub : Mirage_crypto_pk.Rsa.pub) =
  (* Canonical JSON: members in lexicographic order *)
  let canonical = Printf.sprintf
    {|{"e":"%s","kty":"RSA","n":"%s"}|}
    (base64url (z_to_be pub.e))
    (base64url (z_to_be pub.n))
  in
  base64url Digestif.SHA256.(digest_string canonical |> to_raw_string)

(* ── Nonce state ────────────────────────────────────────────────── *)

let _nonce : string ref = ref ""

let extract_nonce headers =
  match List.assoc_opt "replay-nonce" headers with
  | Some n -> _nonce := n
  | None -> ()

let fetch_nonce dir =
  let resp = !_fetch_ref ~method_:"GET" ~headers:[] ~body:"" dir.new_nonce in
  extract_nonce resp.http_headers;
  !_nonce

(* ── JWS RS256 signing ──────────────────────────────────────────── *)

type jws_payload = Empty | Json of Yojson.Safe.t

let jws_sign ~priv ~protected ~payload =
  let protected_b64 = base64url (Yojson.Safe.to_string protected) in
  let payload_b64 = match payload with
    | Empty -> ""
    | Json j -> base64url (Yojson.Safe.to_string j)
  in
  let signing_input = protected_b64 ^ "." ^ payload_b64 in
  let signature =
    Mirage_crypto_pk.Rsa.PKCS1.sign ~hash:`SHA256 ~key:priv
      (`Message signing_input)
  in
  Yojson.Safe.to_string (`Assoc [
    ("protected", `String protected_b64);
    ("payload", `String payload_b64);
    ("signature", `String (base64url signature));
  ])

(* ── ACME POST ──────────────────────────────────────────────────── *)

let acme_post ~priv ~key_id ~url payload =
  let nonce = !_nonce in
  let protected =
    let base = [
      ("alg", `String "RS256");
      ("nonce", `String nonce);
      ("url", `String url);
    ] in
    match key_id with
    | Some kid -> `Assoc (("kid", `String kid) :: base)
    | None ->
        let pub = Mirage_crypto_pk.Rsa.pub_of_priv priv in
        `Assoc (("jwk", jwk_of_rsa pub) :: base)
  in
  let body = jws_sign ~priv ~protected ~payload in
  let resp = !_fetch_ref ~method_:"POST"
    ~headers:[("Content-Type", "application/jose+json")]
    ~body url
  in
  extract_nonce resp.http_headers;
  resp

(* ── Account creation ───────────────────────────────────────────── *)

let create_account ~priv dir =
  let resp = acme_post ~priv ~key_id:None ~url:dir.new_account
    (Json (`Assoc [("termsOfServiceAgreed", `Bool true)])) in
  if resp.http_status <> 200 && resp.http_status <> 201 then
    failwith (Printf.sprintf "ACME: account creation failed (%d): %s"
      resp.http_status resp.http_body);
  match List.assoc_opt "location" resp.http_headers with
  | Some kid -> kid
  | None -> failwith "ACME: no Location header in account response"

(* ── Order creation ─────────────────────────────────────────────── *)

type order_info = {
  order_url : string;
  authorizations : string list;
  finalize_url : string;
}

let create_order ~priv ~kid dir domain =
  let resp = acme_post ~priv ~key_id:(Some kid) ~url:dir.new_order
    (Json (`Assoc [
      ("identifiers", `List [
        `Assoc [("type", `String "dns"); ("value", `String domain)]
      ]);
    ])) in
  if resp.http_status <> 201 then
    failwith (Printf.sprintf "ACME: order creation failed (%d): %s"
      resp.http_status resp.http_body);
  let json = Yojson.Safe.from_string resp.http_body in
  let open Yojson.Safe.Util in
  {
    order_url =
      (match List.assoc_opt "location" resp.http_headers with
       | Some u -> u | None -> "");
    authorizations =
      json |> member "authorizations" |> to_list |> List.map to_string;
    finalize_url = json |> member "finalize" |> to_string;
  }

(* ── Challenge extraction ───────────────────────────────────────── *)

type challenge_info = {
  challenge_url : string;
  token : string;
}

let get_http01_challenge ~priv ~kid authz_url =
  let resp = acme_post ~priv ~key_id:(Some kid) ~url:authz_url Empty in
  let json = Yojson.Safe.from_string resp.http_body in
  let open Yojson.Safe.Util in
  let challenges = json |> member "challenges" |> to_list in
  match List.find_opt (fun c ->
    c |> member "type" |> to_string = "http-01"
  ) challenges with
  | Some c ->
      { challenge_url = c |> member "url" |> to_string;
        token = c |> member "token" |> to_string }
  | None -> failwith "ACME: no http-01 challenge found"

(* ── Challenge response ─────────────────────────────────────────── *)

let respond_to_challenge ~priv ~kid ~pub challenge =
  let thumbprint = jwk_thumbprint pub in
  let key_authz = challenge.token ^ "." ^ thumbprint in
  Hashtbl.replace _challenges challenge.token key_authz;
  let resp = acme_post ~priv ~key_id:(Some kid)
    ~url:challenge.challenge_url (Json (`Assoc [])) in
  if resp.http_status <> 200 then
    Log.log ~level:"warn" "ACME: challenge response status %d"
      resp.http_status

(* ── Polling ────────────────────────────────────────────────────── *)

let poll_until_ready ~priv ~kid url =
  let max_attempts = 30 in
  let rec loop attempt =
    if attempt >= max_attempts then
      failwith "ACME: timed out waiting for order to become ready";
    !_sleep_ref 2.0;
    let resp = acme_post ~priv ~key_id:(Some kid) ~url Empty in
    let json = Yojson.Safe.from_string resp.http_body in
    let status = Yojson.Safe.Util.(json |> member "status" |> to_string) in
    match status with
    | "ready" | "valid" -> json
    | "invalid" ->
        failwith (Printf.sprintf "ACME: order invalid: %s" resp.http_body)
    | _ -> loop (attempt + 1)
  in
  loop 0

(* ── CSR creation ───────────────────────────────────────────────── *)

let create_csr domain =
  let domain_key : X509.Private_key.t =
    X509.Private_key.generate ~bits:2048 `RSA
  in
  let dn : X509.Distinguished_name.t = [
    X509.Distinguished_name.Relative_distinguished_name.singleton
      (X509.Distinguished_name.CN domain)
  ] in
  let san = X509.General_name.singleton X509.General_name.DNS [domain] in
  let extensions =
    X509.Extension.singleton X509.Extension.Subject_alt_name (false, san)
  in
  let req_ext =
    X509.Signing_request.Ext.singleton
      X509.Signing_request.Ext.Extensions extensions
  in
  match X509.Signing_request.create dn ~extensions:req_ext domain_key with
  | Ok csr -> (csr, domain_key)
  | Error (`Msg m) -> failwith ("ACME: CSR creation failed: " ^ m)

(* ── Finalize order ─────────────────────────────────────────────── *)

let finalize_order ~priv ~kid ~finalize_url domain =
  let csr, domain_key = create_csr domain in
  let csr_der = X509.Signing_request.encode_der csr in
  let resp = acme_post ~priv ~key_id:(Some kid) ~url:finalize_url
    (Json (`Assoc [("csr", `String (base64url csr_der))])) in
  if resp.http_status <> 200 then
    failwith (Printf.sprintf "ACME: finalize failed (%d): %s"
      resp.http_status resp.http_body);
  let json = Yojson.Safe.from_string resp.http_body in
  (json, domain_key)

(* ── Download certificate ───────────────────────────────────────── *)

let download_cert ~priv ~kid cert_url =
  let resp = acme_post ~priv ~key_id:(Some kid) ~url:cert_url Empty in
  if resp.http_status <> 200 then
    failwith (Printf.sprintf "ACME: cert download failed (%d): %s"
      resp.http_status resp.http_body);
  resp.http_body

(* ── Certificate validity ───────────────────────────────────────── *)

let cert_days_remaining pem_data =
  match X509.Certificate.decode_pem pem_data with
  | Ok cert ->
      let _valid_from, valid_until = X509.Certificate.validity cert in
      let now = match Ptime.of_float_s (Unix.gettimeofday ()) with
        | Some t -> t
        | None -> Ptime.epoch
      in
      let span = Ptime.diff valid_until now in
      int_of_float (Ptime.Span.to_float_s span /. 86400.0)
  | Error _ -> 0

(* ── Full provision flow ────────────────────────────────────────── *)

let provision ~staging domain =
  Log.log "ACME: provisioning certificate for %s%s"
    domain (if staging then " (staging)" else "");
  let priv = load_or_create_account_key () in
  let pub = Mirage_crypto_pk.Rsa.pub_of_priv priv in
  (* Fetch ACME directory + initial nonce *)
  let dir = get_directory ~staging in
  ignore (fetch_nonce dir);
  (* Register/find account *)
  let kid = create_account ~priv dir in
  Log.log "ACME: account ready";
  (* Create order *)
  let order = create_order ~priv ~kid dir domain in
  Log.log "ACME: order created";
  (* Process each authorization *)
  List.iter (fun authz_url ->
    let challenge = get_http01_challenge ~priv ~kid authz_url in
    Log.log "ACME: challenge token: %s..."
      (String.sub challenge.token 0 (min 16 (String.length challenge.token)));
    respond_to_challenge ~priv ~kid ~pub challenge
  ) order.authorizations;
  (* Poll until ready *)
  Log.log "ACME: waiting for validation...";
  ignore (poll_until_ready ~priv ~kid order.order_url);
  (* Finalize with CSR *)
  Log.log "ACME: finalizing order...";
  let order_json, domain_key = finalize_order ~priv ~kid
    ~finalize_url:order.finalize_url domain in
  (* Get certificate URL — may need polling *)
  let cert_url = match Yojson.Safe.Util.member "certificate" order_json with
    | `String s -> s
    | _ ->
        let json = poll_until_ready ~priv ~kid order.order_url in
        (match Yojson.Safe.Util.member "certificate" json with
         | `String s -> s
         | _ -> failwith "ACME: certificate URL not available after polling")
  in
  (* Download certificate chain *)
  let cert_pem = download_cert ~priv ~kid cert_url in
  (* Save to disk *)
  write_pem (cert_file domain) cert_pem;
  write_pem (key_file domain) (X509.Private_key.encode_pem domain_key);
  Log.log "ACME: certificate saved to %s" (cert_file domain);
  Hashtbl.clear _challenges;
  (cert_pem, domain_key)

(* ── Ensure certificate (load existing or provision new) ────────── *)

let ensure_certificate ~staging domain =
  let cp = cert_file domain in
  let kp = key_file domain in
  if Sys.file_exists cp && Sys.file_exists kp then begin
    let cert_pem = read_pem cp in
    let days = cert_days_remaining cert_pem in
    Log.log "ACME: existing cert — %d days remaining" days;
    if days > 30 then begin
      let key_pem = read_pem kp in
      match X509.Private_key.decode_pem key_pem with
      | Ok domain_key -> (cert_pem, domain_key)
      | Error (`Msg m) ->
          Log.log ~level:"warn" "ACME: bad domain key (%s), re-provisioning" m;
          provision ~staging domain
    end else begin
      Log.log "ACME: cert expiring soon, renewing";
      provision ~staging domain
    end
  end else
    provision ~staging domain

(* ── Build TLS server config ────────────────────────────────────── *)

let build_tls_config cert_pem (domain_key : X509.Private_key.t) =
  match X509.Certificate.decode_pem_multiple cert_pem with
  | Error (`Msg m) -> failwith ("ACME: cannot decode certificate: " ^ m)
  | Ok certs ->
      match Tls.Config.server ~certificates:(`Single (certs, domain_key)) () with
      | Ok cfg -> cfg
      | Error (`Msg m) -> failwith ("ACME: TLS config error: " ^ m)

(* ── Renewal fiber (runs in background, checks daily) ───────────── *)

let renewal_fiber ~staging domain =
  let day_seconds = 86400.0 in
  try
    while true do
      !_sleep_ref day_seconds;
      (try
        let cp = cert_file domain in
        if Sys.file_exists cp then begin
          let cert_pem = read_pem cp in
          let days = cert_days_remaining cert_pem in
          Log.log "ACME: renewal check — %d days remaining" days;
          if days <= 30 then begin
            Log.log "ACME: renewing certificate";
            let cert_pem, domain_key = provision ~staging domain in
            let cfg = build_tls_config cert_pem domain_key in
            _tls_config := Some cfg;
            Log.log "ACME: TLS config hot-reloaded"
          end
        end
      with exn ->
        Log.log ~level:"error" "ACME: renewal error: %s"
          (Printexc.to_string exn))
    done
  with _ -> ()
