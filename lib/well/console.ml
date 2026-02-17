(* Console — Built-in admin panel at /_well/ *)
(* Showcases LiveView, DB browsing, service introspection, real-time logs *)

(* ── Forward refs (wired by well.ml before init) ─────────────────── *)

type console_response =
  | CRHtml of string
  | CRRedirect of string

let _register_console_get :
  (string -> (Types.request -> console_response) -> unit) ref =
  ref (fun _ _ -> ())

let _register_console_post :
  (string -> (Types.request -> console_response) -> unit) ref =
  ref (fun _ _ -> ())

let _console_log_hook :
  (string -> string -> int -> float -> unit) option ref = ref None

(* ── Console password ────────────────────────────────────────────── *)

let console_password = ref ""

(* ── Log ring buffer ─────────────────────────────────────────────── *)

module Log_buffer = struct
  type entry = {
    id : int;
    meth : string;
    path : string;
    status : int;
    duration_ms : float;
    timestamp : float;
  }

  let max_size = 1000
  let buffer : entry array = Array.make max_size
    { id = 0; meth = ""; path = ""; status = 0;
      duration_ms = 0.0; timestamp = 0.0 }
  let head = ref 0
  let count = ref 0
  let next_id = ref 0
  let mu = Mutex.create ()

  (* Subscribers: id -> callback *)
  let subscribers : (int, entry -> unit) Hashtbl.t = Hashtbl.create 4
  let next_sub_id = ref 0

  let push ~meth ~path ~status ~duration_ms =
    Mutex.lock mu;
    let id = incr next_id; !next_id in
    let entry = { id; meth; path; status; duration_ms;
                  timestamp = Unix.gettimeofday () } in
    buffer.(!head) <- entry;
    head := (!head + 1) mod max_size;
    if !count < max_size then incr count;
    let subs = Hashtbl.fold (fun _ cb acc -> cb :: acc) subscribers [] in
    Mutex.unlock mu;
    (* Notify outside lock *)
    List.iter (fun cb -> (try cb entry with _ -> ())) subs

  let recent n =
    Mutex.lock mu;
    let n = min n !count in
    let result = ref [] in
    for i = 0 to n - 1 do
      let idx = ((!head - 1 - i) + max_size) mod max_size in
      result := buffer.(idx) :: !result
    done;
    Mutex.unlock mu;
    !result

  let subscribe cb =
    Mutex.lock mu;
    let id = incr next_sub_id; !next_sub_id in
    Hashtbl.replace subscribers id cb;
    Mutex.unlock mu;
    id

  let unsubscribe id =
    Mutex.lock mu;
    Hashtbl.remove subscribers id;
    Mutex.unlock mu
end

(* ── CSS ─────────────────────────────────────────────────────────── *)

let console_css = {|
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700&family=Plus+Jakarta+Sans:wght@400;500;600;700&display=swap');
:root {
  --bg-deep: #08080d;
  --bg-sidebar: #0c0c14;
  --bg-content: #101018;
  --bg-card: #16161f;
  --bg-card-hover: #1c1c28;
  --bg-input: #0e0e16;
  --border: #232333;
  --border-subtle: #1a1a2a;
  --text-primary: #e2e8f0;
  --text-secondary: #7b819a;
  --text-muted: #4a4e6a;
  --accent: #a78bfa;
  --accent-dim: rgba(167,139,250,0.15);
  --accent-glow: rgba(167,139,250,0.25);
  --green: #34d399;
  --green-dim: rgba(52,211,153,0.12);
  --blue: #60a5fa;
  --blue-dim: rgba(96,165,250,0.12);
  --amber: #fbbf24;
  --amber-dim: rgba(251,191,36,0.12);
  --red: #f87171;
  --red-dim: rgba(248,113,113,0.12);
  --mono: 'JetBrains Mono', 'Fira Code', 'SF Mono', monospace;
  --sans: 'Plus Jakarta Sans', system-ui, -apple-system, sans-serif;
  --radius: 6px;
  --radius-lg: 10px;
}

*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

body {
  font-family: var(--sans);
  background: var(--bg-deep);
  color: var(--text-primary);
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
}

/* ── Layout ────────────────────────────────────── */

.console-wrap { display: flex; min-height: 100vh; }

.console-sidebar {
  width: 220px;
  min-height: 100vh;
  background: var(--bg-sidebar);
  border-right: 1px solid var(--border-subtle);
  display: flex;
  flex-direction: column;
  position: fixed;
  top: 0; left: 0; bottom: 0;
  z-index: 100;
  background-image:
    repeating-linear-gradient(
      0deg,
      transparent,
      transparent 2px,
      rgba(255,255,255,0.008) 2px,
      rgba(255,255,255,0.008) 4px
    );
}

.console-content {
  flex: 1;
  margin-left: 220px;
  padding: 28px 32px;
  min-height: 100vh;
  background: var(--bg-content);
}

/* ── Sidebar ───────────────────────────────────── */

.sidebar-brand {
  padding: 24px 20px 20px;
  border-bottom: 1px solid var(--border-subtle);
}

.sidebar-brand h1 {
  font-family: var(--mono);
  font-size: 15px;
  font-weight: 700;
  color: var(--accent);
  letter-spacing: -0.02em;
}

.sidebar-brand h1 span {
  color: var(--text-muted);
  font-weight: 400;
}

.sidebar-brand .version {
  font-family: var(--mono);
  font-size: 11px;
  color: var(--text-muted);
  margin-top: 2px;
}

.sidebar-nav {
  padding: 12px 0;
  flex: 1;
}

.sidebar-nav a {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px 20px;
  color: var(--text-secondary);
  text-decoration: none;
  font-size: 13px;
  font-weight: 500;
  border-left: 3px solid transparent;
  transition: all 0.15s ease;
}

.sidebar-nav a:hover {
  color: var(--text-primary);
  background: rgba(255,255,255,0.03);
}

.sidebar-nav a.active {
  color: var(--accent);
  background: var(--accent-dim);
  border-left-color: var(--accent);
}

.sidebar-nav .nav-icon {
  font-size: 16px;
  width: 20px;
  text-align: center;
  opacity: 0.7;
}

.sidebar-nav a.active .nav-icon { opacity: 1; }

.sidebar-footer {
  padding: 16px 20px;
  border-top: 1px solid var(--border-subtle);
  font-family: var(--mono);
  font-size: 11px;
  color: var(--text-muted);
}

.sidebar-footer a {
  color: var(--text-muted);
  text-decoration: none;
}

.sidebar-footer a:hover { color: var(--text-secondary); }

/* ── Page header ───────────────────────────────── */

.page-header {
  margin-bottom: 24px;
}

.page-header h2 {
  font-family: var(--sans);
  font-size: 20px;
  font-weight: 700;
  color: var(--text-primary);
}

.page-header .subtitle {
  font-size: 13px;
  color: var(--text-secondary);
  margin-top: 4px;
}

/* ── Cards ─────────────────────────────────────── */

.card {
  background: var(--bg-card);
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  padding: 20px;
  margin-bottom: 16px;
  position: relative;
  overflow: hidden;
}

.card::before {
  content: '';
  position: absolute;
  top: 0; left: 0; right: 0;
  height: 1px;
  background: linear-gradient(90deg, transparent, var(--accent-glow), transparent);
  opacity: 0;
  transition: opacity 0.3s;
}

.card:hover::before { opacity: 1; }

.card-title {
  font-family: var(--mono);
  font-size: 12px;
  font-weight: 600;
  color: var(--text-secondary);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  margin-bottom: 16px;
}

/* ── Stat grid ─────────────────────────────────── */

.stat-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: 12px;
  margin-bottom: 20px;
}

