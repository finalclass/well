let nav_items = [
  ("/_well/", "Overview", {|&#9670;|});
  ("/_well/routes", "Routes", {|&#9741;|});
  ("/_well/connections", "Connections", {|&#9729;|});
  ("/_well/db", "Database", {|&#9641;|});
  ("/_well/services", "Services", {|&#9656;|});
  ("/_well/messages", "Messages", {|&#9993;|});
  ("/_well/logs", "Logs", {|&#9776;|});
  ("/_well/telemetry", "Telemetry", {|&#9201;|});
  ("/_well/repl", "REPL", {|&#9002;|});
  ("/_well/users", "Users", {|&#9823;|});
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
  <div class="sidebar-backdrop" onclick="document.querySelector('.console-sidebar').classList.remove('open')"></div>
  <button class="menu-toggle" onclick="document.querySelector('.console-sidebar').classList.toggle('open')" aria-label="Menu">&#9776;</button>
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
      const lf = this.el.dataset.level || "all";
      const sf = (this.el.dataset.search || "").toLowerCase();
      if (lf !== "all" && e.level !== lf) return;
      if (sf && !e.message.toLowerCase().includes(sf)) return;
      const d = document.createElement("div");
      d.className = "log-entry";
      d.dataset.id = e.id;
      d.innerHTML = '<span class="log-time">' + _t(e.timestamp) +
        '</span>' + _b(e.level) + _ctx(e.ctx) +
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
    const jid = this.el.dataset.jump;
    if (jid && jid !== "-1") {
      const target = this.el.querySelector('.log-entry[data-id="' + jid + '"]');
      if (target) {
        target.scrollIntoView({ block: "center" });
        this._auto = false;
        return;
      }
    }
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
            '</span>' + _b(e.level) + _ctx(e.ctx) +
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
Well.hooks.ReplTerminal = {
  mounted() {
    this._history = [];
    this._histIdx = -1;
    this._histSaved = '';
    this._schema = {};
    this._vars = [];
    this._compItems = [];
    this._compIdx = -1;
    this._compStart = 0;

    this._readData = () => {
      const d = this.el.querySelector('[data-lv="repl-data"]');
      if (!d) return;
      try { this._schema = JSON.parse(d.dataset.schema); } catch(e) {}
      try { this._vars = JSON.parse(d.dataset.vars); } catch(e) {}
    };
    this._scrollBottom = () => {
      const o = this.el.querySelector('.repl-output-area');
      if (o) o.scrollTop = o.scrollHeight;
    };
    this._hideComp = () => {
      const p = this.el.querySelector('.repl-completions');
      if (p) p.style.display = 'none';
      this._compItems = []; this._compIdx = -1;
    };
    this._renderComp = (popup) => {
      popup.innerHTML = this._compItems.map((item, i) =>
        '<div class="repl-comp-item' + (i === this._compIdx ? ' active' : '') + '">' +
        _e(item) + '</div>'
      ).join('');
    };
    this._getCompletions = (word) => {
      const results = [];
      const lw = word.toLowerCase();
      const di = word.indexOf('.');
      if (di >= 0) {
        const pfx = word.substring(0, di);
        const sfx = word.substring(di + 1).toLowerCase();
        if (this._schema[pfx]) {
          Object.keys(this._schema[pfx]).forEach(m => {
            if (m.toLowerCase().startsWith(sfx)) results.push(pfx + '.' + m);
          });
        }
      } else {
        Object.keys(this._schema).forEach(s => {
          if (s.toLowerCase().startsWith(lw)) results.push(s);
        });
        (this._vars || []).forEach(v => {
          if (v.toLowerCase().startsWith(lw) && !results.includes(v)) results.push(v);
        });
        ['let','map','filter','pick','count','first','sort'].forEach(k => {
          if (k.startsWith(lw) && !results.includes(k)) results.push(k);
        });
      }
      return results.sort();
    };
    this._getHint = (text) => {
      const t = text.trim();
      if (!t) return null;
      const dotIdx = t.lastIndexOf('.');
      if (dotIdx < 0) {
        if (this._schema[t]) {
          return '  .' + Object.keys(this._schema[t]).join(' .');
        }
        return null;
      }
      const svc = t.substring(0, dotIdx);
      if (!this._schema[svc]) return null;
      const rest = t.substring(dotIdx + 1);
      const method = rest.split(/\s/)[0];
      const info = this._schema[svc][method];
      if (!info) return null;
      if (!info.params || info.params.length === 0) return '  (no params)';
      const typed = new Set();
      t.split(/\s+/).forEach(p => {
        const ci = p.indexOf(':');
        if (ci > 0) {
          let n = p.substring(0, ci);
          if (n.startsWith('~')) n = n.substring(1);
          typed.add(n);
        }
      });
      const rem = info.params.filter(p => !typed.has(p.name));
      if (rem.length === 0) return null;
      return '  ' + rem.map(p =>
        (p.optional ? '?' : '') + p.name + ':' + p.type
      ).join(' ');
    };
    this._updateHint = () => {
      const hint = this.el.querySelector('.repl-hint');
      const inp = this.el.querySelector('.repl-input-field');
      if (!hint || !inp) return;
      const h = this._getHint(inp.value);
      hint.textContent = h || '';
    };
    this._tabComplete = (input) => {
      const text = input.value;
      const pos = input.selectionStart || text.length;
      const before = text.substring(0, pos);
      let ws = pos;
      while (ws > 0 && /[a-zA-Z0-9_.]/.test(before[ws - 1])) ws--;
      const word = before.substring(ws, pos);
      const completions = this._getCompletions(word);
      if (completions.length === 0) return;
      if (completions.length === 1) {
        const after = text.substring(pos);
        input.value = before.substring(0, ws) + completions[0] + after;
        const np = ws + completions[0].length;
        input.setSelectionRange(np, np);
        this._hideComp();
        this._updateHint();
      } else {
        this._compItems = completions;
        this._compIdx = 0;
        this._compStart = ws;
        const popup = this.el.querySelector('.repl-completions');
        if (popup) { this._renderComp(popup); popup.style.display = 'block'; }
      }
    };
    this._acceptComp = (input) => {
      if (this._compIdx >= 0 && this._compIdx < this._compItems.length) {
        const text = input.value;
        const pos = input.selectionStart || text.length;
        const after = text.substring(pos);
        const comp = this._compItems[this._compIdx];
        input.value = text.substring(0, this._compStart) + comp + after;
        const np = this._compStart + comp.length;
        input.setSelectionRange(np, np);
        this._updateHint();
      }
      this._hideComp();
    };
    this._onKey = (e) => {
      const input = this.el.querySelector('.repl-input-field');
      if (!input) return;
      const popup = this.el.querySelector('.repl-completions');
      const cv = popup && popup.style.display !== 'none' && this._compItems.length > 0;
      if (e.key === 'Tab') { e.preventDefault(); this._tabComplete(input); return; }
      if (e.key === 'Escape' && cv) { e.preventDefault(); this._hideComp(); return; }
      if (cv && e.key === 'ArrowDown') {
        e.preventDefault();
        this._compIdx = Math.min(this._compIdx + 1, this._compItems.length - 1);
        this._renderComp(popup); return;
      }
      if (cv && e.key === 'ArrowUp') {
        e.preventDefault();
        this._compIdx = Math.max(this._compIdx - 1, 0);
        this._renderComp(popup); return;
      }
      if (cv && e.key === 'Enter') { e.preventDefault(); this._acceptComp(input); return; }
      if (e.key === 'ArrowUp' && !cv) {
        e.preventDefault();
        if (this._history.length > 0) {
          if (this._histIdx === -1) {
            this._histSaved = input.value;
            this._histIdx = this._history.length - 1;
          } else if (this._histIdx > 0) { this._histIdx--; }
          input.value = this._history[this._histIdx];
          this._updateHint();
        }
        return;
      }
      if (e.key === 'ArrowDown' && !cv) {
        e.preventDefault();
        if (this._histIdx >= 0) {
          this._histIdx++;
          if (this._histIdx >= this._history.length) {
            this._histIdx = -1; input.value = this._histSaved;
          } else { input.value = this._history[this._histIdx]; }
          this._updateHint();
        }
        return;
      }
      if (e.key === 'l' && e.ctrlKey) {
        e.preventDefault();
        const btn = this.el.querySelector('[data-lv-click*="Clear"]');
        if (btn) btn.click();
        return;
      }
      if (e.key === 'k' && e.ctrlKey) {
        e.preventDefault(); input.value = ''; this._updateHint(); return;
      }
      if (e.key === 'Enter' && !cv) {
        const v = input.value.trim();
        if (!v) { e.preventDefault(); return; }
        this._history.push(v);
        this._histIdx = -1;
      }
      this._hideComp();
    };

    this._readData();
    this.el.addEventListener('keydown', (e) => {
      if (e.target.classList.contains('repl-input-field')) this._onKey(e);
    });
    this.el.addEventListener('input', (e) => {
      if (e.target.classList.contains('repl-input-field')) this._updateHint();
    });
    this._scrollBottom();
    const inp = this.el.querySelector('.repl-input-field');
    if (inp) inp.focus();
  },
  updated() {
    if (this._readData) this._readData();
    if (this._scrollBottom) this._scrollBottom();
    const input = this.el.querySelector('.repl-input-field');
    if (input) { input.value = ''; input.focus(); }
    if (this._hideComp) this._hideComp();
    if (this._updateHint) this._updateHint();
  }
};
Well.hooks.TelemetryRefresh = {
  mounted() {
    this._timer = setInterval(() => this.pushEvent("tick", {}), 2000);
  },
  updated() {},
  destroyed() { if (this._timer) clearInterval(this._timer); }
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
function _ctx(ctx) {
  if (!ctx || typeof ctx !== "object" || Object.keys(ctx).length === 0) return "";
  return '<span class="log-ctx">' + Object.entries(ctx).map(([k, v]) =>
    '<span class="log-ctx-key">' + _e(k) + '</span>=<span class="log-ctx-val">' + _e(v) + '</span>'
  ).join(" ") + '</span>';
}
</script>
</body>
</html>|}
    (esc title) Cap_css.css
    (esc Well.version)
    nav_html (esc title) content
