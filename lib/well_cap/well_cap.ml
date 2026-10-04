open Cap_helpers
open Well.Cap_hook

let seed_cap_user () =
  if not (Well.Auth.has_any_grant "cap")
  then
    match Well.Auth.create_seed_user ~login:"cap" ~password:"admin" with
    | Ok user -> Well.Auth.grant ~user_id:user.id "cap"
    | Error _ -> (
      match Well.Auth.find_user_by_email "cap" with
      | Some user -> Well.Auth.grant ~user_id:user.id "cap"
      | None -> () )

let page req path title content =
  CRHtml
    (Cap_page.cap_page
       req
       ~path
       ~title
       ~content:(Html.element_to_string content) )

let authenticated handler req =
  if Cap_auth.is_authed req then handler req else CRRedirect "/_cap/login"

let api handler req =
  if Cap_auth.is_authed req
  then CRJson (Yojson.Safe.to_string (handler req))
  else CRStatus (401, "Unauthorized")

let user_id req =
  match Option.bind (List.assoc_opt "id" req.Well.params) int_of_string_opt with
  | Some id -> id
  | None -> -1

let users_model req view =
  let model, _ = Users_page.init req `Null in
  let model = Users_page.update req model view in
  match view with
  | Users_page.Search search -> {model with view= Users_page.List; search}
  | _ -> model

let user_exists model id =
  List.exists
    (fun ((u : Well.Auth.user), _) -> u.id = id)
    model.Users_page.users

let user_page req =
  let id = user_id req in
  let model = users_model req (Users_page.ShowEdit id) in
  if user_exists model id
  then
    page
      req
      "/_cap/users"
      ("Użytkownik #" ^ string_of_int id)
      (Users_page.view req model)
  else CRStatus (404, "Nie znaleziono użytkownika")

let user_action operation req =
  let id = user_id req in
  let model = users_model req (Users_page.ShowEdit id) in
  if not (user_exists model id)
  then CRStatus (404, "Nie znaleziono użytkownika")
  else
    let model = Users_page.update req model (operation id req) in
    if model.error <> ""
    then
      page
        req
        "/_cap/users"
        ("Użytkownik #" ^ string_of_int id)
        (Users_page.view req model)
    else begin
      Well.put_flash req "cap" model.success ;
      CRRedirect
        ( match model.view with
        | Users_page.List -> "/_cap/users"
        | _ -> Users_page.user_url id )
    end

let db_model req =
  let m, _ = Db_page.init req `Null in
  let m = Db_page.update req m (Db_page.SwitchDb (query req "source")) in
  let table = query req "table" in
  let m =
    if table = ""
    then m
    else if List.mem table m.tables
    then Db_page.update req m (Db_page.SelectTable table)
    else invalid_arg "Nieznana tabela"
  in
  let page =
    Option.value (int_of_string_opt (query req "page")) ~default:0 |> max 0
  in
  let m =
    if m.selected_table = ""
    then m
    else
      Db_page.update
        req
        m
        (Db_page.GoPage
           (min page (max 0 ((m.total_rows - 1) / Db_page.page_size))) )
  in
  let row = query req "row" and column = query req "column" in
  if row = "" || column = ""
  then m
  else
    match Db_page.find_pk m.db_source m.selected_table with
    | None -> invalid_arg "Tabela nie ma klucza głównego"
    | Some pk -> (
        let pk_index = List.find_index (fun c -> c = pk) m.columns in
        let column_index =
          List.find_index (fun c -> c = column && c <> pk) m.columns
        in
        match (pk_index, column_index) with
        | Some pi, Some ci -> (
          match
            List.find_opt (fun values -> List.nth values pi = row) m.rows
          with
          | Some values ->
              Db_page.update
                req
                m
                (Db_page.EditCell (row, column, List.nth values ci))
          | None -> invalid_arg "Nieznany wiersz" )
        | _ -> invalid_arg "Nieznana kolumna" )

let db_page req =
  try page req "/_cap/db" "Database" (Db_page.view req (db_model req)) with
  | Invalid_argument message -> CRStatus (400, message)

