(** Well.OAuth -- OAuth 2.0 client with PKCE S256 for Google, GitHub, Microsoft, and Facebook.
    State is session-bound, single-use, with 10-minute expiry. *)

(* ── Types ──────────────────────────────────────────────────────── *)

type oauth_response =
  | ORedirect of string
  | OHtml of string * int
  | ORedirectWithRegenerate of string

(** OAuth provider configuration: endpoints, client credentials, and scopes. *)
type provider_config = {
  name : string;
  client_id : string;
  client_secret : string;
  scopes : string list;
  authorize_url : string;
  token_url : string;
  userinfo_url : string;
  is_oidc : bool;
}

(** User info returned by an OAuth provider after authentication. *)
type provider_user = {
  uid : string;
  email : string option;
  email_verified : bool;
  name : string option;
  avatar_url : string option;
}

(* ── Forward refs (wired by well.ml) ────────────────────────────── *)

let _fetch_ref :
  (method_:string -> headers:(string * string) list -> body:string ->
   string -> int * (string * string) list * string) ref =
  ref (fun ~method_:_ ~headers:_ ~body:_ _ ->
    failwith "Oauth._fetch_ref not wired")

let _session_get_ref : (string -> string -> string option) ref =
  ref (fun _ _ -> failwith "Oauth._session_get_ref not wired")

let _session_set_ref : (string -> string -> string -> unit) ref =
  ref (fun _ _ _ -> failwith "Oauth._session_set_ref not wired")

let _session_delete_ref : (string -> string -> unit) ref =
  ref (fun _ _ -> failwith "Oauth._session_delete_ref not wired")

let _handle_get_ref :
  (string -> (Types.request -> oauth_response) -> unit) ref =
  ref (fun _ _ -> failwith "Oauth._handle_get_ref not wired")

let _put_flash_ref : (Types.request -> string -> string -> unit) ref =
  ref (fun _ _ _ -> failwith "Oauth._put_flash_ref not wired")

let _log_ref : (string -> unit) ref =
  ref (fun _ -> ())

(* ── URL encoding ───────────────────────────────────────────────── *)

let url_encode str =
  let buf = Buffer.create (String.length str * 3) in
  String.iter (fun c ->
    match c with
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '~' | '.' ->
      Buffer.add_char buf c
    | _ -> Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c))
  ) str;
  Buffer.contents buf

(* ── Crypto helpers ─────────────────────────────────────────────── *)

let hex_encode s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter (fun c ->
    Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) s;
  Buffer.contents buf

(* Length check is safe: state is always 64 hex chars (generate_state) *)
let constant_time_equal a b =
  let len_a = String.length a in
  let len_b = String.length b in
  if len_a <> len_b then false
  else begin
    let diff = ref 0 in
    for i = 0 to len_a - 1 do
      diff := !diff lor (Char.code a.[i] lxor Char.code b.[i])
    done;
    !diff = 0
  end

let base64url_encode s =
  let b64 = Base64.encode_exn s in
  (* Convert standard base64 to URL-safe: + → -, / → _, strip = padding *)
  let buf = Buffer.create (String.length b64) in
  String.iter (fun c ->
    match c with
    | '+' -> Buffer.add_char buf '-'
    | '/' -> Buffer.add_char buf '_'
    | '=' -> ()
    | c -> Buffer.add_char buf c
  ) b64;
  Buffer.contents buf

let generate_state () =
  hex_encode (Mirage_crypto_rng.generate 32)

let generate_code_verifier () =
  (* 43 chars from unreserved charset [A-Za-z0-9-._~], rejection sampling to avoid modulo bias *)
  let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~" in
  let len = String.length chars in (* 66 *)
  let limit = (256 / len) * len in (* 252 — largest multiple of 66 ≤ 256 *)
  let buf = Buffer.create 43 in
  let pool = ref (Mirage_crypto_rng.generate 64) in
  let pos = ref 0 in
  while Buffer.length buf < 43 do
    if !pos >= String.length !pool then begin
      pool := Mirage_crypto_rng.generate 64;
      pos := 0
    end;
    let b = Char.code (String.get !pool !pos) in
    incr pos;
    if b < limit then
      Buffer.add_char buf chars.[b mod len]
  done;
  Buffer.contents buf

