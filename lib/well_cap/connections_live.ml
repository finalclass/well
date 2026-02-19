open Cap_helpers

type model = {
  sessions : (string * string * float) list;
  ws_count : int;
}

type msg = Refresh

let persistence = Well.LiveView.Ephemeral
let subscriptions = []

let init _req _props =
  { sessions = Well.LiveView.list_sessions ();
    ws_count = Well.LiveView.count_connections () }

let update _req _model _msg =
  { sessions = Well.LiveView.list_sessions ();
    ws_count = Well.LiveView.count_connections () }

let handle_params _req model = model
let temporary_assigns model = model

let format_relative now ts =
  let delta = now -. ts in
  if delta < 60.0 then Printf.sprintf "%.0fs ago" delta
  else if delta < 3600.0 then Printf.sprintf "%.0fm ago" (delta /. 60.0)
  else if delta < 86400.0 then Printf.sprintf "%.0fh ago" (delta /. 3600.0)
  else Printf.sprintf "%.0fd ago" (delta /. 86400.0)

let format_idle now ts =
  let d = int_of_float (now -. ts) in
  if d < 60 then Printf.sprintf "%ds" d
  else if d < 3600 then Printf.sprintf "%dm %ds" (d / 60) (d mod 60)
  else Printf.sprintf "%dh %dm" (d / 3600) ((d mod 3600) / 60)

let view model =
  let now = Unix.gettimeofday () in
  let session_count = List.length model.sessions in
  let rows =
    if model.sessions = [] then
      {|<tr><td colspan="4" style="color:var(--text-muted)">No active sessions</td></tr>|}
    else begin
      let sorted = List.sort (fun (_, _, a) (_, _, b) -> compare b a) model.sessions in
      String.concat ""
        (List.map (fun (key, endpoint, last_active) ->
          let short_key =
            if String.length key > 12 then String.sub key 0 12 ^ "..."
            else key
          in
          Printf.sprintf
            {|<tr><td title="%s">%s</td><td style="font-family:var(--mono)">%s</td><td>%s</td><td>%s</td></tr>|}
            (esc key) (esc short_key) (esc endpoint)
            (format_relative now last_active)
            (format_idle now last_active)
        ) sorted)
    end
  in
  `Html (Printf.sprintf
    {|<div>
      <div class="stat-grid">
        <div class="stat-card">
          <div class="stat-label">LiveView Sessions</div>
          <div class="stat-value accent" data-lv="conn-sessions">%d</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">WS Connections</div>
          <div class="stat-value green" data-lv="conn-ws">%d</div>
        </div>
      </div>
      <div class="card">
        <div class="card-title">Active Sessions</div>
        <table class="data-table">
          <thead><tr><th>Session</th><th>Endpoint</th><th>Last Active</th><th>Idle</th></tr></thead>
          <tbody data-lv="conn-rows">%s</tbody>
        </table>
      </div>
    </div>|}
    session_count model.ws_count rows)

let model_to_yojson _m = `Null
let model_of_yojson _j = Error "ephemeral"

let msg_of_yojson _j = Ok Refresh
