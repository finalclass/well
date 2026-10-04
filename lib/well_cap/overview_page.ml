open Cap_helpers

type model =
  { table_count: int
  ; service_health: (string * string) list
  ; recent_logs: Well.Cap_hook.Log_buffer.entry list
  ; log_count: int
  ; uptime_s: float
  ; gc: Gc.stat
  ; ocaml_version: string
  ; ws_connections: int }

type msg = Refresh

let gather () =
  let tables = !Well.Db.registered_tables in
  let health = Well.Service.health () in
  let logs = Well.Cap_hook.Log_buffer.recent 10 in
  { table_count= List.length tables
  ; service_health= health
  ; recent_logs= logs
  ; log_count= !Well.Cap_hook.Log_buffer.count
  ; uptime_s= Unix.gettimeofday () -. !Well.Cap_hook.start_time
  ; gc= Gc.stat ()
  ; ocaml_version= Sys.ocaml_version
  ; ws_connections= Atomic.get Well.Telemetry.active_ws_connections }

let init _req _props = (gather (), [])

let update _req _model _msg = gather ()

let format_uptime s =
  let s = int_of_float s in
  let d = s / 86400 in
  let h = s mod 86400 / 3600 in
  let m = s mod 3600 / 60 in
  if d > 0
  then Printf.sprintf "%dd %dh %dm" d h m
  else if h > 0
  then Printf.sprintf "%dh %dm" h m
  else Printf.sprintf "%dm" m

let format_memory_mb gc =
  let bytes =
    float_of_int gc.Gc.heap_words *. (float_of_int Sys.word_size /. 8.0)
  in
  Printf.sprintf "%.1f MB" (bytes /. 1048576.0)

let view model =
  let services_count = List.length model.service_health in
  let running =
    List.length (List.filter (fun (_, s) -> s = "running") model.service_health)
  in
  let stats_html =
    Printf.sprintf
      {|<div class="stat-grid">
      <div class="stat-card">
        <div class="stat-label">Tables</div>
        <div class="stat-value accent">%d</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Services</div>
        <div class="stat-value">%d / %d</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Log entries</div>
        <div class="stat-value green">%d</div>
      </div>
    </div>|}
      model.table_count
      running
      services_count
      model.log_count
  in
  let sys_html =
    Printf.sprintf
      {|<div class="stat-grid">
      <div class="stat-card">
        <div class="stat-label">Uptime</div>
        <div class="stat-value">%s</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Memory</div>
        <div class="stat-value">%s</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">OCaml</div>
        <div class="stat-value" style="font-size:16px">%s</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Połączenia WS</div>
        <div class="stat-value green">%d</div>
      </div>
    </div>|}
      (format_uptime model.uptime_s)
      (format_memory_mb model.gc)
      (esc model.ocaml_version)
      model.ws_connections
  in
  let health_rows =
    if model.service_health = []
    then
      {|<tr><td colspan="2" style="color:var(--text-muted)">No services registered</td></tr>|}
    else
      String.concat
        ""
        (List.map
           (fun (name, st) ->
             let dot_color =
               if st = "running"
               then "green"
               else if String.length st > 5 && String.sub st 0 4 = "down"
               then "red"
               else "amber"
             in
             Printf.sprintf
               {|<tr><td>%s%s</td><td>%s</td></tr>|}
               (status_dot dot_color)
               (esc name)
               (esc st) )
           model.service_health )
  in
  let log_rows =
    if model.recent_logs = []
    then
      {|<div class="empty-state"><div class="icon">&#9776;</div><p>No log entries yet</p></div>|}
    else
      let entries =
        String.concat
          ""
          (List.map
             (fun (e : Well.Cap_hook.Log_buffer.entry) ->
               Printf.sprintf
                 {|<div class="log-entry"><span class="log-time">%s</span>%s<span class="log-path">%s</span></div>|}
                 (format_time e.timestamp)
                 (level_badge e.level)
                 (esc e.message) )
             model.recent_logs )
      in
      Printf.sprintf
        {|<div class="log-stream" style="max-height:300px">%s</div>|}
        entries
  in

  html_raw
    (Printf.sprintf
       {|<div>%s%s
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px">
        <div class="card">
          <div class="card-title">Services</div>
          <table class="data-table"><thead><tr><th>Name</th><th>Status</th></tr></thead><tbody>%s</tbody></table>
        </div>
        <div class="card">
          <div class="card-title">Recent logs</div>
          <div>%s</div>
        </div>
      </div>
    </div>|}
       stats_html
       sys_html
       health_rows
       log_rows )
