open Cap_helpers

type edit_view =
  | List
  | Create
  | Edit of int

type model =
  { users: (Well.Auth.user * string list) list
  ; view: edit_view
  ; form_email: string
  ; form_password: string
  ; form_grant: string
  ; error: string
  ; success: string
  ; search: string }

type msg =
  | Refresh
  | Search of string
  | ShowCreate
  | ShowEdit of int
  | BackToList
  | CreateUser of string * string
  | UpdateEmail of int * string
  | SetPassword of int * string
  | DeleteUser of int
  | AddGrant of int * string
  | RevokeGrant of int * string

let load_users ?(search = "") () =
  let users = Well.Auth.list_users ~search () in
  let all_g = Well.Auth.all_grants () in
  List.map
    (fun (u : Well.Auth.user) ->
      let grants =
        List.filter_map
          (fun (uid, g) -> if uid = u.id then Some g else None)
          all_g
      in
      (u, grants) )
    users

let init _req _props =
  ( { users= load_users ()
    ; view= List
    ; form_email= ""
    ; form_password= ""
    ; form_grant= ""
    ; error= ""
    ; success= ""
    ; search= "" }
  , [] )

let update _req model msg =
  let clear m = {m with error= ""; success= ""} in
  match msg with
  | Refresh -> {(clear model) with users= load_users ~search:model.search ()}
  | Search s -> {(clear model) with search= s; users= load_users ~search:s ()}
  | ShowCreate ->
      {(clear model) with view= Create; form_email= ""; form_password= ""}
  | ShowEdit id ->
      let email =
        match
          List.find_opt (fun ((u : Well.Auth.user), _) -> u.id = id) model.users
        with
        | Some (u, _) -> u.email
        | None -> ""
      in
      { (clear model) with
        view= Edit id
      ; form_email= email
      ; form_password= ""
      ; form_grant= "" }
  | BackToList ->
      {(clear model) with view= List; users= load_users ~search:model.search ()}
  | CreateUser (email, password) -> (
    match Well.Auth.register ~email ~password () with
    | Ok _user ->
        { (clear model) with
          view= List
        ; users= load_users ~search:model.search ()
        ; success= "User created" }
    | Error e -> {(clear model) with error= e} )
  | UpdateEmail (id, email) -> (
    match Well.Auth.update_email id email with
    | Ok () ->
        { (clear model) with
          users= load_users ~search:model.search ()
        ; success= "Email updated"
        ; form_email= email }
    | Error e -> {(clear model) with error= e} )
  | SetPassword (id, password) -> (
    match Well.Auth.set_password id password with
    | Ok () ->
        {(clear model) with success= "Password updated"; form_password= ""}
    | Error e -> {(clear model) with error= e; form_password= ""} )
  | DeleteUser id ->
      if
        Well.Auth.has_grant ~user_id:id "cap"
        && Well.Auth.count_grant_holders "cap" <= 1
      then {model with error= "Cannot delete the last cap user"}
      else begin
        Well.Auth.delete_user id ;
        { (clear model) with
          view= List
        ; users= load_users ~search:model.search ()
        ; success= "User deleted" }
      end
  | AddGrant (id, name) ->
      if name = ""
      then {model with error= "Grant name required"}
      else begin
        Well.Auth.grant ~user_id:id name ;
        { (clear model) with
          users= load_users ~search:model.search ()
        ; success= Printf.sprintf "Grant '%s' added" name
        ; form_grant= "" }
      end
  | RevokeGrant (id, name) ->
      if
        name = "cap"
        && Well.Auth.has_grant ~user_id:id "cap"
        && Well.Auth.count_grant_holders "cap" <= 1
      then {model with error= "Cannot revoke cap from the last cap user"}
      else begin
        Well.Auth.revoke ~user_id:id name ;
        { (clear model) with
          users= load_users ~search:model.search ()
        ; success= Printf.sprintf "Grant '%s' revoked" name }
      end

let user_url id = "/_cap/users/" ^ string_of_int id

