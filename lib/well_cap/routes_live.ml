open Cap_helpers

type model = {
  routes : (string * string * string) list;
}

type msg = Refresh

let persistence = Well.LiveView.Ephemeral

let init _req _props =
  ({ routes = Well.list_routes () }, [])

let update _req _model _msg =
  { routes = Well.list_routes () }

let handle_params _req model = model
let temporary_assigns model = model

let kind_badge k =
  let cls = match k with
    | "handler" -> "badge-get"
    | "cap" -> "badge-put"
    | "websocket" -> "badge-post"
    | "liveview" -> "badge-accent"
    | _ -> "badge-head"
  in
  Printf.sprintf {|<span class="badge %s">%s</span>|} cls (esc k)

let view model =
  let rows =
    if model.routes = [] then
      {|<tr><td colspan="3" style="color:var(--text-muted)">No routes registered</td></tr>|}
    else
      String.concat ""
        (List.map (fun (meth, path, kind) ->
          Printf.sprintf {|<tr><td>%s</td><td style="font-family:var(--mono)">%s</td><td>%s</td></tr>|}
            (method_badge meth) (esc path) (kind_badge kind)
        ) model.routes)
  in
  let count = List.length model.routes in
  
html_raw (Printf.sprintf
    {|<div>
      <div class="stat-grid">
        <div class="stat-card">
          <div class="stat-label">Total Routes</div>
          <div class="stat-value accent" data-lv="route-count">%d</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">LiveViews</div>
          <div class="stat-value green" data-lv="route-lv">%d</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">WebSocket</div>
          <div class="stat-value" data-lv="route-ws">%d</div>
        </div>
      </div>
      <div class="card">
        <div class="card-title">Registered Routes</div>
        <table class="data-table">
          <thead><tr><th>Method</th><th>Path</th><th>Kind</th></tr></thead>
          <tbody data-lv="route-rows">%s</tbody>
        </table>
      </div>
    </div>|}
    count
    (List.length (List.filter (fun (_, _, k) -> k = "liveview") model.routes))
    (List.length (List.filter (fun (_, _, k) -> k = "websocket") model.routes))
    rows)

let model_to_yojson _m = `Null
let model_of_yojson _j = Error "ephemeral"

let msg_of_yojson _j = Ok Refresh
