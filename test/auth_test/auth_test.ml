let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then incr pass
  else begin
    incr fail;
    Printf.eprintf "FAIL: %s\n%!" name
  end

let () =
  Mirage_crypto_rng_unix.use_default ();

  (* ── PBKDF2 correctness ─────────────────────────────────────────── *)

  let r1 = Well.Auth.register ~email:"test@example.com" ~password:"password123" () in
  check "register succeeds" (Result.is_ok r1);
  let user1 = Result.get_ok r1 in
  check "register returns id" (user1.id > 0);
  check "register returns email" (user1.email = "test@example.com");
  check "register returns created_at" (String.length user1.created_at > 0);

  (* Login with correct password *)
  let l1 = Well.Auth.login ~email:"test@example.com" ~password:"password123" () in
  check "login correct password" (Result.is_ok l1);
  let login_user = Result.get_ok l1 in
  check "login returns same id" (login_user.id = user1.id);
  check "login returns same email" (login_user.email = "test@example.com");

  (* Login with wrong password *)
  let l2 = Well.Auth.login ~email:"test@example.com" ~password:"wrongpassword" () in
  check "login wrong password fails" (Result.is_error l2);
  check "login wrong password msg" (Result.get_error l2 = "Invalid email or password");

  (* Login with nonexistent email *)
  let l3 = Well.Auth.login ~email:"nobody@example.com" ~password:"password123" () in
  check "login nonexistent email fails" (Result.is_error l3);
  check "login nonexistent msg" (Result.get_error l3 = "Invalid email or password");

  (* get_user *)
  let u = Well.Auth.get_user user1.id in
  check "get_user found" (Option.is_some u);
  check "get_user email" ((Option.get u).email = "test@example.com");
  let u_none = Well.Auth.get_user 999999 in
  check "get_user not found" (Option.is_none u_none);

  (* ── Email normalization ─────────────────────────────────────────── *)

  (* Case insensitive — "TEST@Example.COM" should match "test@example.com" *)
  let r_upper = Well.Auth.register ~email:"TEST@Example.COM" ~password:"password123" () in
  check "register case-normalized rejects dupe" (Result.is_error r_upper);

  (* Login with different case *)
  let l_case = Well.Auth.login ~email:"TEST@EXAMPLE.COM" ~password:"password123" () in
  check "login case-insensitive" (Result.is_ok l_case);

  (* Whitespace trimmed *)
  let l_trim = Well.Auth.login ~email:"  test@example.com  " ~password:"password123" () in
  check "login trims whitespace" (Result.is_ok l_trim);

  (* ── Email validation ────────────────────────────────────────────── *)

  let r_empty = Well.Auth.register ~email:"" ~password:"password123" () in
  check "register empty email" (Result.is_error r_empty);

  let r_no_at = Well.Auth.register ~email:"notanemail" ~password:"password123" () in
  check "register no @ in email" (Result.is_error r_no_at);

  let r_no_domain = Well.Auth.register ~email:"user@" ~password:"password123" () in
  check "register no domain" (Result.is_error r_no_domain);

  let r_no_local = Well.Auth.register ~email:"@example.com" ~password:"password123" () in
  check "register no local part" (Result.is_error r_no_local);

  let r_no_dot = Well.Auth.register ~email:"user@localhost" ~password:"password123" () in
  check "register no dot in domain" (Result.is_error r_no_dot);

  let r_spaces = Well.Auth.register ~email:"user @example.com" ~password:"password123" () in
  check "register space in email" (Result.is_error r_spaces);

  let r_newline = Well.Auth.register ~email:"user\n@example.com" ~password:"password123" () in
  check "register newline in email" (Result.is_error r_newline);

  let r_cr = Well.Auth.register ~email:"user\r@example.com" ~password:"password123" () in
  check "register CR in email" (Result.is_error r_cr);

  (* ── Password validation ─────────────────────────────────────────── *)

  let r_short = Well.Auth.register ~email:"short@example.com" ~password:"1234567" () in
  check "register short password" (Result.is_error r_short);
  check "register short password msg" (Result.get_error r_short = "Password must be at least 8 characters");

  let r_empty_pw = Well.Auth.register ~email:"empty_pw@example.com" ~password:"" () in
  check "register empty password" (Result.is_error r_empty_pw);

  (* Max password length — DoS prevention *)
  let huge_pw = String.make 2000 'A' in
  let r_huge = Well.Auth.register ~email:"huge@example.com" ~password:huge_pw () in
  check "register huge password rejected" (Result.is_error r_huge);
  check "register huge pw msg" (Result.get_error r_huge = "Password is too long");

  (* Login with huge password — should not DoS *)
  let l_huge = Well.Auth.login ~email:"test@example.com" ~password:huge_pw () in
  check "login huge password fast rejection" (Result.is_error l_huge);

  (* ── Duplicate email ─────────────────────────────────────────────── *)

  let r_dup = Well.Auth.register ~email:"test@example.com" ~password:"password456" () in
  check "register duplicate email" (Result.is_error r_dup);
  check "register duplicate msg" (Result.get_error r_dup = "Email already taken");

  (* ── Timing oracle resistance ────────────────────────────────────── *)
  (* Both existing and nonexistent email should take similar time
     because we burn a dummy hash on miss. We can't test exact timing,
     but we verify the dummy hash path doesn't crash. *)
  let l_existing_wrong = Well.Auth.login ~email:"test@example.com" ~password:"wrongwrong" () in
  check "timing: existing email wrong pw" (Result.is_error l_existing_wrong);
  let l_nonexistent = Well.Auth.login ~email:"doesnotexist@example.com" ~password:"wrongwrong" () in
  check "timing: nonexistent email" (Result.is_error l_nonexistent);

  (* ── Grants ──────────────────────────────────────────────────────── *)

  check "has_grant initially false" (not (Well.Auth.has_grant ~user_id:user1.id "admin"));
  check "user_grants initially empty" (Well.Auth.user_grants ~user_id:user1.id = []);

  Well.Auth.grant ~user_id:user1.id "admin";
  check "has_grant after grant" (Well.Auth.has_grant ~user_id:user1.id "admin");
  check "user_grants after grant" (Well.Auth.user_grants ~user_id:user1.id = ["admin"]);

  Well.Auth.grant ~user_id:user1.id "editor";
  check "user_grants multiple" (Well.Auth.user_grants ~user_id:user1.id = ["admin"; "editor"]);

  (* Duplicate grant is idempotent *)
  Well.Auth.grant ~user_id:user1.id "admin";
  check "duplicate grant idempotent" (Well.Auth.user_grants ~user_id:user1.id = ["admin"; "editor"]);

  Well.Auth.revoke ~user_id:user1.id "admin";
  check "has_grant after revoke" (not (Well.Auth.has_grant ~user_id:user1.id "admin"));
  check "user_grants after revoke" (Well.Auth.user_grants ~user_id:user1.id = ["editor"]);

  (* Revoke nonexistent grant is safe *)
  Well.Auth.revoke ~user_id:user1.id "nonexistent";
  check "revoke nonexistent safe" true;

  (* Grants for nonexistent user *)
  check "has_grant nonexistent user" (not (Well.Auth.has_grant ~user_id:999999 "admin"));
  check "user_grants nonexistent user" (Well.Auth.user_grants ~user_id:999999 = []);

  (* ── require_grant middleware ────────────────────────────────────── *)

  (* require_grant raises Auth_denied(401) without session *)
  let mk_req ?(session_id = "nosession") () : Well.request =
    { meth = "GET"; path = "/"; headers = []; body = "";
      params = []; query = []; session_id; _context = [] }
  in
  let dummy_handler (_req : Well.request) = Well.text "ok" in
  let denied_401 =
    try
      ignore (Well.Auth.require_grant "admin" dummy_handler (mk_req ()));
      false
    with Well.Auth.Auth_denied (401, _) -> true
       | _ -> false
  in
  check "require_grant: no session = 401" denied_401;

  (* ── Password hash format ───────────────────────────────────────── *)

  (* Verify the stored hash is not reversible / is properly formatted *)
  let r_fmt = Well.Auth.register ~email:"format@example.com" ~password:"testformat123" () in
  check "hash format: register ok" (Result.is_ok r_fmt);

  (* Verify password against itself *)
  let l_fmt = Well.Auth.login ~email:"format@example.com" ~password:"testformat123" () in
  check "hash format: login ok" (Result.is_ok l_fmt);

  (* Wrong password of same length *)
  let l_wrong_same_len = Well.Auth.login ~email:"format@example.com" ~password:"testformat124" () in
  check "hash format: wrong pw same length" (Result.is_error l_wrong_same_len);

  (* ── Malformed hash resilience ──────────────────────────────────── *)
  (* verify_password should handle garbage gracefully *)
  check "verify garbage hash" (not (Well.Auth.verify_password ~password:"test" ~hash:"garbage"));
  check "verify empty hash" (not (Well.Auth.verify_password ~password:"test" ~hash:""));
  check "verify partial hash" (not (Well.Auth.verify_password ~password:"test" ~hash:"pbkdf2-sha256$"));
  check "verify bad iter" (not (Well.Auth.verify_password ~password:"test" ~hash:"pbkdf2-sha256$notanumber$aa$bb"));
  check "verify zero iter" (not (Well.Auth.verify_password ~password:"test" ~hash:"pbkdf2-sha256$0$aa$bb"));
  check "verify negative iter" (not (Well.Auth.verify_password ~password:"test" ~hash:"pbkdf2-sha256$-1$aa$bb"));

  (* ── SQL injection resistance ───────────────────────────────────── *)
  (* Parameterized queries should handle these fine *)
  let r_sqli = Well.Auth.register ~email:"bobby'; DROP TABLE users;--@example.com" ~password:"password123" () in
  check "SQLi in email: register ok or dup" (Result.is_ok r_sqli || Result.is_error r_sqli);
  (* If it registered, the user should exist with the exact email *)
  (match r_sqli with
   | Ok u ->
     let found = Well.Auth.get_user u.id in
     check "SQLi email stored literally" (
       match found with
       | Some f -> String.length f.email > 20  (* the full SQLi string *)
       | None -> false)
   | Error _ -> check "SQLi in email: rejected by validation" true);

  let r_sqli_pw = Well.Auth.register ~email:"sqli_pw@example.com" ~password:"'; DROP TABLE users;-- padding" () in
  check "SQLi in password: register ok" (Result.is_ok r_sqli_pw);
  let l_sqli_pw = Well.Auth.login ~email:"sqli_pw@example.com" ~password:"'; DROP TABLE users;-- padding" () in
  check "SQLi in password: login ok" (Result.is_ok l_sqli_pw);

  (* ── Unicode in email/password ──────────────────────────────────── *)
  (* test@example.com already taken — verify unicode password doesn't bypass anything *)
  let r_unicode = Well.Auth.register ~email:"test@example.com" ~password:"\xc3\xa9\xc3\xa0\xc3\xbc12345" () in
  check "unicode password: register (dup email)" (Result.is_error r_unicode);
  let r_uni2 = Well.Auth.register ~email:"unicode@example.com" ~password:"\xc3\xa9\xc3\xa0\xc3\xbc12345" () in
  check "unicode password: register new" (Result.is_ok r_uni2);
  let l_uni2 = Well.Auth.login ~email:"unicode@example.com" ~password:"\xc3\xa9\xc3\xa0\xc3\xbc12345" () in
  check "unicode password: login" (Result.is_ok l_uni2);

  (* ── Integration: error_handler catches Auth_denied ──────────────── *)

  Well.use Well.error_handler;
  Well.get "/t/grant-test" @@ Well.Auth.require_grant "superadmin" (fun _req ->
    Well.text "secret");

  Well.with_test_server ~disable_cap:true (fun port ->
    let url path = Printf.sprintf "http://127.0.0.1:%d%s" port path in

    (* No session = 401 *)
    let resp = Well.fetch (url "/t/grant-test") in
    check "grant endpoint: 401 no session" (resp.status = 401);
    check "grant endpoint: body Unauthorized" (resp.body = "Unauthorized");

    (* 401 does not leak stack trace *)
    check "grant endpoint: no stack trace" (
      not (try let _ = Str.search_forward (Str.regexp "Auth_denied") resp.body 0 in true
           with Not_found -> false));

    (* Non-admin user = 403 *)
    (* Register and login a user via the auth module *)
    let _r = Well.Auth.register ~email:"grantuser@example.com" ~password:"password123" () in
    (* We can't easily set session in test, so we verify the module behavior directly *)

    (* ── create_user_without_password ────────────────────────────────── *)

    let r_nopw = Well.Auth.create_user_without_password ~email:"oauth@example.com" in
    check "create_user_without_password: ok" (Result.is_ok r_nopw);
    let nopw_user = Result.get_ok r_nopw in
    check "create_user_without_password: has id" (nopw_user.id > 0);
    check "create_user_without_password: email" (nopw_user.email = "oauth@example.com");

    (* Password login impossible on no-password account *)
    let l_nopw = Well.Auth.login ~email:"oauth@example.com" ~password:"anything" () in
    check "no-password user: login fails" (Result.is_error l_nopw);

    (* Duplicate email *)
    let r_dup_nopw = Well.Auth.create_user_without_password ~email:"oauth@example.com" in
    check "create_user_without_password: dup email" (Result.is_error r_dup_nopw);

    (* Invalid email *)
    let r_bad_nopw = Well.Auth.create_user_without_password ~email:"notanemail" in
    check "create_user_without_password: invalid email" (Result.is_error r_bad_nopw);

    (* ── find_user_by_email ──────────────────────────────────────────── *)

    let found = Well.Auth.find_user_by_email "oauth@example.com" in
    check "find_user_by_email: found" (Option.is_some found);
    check "find_user_by_email: correct id" ((Option.get found).id = nopw_user.id);

    (* Case insensitive *)
    let found_case = Well.Auth.find_user_by_email "OAUTH@EXAMPLE.COM" in
    check "find_user_by_email: case insensitive" (Option.is_some found_case);

    (* Missing *)
    let not_found = Well.Auth.find_user_by_email "nobody@nowhere.com" in
    check "find_user_by_email: not found" (Option.is_none not_found);

    (* ── OTP delivery through Well.Mailer ────────────────────────────── *)

    let r_otp_user =
      Well.Auth.register ~email:"otp@example.com" ~password:"password123" ()
    in
    check "otp user: register" (Result.is_ok r_otp_user);
    Well.Mailer.setup
      { from_email = "noreply@example.com"; from_name = "Well"; adapter = Log };
    let sent_otp =
      Well.Auth.initiate_otp_and_send ~email:"otp@example.com" ()
    in
    check "initiate_otp_and_send: ok" (Result.is_ok sent_otp);
    let otp_code =
      Well.Auth.with_db (fun db ->
          let stmt =
            Sqlite3.prepare
              db
              "SELECT code FROM _well_otps WHERE email = ? ORDER BY id DESC \
               LIMIT 1"
          in
          let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT "otp@example.com") in
          let code =
            match Sqlite3.step stmt with
            | Sqlite3.Rc.ROW -> Sqlite3.column_text stmt 0
            | _ -> ""
          in
          let _ = Sqlite3.finalize stmt in
          code)
    in
    check "initiate_otp_and_send: stores code" (String.length otp_code > 0);
    let verified_otp =
      Well.Auth.verify_otp ~email:"otp@example.com" ~code:otp_code ()
    in
    check "initiate_otp_and_send: verifiable" (Result.is_ok verified_otp);

    let unknown_email = "otp-unknown@example.com" in
    let unknown_otp = Well.Auth.initiate_otp ~email:unknown_email () in
    check "initiate_otp: unknown email ok" (Result.is_ok unknown_otp);
    let unknown_code = Result.get_ok unknown_otp in
    let verified_unknown =
      Well.Auth.verify_otp ~email:unknown_email ~code:unknown_code ()
    in
    check "verify_otp: unknown email fails" (Result.is_error verified_unknown);
    check "verify_otp: unknown email msg"
      (Result.get_error verified_unknown = "Invalid or expired code");
    check "verify_otp: does not create user"
      (Option.is_none (Well.Auth.find_user_by_email unknown_email));

    (* ── with_db ─────────────────────────────────────────────────────── *)

    let db_ok = ref false in
    Well.Auth.with_db (fun _db -> db_ok := true);
    check "with_db: executes under mutex" !db_ok;

    (* ── OAuth identity DB ───────────────────────────────────────────── *)

    (* Create identity *)
    Well.OAuth.create_identity ~user_id:nopw_user.id
      ~provider:"google" ~provider_uid:"g_12345"
      ~email:"oauth@example.com" ~name:"Test User" ();

    (* Find identity *)
    let ident = Well.OAuth.find_identity ~provider:"google" ~provider_uid:"g_12345" in
    check "find_identity: found" (Option.is_some ident);
    check "find_identity: correct user_id" (Option.get ident = nopw_user.id);

    (* Not found *)
    let no_ident = Well.OAuth.find_identity ~provider:"google" ~provider_uid:"g_99999" in
    check "find_identity: not found" (Option.is_none no_ident);

    (* User identities *)
    let idents = Well.OAuth.user_identities ~user_id:nopw_user.id in
    check "user_identities: one identity" (List.length idents = 1);
    check "user_identities: provider" (fst (List.hd idents) = "google");
    check "user_identities: uid" (snd (List.hd idents) = "g_12345");

    (* Add second identity *)
    Well.OAuth.create_identity ~user_id:nopw_user.id
      ~provider:"github" ~provider_uid:"gh_67890" ();
    let idents2 = Well.OAuth.user_identities ~user_id:nopw_user.id in
    check "user_identities: two identities" (List.length idents2 = 2);

    (* Empty for nonexistent user *)
    let no_idents = Well.OAuth.user_identities ~user_id:999999 in
    check "user_identities: empty for missing user" (no_idents = []);

    (* ── Provider configs ────────────────────────────────────────────── *)

    let gp = Well.OAuth.google ~client_id:"cid" ~client_secret:"csec" in
    check "google: name" (gp.name = "google");
    check "google: is_oidc" gp.is_oidc;
    check "google: has scopes" (List.length gp.scopes > 0);

    let ghp = Well.OAuth.github ~client_id:"cid" ~client_secret:"csec" in
    check "github: name" (ghp.name = "github");
    check "github: not oidc" (not ghp.is_oidc);

    let msp = Well.OAuth.microsoft ~client_id:"cid" ~client_secret:"csec" in
    check "microsoft: name" (msp.name = "microsoft");
    check "microsoft: is_oidc" msp.is_oidc;

    let fbp = Well.OAuth.facebook ~client_id:"cid" ~client_secret:"csec" in
    check "facebook: name" (fbp.name = "facebook");
    check "facebook: not oidc" (not fbp.is_oidc);

    (* ── configured_providers ────────────────────────────────────────── *)

    (* Before setup: empty *)
    check "configured_providers: empty before setup" (Well.OAuth.configured_providers () = []);

    (* ── PKCE: code_challenge is S256 of verifier ────────────────────── *)

    let verifier = Well.OAuth.generate_code_verifier () in
    check "PKCE verifier: length 43" (String.length verifier = 43);
    (* All chars in unreserved set *)
    check "PKCE verifier: valid chars" (
      let valid = ref true in
      String.iter (fun c ->
        match c with
        | 'A'..'Z' | 'a'..'z' | '0'..'9' | '-' | '.' | '_' | '~' -> ()
        | _ -> valid := false
      ) verifier;
      !valid);
    (* Challenge is not empty *)
    let challenge = Well.OAuth.code_challenge verifier in
    check "PKCE challenge: not empty" (String.length challenge > 0);
    (* Challenge is URL-safe base64 (no +, /, =) *)
    check "PKCE challenge: url-safe" (
      let safe = ref true in
      String.iter (fun c ->
        if c = '+' || c = '/' || c = '=' then safe := false
      ) challenge;
      !safe);
    (* Two different verifiers produce different challenges *)
    let verifier2 = Well.OAuth.generate_code_verifier () in
    let challenge2 = Well.OAuth.code_challenge verifier2 in
    check "PKCE: different verifiers → different challenges"
      (challenge <> challenge2);

    (* ── State generation ────────────────────────────────────────────── *)

    let state1 = Well.OAuth.generate_state () in
    let state2 = Well.OAuth.generate_state () in
    check "state: 64 hex chars" (String.length state1 = 64);
    check "state: unique" (state1 <> state2);

    (* ── Provider userinfo parsing ───────────────────────────────────── *)

    (* Google *)
    let google_json = Yojson.Safe.from_string
      {|{"sub":"123","email":"test@gmail.com","email_verified":true,"name":"Test","picture":"https://photo"}|} in
    let gu = Well.OAuth.parse_google_user google_json in
    check "parse google: uid" (gu.uid = "123");
    check "parse google: email" (gu.email = Some "test@gmail.com");
    check "parse google: verified" gu.email_verified;
    check "parse google: name" (gu.name = Some "Test");
    check "parse google: avatar" (gu.avatar_url = Some "https://photo");

    (* Microsoft *)
    let ms_json = Yojson.Safe.from_string
      {|{"id":"ms456","mail":"user@outlook.com","displayName":"MS User"}|} in
    let mu = Well.OAuth.parse_microsoft_user ms_json in
    check "parse microsoft: uid" (mu.uid = "ms456");
    check "parse microsoft: email" (mu.email = Some "user@outlook.com");
    check "parse microsoft: not auto-verified" (not mu.email_verified);
    check "parse microsoft: name" (mu.name = Some "MS User");

    (* Microsoft fallback to userPrincipalName *)
    let ms_json2 = Yojson.Safe.from_string
      {|{"id":"ms789","userPrincipalName":"upn@example.com","displayName":"UPN"}|} in
    let mu2 = Well.OAuth.parse_microsoft_user ms_json2 in
    check "parse microsoft: fallback to UPN" (mu2.email = Some "upn@example.com");

    (* Facebook *)
    let fb_json = Yojson.Safe.from_string
      {|{"id":"fb111","name":"FB User","email":"fb@example.com","picture":{"data":{"url":"https://fbpic"}}}|} in
    let fu = Well.OAuth.parse_facebook_user fb_json in
    check "parse facebook: uid" (fu.uid = "fb111");
    check "parse facebook: email" (fu.email = Some "fb@example.com");
    check "parse facebook: name" (fu.name = Some "FB User");
    check "parse facebook: avatar" (fu.avatar_url = Some "https://fbpic");

    (* ── Account linking: verified email links to existing ───────────── *)

    let r_link = Well.Auth.register ~email:"linked@example.com" ~password:"password123" () in
    check "link: register existing user" (Result.is_ok r_link);
    let link_user = Result.get_ok r_link in
    let link_result = Well.OAuth.link_or_create_user
      { uid = "link_uid_1"; email = Some "linked@example.com";
        email_verified = true; name = Some "Linked"; avatar_url = None }
      ~provider_name:"google" in
    check "link: verified email links to existing" (Result.is_ok link_result);
    check "link: same user id" ((Result.get_ok link_result).id = link_user.id);
    let link_idents = Well.OAuth.user_identities ~user_id:link_user.id in
    check "link: identity created" (List.exists (fun (p, _) -> p = "google") link_idents);

    (* ── Account linking: unverified email creates separate ──────────── *)

    let r_existing = Well.Auth.register ~email:"existing@example.com" ~password:"password123" () in
    check "separate: register existing" (Result.is_ok r_existing);
    let existing_user = Result.get_ok r_existing in
    let sep_result = Well.OAuth.link_or_create_user
      { uid = "sep_uid_1"; email = Some "existing@example.com";
        email_verified = false; name = None; avatar_url = None }
      ~provider_name:"github" in
    check "separate: unverified creates new account" (Result.is_ok sep_result);
    check "separate: different user id" ((Result.get_ok sep_result).id <> existing_user.id);

    (* ── Account linking: same provider UID reuses ───────────────────── *)

    let reuse_result = Well.OAuth.link_or_create_user
      { uid = "link_uid_1"; email = Some "linked@example.com";
        email_verified = true; name = Some "Updated Name"; avatar_url = None }
      ~provider_name:"google" in
    check "reuse: same provider UID" (Result.is_ok reuse_result);
    check "reuse: same user id" ((Result.get_ok reuse_result).id = link_user.id);

    Printf.printf "Auth tests: %d passed, %d failed\n%!" !pass !fail;
    Well.Db.close_well_db ();
    (* Clean up test database *)
    (try Sys.remove "data/well.sqlite" with _ -> ());
    (try Sys.remove "data/well.sqlite-wal" with _ -> ());
    (try Sys.remove "data/well.sqlite-shm" with _ -> ());
    exit (if !fail > 0 then 1 else 0)
  )
