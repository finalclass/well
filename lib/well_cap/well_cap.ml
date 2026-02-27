(* Well_cap — Cap admin panel initialization *)
(* Registers LiveView endpoints, routes, and hooks for /_cap/ *)

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
  Well.LiveView.register "/live/_cap/" (module Overview_live);
  Well.LiveView.register "/live/_cap/routes" (module Routes_live);
  Well.LiveView.register "/live/_cap/connections" (module Connections_live);
  Well.LiveView.register "/live/_cap/db" (module Db_live);
  Well.LiveView.register "/live/_cap/services" (module Services_live);
  Well.LiveView.register "/live/_cap/messages" (module Messages_live);
  Well.LiveView.register "/live/_cap/logs" (module Logs_live);
  Well.LiveView.register "/live/_cap/telemetry" (module Telemetry_live);
  Well.LiveView.register "/live/_cap/repl" (module Repl_live);
  Well.LiveView.register "/live/_cap/users" (module Users_live);
  (* Serve embedded well.js — no auth needed for static asset *)
  !(Well.Cap_hook._register_cap_get) "/_cap/well.js" (fun _req ->
    Well.Cap_hook.CRJs Cap_js.js);
  (* Login routes — no auth *)
  !(Well.Cap_hook._register_cap_get) "/_cap/login" (fun _req ->
    Well.Cap_hook.CRHtml (Cap_login.login_page ()));
  !(Well.Cap_hook._register_cap_post) "/_cap/login" (fun req ->
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
          Well.Cap_hook.CRRedirect "/_cap/"
        else begin
          Well.Auth.logout req;
          Well.Cap_hook.CRHtml (Cap_login.login_page
            ~error:"Access denied (requires 'cap' grant)" ())
        end
      | Error _ ->
        Well.Cap_hook.CRHtml (Cap_login.login_page
          ~error:"Invalid login or password" ()));
  (* Logout route *)
  !(Well.Cap_hook._register_cap_get) "/_cap/logout" (fun req ->
    Well.Auth.logout req;
    Well.Cap_hook.CRRedirect "/_cap/login");
  (* Cap page routes — with auth *)
  let authed handler req = Cap_auth.cap_auth_mw handler req in
  !(Well.Cap_hook._register_cap_get) "/_cap/" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_cap/" ~title:"Overview"
              ~endpoint:"/live/_cap/")));
  !(Well.Cap_hook._register_cap_get) "/_cap/routes" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_cap/routes" ~title:"Routes"
              ~endpoint:"/live/_cap/routes")));
  !(Well.Cap_hook._register_cap_get) "/_cap/connections" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_cap/connections" ~title:"Connections"
              ~endpoint:"/live/_cap/connections")));
  !(Well.Cap_hook._register_cap_get) "/_cap/db" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_cap/db" ~title:"Database"
              ~endpoint:"/live/_cap/db")));
  !(Well.Cap_hook._register_cap_get) "/_cap/services" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_cap/services" ~title:"Services"
              ~endpoint:"/live/_cap/services")));
  !(Well.Cap_hook._register_cap_get) "/_cap/messages" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_cap/messages" ~title:"Messages"
              ~endpoint:"/live/_cap/messages")));
  !(Well.Cap_hook._register_cap_get) "/_cap/logs" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_cap/logs" ~title:"Logs"
              ~endpoint:"/live/_cap/logs")));
  !(Well.Cap_hook._register_cap_get) "/_cap/telemetry" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_cap/telemetry" ~title:"Telemetry"
              ~endpoint:"/live/_cap/telemetry")));
  !(Well.Cap_hook._register_cap_get) "/_cap/repl" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_cap/repl" ~title:"REPL"
              ~endpoint:"/live/_cap/repl")));
  !(Well.Cap_hook._register_cap_get) "/_cap/users" (authed (fun _req ->
    Well.Cap_hook.CRHtml (Cap_page.cap_page ~path:"/_cap/users" ~title:"Users"
              ~endpoint:"/live/_cap/users")));
  (* Logs pagination API *)
  !(Well.Cap_hook._register_cap_get) "/_cap/api/logs" (authed (fun req ->
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
    Well.LiveView.send_event "/live/_cap/logs" "new_log"
      (`Assoc [
        ("id", `Int entry.id);
        ("level", `String level);
        ("message", `String msg);
        ("timestamp", `Float ts);
        ("ctx", ctx_json);
      ]));
  (* Set up MessageBus subscriber for Messages LiveView *)
  (* Filter out /_cap/* channels to avoid infinite loop:
     subscribe "*" catches ALL messages including our own publishes *)
  ignore (Well.MessageBus.subscribe "*" (fun event ->
    if not (String.length event.Well.MessageBus.channel >= 11
            && String.sub event.Well.MessageBus.channel 0 11 = "/live/_cap/") then begin
      let msg_json = `Assoc [
        ("channel", `String event.Well.MessageBus.channel);
        ("payload", `String (Yojson.Safe.to_string event.payload));
        ("timestamp", `Float event.created_at);
      ] in
      ignore (Well.MessageBus.publish ~ephemeral:true "/live/_cap/messages" msg_json)
    end));
  Printf.printf "[well] cap at /_cap/\n%!"

(* Register init at module load time — well.ml calls !Cap_hook._cap_init () *)
let () = Well.Cap_hook._cap_init := init
