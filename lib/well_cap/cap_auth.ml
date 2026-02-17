let is_authed req =
  match Well.session_get req "well_console_auth" with
  | Some "1" -> true
  | _ -> false

let cap_auth_mw handler req =
  if is_authed req then handler req
  else Well.Cap_hook.CRRedirect "/_well/login"
