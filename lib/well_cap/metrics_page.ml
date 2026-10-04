open Cap_helpers

let windows = [("hour", "Last hour"); ("day", "Last day")]
let classes = [("app", "Application"); ("static", "Static"); ("cap", "CAP")]

let minutes_of = function
  | "day" -> 1440
  | _ -> 60

let normalize_window = function
  | "day" -> "day"
  | _ -> "hour"

let normalize_class = function
  | "static" -> "static"
  | "cap" -> "cap"
  | _ -> "app"

let fmt_us n =
  if n < 0 then "> 5 s"
  else if n >= 1_000_000 then Printf.sprintf "%.2f s" (float_of_int n /. 1_000_000.)
  else if n >= 1_000 then Printf.sprintf "%.1f ms" (float_of_int n /. 1_000.)
  else Printf.sprintf "%d us" n

let fmt_until ts =
  let t = Unix.localtime ts in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d" (t.tm_year + 1900) (t.tm_mon + 1)
    t.tm_mday t.tm_hour t.tm_min

let page_url ~window ~class_ =
  url "/_cap/metrics" [("window", window); ("class", class_)]

let tabs current options render =
  String.concat ""
    (List.map
       (fun (id, label) ->
         let cls = if id = current then "btn btn-sm btn-accent" else "btn btn-sm" in
         render cls id label)
       options)

let known_target service rpc =
  List.exists
    (fun (name, rpcs, _) ->
      name = service
      && (rpc = "" || List.exists (fun (r : Well.Service.rpc_info) -> r.rname = rpc) rpcs))
    (Well.Service.entries ())

let gather ~window ~class_ =
  let minutes = minutes_of window in
  let http =
    List.filter (fun (row : Well.Metrics.http_row) -> row.class_ = class_)
      (Well.Metrics.http_summary ~minutes)
  in
  let flow = if class_ = "app" then Well.Metrics.flow_summary ~minutes else [] in
  (http, flow, Well.Metrics.service_summary ~minutes, Well.Metrics.active_mutes ())

let mute_form req ~window ~class_ ~service ~rpc =
  Printf.sprintf
    {|%s%s%s%s<select name="hours" class="input" style="width:auto">
        <option value="1">1 hour</option>
        <option value="6">6 hours</option>
        <option value="24">24 hours</option>
      </select>
      <button class="btn btn-sm" name="action" value="mute" type="submit">Mute</button>
      <button class="btn btn-sm" name="action" value="unmute" type="submit">Restore</button>
    </form>|}
    (form_open req "/_cap/metrics/mute")
    (hidden "window" window)
    (hidden "class" class_)
    (hidden "service" service ^ hidden "rpc" rpc)

