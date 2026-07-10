[@@@warning "-8"]

let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then incr pass
  else begin
    incr fail;
    Printf.eprintf "FAIL: %s\n%!" name
  end

let html_str (`Html v : unit Html.node) = Html.element_to_string (`Html v)

(* Simple session store for testing *)
let _sessions : (string, (string, string) Hashtbl.t) Hashtbl.t = Hashtbl.create 16

let session_get sid key =
  match Hashtbl.find_opt _sessions sid with
  | None -> None
  | Some tbl -> Hashtbl.find_opt tbl key

let session_set sid key value =
  let tbl = match Hashtbl.find_opt _sessions sid with
    | Some t -> t
    | None -> let t = Hashtbl.create 8 in Hashtbl.replace _sessions sid t; t
  in
  Hashtbl.replace tbl key value

let session_delete sid key =
  match Hashtbl.find_opt _sessions sid with
  | None -> ()
  | Some tbl -> Hashtbl.remove tbl key

let session_clear sid =
  Hashtbl.remove _sessions sid

let make_req ?(meth="GET") ?(path="/") ?(body="") ?(query=[]) ?(session_id="test-session") () : Well.request =
  { meth; path; headers = []; body; params = []; query; session_id; _context = [] }

let () =
  Mirage_crypto_rng_unix.use_default ();

  (* Wire forward refs for testing *)
  Well.OAuthProvider._session_get_ref := session_get;
  Well.OAuthProvider._session_set_ref := session_set;
  Well.OAuthProvider._session_delete_ref := session_delete;
  Well.OAuthProvider._session_clear_ref := session_clear;
  Well.OAuthProvider._login_ref := Well.Auth.login;
  Well.OAuthProvider._current_user_ref := (fun req ->
    session_get req.session_id "user_id");
  Well.OAuthProvider._log_ref := (fun msg -> Printf.eprintf "LOG: %s\n%!" msg);

  (* Track registered routes for testing *)
  let get_handlers : (string, Well.request -> Well.response) Hashtbl.t = Hashtbl.create 4 in
  let post_handlers : (string, Well.request -> Well.response) Hashtbl.t = Hashtbl.create 4 in
  Well.OAuthProvider._register_get_ref := (fun path handler ->
    Hashtbl.replace get_handlers path handler);
  Well.OAuthProvider._register_post_ref := (fun path handler ->
    Hashtbl.replace post_handlers path handler);

  (* Register a test user *)
  let _user = Result.get_ok (Well.Auth.register ~email:"admin@test.com" ~password:"secret123" ()) in

  (* ── Setup ────────────────────────────────────────────────────── *)

  Well.OAuthProvider.setup [
    { client_id = "operations"; redirect_uris = ["http://localhost/"]; name = "Operations" };
    { client_id = "planner"; redirect_uris = ["http://localhost/planner/"; "https://app.example.com/planner/"]; name = "Planner" };
  ];

  check "routes registered: GET /oauth/authorize" (Hashtbl.mem get_handlers "/oauth/authorize");
  check "routes registered: POST /oauth/authorize" (Hashtbl.mem post_handlers "/oauth/authorize");
  check "routes registered: POST /oauth/token" (Hashtbl.mem post_handlers "/oauth/token");
  check "routes registered: GET /oauth/logout" (Hashtbl.mem get_handlers "/oauth/logout");

  let handle_get path req = (Hashtbl.find get_handlers path) req in
  let handle_post path req = (Hashtbl.find post_handlers path) req in

  (* ── GET /oauth/authorize — unknown client ───────────────────── *)

  let req = make_req ~query:[
    ("client_id", "unknown"); ("redirect_uri", "http://localhost/");
    ("response_type", "code"); ("state", "abc")
  ] () in
  (match handle_get "/oauth/authorize" req with
   | `Html v -> let body = html_str (`Html v) in
     check "unknown client shows error" (let r = Str.regexp_string "Nieprawidłowy client_id" in
       try ignore (Str.search_forward r body 0); true with Not_found -> false)
   | `Redirect _ -> check "unknown client should not redirect" false);

  (* ── GET /oauth/authorize — invalid redirect_uri ──────────────── *)

  let req = make_req ~query:[
    ("client_id", "operations"); ("redirect_uri", "http://evil.com/");
    ("response_type", "code"); ("state", "abc")
  ] () in
  (match handle_get "/oauth/authorize" req with
   | `Html v -> let body = html_str (`Html v) in
     check "invalid redirect shows error" (let r = Str.regexp_string "Nieprawidłowy redirect_uri" in
       try ignore (Str.search_forward r body 0); true with Not_found -> false)
   | `Redirect _ -> check "invalid redirect should not redirect" false);

  (* ── GET /oauth/authorize — wrong response_type ──────────────── *)

  let req = make_req ~query:[
    ("client_id", "operations"); ("redirect_uri", "http://localhost/");
    ("response_type", "token"); ("state", "abc")
  ] () in
  (match handle_get "/oauth/authorize" req with
   | `Html v -> let body = html_str (`Html v) in
     check "wrong response_type shows error" (let r = Str.regexp_string "response_type" in
       try ignore (Str.search_forward r body 0); true with Not_found -> false)
   | `Redirect _ -> check "wrong response_type should not redirect" false);

  (* ── GET /oauth/authorize — not logged in → login form ────────── *)

  let req = make_req ~query:[
    ("client_id", "operations"); ("redirect_uri", "http://localhost/");
    ("response_type", "code"); ("state", "mystate")
  ] () in
  (match handle_get "/oauth/authorize" req with
   | `Html v -> let body = html_str (`Html v) in
     check "login form contains email field" (let r = Str.regexp_string "name=\"email\"" in
       try ignore (Str.search_forward r body 0); true with Not_found -> false);
     check "login form contains password field" (let r = Str.regexp_string "name=\"password\"" in
       try ignore (Str.search_forward r body 0); true with Not_found -> false);
     check "login form contains hidden client_id" (let r = Str.regexp_string "value=\"operations\"" in
       try ignore (Str.search_forward r body 0); true with Not_found -> false);
     check "login form contains hidden state" (let r = Str.regexp_string "value=\"mystate\"" in
       try ignore (Str.search_forward r body 0); true with Not_found -> false)
   | `Redirect _ -> check "not logged in should show form" false);

  (* ── GET /oauth/authorize — already logged in → redirect with code *)

  let sid = "logged-in-session" in
  session_set sid "user_id" (string_of_int _user.id);
  let req = make_req ~session_id:sid ~query:[
    ("client_id", "operations"); ("redirect_uri", "http://localhost/");
    ("response_type", "code"); ("state", "mystate")
  ] () in
  (match handle_get "/oauth/authorize" req with
   | `Redirect url ->
     check "redirect starts with redirect_uri" (String.length url > 20 &&
       String.sub url 0 21 = "http://localhost/?cod");
     check "redirect contains state" (let r = Str.regexp_string "state=mystate" in
       try ignore (Str.search_forward r url 0); true with Not_found -> false)
   | `Html _ -> check "logged in should redirect" false);

  (* ── POST /oauth/authorize — login form submission ────────────── *)

  let req = make_req ~meth:"POST" ~session_id:"fresh-session"
    ~body:"client_id=operations&redirect_uri=http%3A%2F%2Flocalhost%2F&state=s1&email=admin%40test.com&password=secret123" () in
  (match handle_post "/oauth/authorize" req with
   | `Redirect url ->
     check "POST login redirects with code" (let r = Str.regexp_string "code=" in
       try ignore (Str.search_forward r url 0); true with Not_found -> false);
     check "POST login includes state" (let r = Str.regexp_string "state=s1" in
       try ignore (Str.search_forward r url 0); true with Not_found -> false);
     (* Extract code for token exchange test *)
     let code_start = try ignore (Str.search_forward (Str.regexp "code=\\([^&]*\\)") url 0); Str.matched_group 1 url with Not_found -> "" in
     check "code is non-empty" (String.length code_start > 0);

     (* ── POST /oauth/token — exchange code for session ─────────── *)

     let token_req = make_req ~meth:"POST" ~session_id:"token-client"
       ~body:(Printf.sprintf "grant_type=authorization_code&code=%s&client_id=operations&redirect_uri=http%%3A%%2F%%2Flocalhost%%2F" code_start) () in
     (match handle_post "/oauth/token" token_req with
      | `Assoc pairs ->
        check "token response has session_id" (List.assoc_opt "session_id" pairs <> None);
        check "token response has user_id" (List.assoc_opt "user_id" pairs <> None);
        check "token response has token_type" (List.assoc_opt "token_type" pairs = Some (`String "bearer"));
        (* session_id should be the one from the authorize step *)
        (match List.assoc_opt "session_id" pairs with
         | Some (`String sid) ->
           check "token session_id is fresh-session" (sid = "fresh-session")
         | _ -> check "token session_id is string" false)
      | _ -> check "token response should be JSON object" false);

     (* ── POST /oauth/token — code reuse (single-use) ───────────── *)

     let reuse_req = make_req ~meth:"POST" ~session_id:"reuse-client"
       ~body:(Printf.sprintf "grant_type=authorization_code&code=%s&client_id=operations&redirect_uri=http%%3A%%2F%%2Flocalhost%%2F" code_start) () in
     (match handle_post "/oauth/token" reuse_req with
      | `Assoc pairs ->
        check "reused code fails" (List.assoc_opt "error" pairs = Some (`String "invalid_grant"))
      | _ -> check "reused code response should be JSON" false)

   | `Html _ -> check "POST login should redirect on success" false
   | _ -> check "POST login unexpected response" false);

  (* ── POST /oauth/authorize — wrong password ───────────────────── *)

  let req = make_req ~meth:"POST" ~session_id:"fail-session"
    ~body:"client_id=operations&redirect_uri=http%3A%2F%2Flocalhost%2F&state=s2&email=admin%40test.com&password=wrongpass" () in
  (match handle_post "/oauth/authorize" req with
   | `Html v -> let body = html_str (`Html v) in
     check "wrong password shows error" (let r = Str.regexp_string "Nieprawidłowy email lub hasło" in
       try ignore (Str.search_forward r body 0); true with Not_found -> false)
   | _ -> check "wrong password should show form" false);

  (* ── POST /oauth/token — wrong grant_type ─────────────────────── *)

  let req = make_req ~meth:"POST"
    ~body:"grant_type=password&code=abc&client_id=operations" () in
  (match handle_post "/oauth/token" req with
   | `Assoc pairs ->
     check "wrong grant_type error" (List.assoc_opt "error" pairs = Some (`String "unsupported_grant_type"))
   | _ -> check "wrong grant_type response should be JSON" false);

  (* ── POST /oauth/token — unknown client ───────────────────────── *)

  let req = make_req ~meth:"POST"
    ~body:"grant_type=authorization_code&code=abc&client_id=unknown&redirect_uri=http%3A%2F%2Flocalhost%2F" () in
  (match handle_post "/oauth/token" req with
   | `Assoc pairs ->
     check "unknown client error" (List.assoc_opt "error" pairs = Some (`String "invalid_client"))
   | _ -> check "unknown client response should be JSON" false);

  (* ── GET /oauth/logout ───────────────────────────────────────── *)

  let logout_sid = "logout-session" in
  session_set logout_sid "user_id" "42";
  session_set logout_sid "user_name" "admin@test.com";
  let req = make_req ~session_id:logout_sid ~query:[
    ("redirect_uri", "http://localhost/bye")
  ] () in
  (match handle_get "/oauth/logout" req with
   | `Redirect url ->
     check "logout redirects to redirect_uri" (url = "http://localhost/bye");
     check "logout clears session" (session_get logout_sid "user_id" = None)
   | `Html _ -> check "logout should redirect" false);

  (* ── GET /oauth/logout — no redirect_uri defaults to / ────────── *)

  let req = make_req ~session_id:"logout2" ~query:[] () in
  (match handle_get "/oauth/logout" req with
   | `Redirect url -> check "logout default redirect to /" (url = "/")
   | `Html _ -> check "logout default should redirect" false);

  (* ── Client validation ────────────────────────────────────────── *)

  check "find_client operations" (Well.OAuthProvider.find_client "operations" <> None);
  check "find_client unknown" (Well.OAuthProvider.find_client "nonexistent" = None);

  (* ── Summary ──────────────────────────────────────────────────── *)

  Printf.printf "\nOAuth Provider tests: %d passed, %d failed\n%!" !pass !fail;
  if !fail > 0 then exit 1
