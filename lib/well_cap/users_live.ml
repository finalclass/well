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

let persistence = Well.LiveView.Ephemeral

let subscriptions = []

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
  { users= load_users ()
  ; view= List
  ; form_email= ""
  ; form_password= ""
  ; form_grant= ""
  ; error= ""
  ; success= ""
  ; search= "" }

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
    match Well.Auth.register ~email ~password with
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
      if Well.Auth.has_grant ~user_id:id "cap"
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
      if name = "cap" && Well.Auth.count_grant_holders "cap" <= 1
      then {model with error= "Cannot revoke cap from the last cap user"}
      else begin
        Well.Auth.revoke ~user_id:id name ;
        { (clear model) with
          users= load_users ~search:model.search ()
        ; success= Printf.sprintf "Grant '%s' revoked" name }
      end

let handle_params _req model = model

let temporary_assigns model = model

let render_list model =
  let search_html =
    Printf.sprintf
      {|<div style="display:flex;gap:8px;margin-bottom:16px;align-items:center">
      <form data-lv-submit="search" style="flex:1;display:flex;gap:8px">
        <input type="text" name="q" class="input" placeholder="Search by email..."
               value="%s" style="flex:1" />
        <button type="submit" class="btn btn-sm">Search</button>
      </form>
      <button class="btn btn-accent btn-sm" data-lv-click='["ShowCreate"]'>+ Create user</button>
    </div>|}
      (esc model.search)
  in
  let rows =
    if model.users = []
    then
      {|<tr><td colspan="5" style="color:var(--text-muted);text-align:center;padding:24px">No users found</td></tr>|}
    else
      String.concat
        ""
        (List.map
           (fun ((u : Well.Auth.user), grants) ->
             let grants_html =
               if grants = []
               then {|<span style="color:var(--text-muted)">none</span>|}
               else
                 String.concat
                   " "
                   (List.map
                      (fun g ->
                        Printf.sprintf
                          {|<span class="badge badge-get">%s</span>|}
                          (esc g) )
                      grants )
             in
             Printf.sprintf
               {|<tr>
              <td>%d</td>
              <td>%s</td>
              <td style="font-size:12px;color:var(--text-muted)">%s</td>
              <td>%s</td>
              <td>
                <button class="btn btn-sm" data-lv-click='["ShowEdit",%d]'>Edit</button>
                <button class="btn btn-sm" style="color:var(--red)"
                  data-lv-click='["DeleteUser",%d]'>Delete</button>
              </td>
            </tr>|}
               u.id
               (esc u.email)
               (esc u.created_at)
               grants_html
               u.id
               u.id )
           model.users )
  in
  Printf.sprintf
    {|%s
    <div class="card">
      <table class="data-table">
        <thead><tr>
          <th style="width:50px">ID</th>
          <th>Email</th>
          <th style="width:160px">Created</th>
          <th>Grants</th>
          <th style="width:140px">Actions</th>
        </tr></thead>
        <tbody data-lv="users-list">%s</tbody>
      </table>
    </div>|}
    search_html
    rows

let render_create model =
  Printf.sprintf
    {|<div class="card">
      <div class="card-title">Create user</div>
      <form data-lv-submit="create_user">
        <div style="display:grid;gap:12px;max-width:400px">
          <div>
            <label>Email</label>
            <input type="email" name="email" class="input" placeholder="user@example.com"
                   value="%s" autofocus />
          </div>
          <div>
            <label>Password</label>
            <input type="password" name="password" class="input"
                   placeholder="Min 8 characters" />
          </div>
          <div style="display:flex;gap:8px">
            <button type="submit" class="btn btn-accent btn-sm">Create</button>
            <button type="button" class="btn btn-sm"
              data-lv-click='["BackToList"]'>Cancel</button>
          </div>
        </div>
      </form>
    </div>|}
    (esc model.form_email)

