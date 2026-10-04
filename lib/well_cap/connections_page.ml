open Cap_helpers

let view () =
  html_raw
    (Printf.sprintf
       {|<div class="stat-grid">
      <div class="stat-card"><div class="stat-label">HTTP</div><div class="stat-value accent">%d</div></div>
      <div class="stat-card"><div class="stat-label">WebSocket</div><div class="stat-value green">%d</div></div>
    </div>|}
       (Atomic.get Well.Telemetry.active_connections)
       (Atomic.get Well.Telemetry.active_ws_connections) )
