open Cap_helpers

type model = {routes: (string * string * string) list}

type msg = Refresh

let init _req _props = ({routes= Well.list_routes ()}, [])

let update _req _model _msg = {routes= Well.list_routes ()}

let kind_badge k =
  let cls =
    match k with
    | "handler" -> "badge-get"
    | "cap" -> "badge-put"
    | "websocket" -> "badge-post"
    | _ -> "badge-head"
  in
  Printf.sprintf {|<span class="badge %s">%s</span>|} cls (esc k)

let view model =
  let rows =
    if model.routes = []
    then
      {|<tr><td colspan="3" style="color:var(--text-muted)">No routes registered</td></tr>|}
    else
      String.concat
        ""
        (List.map
           (fun (meth, path, kind) ->
             Printf.sprintf
               {|<tr><td>%s</td><td style="font-family:var(--mono)">%s</td><td>%s</td></tr>|}
               (method_badge meth)
               (esc path)
               (kind_badge kind) )
           model.routes )
  in
  let count = List.length model.routes in

  html_raw
    (Printf.sprintf
       {|<div>
      <div class="stat-grid">
        <div class="stat-card">
          <div class="stat-label">Total Routes</div>
          <div class="stat-value accent">%d</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Strony HTTP</div>
          <div class="stat-value green">%d</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">WebSocket</div>
          <div class="stat-value">%d</div>
        </div>
      </div>
      <div class="card">
        <div class="card-title">Registered Routes</div>
        <table class="data-table">
          <thead><tr><th>Method</th><th>Path</th><th>Kind</th></tr></thead>
          <tbody>%s</tbody>
        </table>
      </div>
    </div>|}
       count
       (List.length
          (List.filter
             (fun (_, _, k) -> k = "handler" || k = "cap")
             model.routes ) )
       (List.length
          (List.filter (fun (_, _, k) -> k = "websocket") model.routes) )
       rows )
