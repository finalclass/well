let nav_items =
  [ ("/_cap/", "Overview", {|&#9670;|})
  ; ("/_cap/routes", "Routes", {|&#9741;|})
  ; ("/_cap/connections", "Connections", {|&#9729;|})
  ; ("/_cap/db", "Database", {|&#9641;|})
  ; ("/_cap/services", "Services", {|&#9656;|})
  ; ("/_cap/messages", "Messages", {|&#9993;|})
  ; ("/_cap/logs", "Logs", {|&#9776;|})
  ; ("/_cap/telemetry", "Telemetry", {|&#9201;|})
  ; ("/_cap/repl", "REPL", {|&#9002;|})
  ; ("/_cap/users", "Users", {|&#9823;|}) ]

let cap_layout req ~active_path ~title ~content =
  let csrf = Cap_helpers.csrf in
  let esc = Html.escape_html in
  let nav_html =
    String.concat
      ""
      (List.map
         (fun (path, label, icon) ->
           let cls = if path = active_path then " active" else "" in
           Printf.sprintf
             {|<a href="%s" class="%s"><span class="nav-icon">%s</span>%s</a>|}
             (esc path)
             cls
             icon
             (esc label) )
         nav_items )
  in
  Printf.sprintf
    {|<!DOCTYPE html>
<html lang="pl">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>%s — well.cap</title>
<style>%s
.tab-bar a{padding:8px 16px;color:var(--text-secondary)}.tab-bar a.active{color:var(--accent);border-bottom:2px solid var(--accent)}
#cap-menu:checked~.console-wrap .console-sidebar{transform:translateX(0)}#cap-menu:checked~.console-wrap .sidebar-backdrop{display:block}
</style>
</head>
<body>
<input type="checkbox" id="cap-menu" hidden />
<div class="console-wrap">
  <aside class="console-sidebar">
    <div class="sidebar-brand">
      <h1>well<span>.cap</span></h1>
      <div class="version">v%s</div>
    </div>
    <nav class="sidebar-nav">%s</nav>
    <div class="sidebar-footer"><form method="post" action="/_cap/logout">%s<button type="submit" class="btn btn-sm">Wyloguj</button></form></div>
  </aside>
  <label class="sidebar-backdrop" for="cap-menu"></label>
  <label class="menu-toggle" for="cap-menu" aria-label="Menu">&#9776;</label>
  <main class="console-content">
    <div class="page-header"><h2>%s</h2></div>
    %s
  </main>
</div>
<script defer src="/_cap/app.js"></script>
</body>
</html>|}
    (esc title)
    Cap_css.css
    (esc Well.version)
    nav_html
    (csrf req)
    (esc title)
    content
