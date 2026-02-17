let esc = Html.escape_html

let method_badge m =
  let cls = match String.uppercase_ascii m with
    | "GET" -> "badge-get" | "POST" -> "badge-post"
    | "PUT" -> "badge-put" | "DELETE" -> "badge-delete"
    | _ -> "badge-head"
  in
  Printf.sprintf {|<span class="badge %s">%s</span>|} cls (esc m)

let status_class s =
  if s >= 200 && s < 300 then "s2xx"
  else if s >= 300 && s < 400 then "s3xx"
  else if s >= 400 && s < 500 then "s4xx"
  else "s5xx"

let format_time ts =
  let t = Unix.gmtime ts in
  Printf.sprintf "%02d:%02d:%02d" t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

let status_dot color =
  Printf.sprintf {|<span class="status-dot %s"></span>|} color