let code_challenge verifier =
  let hash = Digestif.SHA256.digest_string verifier |> Digestif.SHA256.to_raw_string in
  base64url_encode hash

(* ── Provider configs ───────────────────────────────────────────── *)

(** Create a Google OAuth provider config (OpenID Connect). *)
let google ~client_id ~client_secret =
  { name = "google"; client_id; client_secret;
    scopes = ["openid"; "email"; "profile"];
    authorize_url = "https://accounts.google.com/o/oauth2/v2/auth";
    token_url = "https://oauth2.googleapis.com/token";
    userinfo_url = "https://openidconnect.googleapis.com/v1/userinfo";
    is_oidc = true }

(** Create a GitHub OAuth provider config. *)
let github ~client_id ~client_secret =
  { name = "github"; client_id; client_secret;
    scopes = ["user:email"; "read:user"];
    authorize_url = "https://github.com/login/oauth/authorize";
    token_url = "https://github.com/login/oauth/access_token";
    userinfo_url = "https://api.github.com/user";
    is_oidc = false }

(** Create a Microsoft OAuth provider config (Azure AD, OpenID Connect). *)
let microsoft ~client_id ~client_secret =
  { name = "microsoft"; client_id; client_secret;
    scopes = ["openid"; "email"; "profile"; "User.Read"];
    authorize_url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize";
    token_url = "https://login.microsoftonline.com/common/oauth2/v2.0/token";
    userinfo_url = "https://graph.microsoft.com/v1.0/me";
    is_oidc = true }

(** Create a Facebook OAuth provider config. *)
let facebook ~client_id ~client_secret =
  { name = "facebook"; client_id; client_secret;
    scopes = ["email"; "public_profile"];
    authorize_url = "https://www.facebook.com/v19.0/dialog/oauth";
    token_url = "https://graph.facebook.com/v19.0/oauth/access_token";
    userinfo_url = "https://graph.facebook.com/v19.0/me?fields=id,name,email,picture";
    is_oidc = false }

(* ── State ──────────────────────────────────────────────────────── *)

let _base_url = ref ""
let _providers : provider_config list ref = ref []

(* ── DB — _well_oauth_identities table in well.sqlite ────────────────── *)

let _table_created = Atomic.make false

let ensure_table () =
  if not (Atomic.get _table_created) then begin
    Auth.with_db (fun db ->
      let _ = Sqlite3.exec db
        {|CREATE TABLE IF NOT EXISTS _well_oauth_identities (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            provider TEXT NOT NULL,
            provider_uid TEXT NOT NULL,
            email TEXT,
            name TEXT,
            avatar_url TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
            UNIQUE(provider, provider_uid)
          )|} in
      ());
    Atomic.set _table_created true
  end

(* ── Identity queries ───────────────────────────────────────────── *)

(** Find the user_id linked to a provider identity, if any. *)
let find_identity ~provider ~provider_uid =
  ensure_table ();
  Auth.with_db (fun db ->
    let stmt = Sqlite3.prepare db
      "SELECT user_id, email, name, avatar_url FROM _well_oauth_identities \
       WHERE provider = ? AND provider_uid = ?" in
    let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT provider) in
    let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT provider_uid) in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      let user_id = Sqlite3.column_int stmt 0 in
      let _ = Sqlite3.finalize stmt in
      Some user_id
    | _ ->
      let _ = Sqlite3.finalize stmt in
      None)

(** Create or update an OAuth identity record linking a provider UID to a user. *)
let create_identity ~user_id ~provider ~provider_uid ?email ?name ?avatar_url () =
  ensure_table ();
  Auth.with_db (fun db ->
    (* ON CONFLICT: only update if same user_id — prevents identity theft *)
    let stmt = Sqlite3.prepare db
      "INSERT INTO _well_oauth_identities \
       (user_id, provider, provider_uid, email, name, avatar_url) \
       VALUES (?, ?, ?, ?, ?, ?) \
       ON CONFLICT(provider, provider_uid) DO UPDATE SET \
         email = excluded.email, name = excluded.name, \
         avatar_url = excluded.avatar_url, \
         updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') \
       WHERE user_id = excluded.user_id" in
    let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int user_id)) in
    let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT provider) in
    let _ = Sqlite3.bind stmt 3 (Sqlite3.Data.TEXT provider_uid) in
    let _ = Sqlite3.bind stmt 4 (match email with
      | Some e -> Sqlite3.Data.TEXT e | None -> Sqlite3.Data.NULL) in
    let _ = Sqlite3.bind stmt 5 (match name with
      | Some n -> Sqlite3.Data.TEXT n | None -> Sqlite3.Data.NULL) in
    let _ = Sqlite3.bind stmt 6 (match avatar_url with
      | Some a -> Sqlite3.Data.TEXT a | None -> Sqlite3.Data.NULL) in
    let _ = Sqlite3.step stmt in
    let _ = Sqlite3.finalize stmt in
    ())

