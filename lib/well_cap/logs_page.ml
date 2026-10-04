open Cap_helpers

type model =
  { entries: Well.Cap_hook.Log_buffer.entry list
  ; level_filter: string
  ; search: string
  ; jump_target: int }

type msg =
  | Clear
  | SetLevel of string
  | SetSearch of string
  | JumpTo of string

let load_entries level search =
  Well.Cap_hook.Log_buffer.recent_filtered ~n:200 ~level ~search ()

let parse_datetime_local s =
  try
    Scanf.sscanf s "%d-%d-%dT%d:%d" (fun y mo d h mi ->
        let tm =
          { Unix.tm_sec= 0
          ; tm_min= mi
          ; tm_hour= h
          ; tm_mday= d
          ; tm_mon= mo - 1
          ; tm_year= y - 1900
          ; tm_wday= 0
          ; tm_yday= 0
          ; tm_isdst= false }
        in
        let t, _ = Unix.mktime tm in
        Some t )
  with
  | _ -> None

let init _req _props =
  ( { entries= load_entries "all" ""
    ; level_filter= "all"
    ; search= ""
    ; jump_target= -1 }
  , [] )

let update _req model msg =
  match msg with
  | Clear -> {model with entries= []; jump_target= -1}
  | SetLevel level ->
      { model with
        level_filter= level
      ; jump_target= -1
      ; entries= load_entries level model.search }
  | SetSearch search ->
      { model with
        search
      ; jump_target= -1
      ; entries= load_entries model.level_filter search }
  | JumpTo dt_str -> (
    match parse_datetime_local dt_str with
    | Some ts ->
        let entries, target_id =
          Well.Cap_hook.Log_buffer.around ~target_ts:ts ~n:200
        in
        {model with entries; jump_target= target_id}
    | None -> model )

let format_time ts =
  let t = Unix.localtime ts in
  Printf.sprintf "%02d:%02d:%02d" t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

let render_ctx (ctx : (string * string) list) =
  if ctx = []
  then ""
  else
    let pairs =
      String.concat
        " "
        (List.map
           (fun (k, v) ->
             Printf.sprintf
               {|<span class="log-ctx-key">%s</span>=<span class="log-ctx-val">%s</span>|}
               (esc k)
               (esc v) )
           ctx )
    in
    Printf.sprintf {|<span class="log-ctx">%s</span>|} pairs

let render_entry ~jump_target (e : Well.Cap_hook.Log_buffer.entry) =
  let highlight = if e.id = jump_target then " log-jump-target" else "" in
  Printf.sprintf
    {|<div class="log-entry%s" data-id="%d"><span class="log-time">%s</span>%s%s<span class="log-msg">%s</span></div>|}
    highlight
    e.id
    (format_time e.timestamp)
    (level_badge e.level)
    (render_ctx e.ctx)
    (esc e.message)

let view req model =
  let options =
    String.concat
      ""
      (List.map
         (fun level ->
           Printf.sprintf
             {|<option value="%s"%s>%s</option>|}
             level
             (if model.level_filter = level then " selected" else "")
             level )
         ["all"; "info"; "warn"; "error"] )
  in
  let filters =
    Printf.sprintf
      {|<form method="get" action="/_cap/logs" class="log-filters" style="flex-wrap:wrap">
    <select name="level" class="input" aria-label="Poziom">%s</select>
    <input name="q" class="input log-search-input" placeholder="Szukaj w logach..." value="%s" />
    <input name="at" type="datetime-local" class="input log-jump-input" value="%s" aria-label="Przejdź do daty" />
    <button class="btn btn-sm" type="submit">Filtruj</button>%s</form>|}
      options
      (esc model.search)
      (esc (query req "at"))
      (link "/_cap/logs" "Reset")
  in
  html_raw
    ( filters
    ^ String.concat
        ""
        (List.map (render_entry ~jump_target:model.jump_target) model.entries)
    )
