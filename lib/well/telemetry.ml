(* Telemetry — Atomic counters + system metrics for Cap admin *)

(* ── Atomic counters (lock-free hot path) ─────────────────────────── *)

let http_requests = Atomic.make 0
let http_errors_5xx = Atomic.make 0
let http_latency_sum_us = Atomic.make 0
let ws_messages_received = Atomic.make 0
let bus_events_published = Atomic.make 0

let incr_requests () = Atomic.incr http_requests
let incr_errors () = Atomic.incr http_errors_5xx
let add_latency_us us = ignore (Atomic.fetch_and_add http_latency_sum_us us)
let incr_ws_messages () = Atomic.incr ws_messages_received
let incr_bus_events () = Atomic.incr bus_events_published

type counter_snapshot = {
  total_requests : int;
  errors_5xx : int;
  avg_latency_us : int;
  ws_messages : int;
  bus_events : int;
}

let snapshot_counters () =
  let total = Atomic.get http_requests in
  let errors = Atomic.get http_errors_5xx in
  let lat_sum = Atomic.get http_latency_sum_us in
  let avg = if total > 0 then lat_sum / total else 0 in
  { total_requests = total;
    errors_5xx = errors;
    avg_latency_us = avg;
    ws_messages = Atomic.get ws_messages_received;
    bus_events = Atomic.get bus_events_published }

(* ── Requests per second (delta-based) ────────────────────────────── *)

let _prev_requests = ref 0
let _prev_time = ref 0.0

let requests_per_sec () =
  let now = Unix.gettimeofday () in
  let cur = Atomic.get http_requests in
  let dt = now -. !_prev_time in
  let rps =
    if dt > 0.01 then
      float_of_int (cur - !_prev_requests) /. dt
    else 0.0
  in
  _prev_requests := cur;
  _prev_time := now;
  rps

(* ── /proc readers (Linux, graceful fallback) ─────────────────────── *)

let _prev_cpu_total = ref 0
let _prev_cpu_time = ref 0.0

let cpu_percent () =
  try
    let ic = open_in "/proc/self/stat" in
    let line = input_line ic in
    close_in ic;
    (* Fields after last ')': skip comm field which may contain spaces *)
    let i = String.rindex line ')' in
    let rest = String.sub line (i + 2) (String.length line - i - 2) in
    let fields = String.split_on_char ' ' rest in
    let arr = Array.of_list fields in
    (* utime=field[11], stime=field[12] after the state field (index 0) *)
    let utime = int_of_string arr.(11) in
    let stime = int_of_string arr.(12) in
    let total = utime + stime in
    let now = Unix.gettimeofday () in
    let dt = now -. !_prev_cpu_time in
    let pct =
      if dt > 0.01 && !_prev_cpu_total > 0 then begin
        let ticks_per_sec = 100 in (* sysconf(_SC_CLK_TCK), typically 100 *)
        let dticks = total - !_prev_cpu_total in
        float_of_int dticks /. (dt *. float_of_int ticks_per_sec) *. 100.0
      end else 0.0
    in
    _prev_cpu_total := total;
    _prev_cpu_time := now;
    pct
  with _ -> -1.0

let rss_kb () =
  try
    let ic = open_in "/proc/self/status" in
    let rec scan () =
      let line = input_line ic in
      if String.length line > 6 && String.sub line 0 6 = "VmRSS:" then begin
        close_in ic;
        Scanf.sscanf (String.trim (String.sub line 6 (String.length line - 6)))
          "%d" (fun n -> n)
      end else scan ()
    in
    scan ()
  with _ -> 0

let load_average () =
  try
    let ic = open_in "/proc/loadavg" in
    let line = input_line ic in
    close_in ic;
    Scanf.sscanf line "%f %f %f" (fun a b c -> (a, b, c))
  with _ -> (0.0, 0.0, 0.0)

let system_memory_kb () =
  try
    let ic = open_in "/proc/meminfo" in
    let total = ref 0 in
    let available = ref 0 in
    let rec scan () =
      let line = input_line ic in
      if String.length line > 9 && String.sub line 0 9 = "MemTotal:" then
        total := Scanf.sscanf
          (String.trim (String.sub line 9 (String.length line - 9)))
          "%d" (fun n -> n)
      else if String.length line > 13 && String.sub line 0 13 = "MemAvailable:" then
        available := Scanf.sscanf
          (String.trim (String.sub line 13 (String.length line - 13)))
          "%d" (fun n -> n);
      if !total > 0 && !available > 0 then (close_in ic; (!total, !available))
      else scan ()
    in
    scan ()
  with _ -> (0, 0)

let data_dir_size_bytes () =
  try
    let dir = "data" in
    let dh = Unix.opendir dir in
    let total = ref 0 in
    (try while true do
       let name = Unix.readdir dh in
       if name <> "." && name <> ".." then begin
         try
           let st = Unix.stat (Filename.concat dir name) in
           if st.Unix.st_kind = Unix.S_REG then
             total := !total + st.Unix.st_size
         with _ -> ()
       end
     done with End_of_file -> ());
    Unix.closedir dh;
    !total
  with _ -> 0

(* ── System snapshot ──────────────────────────────────────────────── *)

type system_snapshot = {
  cpu_pct : float;
  rss_mb : float;
  heap_mb : float;
  live_mb : float;
  gc_major : int;
  gc_minor : int;
  gc_compactions : int;
  load_1m : float;
  load_5m : float;
  load_15m : float;
  sys_mem_total_mb : float;
  sys_mem_available_mb : float;
  data_dir_mb : float;
  uptime_s : float;
}

let system_snapshot () =
  let gc = Gc.stat () in
  let ws = float_of_int Sys.word_size /. 8.0 in
  let heap_mb = float_of_int gc.Gc.heap_words *. ws /. 1048576.0 in
  let live_mb = float_of_int gc.Gc.live_words *. ws /. 1048576.0 in
  let l1, l5, l15 = load_average () in
  let mt, ma = system_memory_kb () in
  { cpu_pct = cpu_percent ();
    rss_mb = float_of_int (rss_kb ()) /. 1024.0;
    heap_mb;
    live_mb;
    gc_major = gc.Gc.major_collections;
    gc_minor = gc.Gc.minor_collections;
    gc_compactions = gc.Gc.compactions;
    load_1m = l1; load_5m = l5; load_15m = l15;
    sys_mem_total_mb = float_of_int mt /. 1024.0;
    sys_mem_available_mb = float_of_int ma /. 1024.0;
    data_dir_mb = float_of_int (data_dir_size_bytes ()) /. 1048576.0;
    uptime_s = Unix.gettimeofday () -. !(Cap_hook.start_time) }