let view req ~window ~class_ http flow services mutes =
  let window_tabs =
    tabs window windows (fun cls id label ->
        link ~class_:cls (page_url ~window:id ~class_) label)
  in
  let class_tabs =
    tabs class_ classes (fun cls id label ->
        link ~class_:cls (page_url ~window ~class_:id) label)
  in
  let http_rows =
    if http = [] then
      {|<tr><td colspan="8" style="color:var(--text-muted)">No requests in this window</td></tr>|}
    else
      String.concat ""
        (List.map
           (fun (row : Well.Metrics.http_row) ->
             Printf.sprintf
               {|<tr><td>%s</td><td style="font-family:var(--mono)">%s</td><td>%d</td><td>%s</td><td>%s</td><td>%d</td><td>%d</td><td>%d</td></tr>|}
               (method_badge row.meth) (esc row.route) row.count (esc (fmt_us row.mean_us))
               (esc (fmt_us row.p95_us)) row.c2xx row.c4xx row.c5xx)
           http)
  in
  let flow_card =
    if class_ <> "app" then ""
    else
      let rows =
        if flow = [] then
          {|<tr><td colspan="3" style="color:var(--text-muted)">No document transitions in this window</td></tr>|}
        else
          String.concat ""
            (List.map
               (fun (row : Well.Metrics.flow_row) ->
                 Printf.sprintf
                   {|<tr><td style="font-family:var(--mono)">%s</td><td style="font-family:var(--mono)">%s</td><td>%d</td></tr>|}
                   (esc row.from_route) (esc row.to_route) row.count)
               flow)
      in
      Printf.sprintf
        {|<div class="card" style="margin-bottom:16px">
            <div class="card-title">Document flow</div>
            <p style="color:var(--text-secondary);margin-bottom:12px">HTML responses of application routes, within one browser session. JSON, static files, CAP, and non-2xx responses stay out of this table.</p>
            <div style="overflow-x:auto"><table class="data-table"><thead><tr><th>From</th><th>To</th><th>Count</th></tr></thead><tbody>%s</tbody></table></div>
          </div>|}
        rows
  in
  let mute_until service rpc =
    let direct =
      List.find_map
        (fun (m : Well.Metrics.mute) ->
          if m.service = service && m.rpc = rpc then Some m.until_unix else None)
        mutes
    in
    let whole =
      List.find_map
        (fun (m : Well.Metrics.mute) ->
          if m.service = service && m.rpc = "" then Some m.until_unix else None)
        mutes
    in
    match (direct, whole) with
    | Some a, Some b -> Some (max a b)
    | Some a, None -> Some a
    | None, Some b -> Some b
    | None, None -> None
  in
  let stat service rpc =
    List.find_opt
      (fun (row : Well.Metrics.service_row) -> row.service = service && row.rpc = rpc)
      services
  in
  let method_row service rpc =
    let row = stat service rpc in
    let count = match row with Some r -> r.count | None -> 0 in
    let mean = match row with Some r -> fmt_us r.mean_us | None -> "—" in
    let p95 = match row with Some r -> fmt_us r.p95_us | None -> "—" in
    let ok = match row with Some r -> string_of_int r.ok | None -> "0" in
    let err = match row with Some r -> string_of_int r.err | None -> "0" in
    let until =
      match mute_until service rpc with
      | Some ts -> esc (fmt_until ts)
      | None -> "on"
    in
    Printf.sprintf
      {|<tr><td style="font-family:var(--mono)">%s</td><td>%d</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>|}
      (esc rpc) count (esc mean) (esc p95) ok err until
      (mute_form req ~window ~class_ ~service ~rpc)
  in
  let registered = Well.Service.entries () in
  let service_blocks =
    if registered = [] && services = [] then
      {|<p style="color:var(--text-muted)">No services registered</p>|}
    else
      let known = Hashtbl.create 16 in
      let blocks =
        String.concat ""
          (List.map
             (fun (name, rpcs, kind) ->
               Hashtbl.replace known name ();
               let kind_label = match kind with `Actor -> "actor" | `Service -> "service" in
               let rows = String.concat "" (List.map (fun (r : Well.Service.rpc_info) -> method_row name r.rname) rpcs) in
               Printf.sprintf
                 {|<h3 style="margin:16px 0 8px">%s <span style="color:var(--text-muted);font-size:13px">%s</span></h3>
                   %s
                   <div style="overflow-x:auto"><table class="data-table"><thead><tr><th>Method</th><th>Calls</th><th>Mean</th><th>p95</th><th>Ok</th><th>Error</th><th>Recording</th><th></th></tr></thead><tbody>%s</tbody></table></div>|}
                 (esc name) kind_label
                 (mute_form req ~window ~class_ ~service:name ~rpc:"")
                 rows)
             registered)
      in
      let extra =
        String.concat ""
          (List.filter_map
             (fun (row : Well.Metrics.service_row) ->
               if Hashtbl.mem known row.service then None
               else
                 Some
                   (Printf.sprintf
                      {|<tr><td>%s</td><td style="font-family:var(--mono)">%s</td><td>%d</td><td>%s</td><td>%s</td><td>%d</td><td>%d</td></tr>|}
                      (esc row.service) (esc row.rpc) row.count (esc (fmt_us row.mean_us))
                      (esc (fmt_us row.p95_us)) row.ok row.err))
             services)
      in
      let extra_table =
        if extra = "" then ""
        else
          Printf.sprintf
            {|<h3 style="margin:16px 0 8px">Recorded earlier</h3>
              <div style="overflow-x:auto"><table class="data-table"><thead><tr><th>Service</th><th>Method</th><th>Calls</th><th>Mean</th><th>p95</th><th>Ok</th><th>Error</th></tr></thead><tbody>%s</tbody></table></div>|}
            extra
      in
      blocks ^ extra_table
  in
  html_raw
    (Printf.sprintf
       {|%s
         <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px">%s</div>
         <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:16px">%s</div>
         <div class="card" style="margin-bottom:16px">
           <div class="card-title">Endpoints</div>
           <div style="overflow-x:auto"><table class="data-table"><thead><tr><th>Method</th><th>Route</th><th>Count</th><th>Mean</th><th>p95</th><th>2xx</th><th>4xx</th><th>5xx</th></tr></thead><tbody>%s</tbody></table></div>
         </div>
         %s
         <div class="card">
           <div class="card-title">Service methods</div>
           <p style="color:var(--text-secondary);margin-bottom:12px">Every registered service and actor method is recorded until it is muted. Mute applies to the whole service when no method is chosen, and ends after the selected time.</p>
           %s
         </div>|}
       (flash req) window_tabs class_tabs http_rows flow_card service_blocks)

let apply req ~window ~class_ =
  let service = field req "service" in
  let rpc = field req "rpc" in
  let action = field req "action" in
  let back = page_url ~window ~class_ in
  if service = "" || not (known_target service rpc) then begin
    Well.put_flash req "cap" "Unknown service or method";
    back
  end
  else if action = "unmute" then begin
    Well.Metrics.unmute ~service ~rpc;
    Well.put_flash req "cap" "Recording restored";
    back
  end
  else
    match int_of_string_opt (field req "hours") with
    | Some hours when action = "mute" && (hours = 1 || hours = 6 || hours = 24) ->
        Well.Metrics.mute ~service ~rpc
          ~until_unix:(Unix.gettimeofday () +. (float_of_int hours *. 3600.));
        Well.put_flash req "cap" "Recording muted";
        back
    | _ ->
        Well.put_flash req "cap" "Choose 1, 6, or 24 hours";
        back