(** List all OAuth identities linked to a user as [(provider, provider_uid)] pairs. *)
let user_identities ~user_id =
  ensure_table ();
  Auth.with_db (fun db ->
    let stmt = Sqlite3.prepare db
      "SELECT provider, provider_uid FROM _well_oauth_identities \
       WHERE user_id = ? ORDER BY provider" in
    let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int user_id)) in
    let results = ref [] in
    while Sqlite3.step stmt = Sqlite3.Rc.ROW do
      let provider = Sqlite3.column_text stmt 0 in
      let uid = Sqlite3.column_text stmt 1 in
      results := (provider, uid) :: !results
    done;
    let _ = Sqlite3.finalize stmt in
    List.rev !results)

(* ── JSON helpers ───────────────────────────────────────────────── *)

let json_string_opt key json =
  match json with
  | `Assoc pairs ->
    (match List.assoc_opt key pairs with
     | Some (`String s) when s <> "" -> Some s
     | _ -> None)
  | _ -> None

let json_bool_opt key json =
  match json with
  | `Assoc pairs ->
    (match List.assoc_opt key pairs with
     | Some (`Bool b) -> Some b
     | _ -> None)
  | _ -> None

let json_int_opt key json =
  match json with
  | `Assoc pairs ->
    (match List.assoc_opt key pairs with
     | Some (`Int i) -> Some i
     | Some (`Intlit s) -> int_of_string_opt s
     | _ -> None)
  | _ -> None

(* ── Provider-specific userinfo parsing ─────────────────────────── *)

let parse_google_user json =
  { uid = (match json_string_opt "sub" json with Some s -> s | None -> "");
    email = json_string_opt "email" json;
    email_verified = (match json_bool_opt "email_verified" json with Some b -> b | None -> false);
    name = json_string_opt "name" json;
    avatar_url = json_string_opt "picture" json }

let parse_github_user ~access_token json =
  let uid = match json_int_opt "id" json with
    | Some i -> string_of_int i | None -> "" in
  let name = json_string_opt "name" json in
  let avatar_url = json_string_opt "avatar_url" json in
  (* GitHub: need separate API call for verified primary email *)
  let email, email_verified =
    try
      let (status, _, body) = !_fetch_ref
        ~method_:"GET"
        ~headers:[("Authorization", "Bearer " ^ access_token);
                  ("Accept", "application/json");
                  ("User-Agent", "well-framework")]
        ~body:""
        "https://api.github.com/user/emails" in
      if status = 200 then
        match Yojson.Safe.from_string body with
        | `List emails ->
          let primary_verified = List.find_opt (fun e ->
            json_bool_opt "primary" e = Some true &&
            json_bool_opt "verified" e = Some true
          ) emails in
          (match primary_verified with
           | Some e -> (json_string_opt "email" e, true)
           | None ->
             let any_verified = List.find_opt (fun e ->
               json_bool_opt "verified" e = Some true
             ) emails in
             (match any_verified with
              | Some e -> (json_string_opt "email" e, true)
              | None -> (json_string_opt "email" json, false)))
        | _ -> (json_string_opt "email" json, false)
      else (json_string_opt "email" json, false)
    with _ -> (json_string_opt "email" json, false)
  in
  { uid; email; email_verified; name; avatar_url }

let parse_microsoft_user json =
  let uid = match json_string_opt "id" json with Some s -> s | None -> "" in
  let email = match json_string_opt "mail" json with
    | Some _ as e -> e
    | None -> json_string_opt "userPrincipalName" json in
  { uid;
    email;
    (* Microsoft Graph /me does NOT expose email verification status.
       Setting false prevents account takeover via unverified Azure emails. *)
    email_verified = false;
    name = json_string_opt "displayName" json;
    avatar_url = None }

let parse_facebook_user json =
  let uid = match json_string_opt "id" json with Some s -> s | None -> "" in
  let avatar_url =
    match json with
    | `Assoc pairs ->
      (match List.assoc_opt "picture" pairs with
       | Some (`Assoc data_pairs) ->
         (match List.assoc_opt "data" data_pairs with
          | Some d -> json_string_opt "url" d
          | None -> None)
       | _ -> None)
    | _ -> None in
  { uid;
    email = json_string_opt "email" json;
    (* Facebook Graph API does not expose email verification status *)
    email_verified = false;
    name = json_string_opt "name" json;
    avatar_url }

