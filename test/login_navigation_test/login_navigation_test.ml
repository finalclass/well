let checks = ref 0

let check name condition =
  incr checks ;
  if not condition then failwith name

let request
    ?(meth = "GET")
    ?(path = "/operations")
    ?(headers = [])
    ?(query = [])
    ?(session_id = "anonymous")
    () : Well.request =
  {meth; path; headers; body= ""; params= []; query; session_id; _context= []}

let utf8 code =
  let buffer = Buffer.create 4 in
  Buffer.add_utf_8_uchar buffer (Uchar.of_int code) ;
  Buffer.contents buffer

let whitespace =
  [0x09; 0x0a; 0x0b; 0x0c; 0x0d; 0x20; 0x85; 0xa0; 0x1680]
  @ List.init 11 (fun index -> 0x2000 + index)
  @ [0x2028; 0x2029; 0x202f; 0x205f; 0x3000]

let controls = List.init 32 Fun.id @ List.init 33 (fun index -> 0x7f + index)

let safe_targets =
  [ "/"
  ; "/operations?filter=a%26b"
  ; "/a+b?query=x+y"
  ; "/raport/żółć?filter=Łódź"
  ; "/operations?filter=a%20b"
  ; "/operations?filter=a%2526b"
  ; "/operations?percent=100%25"
  ; "/operations?percent=100%"
  ; "/operations?escape=%2G"
  ; "/operations#section"
  ; "/😀?q=%F0%9F%98%80" ]

let unsafe_query_whitespace =
  whitespace
  |> List.filter (fun code -> not (List.mem code controls))
  |> List.map (fun code -> "/operations?q=" ^ utf8 code)

let unsafe_targets =
  [ ""
  ; "https://evil.example"
  ; "http://evil.example"
  ; "javascript:alert(1)"
  ; "evil.example/path"
  ; "//evil.example"
  ; "///evil.example"
  ; "\\evil.example"
  ; "/\\evil.example"
  ; "/operations?query=\\evil"
  ; "/%2fevil.example"
  ; "/%252Fevil.example"
  ; "/%255cevil.example"
  ; "/%0d%0aLocation:%20https://evil.example" ]
  @ List.map (fun code -> "/operations" ^ utf8 code ^ "tail") controls
  @ List.map (fun code -> "/operations?q=" ^ utf8 code) controls
  @ List.map (fun code -> "/operations" ^ utf8 code ^ "tail") whitespace
  @ List.map (fun code -> "/operations?q=" ^ utf8 code) whitespace

let validate name target expected =
  check
    (name ^ " utility: " ^ Printf.sprintf "%S" target)
    (Well.Login_navigation.safe_target target = expected) ;
  check
    (name ^ " OAuth: " ^ Printf.sprintf "%S" target)
    (Well.OAuth.validate_return_to target = expected)

let test_validation () =
  List.iter (fun target -> validate "accept" target target) safe_targets ;
  List.iter (fun target -> validate "reject" target "/") unsafe_targets ;
  List.iter
    (fun target ->
      if
        String.length target > 1
        && target.[0] = '/'
        && not (List.mem target unsafe_query_whitespace)
      then
        let suffix = ref (String.sub target 1 (String.length target - 1)) in
        for layer = 1 to 3 do
          suffix := Well.url_encode !suffix ;
          validate
            ("reject encoded layer " ^ string_of_int layer)
            ("/" ^ !suffix)
            "/"
        done )
    unsafe_targets ;
  List.iter
    (fun code ->
      if not (List.mem code controls)
      then
        let target = "/operations?q=" ^ Well.url_encode (utf8 code) in
        validate "accept encoded query whitespace" target target )
    whitespace

let expect_invalid name fn =
  let rejected =
    try
      fn () ;
      false
    with
    | Invalid_argument _ -> true
  in
  check name rejected

