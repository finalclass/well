open Cap_helpers

type model = {
  table_count : int;
  service_health : (string * string) list;
  recent_logs : Well.Cap_hook.Log_buffer.entry list;
  log_count : int;
}

type msg = Refresh

let persistence = Well.LiveView.Ephemeral
let subscriptions = []

let init _req _props =
  let tables = !(Well.Db.registered_tables) in
  let health = Well.Service.health () in
  let logs = Well.Cap_hook.Log_buffer.recent 10 in
  { table_count = List.length tables;
    service_health = health;
    recent_logs = logs;
    log_count = !(Well.Cap_hook.Log_buffer.count); }

let update _req model _msg =
  ignore model;
  let tables = !(Well.Db.registered_tables) in
  let health = Well.Service.health () in
  let logs = Well.Cap_hook.Log_buffer.recent 10 in
  { table_count = List.length tables;
    service_health = health;
    recent_logs = logs;
    log_count = !(Well.Cap_hook.Log_buffer.count); }

let handle_params _req model = model
let temporary_assigns model = model

let view model =
  let services_count = List.length model.service_health in
  let running =
    List.length (List.filter (fun (_, s) -> s = "running") model.service_health)
  in
  let stats_html = Printf.sprintf
    {|<div class="stat-grid">
      <div class="stat-card">
        <div class="stat-label">Tables</div>
        <div class="stat-value accent" data-lv="ov-tables">%d</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Services</div>
        <div class="stat-value" data-lv="ov-services">%d / %d</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Log entries</div>
        <div class="stat-value green" data-lv="ov-reqs">%d</div>
      </div>
    </div>|}
    model.table_count running services_count model.log_count
  in
  let health_rows =
    if model.service_health = [] then
      {|<tr><td colspan="2" style="color:var(--text-muted)">No services registered</td></tr>|}
    else
      String.concat ""
        (List.map (fun (name, st) ->
          let dot_color =
            if st = "running" then "green"
            else if String.length st > 5 && String.sub st 0 4 = "down" then "red"
            else "amber"
          in
          Printf.sprintf {|<tr><td>%s%s</td><td>%s</td></tr>|}
            (status_dot dot_color) (esc name) (esc st)
        ) model.service_health)
  in
  let log_rows =
    if model.recent_logs = [] then
      {|<div class="empty-state"><div class="icon">&#9776;</div><p>No log entries yet</p></div>|}
    else
      let entries = String.concat ""
        (List.map (fun (e : Well.Cap_hook.Log_buffer.entry) ->
          Printf.sprintf
            {|<div class="log-entry"><span class="log-time">%s</span>%s<span class="log-path">%s</span></div>|}
            (format_time e.timestamp) (level_badge e.level)
            (esc e.message)
        ) model.recent_logs)
      in
      Printf.sprintf {|<div class="log-stream" style="max-height:300px">%s</div>|} entries
  in
  `Html (Printf.sprintf
    {|<div>%s
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px">
        <div class="card">
          <div class="card-title">Services</div>
          <table class="data-table"><thead><tr><th>Name</th><th>Status</th></tr></thead><tbody data-lv="ov-health">%s</tbody></table>
        </div>
        <div class="card">
          <div class="card-title">Recent logs</div>
          <div data-lv="ov-logs">%s</div>
        </div>
      </div>
    </div>|}
    stats_html health_rows log_rows)

let model_to_yojson m =
  `Assoc [("table_count", `Int m.table_count);
          ("log_count", `Int m.log_count)]

let model_of_yojson _j = Error "ephemeral"

let msg_of_yojson j =
  match j with
  | `List [`String "Refresh"] -> Ok Refresh
  | _ -> Ok Refresh
