open Cap_helpers

type model = {
  messages : (string * string * float) list;
}

type msg =
  | NewMessage of string * string * float
  | Clear

let persistence = Well.LiveView.Ephemeral
let max_messages = 200

let init _req _props =
  ({ messages = [] }, [])

let update _req model msg =
  match msg with
  | NewMessage (ch, payload, ts) ->
      let msgs = (ch, payload, ts) :: model.messages in
      let msgs =
        if List.length msgs > max_messages then
          List.filteri (fun i _ -> i < max_messages) msgs
        else msgs
      in
      { messages = msgs }
  | Clear -> { messages = [] }

let handle_params _req model = model
let temporary_assigns model = model

let view model =
  let content =
    if model.messages = [] then
      {|<div class="empty-state"><div class="icon">&#9993;</div><p>Listening for MessageBus events...</p><p style="font-size:11px;margin-top:4px">Events will appear here in real-time</p></div>|}
    else
      let entries = String.concat ""
        (List.map (fun (ch, payload, ts) ->
          Printf.sprintf
            {|<div class="msg-entry"><div class="flex items-center justify-between"><span class="msg-channel">%s</span><span class="log-time">%s</span></div><div class="msg-payload">%s</div></div>|}
            (esc ch) (format_time ts) (esc payload)
        ) model.messages)
      in
      Printf.sprintf
        {|<div class="log-stream" style="max-height:600px">%s</div>|}
        entries
  in
  
html_raw (Printf.sprintf
    {|<div class="card">
      <div class="flex items-center justify-between mb-3">
        <div class="card-title" style="margin-bottom:0">MessageBus Events</div>
        <button class="btn btn-sm" data-lv-click="[&quot;Clear&quot;]">Clear</button>
      </div>
      <div data-lv="msg-stream">%s</div>
    </div>|}
    content)

let model_to_yojson _m = `Null
let model_of_yojson _j = Error "ephemeral"

let msg_of_yojson j =
  match j with
  | `List [`String "Clear"] -> Ok Clear
  | `Assoc kvs ->
      let ch = match List.assoc_opt "channel" kvs with
        | Some (`String s) -> s | _ -> "?" in
      let payload = match List.assoc_opt "payload" kvs with
        | Some (`String s) -> s | _ -> "" in
      let ts = match List.assoc_opt "timestamp" kvs with
        | Some (`Float f) -> f | _ -> Unix.gettimeofday () in
      Ok (NewMessage (ch, payload, ts))
  | _ -> Error "unknown msg"