(* ── Token exchange ─────────────────────────────────────────────── *)

let exchange_code provider ~code ~code_verifier ~redirect_uri =
  let body = String.concat "&" [
    "grant_type=authorization_code";
    "code=" ^ url_encode code;
    "redirect_uri=" ^ url_encode redirect_uri;
    "client_id=" ^ url_encode provider.client_id;
    "client_secret=" ^ url_encode provider.client_secret;
    "code_verifier=" ^ url_encode code_verifier;
  ] in
  let headers = [
    ("Content-Type", "application/x-www-form-urlencoded");
    ("Accept", "application/json");
  ] in
  let (status, _, resp_body) =
    !_fetch_ref ~method_:"POST" ~headers ~body provider.token_url in
  if status >= 200 && status < 300 then
    try
      let json = Yojson.Safe.from_string resp_body in
      match json_string_opt "access_token" json with
      | Some token -> Ok token
      | None -> Error "No access_token in response"
    with exn -> Error (Printexc.to_string exn)
  else
    (* Sanitize: extract only OAuth error field, never log raw response *)
    let safe_error = match Yojson.Safe.from_string resp_body with
      | json ->
        let err = match json_string_opt "error" json with
          | Some e -> e | None -> "unknown" in
        let desc = match json_string_opt "error_description" json with
          | Some d -> " — " ^ (String.sub d 0 (min 200 (String.length d)))
          | None -> "" in
        err ^ desc
      | exception _ -> "invalid response" in
    Error (Printf.sprintf "Token exchange failed: %d — %s" status safe_error)

(* ── Fetch userinfo ─────────────────────────────────────────────── *)

let fetch_userinfo provider ~access_token =
  let headers = [
    ("Authorization", "Bearer " ^ access_token);
    ("Accept", "application/json");
    ("User-Agent", "well-framework");
  ] in
  let (status, _, body) =
    !_fetch_ref ~method_:"GET" ~headers ~body:"" provider.userinfo_url in
  if status >= 200 && status < 300 then
    try
      let json = Yojson.Safe.from_string body in
      let user = match provider.name with
        | "google" -> parse_google_user json
        | "github" -> parse_github_user ~access_token json
        | "microsoft" -> parse_microsoft_user json
        | "facebook" -> parse_facebook_user json
        | _ -> parse_google_user json (* fallback to OIDC-style *)
      in
      Ok user
    with exn -> Error (Printexc.to_string exn)
  else
    let safe_error = match Yojson.Safe.from_string body with
      | json -> (match json_string_opt "error" json with
        | Some e -> e | None -> "request failed")
      | exception _ -> "invalid response" in
    Error (Printf.sprintf "Userinfo failed: %d — %s" status safe_error)

(* ── Account linking logic ──────────────────────────────────────── *)

