open Cap_helpers

type model = {
  entries : Well.Cap_hook.Log_buffer.entry list;
}

type msg = Clear

let persistence = Well.LiveView.Ephemeral
let subscriptions = []

let init _req _props =
  let entries = Well.Cap_hook.Log_buffer.recent 100 in
  { entries }

let update _req _model msg =
  match msg with
  | Clear -> { entries = [] }

let handle_params _req model = model
let temporary_assigns model = model

let render_entry (e : Well.Cap_hook.Log_buffer.entry) =
  Printf.sprintf
    {|<div class="log-entry" data-id="%d"><span class="log-time">%s</span>%s<span class="log-msg">%s</span></div>|}
    e.id (format_time e.timestamp) (level_badge e.level) (esc e.message)

let view model =
  let entries_html =
    if model.entries = [] then ""
    else String.concat "" (List.map render_entry model.entries)
  in
  `Html (Printf.sprintf
    {|<div class="log-viewer">
      <div class="log-header">
        <div class="card-title" style="margin-bottom:0">Application Logs</div>
        <div class="flex gap-2 items-center">
          <span class="log-counter" data-lv="log-count">%d entries</span>
          <button class="btn btn-sm" data-lv-click="[\"Clear\"]">Clear</button>
        </div>
      </div>
      <div class="log-stream" data-lv="log-entries" data-lv-hook="LogViewer">%s</div>
    </div>|}
    (List.length model.entries) entries_html)

let model_to_yojson _m = `Null
let model_of_yojson _j = Error "ephemeral"

let msg_of_yojson j =
  match j with
  | `List [`String "Clear"] -> Ok Clear
  | _ -> Error "unknown msg"
