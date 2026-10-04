let initialized = ref false

let operator_id = ref 0

let calls = ref 0

let setup () =
  if not !initialized
  then begin
    let create login =
      match Well.Auth.create_seed_user ~login ~password:"test-password" with
      | Ok user -> user
      | Error message -> failwith message
    in
    let operator = create "operator" in
    ignore (create "reader") ;
    operator_id := operator.id ;
    Well.Auth.grant ~user_id:operator.id "cap" ;
    initialized := true
  end

let publish channel value =
  ignore (Well.MessageBus.publish ~ephemeral:true channel (`String value))

let () =
  Well.use (fun next req ->
      if Well.query req "shortcut" = Some "true"
      then Well.text "middleware-shortcut"
      else next req ) ;
  Well.Service.register_drut
    { dname= "probe"
    ; drpcs= []
    ; dhandler= (fun _ _ payload -> Ok payload)
    ; dset_ref= ignore } ;
  let cap_init = !Well.Cap_hook._cap_init in
  (Well.Cap_hook._cap_init :=
     fun () ->
       cap_init () ;
       !Well.Cap_hook._register_cap_get "/_cap/unwrapped" (fun _ ->
           incr calls ;
           Well.Cap_hook.CRHtml "protected-page" ) ;
       !Well.Cap_hook._register_cap_get "/_cap/api/unwrapped" (fun _ ->
           incr calls ;
           Well.Cap_hook.CRJson "\"protected-data\"" ) ;
       !Well.Cap_hook._register_cap_post "/_cap/api/unwrapped" (fun _ ->
           incr calls ;
           Well.Cap_hook.CRJson "\"protected-operation\"" ) ) ;
  Well.post "/test/login" (fun req ->
      setup () ;
      let email = Option.value ~default:"reader" (Well.form req "email") in
      match
        Well.Auth.login_and_set_session req ~email ~password:"test-password"
      with
      | Ok user -> `Assoc [("id", `Int user.id)]
      | Error message -> Well.text message |> Well.status 401 ) ;
  Well.post "/test/grant" (fun _ ->
      Well.Auth.grant ~user_id:!operator_id "cap" ;
      Well.text "ok" ) ;
  Well.post "/test/revoke" (fun _ ->
      Well.Auth.revoke ~user_id:!operator_id "cap" ;
      Well.text "ok" ) ;
  Well.post "/test/publish" (fun _ ->
      publish "cap:probe" "protected-event" ;
      publish "app:probe" "application-event" ;
      Well.text "ok" ) ;
  Well.get "/test/calls" (fun _ -> `Int !calls) ;
  Well.post "/test/not-ready" (fun _ ->
      (Well.Service._actor_health := fun () -> [("probe", "stopped")]) ;
      Well.text "ok" ) ;
  Well.channel
    "cap:probe"
    ~on_push:(fun _ _ event _ ->
      incr calls ;
      if event = "revoke" then Well.Auth.revoke ~user_id:!operator_id "cap" ;
      if event = "revoke-error"
      then begin
        Well.Auth.revoke ~user_id:!operator_id "cap" ;
        failwith "protected-error"
      end ;
      {Well.Channel.reply= Some (`String "protected-reply"); broadcast= None} )
    (fun _ _ ->
      incr calls ;
      Ok
        { Well.Channel.subscribe= ["cap:probe"]
        ; initial_state= Some (`String "protected-initial") } ) ;
  Well.channel "cap:initial-revoke" (fun _ _ ->
      Well.Auth.revoke ~user_id:!operator_id "cap" ;
      Ok
        { Well.Channel.subscribe= []
        ; initial_state= Some (`String "protected-initial") } ) ;
  Well.channel "cap:error-revoke" (fun _ _ ->
      Well.Auth.revoke ~user_id:!operator_id "cap" ;
      Error "protected-error" ) ;
  Well.channel "*" (fun _ _ ->
      Ok {Well.Channel.subscribe= ["*"]; initial_state= None} ) ;
  Well.channel
    "app:probe"
    ~on_push:(fun _ _ event _ ->
      if event = "queue-revoke"
      then begin
        publish "cap:probe" "queued-protected-event" ;
        Well.Auth.revoke ~user_id:!operator_id "cap"
      end ;
      {Well.Channel.reply= Some (`String "application-reply"); broadcast= None} )
    (fun _ _ -> Ok {Well.Channel.subscribe= ["app:probe"]; initial_state= None}) ;
  Well.run
    ~host:"127.0.0.1"
    ~port:(int_of_string (Sys.getenv "CAP_ACCESS_PORT"))
    ~disable_cap:(Sys.getenv "CAP_ACCESS_ENABLED" = "false")
    ()