let link_or_create_user provider_user ~provider_name =
  ensure_table ();
  (* 1. Check if (provider, uid) already linked *)
  match find_identity ~provider:provider_name ~provider_uid:provider_user.uid with
  | Some user_id ->
    (* Update identity info *)
    create_identity ~user_id ~provider:provider_name
      ~provider_uid:provider_user.uid
      ?email:provider_user.email ?name:provider_user.name
      ?avatar_url:provider_user.avatar_url ();
    (match Auth.get_user user_id with
     | Some user -> Ok user
     | None -> Error "Linked user not found")
  | None ->
    (* 2. Check if verified email matches existing user *)
    let link_to_existing =
      match provider_user.email with
      | Some email when provider_user.email_verified ->
        Auth.find_user_by_email email
      | _ -> None
    in
    (match link_to_existing with
     | Some user ->
       (* Verified email matches → link identity to existing user *)
       create_identity ~user_id:user.id ~provider:provider_name
         ~provider_uid:provider_user.uid
         ?email:provider_user.email ?name:provider_user.name
         ?avatar_url:provider_user.avatar_url ();
       Ok user
     | None ->
       (* 3. Create new user *)
       let email = match provider_user.email with
         | Some e -> e
         | None -> Printf.sprintf "%s_%s@oauth.local" provider_name provider_user.uid
       in
       (match Auth.create_user_without_password ~email with
        | Ok user ->
          create_identity ~user_id:user.id ~provider:provider_name
            ~provider_uid:provider_user.uid
            ?email:provider_user.email ?name:provider_user.name
            ?avatar_url:provider_user.avatar_url ();
          Ok user
        | Error "Email already taken" when not provider_user.email_verified ->
          (* Unverified email collides with existing → create separate account *)
          let alt_email = Printf.sprintf "%s_%s@oauth.local"
            provider_name provider_user.uid in
          (match Auth.create_user_without_password ~email:alt_email with
           | Ok user ->
             create_identity ~user_id:user.id ~provider:provider_name
               ~provider_uid:provider_user.uid
               ?email:provider_user.email ?name:provider_user.name
               ?avatar_url:provider_user.avatar_url ();
             Ok user
           | Error e -> Error e)
        | Error "Email already taken" when provider_user.email_verified ->
          (* Race: verified email collision — retry linking to existing user *)
          (match provider_user.email with
           | Some email ->
             (match Auth.find_user_by_email email with
              | Some user ->
                create_identity ~user_id:user.id ~provider:provider_name
                  ~provider_uid:provider_user.uid
                  ?email:provider_user.email ?name:provider_user.name
                  ?avatar_url:provider_user.avatar_url ();
                Ok user
              | None -> Error "Account creation failed")
           | None -> Error "Account creation failed")
        | Error e -> Error e))

(* ── Validate return_to ─────────────────────────────────────────── *)

let validate_return_to s =
  if s = "" then "/"
  else if String.length s >= 1 && s.[0] = '/'
       && not (String.length s >= 2 && s.[1] = '/') then s
  else "/"

(* ── Route handlers ─────────────────────────────────────────────── *)

let authorize_handler (provider : provider_config) (req : Types.request) =
  let state = generate_state () in
  let verifier = generate_code_verifier () in
  let challenge = code_challenge verifier in
  let timestamp = string_of_float (Unix.gettimeofday ()) in
  let sid = req.session_id in
  let prefix = "oauth_" ^ provider.name ^ "_" in
  !_session_set_ref sid (prefix ^ "state") state;
  !_session_set_ref sid (prefix ^ "verifier") verifier;
  !_session_set_ref sid (prefix ^ "state_time") timestamp;
  if provider.is_oidc then begin
    let nonce = hex_encode (Mirage_crypto_rng.generate 16) in
    !_session_set_ref sid (prefix ^ "nonce") nonce
  end;
  let return_to = match List.assoc_opt "return_to" req.query with
    | Some r -> validate_return_to r | None -> "/" in
  !_session_set_ref sid (prefix ^ "return_to") return_to;
  let redirect_uri = !_base_url ^ "/auth/" ^ provider.name ^ "/callback" in
  let scopes = String.concat " " provider.scopes in
  let params = [
    ("client_id", provider.client_id);
    ("redirect_uri", redirect_uri);
    ("response_type", "code");
    ("scope", scopes);
    ("state", state);
    ("code_challenge", challenge);
    ("code_challenge_method", "S256");
  ] in
  let query_string = String.concat "&"
    (List.map (fun (k, v) -> k ^ "=" ^ url_encode v) params) in
  let url = provider.authorize_url ^ "?" ^ query_string in
  ORedirect url