.stat-card {
  background: var(--bg-card);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 16px;
}

.stat-label {
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-muted);
  margin-bottom: 6px;
}

.stat-value {
  font-family: var(--mono);
  font-size: 24px;
  font-weight: 700;
  color: var(--text-primary);
}

.stat-value.accent { color: var(--accent); }
.stat-value.green { color: var(--green); }

/* ── Tables ────────────────────────────────────── */

.data-table {
  width: 100%;
  border-collapse: collapse;
  font-family: var(--mono);
  font-size: 12px;
}

.data-table thead th {
  text-align: left;
  padding: 10px 12px;
  font-weight: 600;
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-muted);
  border-bottom: 1px solid var(--border);
  white-space: nowrap;
  position: sticky;
  top: 0;
  background: var(--bg-card);
}

.data-table tbody td {
  padding: 8px 12px;
  border-bottom: 1px solid var(--border-subtle);
  color: var(--text-secondary);
  max-width: 300px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.data-table tbody tr { transition: background 0.1s; }
.data-table tbody tr:hover { background: rgba(255,255,255,0.02); }
.data-table tbody tr:nth-child(odd) { background: rgba(255,255,255,0.01); }
.data-table tbody tr:nth-child(odd):hover { background: rgba(255,255,255,0.03); }

/* ── Badges ────────────────────────────────────── */

.badge {
  display: inline-block;
  font-family: var(--mono);
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.04em;
  padding: 2px 7px;
  border-radius: 3px;
  text-transform: uppercase;
  line-height: 1.5;
}

.badge-get { background: var(--green-dim); color: var(--green); }
.badge-post { background: var(--blue-dim); color: var(--blue); }
.badge-put { background: var(--amber-dim); color: var(--amber); }
.badge-delete { background: var(--red-dim); color: var(--red); }
.badge-head { background: rgba(255,255,255,0.06); color: var(--text-secondary); }

.badge-status { padding: 2px 8px; border-radius: 10px; }
.badge-success { background: var(--green-dim); color: var(--green); }
.badge-error { background: var(--red-dim); color: var(--red); }
.badge-warning { background: var(--amber-dim); color: var(--amber); }

.status-dot {
  display: inline-block;
  width: 7px; height: 7px;
  border-radius: 50%;
  margin-right: 6px;
}

.status-dot.green { background: var(--green); box-shadow: 0 0 6px var(--green); }
.status-dot.red { background: var(--red); box-shadow: 0 0 6px var(--red); }
.status-dot.amber { background: var(--amber); box-shadow: 0 0 6px var(--amber); }

/* ── SQL editor ────────────────────────────────── */

.sql-editor {
  position: relative;
  margin-bottom: 12px;
}

.sql-editor textarea {
  width: 100%;
  min-height: 100px;
  background: var(--bg-input);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  color: var(--text-primary);
  font-family: var(--mono);
  font-size: 13px;
  padding: 12px 14px;
  resize: vertical;
  line-height: 1.6;
  transition: border-color 0.2s;
  outline: none;
}

.sql-editor textarea:focus {
  border-color: var(--accent);
  box-shadow: 0 0 0 2px var(--accent-dim);
}

.sql-editor textarea::placeholder {
  color: var(--text-muted);
}

/* ── Buttons ───────────────────────────────────── */

.btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-family: var(--mono);
  font-size: 12px;
  font-weight: 600;
  padding: 8px 16px;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--bg-card);
  color: var(--text-primary);
  cursor: pointer;
  transition: all 0.15s;
  text-decoration: none;
}

.btn:hover {
  background: var(--bg-card-hover);
  border-color: var(--text-muted);
}

.btn-accent {
  background: var(--accent);
  border-color: var(--accent);
  color: #0a0a0f;
}

.btn-accent:hover {
  background: #b99cff;
  border-color: #b99cff;
}

.btn-sm {
  font-size: 11px;
  padding: 5px 10px;
}

