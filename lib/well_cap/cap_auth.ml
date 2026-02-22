let is_authed req =
  match Well.session_get req "user_id" with
  | Some uid_s ->
    (match int_of_string_opt uid_s with
     | Some uid -> Well.Auth.has_grant ~user_id:uid "cap"
     | None -> false)
  | None -> false

let cap_auth_mw handler req =
  if is_authed req then handler req
  else Well.Cap_hook.CRRedirect "/_well/login"