let callback_handler (provider : provider_config) (req : Types.request) =
  let sid = req.session_id in
  let prefix = "oauth_" ^ provider.name ^ "_" in
  (* Check if user cancelled *)
  (match List.assoc_opt "error" req.query with
   | Some _ ->
     !_put_flash_ref req "error" "Login cancelled";
     ORedirect "/login"
   | None ->
  (* Validate state — read and immediately delete (single-use) *)
  let stored_state = !_session_get_ref sid (prefix ^ "state") in
  !_session_delete_ref sid (prefix ^ "state");
  let stored_verifier = !_session_get_ref sid (prefix ^ "verifier") in
  !_session_delete_ref sid (prefix ^ "verifier");
  let stored_time = !_session_get_ref sid (prefix ^ "state_time") in
  !_session_delete_ref sid (prefix ^ "state_time");
  let stored_return_to = !_session_get_ref sid (prefix ^ "return_to") in
  !_session_delete_ref sid (prefix ^ "return_to");
  if provider.is_oidc then
    !_session_delete_ref sid (prefix ^ "nonce");
  let return_to = match stored_return_to with
    | Some r -> validate_return_to r | None -> "/" in
  let received_state = match List.assoc_opt "state" req.query with
    | Some s -> s | None -> "" in
  let received_code = match List.assoc_opt "code" req.query with
    | Some c -> c | None -> "" in
  (* Validate state *)
  match stored_state, stored_verifier, stored_time with
  | Some state, Some verifier, Some time_s ->
    if not (constant_time_equal state received_state) then begin
      !_log_ref "[OAuth] State mismatch";
      !_put_flash_ref req "error" "Security validation failed";
      ORedirect "/login"
    end else
    let state_time = match float_of_string_opt time_s with
      | Some f -> f | None -> 0.0 in
    let now = Unix.gettimeofday () in
    if now -. state_time > 600.0 then begin
      !_log_ref "[OAuth] State expired";
      !_put_flash_ref req "error" "Login session expired";
      ORedirect "/login"
    end else if received_code = "" then begin
      !_log_ref "[OAuth] No code in callback";
      !_put_flash_ref req "error" "Authorization failed";
      ORedirect "/login"
    end else begin
      let redirect_uri = !_base_url ^ "/auth/" ^ provider.name ^ "/callback" in
      match exchange_code provider ~code:received_code
              ~code_verifier:verifier ~redirect_uri with
      | Error msg ->
        !_log_ref (Printf.sprintf "[OAuth] Token exchange error: %s" msg);
        !_put_flash_ref req "error" "Authentication failed";
        ORedirect "/login"
      | Ok access_token ->
        match fetch_userinfo provider ~access_token with
        | Error msg ->
          !_log_ref (Printf.sprintf "[OAuth] Userinfo error: %s" msg);
          !_put_flash_ref req "error" "Failed to get user info";
          ORedirect "/login"
        | Ok provider_user ->
          if provider_user.uid = "" then begin
            !_log_ref "[OAuth] Empty UID from provider";
            !_put_flash_ref req "error" "Authentication failed";
            ORedirect "/login"
          end else
          match link_or_create_user provider_user ~provider_name:provider.name with
          | Error msg ->
            !_log_ref (Printf.sprintf "[OAuth] Account linking error: %s" msg);
            !_put_flash_ref req "error" "Account creation failed";
            ORedirect "/login"
          | Ok user ->
            !_session_set_ref sid "user_id" (string_of_int user.id);
            !_session_set_ref sid "user_name" user.email;
            ORedirectWithRegenerate return_to
    end
  | _ ->
    !_log_ref "[OAuth] Missing state/verifier in session";
    !_put_flash_ref req "error" "Login session expired";
    ORedirect "/login")

(* ── Public API ─────────────────────────────────────────────────── *)

(** Set up OAuth routes for the given providers. Registers [/auth/:provider] and callback routes. *)
let setup ~base_url providers =
  _base_url := base_url;
  _providers := providers;
  ensure_table ();
  List.iter (fun (provider : provider_config) ->
    !_handle_get_ref ("/auth/" ^ provider.name) (authorize_handler provider);
    !_handle_get_ref ("/auth/" ^ provider.name ^ "/callback")
      (callback_handler provider);
  ) providers

(** Return the names of all configured OAuth providers. *)
let configured_providers () =
  List.map (fun (p : provider_config) -> p.name) !_providers
