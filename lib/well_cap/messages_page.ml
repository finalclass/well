open Cap_helpers

let view entries =
  html_raw
    (String.concat
       ""
       (List.map
          (fun (channel, payload, time) ->
            Printf.sprintf
              {|<div class="msg-entry"><div class="flex items-center justify-between"><span class="msg-channel">%s</span><span class="log-time">%s</span></div><div class="msg-payload">%s</div></div>|}
              (esc channel)
              (format_time time)
              (esc payload) )
          entries ) )
