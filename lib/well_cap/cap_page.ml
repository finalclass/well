let cap_page ~path ~title ~endpoint =
  let esc = Html.escape_html in
  let content =
    Printf.sprintf
      {|<live-view data-liveview="%s" data-topic="%s" data-props="{}"></live-view>|}
      (esc endpoint) (esc endpoint)
  in
  Cap_layout.cap_layout ~active_path:path ~title ~content