let render_edit model id =
  let user, grants =
    match
      List.find_opt (fun ((u : Well.Auth.user), _) -> u.id = id) model.users
    with
    | Some (u, g) -> (u, g)
    | None -> ({Well.Auth.id; email= ""; created_at= ""}, [])
  in
  let grants_html =
    if grants = []
    then {|<p style="color:var(--text-muted)">No grants</p>|}
    else
      String.concat
        ""
        (List.map
           (fun g ->
             Printf.sprintf
               {|<span class="badge badge-get" style="cursor:pointer;margin-right:4px"
              data-lv-click='["RevokeGrant",%d,"%s"]'>%s &#10005;</span>|}
               id
               (esc g)
               (esc g) )
           grants )
  in
  Printf.sprintf
    {|<div style="margin-bottom:12px">
      <button class="btn btn-sm" data-lv-click='["BackToList"]'>&larr; Back to list</button>
    </div>
    <div style="display:grid;gap:16px;max-width:500px">
      <div class="card">
        <div class="card-title">User #%d</div>
        <div style="font-size:12px;color:var(--text-muted);margin-bottom:12px">Created: %s</div>
        <form data-lv-submit="update_email">
          <input type="hidden" name="user_id" value="%d" />
          <label>Email</label>
          <div style="display:flex;gap:8px">
            <input type="email" name="email" class="input" value="%s" style="flex:1" />
            <button type="submit" class="btn btn-sm">Update email</button>
          </div>
        </form>
      </div>
      <div class="card">
        <div class="card-title">Reset password</div>
        <form data-lv-submit="set_password">
          <input type="hidden" name="user_id" value="%d" />
          <div style="display:flex;gap:8px">
            <input type="password" name="password" class="input"
                   placeholder="New password (min 8 chars)" style="flex:1" />
            <button type="submit" class="btn btn-sm">Set password</button>
          </div>
        </form>
      </div>
      <div class="card">
        <div class="card-title">Grants</div>
        <div data-lv="user-grants" style="margin-bottom:12px">%s</div>
        <form data-lv-submit="add_grant">
          <input type="hidden" name="user_id" value="%d" />
          <div style="display:flex;gap:8px">
            <input type="text" name="grant_name" class="input"
                   placeholder="Grant name (e.g. cap, admin)" value="%s" style="flex:1" />
            <button type="submit" class="btn btn-accent btn-sm">Add grant</button>
          </div>
        </form>
      </div>
    </div>|}
    id
    (esc user.created_at)
    id
    (esc user.email)
    id
    grants_html
    id
    (esc model.form_grant)

let view model =
  let flash =
    let err =
      if model.error <> ""
      then
        Printf.sprintf
          {|<div class="login-error" style="margin-bottom:12px">%s</div>|}
          (esc model.error)
      else ""
    in
    let ok =
      if model.success <> ""
      then
        Printf.sprintf
          {|<div style="background:var(--green);color:#fff;padding:8px 12px;border-radius:6px;margin-bottom:12px;font-size:13px">%s</div>|}
          (esc model.success)
      else ""
    in
    err ^ ok
  in
  let content =
    match model.view with
    | List -> render_list model
    | Create -> render_create model
    | Edit id -> render_edit model id
  in
  `Html (Printf.sprintf {|<div data-lv="content">%s%s</div>|} flash content)

let model_to_yojson _m = `Null

let model_of_yojson _j = Error "ephemeral"

let msg_of_yojson j =
  match j with
  | `List [`String "Refresh"] -> Ok Refresh
  | `List [`String "ShowCreate"] -> Ok ShowCreate
  | `List [`String "ShowEdit"; `Int id] -> Ok (ShowEdit id)
  | `List [`String "BackToList"] -> Ok BackToList
  | `List [`String "DeleteUser"; `Int id] -> Ok (DeleteUser id)
  | `List [`String "RevokeGrant"; `Int id; `String name] ->
      Ok (RevokeGrant (id, name))
  | `List [`String "search"; `Assoc kvs] ->
      let q =
        match List.assoc_opt "q" kvs with
        | Some (`String s) -> s
        | _ -> ""
      in
      Ok (Search q)
  | `List [`String "create_user"; `Assoc kvs] ->
      let email =
        match List.assoc_opt "email" kvs with
        | Some (`String s) -> s
        | _ -> ""
      in
      let password =
        match List.assoc_opt "password" kvs with
        | Some (`String s) -> s
        | _ -> ""
      in
      Ok (CreateUser (email, password))
  | `List [`String "update_email"; `Assoc kvs] ->
      let id =
        match List.assoc_opt "user_id" kvs with
        | Some (`String s) -> (
          try int_of_string s with
          | _ -> 0 )
        | _ -> 0
      in
      let email =
        match List.assoc_opt "email" kvs with
        | Some (`String s) -> s
        | _ -> ""
      in
      Ok (UpdateEmail (id, email))
  | `List [`String "set_password"; `Assoc kvs] ->
      let id =
        match List.assoc_opt "user_id" kvs with
        | Some (`String s) -> (
          try int_of_string s with
          | _ -> 0 )
        | _ -> 0
      in
      let password =
        match List.assoc_opt "password" kvs with
        | Some (`String s) -> s
        | _ -> ""
      in
      Ok (SetPassword (id, password))
  | `List [`String "add_grant"; `Assoc kvs] ->
      let id =
        match List.assoc_opt "user_id" kvs with
        | Some (`String s) -> (
          try int_of_string s with
          | _ -> 0 )
        | _ -> 0
      in
      let name =
        match List.assoc_opt "grant_name" kvs with
        | Some (`String s) -> s
        | _ -> ""
      in
      Ok (AddGrant (id, name))
  | _ -> Ok Refresh