let render_list req model =
  let rows =
    String.concat
      ""
      (List.map
         (fun ((u : Well.Auth.user), grants) ->
           let badges =
             String.concat
               " "
               (List.map
                  (fun g ->
                    {|<span class="badge badge-get">|} ^ esc g ^ "</span>" )
                  grants )
           in
           Printf.sprintf
             {|<tr><td>%d</td><td><a href="%s">%s</a></td><td style="font-size:12px;color:var(--text-muted)">%s</td><td>%s</td><td>%s%s<button class="btn btn-sm" style="color:var(--red)" type="submit">Usuń</button></form></td></tr>|}
             u.id
             (esc (user_url u.id))
             (esc u.email)
             (esc u.created_at)
             badges
             (link (user_url u.id) "Edytuj")
             (Printf.sprintf
                {|<form method="post" action="%s/delete" style="display:inline">%s|}
                (user_url u.id)
                (csrf req) ) )
         model.users )
  in
  Printf.sprintf
    {|<div style="display:flex;gap:8px;margin-bottom:16px;align-items:center">
      <form method="get" action="/_cap/users" style="flex:1;display:flex;gap:8px">
        <input type="text" name="q" class="input" placeholder="Szukaj emaila..." value="%s" style="flex:1" />
        <button type="submit" class="btn btn-sm">Szukaj</button>
      </form>%s</div>
      <div class="card"><table class="data-table"><thead><tr><th style="width:50px">ID</th><th>Email</th><th style="width:160px">Utworzono</th><th>Uprawnienia</th><th style="width:140px">Akcje</th></tr></thead><tbody>%s</tbody></table>%s</div>|}
    (esc model.search)
    (link
       ~class_:"btn btn-accent btn-sm"
       "/_cap/users/new"
       "+ Utwórz użytkownika" )
    rows
    ( if rows = ""
      then {|<div class="empty-state">Brak użytkowników</div>|}
      else "" )

let render_create req model =
  Printf.sprintf
    {|<div class="card"><div class="card-title">Utwórz użytkownika</div>%s
      <div style="display:grid;gap:12px;max-width:400px"><div><label for="email">Email</label>
      <input type="email" id="email" name="email" class="input" value="%s" required autofocus /></div>
      <div><label for="password">Hasło</label><input type="password" id="password" name="password" class="input" minlength="8" required /></div>
      <div style="display:flex;gap:8px"><button type="submit" class="btn btn-accent btn-sm">Utwórz</button>%s</div></div></form></div>|}
    (form_open req "/_cap/users/new")
    (esc model.form_email)
    (link "/_cap/users" "Anuluj")

let render_edit req model id =
  match
    List.find_opt (fun ((u : Well.Auth.user), _) -> u.id = id) model.users
  with
  | None -> ""
  | Some (user, grants) ->
      let base = user_url id in
      let grants_html =
        String.concat
          " "
          (List.map
             (fun g ->
               Printf.sprintf
                 {|<form method="post" action="%s/revoke" style="display:inline">%s%s<button type="submit" class="badge badge-get" style="cursor:pointer;margin-right:4px">%s &#10005;</button></form>|}
                 base
                 (csrf req)
                 (hidden "grant_name" g)
                 (esc g) )
             grants )
      in
      Printf.sprintf
        {|<div style="margin-bottom:12px">%s</div><div style="display:grid;gap:16px;max-width:500px">
      <div class="card"><div class="card-title">Użytkownik #%d</div><div style="font-size:12px;color:var(--text-muted);margin-bottom:12px">Utworzono: %s</div>%s
      <label for="email">Email</label><div style="display:flex;gap:8px"><input type="email" id="email" name="email" class="input" value="%s" style="flex:1" required /><button type="submit" class="btn btn-sm">Zmień email</button></div></form></div>
      <div class="card"><div class="card-title">Reset hasła</div>%s<div style="display:flex;gap:8px"><input type="password" name="password" class="input" placeholder="Nowe hasło (min. 8 znaków)" style="flex:1" minlength="8" required /><button type="submit" class="btn btn-sm">Ustaw hasło</button></div></form></div>
      <div class="card"><div class="card-title">Uprawnienia</div><div style="margin-bottom:12px">%s</div>%s<div style="display:flex;gap:8px"><input type="text" name="grant_name" class="input" placeholder="Nazwa uprawnienia" value="%s" style="flex:1" required /><button type="submit" class="btn btn-accent btn-sm">Dodaj</button></div></form></div></div>|}
        (link "/_cap/users" "&larr; Wróć do listy")
        id
        (esc user.created_at)
        (form_open req (base ^ "/email"))
        (esc model.form_email)
        (form_open req (base ^ "/password"))
        grants_html
        (form_open req (base ^ "/grant"))
        (esc model.form_grant)

let view req model =
  let error =
    if model.error = ""
    then ""
    else {|<div class="login-error mb-3">|} ^ esc model.error ^ "</div>"
  in
  let content =
    match model.view with
    | List -> render_list req model
    | Create -> render_create req model
    | Edit id -> render_edit req model id
  in
  html_raw (flash req ^ error ^ content)