/* ── Tab bar ───────────────────────────────────── */

.tab-bar {
  display: flex;
  gap: 2px;
  border-bottom: 1px solid var(--border);
  margin-bottom: 16px;
}

.tab-bar button, .tab-bar a {
  font-family: var(--mono);
  font-size: 12px;
  font-weight: 500;
  padding: 8px 14px;
  color: var(--text-secondary);
  background: none;
  border: none;
  border-bottom: 2px solid transparent;
  cursor: pointer;
  transition: all 0.15s;
  text-decoration: none;
}

.tab-bar button:hover, .tab-bar a:hover { color: var(--text-primary); }

.tab-bar button.active, .tab-bar a.active {
  color: var(--accent);
  border-bottom-color: var(--accent);
}

/* ── JSON / Code blocks ────────────────────────── */

.code-block {
  background: var(--bg-input);
  border: 1px solid var(--border-subtle);
  border-radius: var(--radius);
  padding: 12px 14px;
  font-family: var(--mono);
  font-size: 12px;
  line-height: 1.6;
  color: var(--text-secondary);
  overflow-x: auto;
  white-space: pre-wrap;
  word-break: break-all;
  max-height: 400px;
  overflow-y: auto;
}

/* ── Inputs ────────────────────────────────────── */

.input {
  background: var(--bg-input);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  color: var(--text-primary);
  font-family: var(--mono);
  font-size: 13px;
  padding: 8px 12px;
  outline: none;
  transition: border-color 0.2s;
  width: 100%;
}

.input:focus {
  border-color: var(--accent);
  box-shadow: 0 0 0 2px var(--accent-dim);
}

.input::placeholder { color: var(--text-muted); }

/* ── Log stream ────────────────────────────────── */

.log-stream {
  font-family: var(--mono);
  font-size: 12px;
  max-height: 600px;
  overflow-y: auto;
  background: var(--bg-input);
  border: 1px solid var(--border-subtle);
  border-radius: var(--radius);
}

.log-entry {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 6px 14px;
  border-bottom: 1px solid rgba(255,255,255,0.02);
  transition: background 0.1s;
}

.log-entry:hover { background: rgba(255,255,255,0.02); }

