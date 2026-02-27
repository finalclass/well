open Cap_helpers

type model = {
  entries : Well.Cap_hook.Log_buffer.entry list;
  level_filter : string;
  search : string;
  jump_target : int;  (* entry id to scroll to, -1 = none *)
}

type msg =
  | Clear
  | SetLevel of string
  | SetSearch of string
  | JumpTo of string   (* "YYYY-MM-DDTHH:MM" from datetime-local input *)

let persistence = Well.LiveView.Ephemeral

let load_entries level search =
  Well.Cap_hook.Log_buffer.recent_filtered ~n:200 ~level ~search ()

let parse_datetime_local s =
  (* "2026-02-18T20:45" → Unix timestamp *)
  try
    Scanf.sscanf s "%d-%d-%dT%d:%d"
      (fun y mo d h mi ->
        let tm = { Unix.tm_sec = 0; tm_min = mi; tm_hour = h;
                   tm_mday = d; tm_mon = mo - 1; tm_year = y - 1900;
                   tm_wday = 0; tm_yday = 0; tm_isdst = false } in
        let (t, _) = Unix.mktime tm in
        Some t)
  with _ -> None

let init _req _props =
  ({ entries = load_entries "all" "";
     level_filter = "all"; search = ""; jump_target = -1 }, [])

let update _req model msg =
  match msg with
  | Clear -> { model with entries = []; jump_target = -1 }
  | SetLevel level ->
      { model with level_filter = level; jump_target = -1;
        entries = load_entries level model.search }
  | SetSearch search ->
      { model with search; jump_target = -1;
        entries = load_entries model.level_filter search }
  | JumpTo dt_str ->
      match parse_datetime_local dt_str with
      | Some ts ->
          let (entries, target_id) =
            Well.Cap_hook.Log_buffer.around ~target_ts:ts ~n:200
          in
          { model with entries; jump_target = target_id }
      | None -> model

let handle_params _req model = model
let temporary_assigns model = model

let format_time ts =
  let t = Unix.localtime ts in
  Printf.sprintf "%02d:%02d:%02d" t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

let render_ctx (ctx : (string * string) list) =
  if ctx = [] then ""
  else
    let pairs = String.concat " "
      (List.map (fun (k, v) ->
        Printf.sprintf {|<span class="log-ctx-key">%s</span>=<span class="log-ctx-val">%s</span>|}
          (esc k) (esc v)
      ) ctx)
    in
    Printf.sprintf {|<span class="log-ctx">%s</span>|} pairs

let render_entry ~jump_target (e : Well.Cap_hook.Log_buffer.entry) =
  let highlight = if e.id = jump_target then " log-jump-target" else "" in
  Printf.sprintf
    {|<div class="log-entry%s" data-id="%d"><span class="log-time">%s</span>%s%s<span class="log-msg">%s</span></div>|}
    highlight e.id (format_time e.timestamp) (level_badge e.level) (render_ctx e.ctx) (esc e.message)

let view model =
  let entries_html =
    if model.entries = [] then ""
    else String.concat "" (List.map (render_entry ~jump_target:model.jump_target) model.entries)
  in
  let level_btn level label =
    let active = if model.level_filter = level then " active" else "" in
    Printf.sprintf
      {|<button class="tab-bar-btn%s" data-lv-click="%s">%s</button>|}
      active (esc (Printf.sprintf {|["SetLevel","%s"]|} level)) (esc label)
  in
  `Html (Printf.sprintf
    {|<div class="log-viewer">
      <div class="log-header">
        <div class="card-title" style="margin-bottom:0">Application Logs</div>
        <div class="flex gap-2 items-center">
          <span class="log-counter" data-lv="log-count">%d entries</span>
          <button class="btn btn-sm" data-lv-click="[&quot;Clear&quot;]">Clear</button>
        </div>
      </div>
      <div class="log-filters">
        <div class="log-filter-tabs" data-lv="log-level-tabs">
          %s%s%s%s
        </div>
        <input class="input log-jump-input" type="datetime-local" step="1"
          data-lv-change="JumpTo" />
        <input class="input log-search-input" type="text" placeholder="Search logs..."
          value="%s"
          data-lv-change="SetSearch"
          data-lv-debounce="300" />
      </div>
      <div class="log-stream" data-lv="log-entries" data-lv-hook="LogViewer"
        data-level="%s" data-search="%s" data-jump="%d">%s</div>
    </div>|}
    (List.length model.entries)
    (level_btn "all" "All")
    (level_btn "error" "Error")
    (level_btn "warn" "Warn")
    (level_btn "info" "Info")
    (esc model.search)
    (esc model.level_filter)
    (esc model.search)
    model.jump_target
    entries_html)

let model_to_yojson _m = `Null
let model_of_yojson _j = Error "ephemeral"

let msg_of_yojson j =
  match j with
  | `List [`String "Clear"] -> Ok Clear
  | `List [`String "SetLevel"; `String level] -> Ok (SetLevel level)
  | `List [`String "SetSearch"; `String s] -> Ok (SetSearch s)
  | `List [`String "JumpTo"; `String s] -> Ok (JumpTo s)
  | _ -> Error "unknown msg"