let db_action req =
  try
    let m = db_model req in
    let m =
      match field req "action" with
      | "run_sql" ->
          Db_page.update
            req
            {m with sql_input= field req "sql"}
            (Db_page.RunSQL (field req "sql"))
      | "save_cell" ->
          let req =
            { req with
              query=
                ("row", field req "row")
                :: ("column", field req "column")
                :: req.query }
          in
          Db_page.update
            req
            (db_model req)
            (Db_page.SaveCell (field req "value"))
      | _ -> invalid_arg "Nieznana operacja"
    in
    page req "/_cap/db" "Database" (Db_page.view req m)
  with
  | Invalid_argument message -> CRStatus (400, message)

let services_model req =
  let m, _ = Services_page.init req `Null in
  let service = query req "service" and rpc = query req "rpc" in
  if service = ""
  then m
  else if rpc = ""
  then Services_page.update req m (Services_page.ToggleMenu service)
  else Services_page.update req m (Services_page.SelectRPC (service, rpc))

let init () =
  start_time := Unix.gettimeofday () ;
  seed_cap_user () ;
  let get path handler = !_register_cap_get path handler in
  let post path handler = !_register_cap_post path handler in
  get "/_cap/app.js" (fun _ -> CRJs Cap_js.js) ;
  get "/_cap/login" (fun req -> CRHtml (Cap_login.login_page req ())) ;
  post "/_cap/login" (fun req ->
      match
        Well.Auth.login_and_set_session
          req
          ~email:(field req "email")
          ~password:(field req "password")
      with
      | Ok user when Well.Auth.has_grant ~user_id:user.id "cap" ->
          CRRedirect "/_cap/"
      | Ok _ ->
          Well.Auth.logout req ;
          CRHtml (Cap_login.login_page req ~error:"Brak uprawnień do CAP" ())
      | Error _ ->
          CRHtml
            (Cap_login.login_page req ~error:"Nieprawidłowy login lub hasło" ()) ) ;
  post
    "/_cap/logout"
    (authenticated (fun req ->
         Well.Auth.logout req ;
         CRRedirect "/_cap/login" ) ) ;
  get
    "/_cap/"
    (authenticated (fun req ->
         page
           req
           "/_cap/"
           "Overview"
           (Overview_page.view (Overview_page.gather ())) ) ) ;
  get
    "/_cap/routes"
    (authenticated (fun req ->
         let m, _ = Routes_page.init req `Null in
         page req "/_cap/routes" "Routes" (Routes_page.view m) ) ) ;
  get
    "/_cap/connections"
    (authenticated (fun req ->
         page req "/_cap/connections" "Connections" (Connections_page.view ()) )
    ) ;
  get "/_cap/db" (authenticated db_page) ;
  post "/_cap/db" (authenticated db_action) ;
  get
    "/_cap/services"
    (authenticated (fun req ->
         page
           req
           "/_cap/services"
           "Services"
           (Services_page.view req (services_model req)) ) ) ;
  post
    "/_cap/services"
    (authenticated (fun req ->
         let m =
           Services_page.update
             req
             (services_model req)
             (Services_page.CallRPC (field req "payload"))
         in
         page req "/_cap/services" "Services" (Services_page.view req m) ) ) ;
  get
    "/_cap/users"
    (authenticated (fun req ->
         let m = users_model req (Users_page.Search (query req "q")) in
         page req "/_cap/users" "Users" (Users_page.view req m) ) ) ;
  get
    "/_cap/users/new"
    (authenticated (fun req ->
         page
           req
           "/_cap/users"
           "Utwórz użytkownika"
           (Users_page.view req (users_model req Users_page.ShowCreate)) ) ) ;
  post
    "/_cap/users/new"
    (authenticated (fun req ->
         let m = users_model req Users_page.ShowCreate in
         let m =
           Users_page.update
             req
             {m with form_email= field req "email"}
             (Users_page.CreateUser (field req "email", field req "password"))
         in
         if m.error <> ""
         then
           page req "/_cap/users" "Utwórz użytkownika" (Users_page.view req m)
         else (
           Well.put_flash req "cap" m.success ;
           CRRedirect "/_cap/users" ) ) ) ;
  get "/_cap/users/:id" (authenticated user_page) ;
  List.iter
    (fun (action, operation) ->
      post ("/_cap/users/:id/" ^ action) (authenticated (user_action operation)) )
    [ ("email", fun id req -> Users_page.UpdateEmail (id, field req "email"))
    ; ( "password"
      , fun id req -> Users_page.SetPassword (id, field req "password") )
    ; ("grant", fun id req -> Users_page.AddGrant (id, field req "grant_name"))
    ; ( "revoke"
      , fun id req -> Users_page.RevokeGrant (id, field req "grant_name") )
    ; ("delete", fun id _ -> Users_page.DeleteUser id) ] ;
  get
    "/_cap/logs"
    (authenticated (fun req ->
         let m = Cap_data.logs_model req in
         let (`Html filters) = Logs_page.view req {m with entries= []} in
         let entries =
           String.concat
             ""
             (List.map
                (Logs_page.render_entry ~jump_target:m.jump_target)
                m.entries )
         in
         let earlier =
           match m.entries with
           | first :: _ when first.id > 0 ->
               link
                 (url
                    "/_cap/logs"
                    ( ("before", string_of_int first.id)
                    :: List.remove_assoc "before" req.query ) )
                 "Starsze wpisy"
           | _ -> ""
         in
         page
           req
           "/_cap/logs"
           "Logs"
           (Html.raw
              ( "<div class=\"log-viewer\">"
              ^ Html.element_to_string (`Html filters)
              ^ Cap_data.stream
                  "logs"
                  req
                  (Cap_data.logs req)
                  ( "<div class=\"card\"><div class=\"log-stream\">"
                  ^ entries
                  ^ "</div></div>" )
              ^ earlier
              ^ "</div>" ) ) ) ) ;
  get
    "/_cap/messages"
    (authenticated (fun req ->
         let (`Html initial) =
           Messages_page.view (Cap_data.recent_messages ())
         in
         page
           req
           "/_cap/messages"
           "Messages"
           (Html.raw
              (Cap_data.stream
                 "messages"
                 req
                 (Cap_data.message_data ())
                 (Html.element_to_string (`Html initial)) ) ) ) ) ;
  get
    "/_cap/telemetry"
    (authenticated (fun req ->
         let (`Html initial) = Telemetry_page.view (Telemetry_page.gather ()) in
         page
           req
           "/_cap/telemetry"
           "Telemetry"
           (Html.raw
              (Cap_data.stream
                 "telemetry"
                 req
                 (Cap_data.telemetry ())
                 (Html.element_to_string (`Html initial)) ) ) ) ) ;
  get
    "/_cap/metrics"
    (authenticated (fun req ->
         let window = Metrics_page.normalize_window (query req "window") in
         let class_ = Metrics_page.normalize_class (query req "class") in
         let http, flow, services, mutes = Metrics_page.gather ~window ~class_ in
         page
           req
           "/_cap/metrics"
           "Metrics"
           (Metrics_page.view req ~window ~class_ http flow services mutes) )) ;
  post
    "/_cap/metrics/mute"
    (authenticated (fun req ->
         let window = Metrics_page.normalize_window (field req "window") in
         let class_ = Metrics_page.normalize_class (field req "class") in
         CRRedirect (Metrics_page.apply req ~window ~class_) )) ;
  get
    "/_cap/repl"
    (authenticated (fun req ->
         let schema = Repl_page.schema_to_json (Repl_page.build_schema ()) in
         page
           req
           "/_cap/repl"
           "REPL"
           (Html.raw
              (Printf.sprintf
                 {|<cap-repl schema="%s"><div class="repl-wrap"><div class="empty-state">REPL wymaga włączonego JavaScript</div></div></cap-repl>|}
                 (esc schema) ) ) ) ) ;
  get "/_cap/api/logs" (api Cap_data.logs) ;
  get "/_cap/api/messages" (api (fun _ -> Cap_data.message_data ())) ;
  get "/_cap/api/telemetry" (api (fun _ -> Cap_data.telemetry ())) ;
  post
    "/_cap/api/repl"
    (api (fun req -> Repl_page.execute req (field req "expr"))) ;
  Log_buffer.load_from_file "well.log" ;
  Well.Log._hook :=
    Some
      (fun timestamp level message ctx ->
        ignore (Log_buffer.push ~level ~message ~timestamp ~ctx ()) ) ;
  ignore
    (Well.MessageBus.subscribe "*" (fun event ->
         Cap_data.push_message
           event.channel
           (Yojson.Safe.to_string event.payload)
           event.created_at ) )

let () = Well.Cap_hook._cap_init := init