let test_login_url () =
  let url = Well.Login_navigation.login_url in
  check
    "default login URL"
    ( url "/operations?filter=a%26b"
    = "/login?return_to=%2Foperations%3Ffilter%3Da%2526b" ) ;
  check
    "malicious target uses root"
    (url "//evil.example" = "/login?return_to=%2F") ;
  check
    "existing query and fragment"
    ( url
        ~login_path:"/logowanie?lang=pl#formularz"
        ~return_param:"redirect"
        "/operations?filter=a%26b"
    = "/logowanie?lang=pl&redirect=%2Foperations%3Ffilter%3Da%2526b#formularz"
    ) ;
  check
    "replace every encoded and duplicate name"
    ( url
        ~login_path:
          "/login?return_to=old&lang=pl&%72eturn_to=other&return_to#form"
        "/operations"
    = "/login?lang=pl&return_to=%2Foperations#form" ) ;
  check
    "preserve other parameter spellings"
    ( url ~login_path:"/login?x=a+b&redirect=keep&y=a%26b" "/"
    = "/login?x=a+b&redirect=keep&y=a%26b&return_to=%2F" ) ;
  check
    "encode parameter name"
    ( url ~return_param:"return&next" "/operations"
    = "/login?return%26next=%2Foperations" ) ;
  check
    "empty existing query"
    (url ~login_path:"/login?#form" "/" = "/login?return_to=%2F#form") ;
  check
    "root is a valid login page"
    (url ~login_path:"/" "/" = "/?return_to=%2F") ;
  expect_invalid "empty parameter rejected" (fun () ->
      ignore (url ~return_param:"" "/") ) ;
  List.iter
    (fun login_path ->
      expect_invalid
        ("unsafe login page: " ^ Printf.sprintf "%S" login_path)
        (fun () -> ignore (url ~login_path "/")) )
    unsafe_targets

let location (response : Well.fetch_response) =
  List.find_map
    (fun (name, value) ->
      if String.lowercase_ascii name = "location" then Some value else None )
    response.headers

