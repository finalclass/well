open Cap_helpers

type model =
  { sys: Well.Telemetry.system_snapshot
  ; counters: Well.Telemetry.counter_snapshot
  ; rps: float
  ; ws_connections: int
  ; services_running: int
  ; services_total: int }

type msg = Tick

let gather () =
  let sys = Well.Telemetry.system_snapshot () in
  let counters = Well.Telemetry.snapshot_counters () in
  let rps = Well.Telemetry.requests_per_sec () in
  let health = Well.Service.health () in
  let running =
    List.length (List.filter (fun (_, s) -> s = "running") health)
  in
  { sys
  ; counters
  ; rps
  ; ws_connections= Atomic.get Well.Telemetry.active_ws_connections
  ; services_running= running
  ; services_total= List.length health }

let init _req _props = (gather (), [])

let update _req _model _msg = gather ()

let fmt_float1 f = Printf.sprintf "%.1f" f

let fmt_float2 f = Printf.sprintf "%.2f" f

let format_uptime s =
  let s = int_of_float s in
  let d = s / 86400 in
  let h = s mod 86400 / 3600 in
  let m = s mod 3600 / 60 in
  let sec = s mod 60 in
  if d > 0
  then Printf.sprintf "%dd %dh %dm" d h m
  else if h > 0
  then Printf.sprintf "%dh %dm %ds" h m sec
  else if m > 0
  then Printf.sprintf "%dm %ds" m sec
  else Printf.sprintf "%ds" sec

let view model =
  let s = model.sys in
  let c = model.counters in
  let cpu_str = if s.cpu_pct < 0.0 then "n/a" else fmt_float1 s.cpu_pct ^ "%" in
  let latency_str =
    if c.avg_latency_us > 1000
    then fmt_float1 (float_of_int c.avg_latency_us /. 1000.0) ^ " ms"
    else string_of_int c.avg_latency_us ^ " us"
  in
  let errors_cls = if c.errors_5xx > 0 then " red" else "" in
  let load_str =
    Printf.sprintf "%.2f / %.2f / %.2f" s.load_1m s.load_5m s.load_15m
  in

  html_raw
    (Printf.sprintf
       {|<div>
      <div class="card" style="margin-bottom:16px">
        <div class="card-title">HTTP</div>
        <div class="stat-grid">
          <div class="stat-card">
            <div class="stat-label">Total requests</div>
            <div class="stat-value accent">%d</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Requests/sec</div>
            <div class="stat-value green">%s</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">5xx errors</div>
            <div class="stat-value%s">%d</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Avg latency</div>
            <div class="stat-value">%s</div>
          </div>
        </div>
      </div>
      <div class="card" style="margin-bottom:16px">
        <div class="card-title">System</div>
        <div class="stat-grid">
          <div class="stat-card">
            <div class="stat-label">CPU</div>
            <div class="stat-value accent">%s</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">RSS</div>
            <div class="stat-value">%s MB</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Heap / Live</div>
            <div class="stat-value">%s / %s MB</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Load avg</div>
            <div class="stat-value" style="font-size:14px">%s</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">System memory</div>
            <div class="stat-value" style="font-size:14px">%s / %s GB</div>
          </div>
        </div>
      </div>
      <div class="card" style="margin-bottom:16px">
        <div class="card-title">Framework</div>
        <div class="stat-grid">
          <div class="stat-card">
            <div class="stat-label">WS connections</div>
            <div class="stat-value">%d</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">WS messages</div>
            <div class="stat-value">%d</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Bus events</div>
            <div class="stat-value">%d</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Services</div>
            <div class="stat-value">%d / %d</div>
          </div>
        </div>
      </div>
      <div class="card">
        <div class="card-title">Runtime</div>
        <div class="stat-grid">
          <div class="stat-card">
            <div class="stat-label">GC major</div>
            <div class="stat-value">%d</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">GC minor</div>
            <div class="stat-value">%d</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Compactions</div>
            <div class="stat-value">%d</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Data dir</div>
            <div class="stat-value">%s MB</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Uptime</div>
            <div class="stat-value green">%s</div>
          </div>
        </div>
      </div>
    </div>|}
       c.total_requests
       (fmt_float1 model.rps)
       errors_cls
       c.errors_5xx
       (esc latency_str)
       (esc cpu_str)
       (fmt_float1 s.rss_mb)
       (fmt_float1 s.heap_mb)
       (fmt_float1 s.live_mb)
       load_str
       (fmt_float2 (s.sys_mem_available_mb /. 1024.0))
       (fmt_float2 (s.sys_mem_total_mb /. 1024.0))
       model.ws_connections
       c.ws_messages
       c.bus_events
       model.services_running
       model.services_total
       s.gc_major
       s.gc_minor
       s.gc_compactions
       (fmt_float2 s.data_dir_mb)
       (esc (format_uptime s.uptime_s)) )
