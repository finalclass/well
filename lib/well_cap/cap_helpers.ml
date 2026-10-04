let esc = Html.escape_html

let html_raw s = Html.raw s

let method_badge m =
  let cls =
    match String.uppercase_ascii m with
    | "GET" -> "badge-get"
    | "POST" -> "badge-post"
    | "PUT" -> "badge-put"
    | "DELETE" -> "badge-delete"
    | _ -> "badge-head"
  in
  Printf.sprintf {|<span class="badge %s">%s</span>|} cls (esc m)

let level_badge l =
  let cls =
    match String.lowercase_ascii l with
    | "error" -> "badge-delete"
    | "warn" -> "badge-put"
    | _ -> "badge-get"
  in
  Printf.sprintf {|<span class="badge %s">%s</span>|} cls (esc l)

let status_class s =
  if s >= 200 && s < 300
  then "s2xx"
  else if s >= 300 && s < 400
  then "s3xx"
  else if s >= 400 && s < 500
  then "s4xx"
  else "s5xx"

let format_time ts =
  let t = Unix.localtime ts in
  Printf.sprintf "%02d:%02d:%02d" t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

let status_dot color =
  Printf.sprintf {|<span class="status-dot %s"></span>|} color

let hidden name value =
  Printf.sprintf
    {|<input type="hidden" name="%s" value="%s" />|}
    (esc name)
    (esc value)

let csrf req = hidden "_csrf_token" (Well.csrf_token req)

let form_open req action =
  Printf.sprintf {|<form method="post" action="%s">%s|} (esc action) (csrf req)

let query req key = Option.value (Well.query req key) ~default:""

let field req key = Option.value (Well.form req key) ~default:""

let url path pairs =
  let pairs = List.filter (fun (_, v) -> v <> "") pairs in
  match pairs with
  | [] -> path
  | _ ->
      path
      ^ "?"
      ^ String.concat
          "&"
          (List.map
             (fun (k, v) -> Well.url_encode k ^ "=" ^ Well.url_encode v)
             pairs )

let link ?(class_ = "btn btn-sm") href label =
  Printf.sprintf
    {|<a class="%s" href="%s">%s</a>|}
    (esc class_)
    (esc href)
    label

let flash req =
  let notice = Option.value (Well.get_flash req "cap") ~default:"" in
  if notice = ""
  then ""
  else
    Printf.sprintf
      {|<div class="mb-3" style="color:var(--green)">%s</div>|}
      (esc notice)
