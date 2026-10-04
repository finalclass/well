open Cap_helpers

let messages = ref []

let message_lock = Mutex.create ()

let push_message channel payload time =
  Mutex.lock message_lock ;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock message_lock)
    (fun () ->
      messages :=
        (channel, payload, time) :: List.filteri (fun i _ -> i < 199) !messages )

let recent_messages () =
  Mutex.lock message_lock ;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock message_lock)
    (fun () -> List.rev !messages)

let logs_model req =
  let model, _ = Logs_page.init req `Null in
  let model =
    Logs_page.update
      req
      model
      (Logs_page.SetLevel
         (query req "level" |> fun s -> if s = "" then "all" else s) )
  in
  let model =
    Logs_page.update req model (Logs_page.SetSearch (query req "q"))
  in
  let model =
    if query req "at" = ""
    then model
    else Logs_page.update req model (Logs_page.JumpTo (query req "at"))
  in
  match int_of_string_opt (query req "before") with
  | None -> model
  | Some before_id ->
      let entries =
        Well.Cap_hook.Log_buffer.before ~before_id:(max 0 before_id) ~n:200
        |> List.filter (fun (e : Well.Cap_hook.Log_buffer.entry) ->
            (model.level_filter = "all" || e.level = model.level_filter)
            && ( model.search = ""
               ||
               try
                 ignore
                   (Str.search_forward
                      (Str.regexp_string_case_fold model.search)
                      e.message
                      0 ) ;
                 true
               with
               | Not_found -> false ) )
      in
      {model with entries}

let logs req =
  let model = logs_model req in
  `List
    (List.map
       (fun (e : Well.Cap_hook.Log_buffer.entry) ->
         `Assoc
           [ ("id", `Int e.id)
           ; ("time", `String (format_time e.timestamp))
           ; ("level", `String e.level)
           ; ("message", `String e.message)
           ; ("ctx", `Assoc (List.map (fun (k, v) -> (k, `String v)) e.ctx))
           ; ("highlight", `String (string_of_bool (e.id = model.jump_target)))
           ] )
       model.entries )

let message_data () =
  `List
    (List.map
       (fun (channel, payload, time) ->
         `Assoc
           [ ("channel", `String channel)
           ; ("payload", `String payload)
           ; ("time", `String (format_time time)) ] )
       (recent_messages ()) )

let telemetry () =
  let m = Telemetry_page.gather () in
  let s = m.sys and c = m.counters in
  let stat ?(class_ = "") ?(style = "") label value =
    `Assoc
      [ ("label", `String label)
      ; ("value", `String value)
      ; ("class", `String class_)
      ; ("style", `String style) ]
  in
  let int = string_of_int and float = Telemetry_page.fmt_float1 in
  let group title stats =
    `Assoc [("title", `String title); ("stats", `List stats)]
  in
  `List
    [ group
        "HTTP"
        [ stat ~class_:"accent" "Total requests" (int c.total_requests)
        ; stat ~class_:"green" "Requests/sec" (float m.rps)
        ; stat
            ~class_:(if c.errors_5xx > 0 then "red" else "")
            "5xx errors"
            (int c.errors_5xx)
        ; stat
            "Avg latency"
            ( if c.avg_latency_us > 1000
              then float (float_of_int c.avg_latency_us /. 1000.) ^ " ms"
              else int c.avg_latency_us ^ " us" ) ]
    ; group
        "System"
        [ stat
            ~class_:"accent"
            "CPU"
            (if s.cpu_pct < 0. then "n/a" else float s.cpu_pct ^ "%")
        ; stat "RSS" (float s.rss_mb ^ " MB")
        ; stat "Heap / Live" (float s.heap_mb ^ " / " ^ float s.live_mb ^ " MB")
        ; stat
            ~style:"font-size:14px"
            "Load avg"
            (Printf.sprintf "%.2f / %.2f / %.2f" s.load_1m s.load_5m s.load_15m)
        ; stat
            ~style:"font-size:14px"
            "System memory"
            ( float (s.sys_mem_available_mb /. 1024.)
            ^ " / "
            ^ float (s.sys_mem_total_mb /. 1024.)
            ^ " GB" ) ]
    ; group
        "Framework"
        [ stat "WS connections" (int m.ws_connections)
        ; stat "WS messages" (int c.ws_messages)
        ; stat "Bus events" (int c.bus_events)
        ; stat "Services" (int m.services_running ^ " / " ^ int m.services_total)
        ]
    ; group
        "Runtime"
        [ stat "GC major" (int s.gc_major)
        ; stat "GC minor" (int s.gc_minor)
        ; stat "Compactions" (int s.gc_compactions)
        ; stat "Data dir" (float s.data_dir_mb ^ " MB")
        ; stat
            ~class_:"green"
            "Uptime"
            (Telemetry_page.format_uptime s.uptime_s) ] ]

let stream kind req data initial =
  let endpoint = url ("/_cap/api/" ^ kind) req.Well.query in
  Printf.sprintf
    {|<cap-stream kind="%s" endpoint="%s" initial="%s">%s</cap-stream>|}
    kind
    (esc endpoint)
    (esc (Yojson.Safe.to_string data))
    initial
