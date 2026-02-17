let nav_items = [
  ("/_well/", "Overview", {|&#9670;|});
  ("/_well/db", "Database", {|&#9641;|});
  ("/_well/services", "Services", {|&#9656;|});
  ("/_well/messages", "Messages", {|&#9993;|});
  ("/_well/logs", "Logs", {|&#9776;|});
]

let cap_layout ~active_path ~title ~content =
  let esc = Html.escape_html in
  let nav_html =
    String.concat ""
      (List.map (fun (path, label, icon) ->
        let cls = if path = active_path then " active" else "" in
        Printf.sprintf
          {|<a href="%s" class="%s"><span class="nav-icon">%s</span>%s</a>|}
          (esc path) cls icon (esc label)
      ) nav_items)
  in
  Printf.sprintf
    {|<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>%s — well.cap</title>
<style>%s</style>
</head>
<body>
<div class="console-wrap">
  <aside class="console-sidebar">
    <div class="sidebar-brand">
      <h1>well<span>.cap</span></h1>
      <div class="version">v%s</div>
    </div>
    <nav class="sidebar-nav">%s</nav>
    <div class="sidebar-footer"><a href="/_well/logout">logout</a></div>
  </aside>
  <main class="console-content">
    <div class="page-header"><h2>%s</h2></div>
    %s
  </main>
</div>
<script type="module" src="/_well/well.js"></script>
</body>
</html>|}
    (esc title) Cap_css.css
    (esc Well.version)
    nav_html (esc title) content
