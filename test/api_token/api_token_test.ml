let checks = ref 0

let check name condition =
  incr checks ;
  if not condition then failwith name

let request headers : Well.request =
  { meth= "POST"
  ; path= "/rpc/Test/who"
  ; headers
  ; body= ""
  ; params= []
  ; query= []
  ; session_id= ""
  ; _context= [] }

let authorization token = [("authorization", "Bearer " ^ token)]

let cookie = ("cookie", "well_session=browser")

let run headers handler =
  Well.session_middleware (Well.csrf handler) (request headers) |> Well.resolve

let user (req : Well.request) =
  Well.Session.get ~session_id:req.session_id ~key:"user_id"

let () =
  Eio_main.run @@ fun _env ->
  Mirage_crypto_rng_unix.use_default () ;
  Well.Db.memory_mode := true ;
  Well.Session.set ~session_id:"browser" ~key:"user_id" ~value:"browser-owner" ;
  let active = ref true in
  let calls = ref 0 in
  Well.Session.set ~session_id:"legacy" ~key:"user_id" ~value:"legacy-owner" ;
  check
    "legacy bearer unchanged"
    ( (run
         (authorization "legacy" @ [("x-requested-with", "XMLHttpRequest")])
         (fun req ->
           check "legacy owner" (user req = Some "legacy-owner") ;
           Well.text "ok" ) )
        .r_status
    = 200 ) ;
  Well.api_token_auth
    ~applies_to:(fun req -> req.path <> "/legacy")
    ~verify:(fun token ->
      incr calls ;
      if token = "verifier-failure" then failwith "secret-verifier-message" ;
      if !active && (token = "alice" || token = "bob")
      then
        Some
          { Well.user_id= token
          ; session_data= [("user_id", "spoof"); ("role", "employee")] }
      else None )
    () ;
  let legacy_request =
    { (request
         (authorization "legacy" @ [("x-requested-with", "XMLHttpRequest")]) )
      with
      path= "/legacy" }
  in
  let before_legacy = !calls in
  let legacy_response =
    Well.session_middleware
      (Well.csrf (fun req ->
           check
             "excluded route legacy identity"
             (user req = Some "legacy-owner") ;
           check
             "excluded route has no token marker"
             (not (Well.api_token_authenticated req)) ;
           Well.text "legacy" ) )
      legacy_request
    |> Well.resolve
  in
  check "excluded route remains available" (legacy_response.r_status = 200) ;
  check "excluded route does not invoke verifier" (!calls = before_legacy) ;
  let observed = ref "" in
  let handler (req : Well.request) =
    observed := req.Well.session_id ;
    check "RPC and Session identity" ((Well.rpc_ctx req).user_id = user req) ;
    check "trusted owner" (user req = Some "alice") ;
    check "token marker" (Well.api_token_authenticated req) ;
    check
      "extra data"
      (Well.Session.get ~session_id:req.session_id ~key:"role" = Some "employee") ;
    check "secret is not context id" (req.session_id <> "alice") ;
    List.iter
      (fun mutate ->
        let rejected =
          try
            mutate () ;
            false
          with
          | Invalid_argument _ -> true
        in
        check "identity immutable" rejected )
      [ (fun () ->
          Well.Session.set
            ~session_id:req.session_id
            ~key:"user_id"
            ~value:"admin" )
      ; (fun () -> Well.Session.delete ~session_id:req.session_id ~key:"user_id")
      ; (fun () -> Well.Session.clear ~session_id:req.session_id) ] ;
    Well.text "accepted"
  in
  let accepted = run (authorization "alice") handler in
  check "bearer without CSRF" (accepted.r_status = 200) ;
  check "no Set-Cookie" (not (List.mem_assoc "Set-Cookie" accepted.r_headers)) ;
  check
    "context absent after completion"
    (Well.Session.get ~session_id:!observed ~key:"user_id" = None) ;
  ignore (run (cookie :: authorization "alice") handler) ;
  let executed = ref false in
  let unexpected _ =
    executed := true ;
    Well.text "wrong"
  in
  List.iter
    (fun headers ->
      let response = run (cookie :: headers) unexpected in
      check "invalid bearer rejected" (response.r_status = 401) ;
      check
        "WWW-Authenticate"
        (List.assoc_opt "WWW-Authenticate" response.r_headers = Some "Bearer") )
    [ authorization "invalid"
    ; authorization ""
    ; [("authorization", "Bearer")]
    ; authorization "alice bob"
    ; authorization "alice" @ authorization "bob" ] ;
  check "no fallback handler" (not !executed) ;
  active := false ;
  check
    "revocation immediately enforced"
    ((run (authorization "alice") unexpected).r_status = 401) ;
  active := true ;
  check "verified per request" (!calls >= 4) ;
  let failure = run (cookie :: authorization "verifier-failure") unexpected in
  check "verifier failure closed" (failure.r_status = 503) ;
  check
    "verifier exception redacted"
    (failure.r_body = "{\"error\":\"API token verification unavailable\"}") ;
  check "cookie still needs CSRF" ((run [cookie] unexpected).r_status = 403) ;
  check
    "Basic unchanged"
    ( (run
         [ cookie
         ; ("authorization", "Basic abc")
         ; ("x-requested-with", "XMLHttpRequest") ]
         (fun req ->
           check "cookie owner" (user req = Some "browser-owner") ;
           check "cookie not token" (not (Well.api_token_authenticated req)) ;
           Well.text "ok" ) )
        .r_status
    = 200 ) ;
  let exception_sid = ref "" in
  ( try
      ignore
        (run (authorization "alice") (fun req ->
             exception_sid := req.session_id ;
             failwith "handler" ) )
    with
  | Failure _ -> () ) ;
  check
    "exception cleans identity"
    (Well.Session.get ~session_id:!exception_sid ~key:"user_id" = None) ;
  Eio.Fiber.both
    (fun () ->
      ignore
        (run (authorization "alice") (fun req ->
             Eio.Fiber.yield () ;
             check "alice fiber isolation" (user req = Some "alice") ;
             Well.text "ok" ) ) )
    (fun () ->
      ignore
        (run (authorization "bob") (fun req ->
             Eio.Fiber.yield () ;
             check "bob fiber isolation" (user req = Some "bob") ;
             Well.text "ok" ) ) ) ;
  let owners = ["alice"; "bob"] in
  let workers =
    List.map
      (fun owner ->
        Domain.spawn (fun () ->
            Eio_main.run (fun _ ->
                let correct = ref false in
                ignore
                  (run (authorization owner) (fun req ->
                       Eio.Fiber.yield () ;
                       correct := user req = Some owner ;
                       Well.text "ok" ) ) ;
                !correct ) ) )
      owners
  in
  List.iter
    (fun worker -> check "domain identity isolation" (Domain.join worker))
    workers ;
  Eio.Switch.run (fun sw ->
      let gate, release = Eio.Promise.create () in
      let done_, finish = Eio.Promise.create () in
      let child_has_identity = ref true in
      ignore
        (run (authorization "alice") (fun req ->
             Eio.Fiber.fork ~sw (fun () ->
                 Eio.Promise.await gate ;
                 child_has_identity := Option.is_some (user req) ;
                 Eio.Promise.resolve finish () ) ;
             Well.text "ok" ) ) ;
      Eio.Promise.resolve release () ;
      Eio.Promise.await done_ ;
      check
        "child fiber cannot retain completed identity"
        (not !child_has_identity) ) ;
  Printf.printf "API token: %d checks passed\n%!" !checks