.log-time { color: var(--text-muted); white-space: nowrap; font-size: 11px; }
.log-method { min-width: 52px; }
.log-path { color: var(--text-secondary); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.log-status { min-width: 32px; text-align: right; }
.log-status.s2xx { color: var(--green); }
.log-status.s3xx { color: var(--blue); }
.log-status.s4xx { color: var(--amber); }
.log-status.s5xx { color: var(--red); }
.log-duration { color: var(--text-muted); min-width: 60px; text-align: right; font-size: 11px; }

/* ── Message stream ────────────────────────────── */

.msg-entry {
  padding: 10px 14px;
  border-bottom: 1px solid var(--border-subtle);
}

.msg-channel {
  font-family: var(--mono);
  font-size: 11px;
  color: var(--accent);
  margin-bottom: 4px;
}

.msg-payload {
  font-family: var(--mono);
  font-size: 12px;
  color: var(--text-secondary);
  white-space: pre-wrap;
  word-break: break-all;
}

/* ── Empty state ───────────────────────────────── */

.empty-state {
  text-align: center;
  padding: 48px 20px;
  color: var(--text-muted);
}

.empty-state .icon {
  font-size: 32px;
  margin-bottom: 12px;
  opacity: 0.5;
}

.empty-state p { font-size: 13px; }

/* ── Login page ────────────────────────────────── */

.login-wrap {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100vh;
  background: var(--bg-deep);
}

.login-card {
  background: var(--bg-card);
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  padding: 36px;
  width: 360px;
  max-width: 90vw;
  position: relative;
  overflow: hidden;
}

.login-card::before {
  content: '';
  position: absolute;
  top: 0; left: 0; right: 0;
  height: 2px;
  background: linear-gradient(90deg, transparent, var(--accent), transparent);
}

.login-card h1 {
  font-family: var(--mono);
  font-size: 16px;
  font-weight: 700;
  color: var(--accent);
  margin-bottom: 4px;
}

.login-card .sub {
  font-size: 13px;
  color: var(--text-muted);
  margin-bottom: 24px;
}

.login-card label {
  display: block;
  font-family: var(--mono);
  font-size: 11px;
  font-weight: 600;
  color: var(--text-secondary);
  text-transform: uppercase;
  letter-spacing: 0.06em;
  margin-bottom: 6px;
}

.login-card .input { margin-bottom: 20px; }

.login-card .btn-accent { width: 100%; justify-content: center; padding: 10px; }

.login-error {
  background: var(--red-dim);
  color: var(--red);
  font-size: 12px;
  padding: 8px 12px;
  border-radius: var(--radius);
  margin-bottom: 16px;
  font-family: var(--mono);
}

/* ── Flex utilities ────────────────────────────── */

.flex { display: flex; }
.flex-col { flex-direction: column; }
.items-center { align-items: center; }
.justify-between { justify-content: space-between; }
.gap-2 { gap: 8px; }
.gap-3 { gap: 12px; }
.gap-4 { gap: 16px; }
.mt-3 { margin-top: 12px; }
.mt-4 { margin-top: 16px; }
.mb-3 { margin-bottom: 12px; }
.mb-4 { margin-bottom: 16px; }

/* ── Scrollbar ─────────────────────────────────── */

::-webkit-scrollbar { width: 6px; height: 6px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
::-webkit-scrollbar-thumb:hover { background: var(--text-muted); }

/* ── Responsive ────────────────────────────────── */

@media (max-width: 768px) {
  .console-sidebar {
    position: fixed;
    transform: translateX(-100%);
    transition: transform 0.2s;
    z-index: 200;
  }
  .console-sidebar.open { transform: translateX(0); }
  .console-content { margin-left: 0; padding: 20px 16px; }
}

/* ── Select ────────────────────────────────────── */

.select {
  background: var(--bg-input);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  color: var(--text-primary);
  font-family: var(--mono);
  font-size: 12px;
  padding: 6px 10px;
  outline: none;
}

.select:focus { border-color: var(--accent); }
|}

(* ── Auth helpers ────────────────────────────────────────────────── *)

let is_authed req =
  match Session_store.get ~session_id:req.Types.session_id
          ~key:"well_console_auth" with
  | Some "1" -> true
  | _ -> false

let console_auth_mw handler req =
  if is_authed req then handler req
  else CRRedirect "/_well/login"

(* ── Layout ──────────────────────────────────────────────────────── *)

let nav_items = [
  ("/_well/", "Overview", {|&#9670;|});
  ("/_well/db", "Database", {|&#9641;|});
  ("/_well/services", "Services", {|&#9656;|});
  ("/_well/messages", "Messages", {|&#9993;|});
  ("/_well/logs", "Logs", {|&#9776;|});
]

let console_layout ~active_path ~title ~content =
  let esc = Html.escape_html in
  let nav_html =
    String.concat ""
      (List.map (fun (path, label, icon) ->
        let cls = if path = active_path then " active" else "" in
        Printf.sprintf
          {|<a href="%s" data-lv-navigate="%s" class="%s"><span class="nav-icon">%s</span>%s</a>|}
          (esc path) (esc path) cls icon (esc label)
      ) nav_items)
  in
  Printf.sprintf
    {|<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>%s — well console</title>
<style>%s</style>
</head>
<body>
<div class="console-wrap">
  <aside class="console-sidebar">
    <div class="sidebar-brand">
      <h1>well<span>.console</span></h1>
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
<script type="module" src="/static/well.js"></script>
</body>
</html>|}
    (esc title) console_css
    (esc (let v = "1.0.0" in v))
    nav_html (esc title) content

(* ── Login page ──────────────────────────────────────────────────── *)

let login_page ?(error = false) () =
  let error_html =
    if error then
      {|<div class="login-error">Invalid password</div>|}
    else ""
  in
  Printf.sprintf
    {|<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Login — well console</title>
<style>%s</style>
</head>
<body>
<div class="login-wrap">
  <div class="login-card">
    <h1>well.console</h1>
    <p class="sub">Enter the console password to continue</p>
    %s
    <form method="post" action="/_well/login">
      <label for="password">Password</label>
      <input type="password" id="password" name="password"
             class="input" placeholder="WELL_CONSOLE_PASS" autofocus />
      <button type="submit" class="btn btn-accent">Sign in</button>
    </form>
  </div>
</div>
</body>
</html>|}
    console_css error_html

(* ── Helpers ─────────────────────────────────────────────────────── *)

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

(* ── Overview LiveView ───────────────────────────────────────────── *)

module Overview_live : Liveview.VIEW = struct
  type model = {
    table_count : int;
    service_health : (string * string) list;
    recent_logs : Log_buffer.entry list;
    log_count : int;
  }

  type msg = Refresh

  let persistence = Liveview.Ephemeral
  let subscriptions = []

  let init _req _props =
    let tables = !(Db.registered_tables) in
    let health = Service.health () in
    let logs = Log_buffer.recent 10 in
    { table_count = List.length tables;
      service_health = health;
      recent_logs = logs;
      log_count = !(Log_buffer.count); }

  let update _req model _msg =
    ignore model;
    let tables = !(Db.registered_tables) in
    let health = Service.health () in
    let logs = Log_buffer.recent 10 in
    { table_count = List.length tables;
      service_health = health;
      recent_logs = logs;
      log_count = !(Log_buffer.count); }

  let handle_params _req model = model
  let temporary_assigns model = model

  let view model =
    let services_count = List.length model.service_health in
    let running =
      List.length (List.filter (fun (_, s) -> s = "running") model.service_health)
    in
    let stats_html = Printf.sprintf
      {|<div class="stat-grid">
        <div class="stat-card">
          <div class="stat-label">Tables</div>
          <div class="stat-value accent" data-lv="ov-tables">%d</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Services</div>
          <div class="stat-value" data-lv="ov-services">%d / %d</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Requests logged</div>
          <div class="stat-value green" data-lv="ov-reqs">%d</div>
        </div>
      </div>|}
      model.table_count running services_count model.log_count
    in
    let health_rows =
      if model.service_health = [] then
        {|<tr><td colspan="2" style="color:var(--text-muted)">No services registered</td></tr>|}
      else
        String.concat ""
          (List.map (fun (name, st) ->
            let dot_color =
              if st = "running" then "green"
              else if String.length st > 5 && String.sub st 0 4 = "down" then "red"
              else "amber"
            in
            Printf.sprintf {|<tr><td>%s%s</td><td>%s</td></tr>|}
              (status_dot dot_color) (esc name) (esc st)
          ) model.service_health)
    in
    let log_rows =
      if model.recent_logs = [] then
        {|<div class="empty-state"><div class="icon">&#9776;</div><p>No requests yet</p></div>|}
      else
        let entries = String.concat ""
          (List.map (fun (e : Log_buffer.entry) ->
            Printf.sprintf
              {|<div class="log-entry"><span class="log-time">%s</span><span class="log-method">%s</span><span class="log-path">%s</span><span class="log-status %s">%d</span><span class="log-duration">%.1fms</span></div>|}
              (format_time e.timestamp) (method_badge e.meth)
              (esc e.path) (status_class e.status) e.status e.duration_ms
          ) model.recent_logs)
        in
        Printf.sprintf {|<div class="log-stream" style="max-height:300px">%s</div>|} entries
    in
    `Html (Printf.sprintf
      {|<div>%s
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px">
          <div class="card">
            <div class="card-title">Services</div>
            <table class="data-table"><thead><tr><th>Name</th><th>Status</th></tr></thead><tbody data-lv="ov-health">%s</tbody></table>
          </div>
          <div class="card">
            <div class="card-title">Recent requests</div>
            <div data-lv="ov-logs">%s</div>
          </div>
        </div>
      </div>|}
      stats_html health_rows log_rows)

  let model_to_yojson m =
    `Assoc [("table_count", `Int m.table_count);
            ("log_count", `Int m.log_count)]

  let model_of_yojson _j = Error "ephemeral"

  let msg_of_yojson j =
    match j with
    | `List [`String "Refresh"] -> Ok Refresh
    | _ -> Ok Refresh
end

(* ── Database LiveView ───────────────────────────────────────────── *)

module Db_live : Liveview.VIEW = struct
  type model = {
    tables : string list;
    selected_table : string;
    rows : string list list;
    columns : string list;
    sql_input : string;
    sql_result : string;
    sql_error : string;
  }

  type msg =
    | SelectTable of string
    | RunSQL of string

  let persistence = Liveview.Ephemeral
  let subscriptions = []

  let get_table_names () =
    List.map (fun (t : Db.table) -> t.name) !(Db.registered_tables)

  let query_table table_name =
    try
      let path = Filename.concat !(Db.data_dir) "app.sqlite" in
      let db = Sqlite3.db_open path in
      let sql = Printf.sprintf "SELECT * FROM %s LIMIT 100"
        (String.map (fun c -> if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
                                 || c >= '0' && c <= '9' || c = '_' then c
                               else '_') table_name) in
      let stmt = Sqlite3.prepare db sql in
      let ncols = Sqlite3.column_count stmt in
      let cols = List.init ncols (fun i -> Sqlite3.column_name stmt i) in
      let rows = ref [] in
      while Sqlite3.step stmt = Sqlite3.Rc.ROW do
        let row = List.init ncols (fun i ->
          match Sqlite3.column stmt i with
          | Sqlite3.Data.NULL -> "NULL"
          | Sqlite3.Data.INT i64 -> Int64.to_string i64
          | Sqlite3.Data.FLOAT f -> string_of_float f
          | Sqlite3.Data.TEXT s -> s
          | Sqlite3.Data.BLOB s -> Printf.sprintf "<blob %d>" (String.length s)
          | _ -> "?"
        ) in
        rows := row :: !rows
      done;
      ignore (Sqlite3.finalize stmt);
      ignore (Sqlite3.db_close db);
      (cols, List.rev !rows, "")
    with exn -> ([], [], Printexc.to_string exn)

  let run_sql sql_str =
    try
      let path = Filename.concat !(Db.data_dir) "app.sqlite" in
      let db = Sqlite3.db_open path in
      let stmt = Sqlite3.prepare db sql_str in
      let ncols = Sqlite3.column_count stmt in
      if ncols = 0 then begin
        (* Non-query (INSERT/UPDATE/DELETE) *)
        ignore (Sqlite3.step stmt);
        ignore (Sqlite3.finalize stmt);
        let changes = Sqlite3.changes db in
        ignore (Sqlite3.db_close db);
        ([], [], "", Printf.sprintf "OK — %d row(s) affected" changes)
      end else begin
        let cols = List.init ncols (fun i -> Sqlite3.column_name stmt i) in
        let rows = ref [] in
        while Sqlite3.step stmt = Sqlite3.Rc.ROW do
          let row = List.init ncols (fun i ->
            match Sqlite3.column stmt i with
            | Sqlite3.Data.NULL -> "NULL"
            | Sqlite3.Data.INT i64 -> Int64.to_string i64
            | Sqlite3.Data.FLOAT f -> string_of_float f
            | Sqlite3.Data.TEXT s -> s
            | Sqlite3.Data.BLOB s -> Printf.sprintf "<blob %d>" (String.length s)
            | _ -> "?"
          ) in
          rows := row :: !rows
        done;
        ignore (Sqlite3.finalize stmt);
        ignore (Sqlite3.db_close db);
        (cols, List.rev !rows, "", "")
      end
    with exn -> ([], [], Printexc.to_string exn, "")

  let init _req _props =
    let tables = get_table_names () in
    let selected_table = match tables with t :: _ -> t | [] -> "" in
    let columns, rows, _err =
      if selected_table <> "" then query_table selected_table
      else ([], [], "")
    in
    { tables; selected_table; rows; columns;
      sql_input = ""; sql_result = ""; sql_error = "" }

  let update _req model msg =
    match msg with
    | SelectTable name ->
        let columns, rows, err = query_table name in
        { model with selected_table = name; columns; rows;
          sql_error = err }
    | RunSQL sql_str ->
        let cols, rows, err, result = run_sql sql_str in
        if err <> "" then
          { model with sql_error = err; sql_result = "" }
        else if result <> "" then
          { model with sql_result = result; sql_error = "";
            columns = cols; rows }
        else
          { model with columns = cols; rows;
            sql_error = ""; sql_result = "" }

  let handle_params _req model = model
  let temporary_assigns model = model

  let view model =
    let table_tabs =
      if model.tables = [] then
        {|<div class="empty-state"><p>No tables registered</p></div>|}
      else
        let tabs = String.concat ""
          (List.map (fun t ->
            let cls = if t = model.selected_table then " active" else "" in
            Printf.sprintf
              {|<button class="%s" data-lv-click="%s">%s</button>|}
              cls
              (esc (Printf.sprintf "[\"SelectTable\",\"%s\"]" t))
              (esc t)
          ) model.tables)
        in
        Printf.sprintf {|<div class="tab-bar">%s</div>|} tabs
    in
    let data_html =
      if model.columns = [] then
        {|<div class="empty-state"><p>No data</p></div>|}
      else
        let thead = String.concat ""
          (List.map (fun c ->
            Printf.sprintf "<th>%s</th>" (esc c)
          ) model.columns)
        in
        let tbody = String.concat ""
          (List.map (fun row ->
            let cells = String.concat ""
              (List.map (fun v ->
                Printf.sprintf "<td>%s</td>" (esc v)
              ) row)
            in
            Printf.sprintf "<tr>%s</tr>" cells
          ) model.rows)
        in
        Printf.sprintf
          {|<div style="overflow-x:auto"><table class="data-table"><thead><tr>%s</tr></thead><tbody>%s</tbody></table></div>|}
          thead tbody
    in
    let err_html =
      if model.sql_error <> "" then
        Printf.sprintf {|<div class="login-error" style="margin-top:8px">%s</div>|}
          (esc model.sql_error)
      else if model.sql_result <> "" then
        Printf.sprintf
          {|<div style="margin-top:8px;color:var(--green);font-family:var(--mono);font-size:12px">%s</div>|}
          (esc model.sql_result)
      else ""
    in
    `Html (Printf.sprintf
      {|<div>
        <div class="card">
          <div class="card-title">Tables</div>
          <div data-lv="db-tabs">%s</div>
          <div data-lv="db-data" class="mt-3">%s</div>
        </div>
        <div class="card">
          <div class="card-title">SQL REPL</div>
          <form data-lv-submit="run_sql">
            <div class="sql-editor">
              <textarea name="sql" class="input" placeholder="SELECT * FROM ..." rows="3">%s</textarea>
            </div>
            <button type="submit" class="btn btn-accent btn-sm">Execute</button>
          </form>
          <div data-lv="db-err">%s</div>
        </div>
      </div>|}
      table_tabs data_html (esc model.sql_input) err_html)

  let model_to_yojson _m = `Null
  let model_of_yojson _j = Error "ephemeral"

  let msg_of_yojson j =
    match j with
    | `List [`String "SelectTable"; `String name] -> Ok (SelectTable name)
    | `Assoc kvs ->
        (match List.assoc_opt "sql" kvs with
         | Some (`String sql) -> Ok (RunSQL sql)
         | _ -> Error "unknown msg")
    | _ -> Error "unknown msg"
end

(* ── Services LiveView ───────────────────────────────────────────── *)

module Services_live : Liveview.VIEW = struct
  type model = {
    services : Yojson.Safe.t;
    health : (string * string) list;
    call_service : string;
    call_rpc : string;
    call_payload : string;
    call_result : string;
  }

  type msg =
    | Refresh
    | SetCallTarget of string * string
    | CallRPC of string

  let persistence = Liveview.Ephemeral
  let subscriptions = []

  let init _req _props =
    { services = Service.describe_services ();
      health = Service.health ();
      call_service = ""; call_rpc = "";
      call_payload = "{}"; call_result = "" }

  let update _req model msg =
    match msg with
    | Refresh ->
        { model with services = Service.describe_services ();
          health = Service.health () }
    | SetCallTarget (svc, rpc) ->
        { model with call_service = svc; call_rpc = rpc;
          call_result = "" }
    | CallRPC payload ->
        if model.call_service = "" || model.call_rpc = "" then
          { model with call_result = "Select a service and RPC first" }
        else begin
          try
            let payload_json =
              if payload = "" then `Null
              else Yojson.Safe.from_string payload
            in
            let result = Service.dispatch_by_name
              model.call_service model.call_rpc `Null payload_json in
            { model with
              call_result = Yojson.Safe.pretty_to_string result }
          with exn ->
            { model with call_result = "Error: " ^ Printexc.to_string exn }
        end

  let handle_params _req model = model
  let temporary_assigns model = model

  let view model =
    let health_map = model.health in
    let services_html =
      match model.services with
      | `Assoc services when services <> [] ->
          String.concat ""
            (List.map (fun (name, rpcs_json) ->
              let st = match List.assoc_opt name health_map with
                | Some s -> s | None -> "unknown"
              in
              let dot = if st = "running" then status_dot "green"
                        else status_dot "red" in
              let rpcs = match rpcs_json with
                | `Assoc rpcs -> rpcs
                | _ -> []
              in
              let rpc_rows = String.concat ""
                (List.map (fun (rpc_name, _info) ->
                  Printf.sprintf
                    {|<tr><td style="padding-left:28px">%s</td><td><button class="btn btn-sm" data-lv-click="%s">Call</button></td></tr>|}
                    (esc rpc_name)
                    (esc (Printf.sprintf "[\"SetCallTarget\",\"%s\",\"%s\"]" name rpc_name))
                ) rpcs)
              in
              Printf.sprintf
                {|<tr style="font-weight:600"><td>%s%s</td><td><span class="badge badge-status %s">%s</span></td></tr>%s|}
                dot (esc name)
                (if st = "running" then "badge-success" else "badge-error")
                (esc st)
                rpc_rows
            ) services)
      | _ ->
          {|<tr><td colspan="2" style="color:var(--text-muted)">No services registered</td></tr>|}
    in
    let call_html =
      if model.call_service = "" then
        {|<div class="empty-state"><p>Select a service RPC to call</p></div>|}
      else
        Printf.sprintf
          {|<div class="mb-3" style="font-family:var(--mono);font-size:13px;color:var(--accent)">%s.%s</div>
            <form data-lv-submit="call_rpc">
              <div class="sql-editor">
                <textarea name="payload" class="input" placeholder='{"key": "value"}' rows="3">%s</textarea>
              </div>
              <button type="submit" class="btn btn-accent btn-sm">Call</button>
            </form>
            %s|}
          (esc model.call_service) (esc model.call_rpc)
          (esc model.call_payload)
          (if model.call_result <> "" then
            Printf.sprintf {|<div class="code-block mt-3">%s</div>|}
              (esc model.call_result)
           else "")
    in
    `Html (Printf.sprintf
      {|<div style="display:grid;grid-template-columns:1fr 1fr;gap:16px">
        <div class="card">
          <div class="card-title">Registered Services</div>
          <table class="data-table" data-lv="svc-list">
            <thead><tr><th>Service / RPC</th><th>Status</th></tr></thead>
            <tbody>%s</tbody>
          </table>
        </div>
        <div class="card">
          <div class="card-title">RPC Caller</div>
          <div data-lv="svc-call">%s</div>
        </div>
      </div>|}
      services_html call_html)

  let model_to_yojson _m = `Null
  let model_of_yojson _j = Error "ephemeral"

  let msg_of_yojson j =
    match j with
    | `List [`String "Refresh"] -> Ok Refresh
    | `List [`String "SetCallTarget"; `String svc; `String rpc] ->
        Ok (SetCallTarget (svc, rpc))
    | `Assoc kvs ->
        (match List.assoc_opt "payload" kvs with
         | Some (`String p) -> Ok (CallRPC p)
         | _ -> Ok Refresh)
    | _ -> Ok Refresh
end

(* ── Messages LiveView ───────────────────────────────────────────── *)

module Messages_live : Liveview.VIEW = struct
  type model = {
    messages : (string * string * float) list; (* channel, payload, time *)
  }

  type msg =
    | NewMessage of string * string * float
    | Clear

  let persistence = Liveview.Ephemeral
  let subscriptions = []
  let max_messages = 200

  let init _req _props =
    { messages = [] }

  let update _req model msg =
    match msg with
    | NewMessage (ch, payload, ts) ->
        let msgs = (ch, payload, ts) :: model.messages in
        let msgs =
          if List.length msgs > max_messages then
            List.filteri (fun i _ -> i < max_messages) msgs
          else msgs
        in
        { messages = msgs }
    | Clear -> { messages = [] }

  let handle_params _req model = model
  let temporary_assigns model = model

  let view model =
    let content =
      if model.messages = [] then
        {|<div class="empty-state"><div class="icon">&#9993;</div><p>Listening for MessageBus events...</p><p style="font-size:11px;margin-top:4px">Events will appear here in real-time</p></div>|}
      else
        let entries = String.concat ""
          (List.map (fun (ch, payload, ts) ->
            Printf.sprintf
              {|<div class="msg-entry"><div class="flex items-center justify-between"><span class="msg-channel">%s</span><span class="log-time">%s</span></div><div class="msg-payload">%s</div></div>|}
              (esc ch) (format_time ts) (esc payload)
          ) model.messages)
        in
        Printf.sprintf
          {|<div class="log-stream" style="max-height:600px">%s</div>|}
          entries
    in
    `Html (Printf.sprintf
      {|<div class="card">
        <div class="flex items-center justify-between mb-3">
          <div class="card-title" style="margin-bottom:0">MessageBus Events</div>
          <button class="btn btn-sm" data-lv-click="[\"Clear\"]">Clear</button>
        </div>
        <div data-lv="msg-stream">%s</div>
      </div>|}
      content)

  let model_to_yojson _m = `Null
  let model_of_yojson _j = Error "ephemeral"

  let msg_of_yojson j =
    match j with
    | `List [`String "Clear"] -> Ok Clear
    | `Assoc kvs ->
        let ch = match List.assoc_opt "channel" kvs with
          | Some (`String s) -> s | _ -> "?" in
        let payload = match List.assoc_opt "payload" kvs with
          | Some (`String s) -> s | _ -> "" in
        let ts = match List.assoc_opt "timestamp" kvs with
          | Some (`Float f) -> f | _ -> Unix.gettimeofday () in
        Ok (NewMessage (ch, payload, ts))
    | _ -> Error "unknown msg"
end

(* ── Logs LiveView ───────────────────────────────────────────────── *)

module Logs_live : Liveview.VIEW = struct
  type model = {
    entries : Log_buffer.entry list;
    filter_path : string;
    filter_method : string;
  }

  type msg =
    | NewLog of Log_buffer.entry
    | Clear

  let persistence = Liveview.Ephemeral
  let subscriptions = []
  let max_entries = 500

  let init _req _props =
    let entries = Log_buffer.recent 100 in
    { entries; filter_path = ""; filter_method = "" }

  let update _req model msg =
    match msg with
    | NewLog entry ->
        let entries = entry :: model.entries in
        let entries =
          if List.length entries > max_entries then
            List.filteri (fun i _ -> i < max_entries) entries
          else entries
        in
        { model with entries }
    | Clear -> { model with entries = [] }

  let handle_params _req model = model
  let temporary_assigns model = model

  let view model =
    let filtered =
      List.filter (fun (e : Log_buffer.entry) ->
        (model.filter_path = "" ||
         (try ignore (Str.search_forward
            (Str.regexp_string model.filter_path) e.path 0); true
          with Not_found -> false)) &&
        (model.filter_method = "" ||
         String.uppercase_ascii e.meth = String.uppercase_ascii model.filter_method)
      ) model.entries
    in
    let entries_html =
      if filtered = [] then
        {|<div class="empty-state"><div class="icon">&#9776;</div><p>No log entries</p></div>|}
      else
        String.concat ""
          (List.map (fun (e : Log_buffer.entry) ->
            Printf.sprintf
              {|<div class="log-entry"><span class="log-time">%s</span><span class="log-method">%s</span><span class="log-path">%s</span><span class="log-status %s">%d</span><span class="log-duration">%.1fms</span></div>|}
              (format_time e.timestamp) (method_badge e.meth)
              (esc e.path) (status_class e.status) e.status e.duration_ms
          ) filtered)
    in
    `Html (Printf.sprintf
      {|<div class="card">
        <div class="flex items-center justify-between mb-3">
          <div class="card-title" style="margin-bottom:0">HTTP Request Log</div>
          <div class="flex gap-2 items-center">
            <span style="font-size:12px;color:var(--text-muted);font-family:var(--mono)" data-lv="log-count">%d entries</span>
            <button class="btn btn-sm" data-lv-click="[\"Clear\"]">Clear</button>
          </div>
        </div>
        <div class="log-stream" data-lv="log-entries">%s</div>
      </div>|}
      (List.length filtered) entries_html)

  let model_to_yojson _m = `Null
  let model_of_yojson _j = Error "ephemeral"

  let msg_of_yojson j =
    match j with
    | `List [`String "Clear"] -> Ok Clear
    | `Assoc kvs ->
        (* Log entry from broadcast *)
        let meth = match List.assoc_opt "meth" kvs with
          | Some (`String s) -> s | _ -> "" in
        let path = match List.assoc_opt "path" kvs with
          | Some (`String s) -> s | _ -> "" in
        let status = match List.assoc_opt "status" kvs with
          | Some (`Int i) -> i | _ -> 0 in
        let duration_ms = match List.assoc_opt "duration_ms" kvs with
          | Some (`Float f) -> f | _ -> 0.0 in
        let timestamp = match List.assoc_opt "timestamp" kvs with
          | Some (`Float f) -> f | _ -> Unix.gettimeofday () in
        let id = match List.assoc_opt "id" kvs with
          | Some (`Int i) -> i | _ -> 0 in
        Ok (NewLog { Log_buffer.id; meth; path; status;
                     duration_ms; timestamp })
    | _ -> Error "unknown msg"
end

(* ── Console page generator (wraps LiveView in layout) ───────────── *)

let console_page ~path ~title ~endpoint =
  let content =
    Printf.sprintf
      {|<live-view data-liveview="%s" data-topic="%s" data-props="{}"></live-view>|}
      (esc endpoint) (esc endpoint)
  in
  console_layout ~active_path:path ~title ~content

(* ── Init — called by well.ml when ~console:true ─────────────────── *)

let init () =
  let pass = try Sys.getenv "WELL_CONSOLE_PASS" with Not_found -> "" in
  if pass = "" then begin
    Printf.eprintf "[well] console: WELL_CONSOLE_PASS not set — console disabled\n%!";
  end else begin
    console_password := pass;
    (* Register LiveView endpoints *)
    Liveview.register "/live/_well/" (module Overview_live);
    Liveview.register "/live/_well/db" (module Db_live);
    Liveview.register "/live/_well/services" (module Services_live);
    Liveview.register "/live/_well/messages" (module Messages_live);
    Liveview.register "/live/_well/logs" (module Logs_live);
    (* Login routes — no auth *)
    !_register_console_get "/_well/login" (fun _req ->
      CRHtml (login_page ()));
    !_register_console_post "/_well/login" (fun req ->
      let submitted =
        (* Parse form body inline *)
        let pairs = String.split_on_char '&' req.Types.body in
        List.fold_left (fun acc pair ->
          match String.index_opt pair '=' with
          | Some i ->
              let k = String.sub pair 0 i in
              let v = String.sub pair (i + 1) (String.length pair - i - 1) in
              if k = "password" then v else acc
          | None -> acc
        ) "" pairs
      in
      if submitted = !console_password then begin
        Session_store.set ~session_id:req.session_id
          ~key:"well_console_auth" ~value:"1";
        CRRedirect "/_well/"
      end else
        CRHtml (login_page ~error:true ()));
    (* Logout route *)
    !_register_console_get "/_well/logout" (fun req ->
      Session_store.delete ~session_id:req.Types.session_id
        ~key:"well_console_auth";
      CRRedirect "/_well/login");
    (* Console page routes — with auth *)
    let authed handler req = console_auth_mw handler req in
    !_register_console_get "/_well/" (authed (fun _req ->
      CRHtml (console_page ~path:"/_well/" ~title:"Overview"
                ~endpoint:"/live/_well/")));
    !_register_console_get "/_well/db" (authed (fun _req ->
      CRHtml (console_page ~path:"/_well/db" ~title:"Database"
                ~endpoint:"/live/_well/db")));
    !_register_console_get "/_well/services" (authed (fun _req ->
      CRHtml (console_page ~path:"/_well/services" ~title:"Services"
                ~endpoint:"/live/_well/services")));
    !_register_console_get "/_well/messages" (authed (fun _req ->
      CRHtml (console_page ~path:"/_well/messages" ~title:"Messages"
                ~endpoint:"/live/_well/messages")));
    !_register_console_get "/_well/logs" (authed (fun _req ->
      CRHtml (console_page ~path:"/_well/logs" ~title:"Logs"
                ~endpoint:"/live/_well/logs")));
    (* Set up log hook for broadcasting to Logs LiveView *)
    _console_log_hook := Some (fun meth path status duration_ms ->
      let entry_json = `Assoc [
        ("id", `Int !(Log_buffer.next_id));
        ("meth", `String meth);
        ("path", `String path);
        ("status", `Int status);
        ("duration_ms", `Float duration_ms);
        ("timestamp", `Float (Unix.gettimeofday ()));
      ] in
      ignore (Message_bus.publish ~ephemeral:true "/live/_well/logs" entry_json));
    (* Set up MessageBus subscriber for Messages LiveView *)
    ignore (Message_bus.subscribe "*" (fun event ->
      let msg_json = `Assoc [
        ("channel", `String event.Message_bus.channel);
        ("payload", `String (Yojson.Safe.to_string event.payload));
        ("timestamp", `Float event.created_at);
      ] in
      ignore (Message_bus.publish ~ephemeral:true "/live/_well/messages" msg_json)));
    Printf.printf "[well] console at /_well/\n%!"
  end
