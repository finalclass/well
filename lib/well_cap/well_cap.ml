(* Well_cap — Cap admin panel initialization *)
(* Registers LiveView endpoints, routes, and hooks for /_well/ *)

let seed_cap_user () =
  if not (Well.Auth.has_any_grant "cap") then begin
    match Well.Auth.create_seed_user ~login:"cap" ~password:"admin" with
    | Ok user ->
      Well.Auth.grant ~user_id:user.id "cap";
      Printf.printf "[well] cap: created default user cap/admin\n%!"
    | Error _ ->
      (* User "cap" exists but has no cap grant — grant it *)
      match Well.Auth.find_user_by_email "cap" with
      | Some user ->
        Well.Auth.grant ~user_id:user.id "cap";
        Printf.printf "[well] cap: granted 'cap' to existing user\n%!"
      | None -> ()
  end

let init () =
  Well.Cap_hook.start_time := Unix.gettimeofday ();
  seed_cap_user ();
  (* Register LiveView endpoints *)
  Well.LiveView.register "/live/_well/" (module Overview_live);
  Well.LiveView.register "/live/_well/routes" (module Routes_live);
  Well.LiveView.register "/live/_well/connections" (module Connections_live);
  Well.LiveView.register "/live/_well/db" (module Db_live);
  Well.LiveView.register "/live/_well/services" (module Services_live);
  Well.LiveView.register "/live/_well/messages" (module Messages_live);
  Well.LiveView.register "/live/_well/logs" (module Logs_live);
  Well.LiveView.register "/live/_well/telemetry" (module Telemetry_live);
  Well.LiveView.register "/live/_well/repl" (module Repl_live);
  Well.LiveView.register "/live/_well/users" (module Users_live);
  (* Serve embedded well.js — no auth needed for static asset *)
  !(Well.Cap_hook._register_cap_get) "/_well/well.js" (fun _req ->
    Well.Cap_hook.CRJs Cap_js.js);
  (* Login routes — no auth *)
  !(Well.Cap_hook._register_cap_get) "/_well/login" (fun _req ->
    Well.Cap_hook.CRHtml (Cap_login.login_page ()));
  !(Well.Cap_hook._register_cap_post) "/_well/login" (fun req ->
    let pairs = String.split_on_char '&' req.body in
    let get_field name =
      List.fold_left (fun acc pair ->
        match String.index_opt pair '=' with
        | Some i ->
            let k = String.sub pair 0 i in
            let v = String.sub pair (i + 1) (String.length pair - i - 1) in
            if k = name then Well.url_decode v else acc
        | None -> acc
      ) "" pairs
    in
    let email = get_field "email" in
    let password = get_field "password" in
    if email = "" then
      Well.Cap_hook.CRHtml (Cap_login.login_page
        ~error:"Login is required" ())
    else
      match Well.Auth.login_and_set_session req ~email ~password with
      | Ok user ->
        if Well.Auth.has_grant ~user_id:user.id "cap" then
          Well.Cap_hook.CRRedirect "/_well/"
        else begin
          Well.Auth.logout req;
          Well.Cap_hook.CRHtml (Cap_login.login_page
            ~error:"Access denied (requires 'cap' grant)" ())
        end
      | Error _ ->
        Well.Cap_hook.CRHtml (Cap_login.login_page
          ~error:"Invalid login or password" ()));
  (* Logout route *)
  !(Well.Cap_hook._register_cap_get) "/_well/logout" (fun req ->
    Well.Auth.logout req;
    Well.Cap_hook.CRRedirect "/_well/login");
  (* Cap page routes — with auth *)
  let authed handler req = Cap_auth.cap_auth_mw handler req in
  !(Well.Cap_hook._register_cap_get) "/_well/" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_well/" ~title:"Overview"
              ~endpoint:"/live/_well/")));
  !(Well.Cap_hook._register_cap_get) "/_well/routes" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_well/routes" ~title:"Routes"
              ~endpoint:"/live/_well/routes")));
  !(Well.Cap_hook._register_cap_get) "/_well/connections" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_well/connections" ~title:"Connections"
              ~endpoint:"/live/_well/connections")));
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
  !(Well.Cap_hook._register_cap_get) "/_well/telemetry" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_well/telemetry" ~title:"Telemetry"
              ~endpoint:"/live/_well/telemetry")));
  !(Well.Cap_hook._register_cap_get) "/_well/repl" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_well/repl" ~title:"REPL"
              ~endpoint:"/live/_well/repl")));
  !(Well.Cap_hook._register_cap_get) "/_well/users" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_well/users" ~title:"Users"
              ~endpoint:"/live/_well/users")));
  (* Logs pagination API *)
  !(Well.Cap_hook._register_cap_get) "/_well/api/logs" (authed (fun req ->
    let before_id = match Well.query req "before" with
      | Some s -> (try int_of_string s with _ -> !(Well.Cap_hook.Log_buffer.count))
      | None -> !(Well.Cap_hook.Log_buffer.count)
    in
    let n = match Well.query req "count" with
      | Some s -> (try min 200 (int_of_string s) with _ -> 100)
      | None -> 100
    in
    let entries = Well.Cap_hook.Log_buffer.before ~before_id ~n in
    let json = "[" ^ String.concat ","
      (List.map Well.Cap_hook.Log_buffer.entry_to_json entries) ^ "]" in
    Well.Cap_hook.CRJson json));
  (* Load historical logs from well.log file *)
  Well.Cap_hook.Log_buffer.load_from_file "well.log";
  (* Set up log hook for real-time new_log events *)
  Well.Log._hook := Some (fun ts level msg ctx ->
    let entry = Well.Cap_hook.Log_buffer.push ~level ~message:msg ~timestamp:ts ~ctx () in
    let ctx_json = `Assoc (List.map (fun (k, v) -> (k, `String v)) ctx) in
    Well.LiveView.send_event "/live/_well/logs" "new_log"
      (`Assoc [
        ("id", `Int entry.id);
        ("level", `String level);
        ("message", `String msg);
        ("timestamp", `Float ts);
        ("ctx", ctx_json);
      ]));
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
  Printf.printf "[well] cap at /_well/\n%!"

(* Register init at module load time — well.ml calls !Cap_hook._cap_init () *)
let () = Well.Cap_hook._cap_init := init
