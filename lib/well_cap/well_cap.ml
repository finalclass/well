(* Well_cap — Cap admin panel initialization *)
(* Registers LiveView endpoints, routes, and hooks for /_well/ *)

let init () =
  let pass = try Sys.getenv "WELL_CAP_PASS" with Not_found -> "" in
  if pass <> "" then Well.Cap_hook.cap_password := pass;
  (* Register LiveView endpoints *)
  Well.LiveView.register "/live/_well/" (module Overview_live);
  Well.LiveView.register "/live/_well/db" (module Db_live);
  Well.LiveView.register "/live/_well/services" (module Services_live);
  Well.LiveView.register "/live/_well/messages" (module Messages_live);
  Well.LiveView.register "/live/_well/logs" (module Logs_live);
  (* Serve embedded well.js — no auth needed for static asset *)
  !(Well.Cap_hook._register_cap_get) "/_well/well.js" (fun _req ->
    Well.Cap_hook.CRJs Cap_js.js);
  (* Login routes — no auth *)
  !(Well.Cap_hook._register_cap_get) "/_well/login" (fun _req ->
    Well.Cap_hook.CRHtml (Cap_login.login_page ()));
  !(Well.Cap_hook._register_cap_post) "/_well/login" (fun req ->
    let submitted =
      let pairs = String.split_on_char '&' req.body in
      List.fold_left (fun acc pair ->
        match String.index_opt pair '=' with
        | Some i ->
            let k = String.sub pair 0 i in
            let v = String.sub pair (i + 1) (String.length pair - i - 1) in
            if k = "password" then v else acc
        | None -> acc
      ) "" pairs
    in
    if !(Well.Cap_hook.cap_password) <> "" && submitted = !(Well.Cap_hook.cap_password) then begin
      Well.session_set req "well_console_auth" "1";
      Well.Cap_hook.CRRedirect "/_well/"
    end else
      Well.Cap_hook.CRHtml (Cap_login.login_page ~error:true ()));
  (* Logout route *)
  !(Well.Cap_hook._register_cap_get) "/_well/logout" (fun req ->
    Well.session_delete req "well_console_auth";
    Well.Cap_hook.CRRedirect "/_well/login");
  (* Cap page routes — with auth *)
  let authed handler req = Cap_auth.cap_auth_mw handler req in
  !(Well.Cap_hook._register_cap_get) "/_well/" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_well/" ~title:"Overview"
              ~endpoint:"/live/_well/")));
  !(Well.Cap_hook._register_cap_get) "/_well/db" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_well/db" ~title:"Database"
              ~endpoint:"/live/_well/db")));
  !(Well.Cap_hook._register_cap_get) "/_well/services" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_well/services" ~title:"Services"
              ~endpoint:"/live/_well/services")));
  !(Well.Cap_hook._register_cap_get) "/_well/messages" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_well/messages" ~title:"Messages"
              ~endpoint:"/live/_well/messages")));
  !(Well.Cap_hook._register_cap_get) "/_well/logs" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_well/logs" ~title:"Logs"
              ~endpoint:"/live/_well/logs")));
  (* Set up log hook for broadcasting to Logs LiveView *)
  Well.Cap_hook._cap_log_hook := Some (fun meth path status duration_ms ->
    let entry_json = `Assoc [
      ("id", `Int !(Well.Cap_hook.Log_buffer.next_id));
      ("meth", `String meth);
      ("path", `String path);
      ("status", `Int status);
      ("duration_ms", `Float duration_ms);
      ("timestamp", `Float (Unix.gettimeofday ()));
    ] in
    ignore (Well.MessageBus.publish ~ephemeral:true "/live/_well/logs" entry_json));
  (* Set up MessageBus subscriber for Messages LiveView *)
  (* Filter out /_well/* channels to avoid infinite loop:
     subscribe "*" catches ALL messages including our own publishes *)
  ignore (Well.MessageBus.subscribe "*" (fun event ->
    if not (String.length event.Well.MessageBus.channel >= 12
            && String.sub event.Well.MessageBus.channel 0 12 = "/live/_well/") then begin
      let msg_json = `Assoc [
        ("channel", `String event.Well.MessageBus.channel);
        ("payload", `String (Yojson.Safe.to_string event.payload));
        ("timestamp", `Float event.created_at);
      ] in
      ignore (Well.MessageBus.publish ~ephemeral:true "/live/_well/messages" msg_json)
    end));
  if pass = "" then
    Printf.printf "[well] cap at /_well/ (set WELL_CAP_PASS to enable login)\n%!"
  else
    Printf.printf "[well] cap at /_well/\n%!"

(* Register init at module load time — well.ml calls !Cap_hook._cap_init () *)
let () = Well.Cap_hook._cap_init := init
