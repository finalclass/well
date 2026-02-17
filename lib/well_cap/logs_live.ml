open Cap_helpers

type model = {
  entries : Well.Cap_hook.Log_buffer.entry list;
  filter_path : string;
  filter_method : string;
}

type msg =
  | NewLog of Well.Cap_hook.Log_buffer.entry
  | Clear

let persistence = Well.LiveView.Ephemeral
let subscriptions = []
let max_entries = 500

let init _req _props =
  let entries = Well.Cap_hook.Log_buffer.recent 100 in
  { entries; filter_path = ""; filter_method = "" }

let update _req model msg =
  match msg with
  | NewLog entry ->
      let entries = entry :: model.entries in
      let entries =
        if List.length entries > max_entries then
          List.filteri (fun i _ -> i < max_entries) entries
        else entries
      in
      { model with entries }
  | Clear -> { model with entries = [] }

let handle_params _req model = model
let temporary_assigns model = model

let view model =
  let filtered =
    List.filter (fun (e : Well.Cap_hook.Log_buffer.entry) ->
      (model.filter_path = "" ||
       (try ignore (Str.search_forward
          (Str.regexp_string model.filter_path) e.path 0); true
        with Not_found -> false)) &&
      (model.filter_method = "" ||
       String.uppercase_ascii e.meth = String.uppercase_ascii model.filter_method)
    ) model.entries
  in
  let entries_html =
    if filtered = [] then
      {|<div class="empty-state"><div class="icon">&#9776;</div><p>No log entries</p></div>|}
    else
      String.concat ""
        (List.map (fun (e : Well.Cap_hook.Log_buffer.entry) ->
          Printf.sprintf
            {|<div class="log-entry"><span class="log-time">%s</span><span class="log-method">%s</span><span class="log-path">%s</span><span class="log-status %s">%d</span><span class="log-duration">%.1fms</span></div>|}
            (format_time e.timestamp) (method_badge e.meth)
            (esc e.path) (status_class e.status) e.status e.duration_ms
        ) filtered)
  in
  `Html (Printf.sprintf
    {|<div class="card">
      <div class="flex items-center justify-between mb-3">
        <div class="card-title" style="margin-bottom:0">HTTP Request Log</div>
        <div class="flex gap-2 items-center">
          <span style="font-size:12px;color:var(--text-muted);font-family:var(--mono)" data-lv="log-count">%d entries</span>
          <button class="btn btn-sm" data-lv-click="[\"Clear\"]">Clear</button>
        </div>
      </div>
      <div class="log-stream" data-lv="log-entries">%s</div>
    </div>|}
    (List.length filtered) entries_html)

let model_to_yojson _m = `Null
let model_of_yojson _j = Error "ephemeral"

let msg_of_yojson j =
  match j with
  | `List [`String "Clear"] -> Ok Clear
  | `Assoc kvs ->
      let meth = match List.assoc_opt "meth" kvs with
        | Some (`String s) -> s | _ -> "" in
      let path = match List.assoc_opt "path" kvs with
        | Some (`String s) -> s | _ -> "" in
      let status = match List.assoc_opt "status" kvs with
        | Some (`Int i) -> i | _ -> 0 in
      let duration_ms = match List.assoc_opt "duration_ms" kvs with
        | Some (`Float f) -> f | _ -> 0.0 in
      let timestamp = match List.assoc_opt "timestamp" kvs with
        | Some (`Float f) -> f | _ -> Unix.gettimeofday () in
      let id = match List.assoc_opt "id" kvs with
        | Some (`Int i) -> i | _ -> 0 in
      Ok (NewLog { Well.Cap_hook.Log_buffer.id; meth; path; status;
                   duration_ms; timestamp })
  | _ -> Error "unknown msg"
