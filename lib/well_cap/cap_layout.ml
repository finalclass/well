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
<script type="module">
Well.hooks.LogViewer = {
  mounted() {
    this._auto = true;
    this._loading = false;
    this._noMore = false;
    this.el.scrollTop = this.el.scrollHeight;
    this.handleEvent("new_log", (e) => {
      const d = document.createElement("div");
      d.className = "log-entry";
      d.dataset.id = e.id;
      d.innerHTML = '<span class="log-time">' + _t(e.timestamp) +
        '</span>' + _b(e.level) +
        '<span class="log-msg">' + _e(e.message) + '</span>';
      this.el.appendChild(d);
      const c = document.querySelector('[data-lv="log-count"]');
      if (c) c.textContent = this.el.querySelectorAll(".log-entry").length + " entries";
      if (this._auto) this.el.scrollTop = this.el.scrollHeight;
    });
    this.el.addEventListener("scroll", () => {
      const bot = this.el.scrollTop + this.el.clientHeight >= this.el.scrollHeight - 30;
      this._auto = bot;
      if (this.el.scrollTop < 100 && !this._loading && !this._noMore) this._more();
    });
  },
  updated() {
    if (this._auto) this.el.scrollTop = this.el.scrollHeight;
  },
  _more() {
    const first = this.el.querySelector(".log-entry[data-id]");
    if (!first) return;
    const bid = parseInt(first.dataset.id);
    if (bid <= 0) { this._noMore = true; return; }
    this._loading = true;
    const ph = this.el.scrollHeight;
    fetch("/_well/api/logs?before=" + bid + "&count=100")
      .then(r => r.json())
      .then(entries => {
        if (!entries.length) { this._noMore = true; this._loading = false; return; }
        const frag = document.createDocumentFragment();
        entries.forEach(e => {
          const d = document.createElement("div");
          d.className = "log-entry";
          d.dataset.id = e.id;
          d.innerHTML = '<span class="log-time">' + _t(e.timestamp) +
            '</span>' + _b(e.level) +
            '<span class="log-msg">' + _e(e.message) + '</span>';
          frag.appendChild(d);
        });
        this.el.insertBefore(frag, this.el.firstChild);
        this.el.scrollTop += (this.el.scrollHeight - ph);
        const c = document.querySelector('[data-lv="log-count"]');
        if (c) c.textContent = this.el.querySelectorAll(".log-entry").length + " entries";
        this._loading = false;
        if (entries.length < 100) this._noMore = true;
      })
      .catch(() => { this._loading = false; });
  }
};
function _t(ts) {
  const d = new Date(ts * 1000);
  return d.toLocaleTimeString("en-GB", { hour12: false });
}
function _b(l) {
  const c = l === "error" ? "badge-delete" : l === "warn" ? "badge-put" : "badge-get";
  return '<span class="badge ' + c + '">' + _e(l) + '</span>';
}
function _e(s) {
  const d = document.createElement("span");
  d.textContent = s;
  return d.innerHTML;
}
</script>
</body>
</html>|}
    (esc title) Cap_css.css
    (esc Well.version)
    nav_html (esc title) content