let test_middleware () =
  let middleware = Well.require_auth () in
  let handler_calls = ref 0 in
  let handler req =
    incr handler_calls ;
    check "current user preserved" (Well.current_user req = Some "member") ;
    Well.text "authenticated"
  in
  let response = middleware handler (request ~query:[("filter", "a&b")] ()) in
  check
    "GET preserves query"
    (response = `Redirect "/login?return_to=%2Foperations%3Ffilter%3Da%2526b") ;
  List.iter
    (fun meth ->
      check
        (meth ^ " uses root")
        ( middleware handler (request ~meth ~query:[("filter", "a&b")] ())
        = `Redirect "/login?return_to=%2F" ) )
    ["POST"; "PUT"; "PATCH"; "DELETE"; "HEAD"; "OPTIONS"] ;
  check
    "HTML Accept redirects"
    ( middleware handler (request ~headers:[("accept", "TEXT/HTML")] ())
    = `Redirect "/login?return_to=%2Foperations" ) ;
  let json =
    middleware handler (request ~headers:[("accept", "application/json")] ())
    |> Well.resolve
  in
  check "JSON remains 401" (json.r_status = 401 && json.r_body = "Unauthorized") ;
  check "JSON has no Location" (not (List.mem_assoc "Location" json.r_headers)) ;
  check "anonymous handler not executed" (!handler_calls = 0) ;
  Well.Session.set ~session_id:"member" ~key:"user_id" ~value:"member" ;
  check
    "authenticated handler passes"
    ( middleware handler (request ~session_id:"member" ())
    = `Text "authenticated" ) ;
  check "authenticated handler called once" (!handler_calls = 1) ;
  let custom =
    Well.require_auth
      ~login_path:"/logowanie?lang=pl#formularz"
      ~return_param:"redirect"
      ()
  in
  check
    "custom middleware configuration"
    ( custom handler (request ())
    = `Redirect "/logowanie?lang=pl&redirect=%2Foperations#formularz" ) ;
  expect_invalid "middleware rejects unsafe configuration" (fun () ->
      let (_ : Well.middleware) =
        Well.require_auth ~login_path:"//evil.example" ()
      in
      () )

let query_json query =
  `List
    (List.map (fun (name, value) -> `List [`String name; `String value]) query)

let observe (req : Well.request) =
  Well.text
    (Yojson.Safe.to_string
       (`Assoc [("path", `String req.path); ("query", query_json req.query)]) )

let query_from_json body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> (
    match List.assoc "query" fields with
    | `List pairs ->
        List.map
          (function
            | `List [`String name; `String value] -> (name, value)
            | _ -> failwith "Unexpected query pair" )
          pairs
    | _ -> failwith "Unexpected query data" )
  | _ -> failwith "Unexpected response"

let test_http port operation_calls =
  let url path = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let member_cookie = [("Cookie", "well_session=member")] in
  let cases =
    [ ("/operations?filter=a%26b", [("filter", "a&b")])
    ; ( "/operations?q=a%3Fb%26c%2Bd&name=%C5%BC%C3%B3%C5%82%C4%87"
      , [("q", "a?b&c+d"); ("name", "żółć")] )
    ; ( "/operations?q=hello+world&space=hello%20world&percent=100%25"
      , [("q", "hello world"); ("space", "hello world"); ("percent", "100%")] )
    ; ( "/operations?literal=a%2526b&filter=x&filter=y&empty=&flag"
      , [ ("literal", "a%26b")
        ; ("filter", "x")
        ; ("filter", "y")
        ; ("empty", "")
        ; ("flag", "") ] )
    ; ( "/operations?%26%3F%2B=%26%3F%2B&%C5%82%C3%B3d%C5%BA=%F0%9F%98%80"
      , [("&?+", "&?+"); ("łódź", "😀")] )
    ; ("/operations/%C5%82%C3%B3d%C5%BA?q=a%26b", [("q", "a&b")]) ]
  in
  List.iter
    (fun (target, expected_query) ->
      let response =
        Well.fetch ~headers:[("Accept", "text/html")] (url target)
      in
      check "HTTP unauthenticated redirect" (response.status = 302) ;
      let login = Option.get (location response) in
      if target = "/operations?filter=a%26b"
      then
        check
          "HTTP acceptance example has exact URL"
          (login = "/login?return_to=%2Foperations%3Ffilter%3Da%2526b") ;
      let login_response = Well.fetch (url login) in
      let login_query = query_from_json login_response.body in
      check
        "HTTP login has exactly one return parameter"
        (List.length login_query = 1) ;
      let return_to = List.assoc "return_to" login_query in
      check
        "HTTP return target remains local"
        ( Well.Login_navigation.safe_target return_to = return_to
        && return_to <> "/" ) ;
      let returned = Well.fetch ~headers:member_cookie (url return_to) in
      check "HTTP authenticated view" (returned.status = 200) ;
      check
        "HTTP query round-trip"
        (query_from_json returned.body = expected_query) ;
      let expected_path = List.hd (String.split_on_char '?' target) in
      check
        "HTTP path escape round-trip"
        ( Yojson.Safe.Util.member "path" (Yojson.Safe.from_string returned.body)
        = `String expected_path ) )
    cases ;
  let custom = Well.fetch (url "/custom?filter=a%26b") in
  check
    "HTTP custom login configuration"
    ( location custom
    = Some "/logowanie?lang=pl&redirect=%2Fcustom%3Ffilter%3Da%2526b#formularz"
    ) ;
  let post =
    Well.fetch ~method_:"POST" ~body:"action=delete" (url "/operations")
  in
  check
    "HTTP POST redirects to root"
    (location post = Some "/login?return_to=%2F") ;
  let login = Well.fetch (url (Option.get (location post))) in
  let root = List.assoc "return_to" (query_from_json login.body) in
  let returned = Well.fetch ~headers:member_cookie (url root) in
  check "HTTP POST resumes GET root" (returned.status = 200 && root = "/") ;
  check "HTTP POST was not executed or replayed" (!operation_calls = 0) ;
  let json =
    Well.fetch ~headers:[("Accept", "application/json")] (url "/operations")
  in
  check
    "HTTP JSON remains 401"
    (json.status = 401 && json.body = "Unauthorized" && location json = None) ;
  List.iter
    (fun suffix ->
      let response = Well.fetch (url ("/operations/" ^ suffix)) in
      check
        "HTTP encoded unsafe path falls back to root"
        (location response = Some "/login?return_to=%2F") )
    ["%5cevil"; "%255Cevil"; "%0d%0aevil"; "%2520evil"]

let test_oauth () =
  let provider =
    { (Well.OAuth.google ~client_id:"test-client" ~client_secret:"test-secret") with
      name= "navigation"
    ; is_oidc= false }
  in
  Well.OAuth.setup ~base_url:"https://app.example.invalid" [provider] ;
  let user =
    Result.get_ok
      (Well.Auth.create_user_without_password
         ~email:"navigation@example.invalid" )
  in
  Well.OAuth.create_identity
    ~user_id:user.id
    ~provider:provider.name
    ~provider_uid:"navigation-user"
    () ;
  let original_fetch = !Well.OAuth._fetch_ref in
  (Well.OAuth._fetch_ref :=
     fun ~method_ ~headers:_ ~body:_ target ->
       if method_ = "POST" && target = provider.token_url
       then (200, [], {|{"access_token":"mock-token"}|})
       else if method_ = "GET" && target = provider.userinfo_url
       then (200, [], {|{"sub":"navigation-user"}|})
       else failwith "Unexpected OAuth network call" ) ;
  Fun.protect
    ~finally:(fun () -> Well.OAuth._fetch_ref := original_fetch)
    (fun () ->
      List.iteri
        (fun index (target, expected) ->
          let sid = "oauth-navigation-" ^ string_of_int index in
          let req = request ~session_id:sid ~query:[("return_to", target)] () in
          ignore (Well.OAuth.authorize_handler provider req) ;
          check
            "OAuth authorize uses shared validation"
            ( Well.Session.get ~session_id:sid ~key:"oauth_navigation_return_to"
            = Some expected ) ;
          let state =
            Option.get
              (Well.Session.get ~session_id:sid ~key:"oauth_navigation_state")
          in
          Well.Session.set
            ~session_id:sid
            ~key:"oauth_navigation_return_to"
            ~value:target ;
          let callback =
            {req with query= [("state", state); ("code", "mock-code")]}
          in
          check
            "OAuth callback revalidates session target"
            ( Well.OAuth.callback_handler provider callback
            = Well.OAuth.ORedirectWithRegenerate expected ) )
        ( List.map (fun target -> (target, target)) safe_targets
        @ List.map (fun target -> (target, "/")) unsafe_targets ) )

let () =
  Well.Db.memory_mode := true ;
  let operation_calls = ref 0 in
  let middleware = [Well.require_auth ()] in
  Well.get ~middleware "/operations" observe ;
  Well.get ~middleware "/operations/:view" observe ;
  Well.post ~middleware "/operations" (fun _ ->
      incr operation_calls ;
      Well.text "executed" ) ;
  Well.get
    ~middleware:
      [ Well.require_auth
          ~login_path:"/logowanie?lang=pl#formularz"
          ~return_param:"redirect"
          () ]
    "/custom"
    observe ;
  Well.get "/login" observe ;
  Well.get "/logowanie" observe ;
  Well.get "/" observe ;
  Well.with_test_server ~disable_cap:true ~workers:2 (fun port ->
      test_validation () ;
      test_login_url () ;
      test_middleware () ;
      test_http port operation_calls ;
      test_oauth () ;
      Printf.printf "Login navigation: %d checks passed\n%!" !checks ;
      exit 0 )
