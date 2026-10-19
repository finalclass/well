let calls = ref 0

let authorizations = ref 0

let operator = ref None

let setup () =
  match !operator with
  | Some user -> user
  | None ->
      let user =
        match
          Well.Auth.create_seed_user
            ~login:"operator"
            ~password:"fixture-password"
        with
        | Ok user -> user
        | Error message -> failwith message
      in
      Well.Auth.grant ~user_id:user.id "cap" ;
      operator := Some user ;
      user

let verify token =
  if List.mem token ["allowed"; "denied"; "failure"]
  then
    let user = setup () in
    Some
      {Well.user_id= string_of_int user.id; session_data= [("decision", token)]}
  else None

let authorize req =
  incr authorizations ;
  Eio.Fiber.yield () ;
  let user = setup () in
  let owner = Some (string_of_int user.id) in
  if
    (not (Well.api_token_authenticated req))
    || (Well.rpc_ctx req).user_id <> owner
    || Well.Session.get ~session_id:req.Well.session_id ~key:"user_id" <> owner
  then failwith "untrusted callback context" ;
  match Well.Session.get ~session_id:req.session_id ~key:"decision" with
  | Some "allowed" -> true
  | Some "failure" -> failwith "private authorization diagnostic"
  | _ -> false

let perform _ =
  incr calls ;
  Well.text "executed"

let () =
  if Sys.getenv "ADMISSION_DEFAULT" = "true"
  then Well.api_token_auth ~verify ()
  else
    Well.api_token_auth
      ~applies_to:(fun req -> req.path <> "/excluded")
      ~authorize
      ~verify
      () ;
  Well.use Well.csrf ;
  Well.Service.register_drut
    { dname= "Admission"
    ; drpcs= [{rname= "echo"; params= []; returns= []; returns_name= "Void"}]
    ; dhandler=
        (fun _ _ payload ->
          incr calls ;
          Ok payload )
    ; dset_ref= ignore } ;
  Well.Service.expose "Admission" ;
  let initialize = !Well.Cap_hook._cap_init in
  (Well.Cap_hook._cap_init :=
     fun () ->
       initialize () ;
       let handler _ =
         incr calls ;
         Well.Cap_hook.CRJson "true"
       in
       !Well.Cap_hook._register_cap_get "/_cap/admission" handler ;
       !Well.Cap_hook._register_cap_post "/_cap/admission" handler ) ;
  Well.get "/effect" perform ;
  Well.post "/effect" perform ;
  Well.get "/excluded" (fun _ -> Well.text "excluded") ;
  Well.get "/stats" (fun _ ->
      Well.json
        (`Assoc
           [("calls", `Int !calls); ("authorizations", `Int !authorizations)] ) ) ;
  Well.post "/login" (fun req ->
      ignore (setup ()) ;
      match
        Well.Auth.login_and_set_session
          req
          ~email:"operator"
          ~password:"fixture-password"
      with
      | Ok _ -> Well.text "logged in"
      | Error message -> Well.text message |> Well.status 401 ) ;
  Well.run
    ~host:"127.0.0.1"
    ~port:(int_of_string (Sys.getenv "ADMISSION_PORT"))
    ()
