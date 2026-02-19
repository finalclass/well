let dune_project name =
  Printf.sprintf
    {|(lang dune 3.17)

(dialect
 (name mlx)
 (implementation
  (extension mlx)
  (merlin_reader mlx)
  (preprocess
   (run mlx-pp %%{input-file}))))

(pin
 (url "file:///home/sel/Documents/well")
 (package (name well)))

(package
 (name %s)
 (allow_empty)
 (synopsis "A well web application")
 (depends
  (ocaml (>= 5.4))
  mlx
  well
  eio
  eio_main
  yojson
  sqlite3
  ppx_deriving_yojson))
|}
    name

let root_dune = {|(dirs :standard \ _build)
|}

let makefile =
  {|.PHONY: build check test clean lock dev

build:
	dune build

check:
	dune build @check

test:
	dune test

clean:
	dune clean

lock:
	dune pkg lock

dev:
	dune exec -w bin/main.exe
|}

let readme name =
  Printf.sprintf {|# %s

Built with [well](https://github.com/anthropics/well) — full-stack OCaml web framework.

## Getting started

```bash
make dev          # start dev server with hot reload (dune exec -w)
make build        # build
make test         # run tests
make check        # type-check only (faster)
```

The dev server runs at **http://localhost:4000**.

`make dev` uses `dune exec -w` which watches for file changes, rebuilds, and restarts the server automatically.

## Project structure

```
bin/main.ml                        # entry point → App.run ()
lib/
  app.ml                           # middleware, services, routes, Well.run ()
  events.ml                        # typed pub/sub topics
  note_access/note_access_impl.ml  # NoteAccess service implementation
  task_access/task_access_impl.ml  # TaskAccess service implementation
  task_manager/task_manager_impl.ml # TaskManager service implementation
  client/
    widgets/layout.mlx             # HTML layout
    pages/                         # route pages (home, counter, notes, ...)
    live/                          # LiveView modules (counter, activity log)
    request_id.ml                  # request ID middleware
  contract/                        # service contracts (TOML → generated code)
static/                            # CSS, JS, assets
test/                              # tests
data/                              # SQLite databases (gitignored)
```

## File types

- `.ml` — OCaml (logic, models, queries)
- `.mlx` — OCaml + JSX (views, components)
- `.ts` — TypeScript (compiled to JS via bun, wired through dune)
|} name

let gitignore =
  {|_build/
*.install
.merlin
_opam/
_esy/
data/*.sqlite
data/*.sqlite-wal
data/*.sqlite-shm
node_modules/
_docs/
|}

let bin_dune _name =
  {|(executable
 (name main)
 (link_flags -linkall)
 (libraries app contract well.core well.cap eio_main))
|}

let bin_main _name =
  {|let () = App.run ()
|}

let lib_app_dune _name =
  {|(include_subdirs unqualified)

(library
 (name app)
 (wrapped false)
 (libraries contract well.core well.html eio yojson sqlite3)
 (preprocess (pps ppx_deriving_yojson well.ppx)))
|}

let app_ml _name =
  {|let run () =
  (* Middleware — executed top-to-bottom on every request *)
  Well.use Well.error_handler;
  Well.use Well.logger;
  Well.use Well.csrf;
  Well.use (Well.rate_limit ~max_requests:60 ~window_ms:60_000 ());
  Well.use Request_id.middleware;

  (* Per-route middleware: see notes_page.mlx for require_auth example *)

  (* Services — IDesign: Manager → Access → DB *)
  Well.Service.register Note_access_impl.spec;
  Well.Service.register Task_access_impl.spec;
  Well.Service.register Task_manager_impl.spec;
  Well.Service.expose "TaskManager";

  (* Keyed pub/sub — echo handler: listens for echo:cmd:*, replies on echo:result:key *)
  ignore (Well.subscribe_keyed Events.echo_cmd (fun kev ->
    let text = kev.event.value.text in
    Well.publish_keyed ~ephemeral:true Events.echo_result
      ~key:kev.key { reply = "Echo: " ^ text }));

  Well.live "/counter" (module Counter_live);
  Well.live "/activity_log" (module Activity_log_live);
  Well.static "/static" "static";
  Well.run ()
|}

let home_page name =
  Printf.sprintf
    {|Well.get "/" @@ fun req ->
let open Html in
let user = Well.session_get req "user_id" in
let auth_section = match user with
  | Some name ->
      <div class_="auth-status">
        (txt ("Logged in as " ^ name ^ " "))
        <form action="/logout" method_="POST" class_="inline-form">
          (csrf_input (Well.csrf_token req))
          <button type_="submit">(txt "Logout")</button>
        </form>
      </div>
  | None ->
      <p class_="auth-status"><a href="/login">(txt "Login")</a></p>
in
<Layout title="%s">
<div>
    <h1>(txt "Welcome to %s")</h1>
    <p>(txt "Edit lib/client/pages/home_page.mlx to get started.")</p>
    auth_section
    <p><a href="/counter">(txt "Counter — LiveView demo")</a></p>
    <p><a href="/dashboard">(txt "Dashboard — LiveView communication demo")</a></p>
    <p><a href="/notes">(txt "Notes — SQLite demo (login required)")</a></p>
    <p><a href="/tasks">(txt "Tasks — Contract/RPC demo")</a></p>
    <p><a href="/upload">(txt "Upload — File upload demo")</a></p>
    <p class_="request-id">(txt ("Request: " ^ Request_id.get req))</p>
</div>
</Layout>

(* Request/reply demo — keyed pub/sub over MessageBus *)
;;
Well.post "/api/echo" @@ fun req ->
let text = Well.form req "text" in
let key = string_of_float (Unix.gettimeofday ()) in
let result = Well.request ~cmd:Events.echo_cmd ~reply:Events.echo_result
               ~key { text } in
Well.json (`Assoc [("reply", `String result.reply)])
|}
    name name

let layout name =
  Printf.sprintf
    {|let createElement ?title:(page_title = "") ?(children = []) () =
  let open Html in
  <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name_="viewport" content="width=device-width, initial-scale=1.0" />
      <title>(txt page_title)</title>
      <link rel="stylesheet" href="/static/app.css" />
    </head>
    <body>
      <main>(children |> cat |> raw)</main>
      <footer>
        <p>(txt "Powered by %s & well")</p>
      </footer>
      <script type_="module" src="/static/well.js" />
    </body>
  </html>
|}
    name

let test_dune name =
  Printf.sprintf
    {|(test
 (name %s_test)
 (libraries app well.test))
|}
    name

let test_main name =
  Printf.sprintf
    {|open Well_test

let () =
  describe "%s" (fun () ->
    it "app module loads" (fun () ->
      expect true |> to_be_true
    );
  );
  run ~source_file:__FILE__ () |> exit_with_result
|}
    name

let ocamlformat =
  {|profile = ocamlformat
break-cases = all
type-decl = sparse
margin = 80
break-infix = fit-or-vertical
break-fun-sig = fit-or-vertical
break-fun-decl = fit-or-vertical
if-then-else = keyword-first
wrap-fun-args = false
break-infix-before-func = false
sequence-blank-line = preserve-one
break-sequences=true
|}

let static_app_css =
  {|*, *::before, *::after {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  font-family: system-ui, -apple-system, sans-serif;
  line-height: 1.6;
  color: #1a1a1a;
  max-width: 48rem;
  margin: 0 auto;
  padding: 2rem 1rem;
}

h1, h2, h3, h4 {
  line-height: 1.2;
  margin-bottom: 0.5em;
}

a {
  color: #2563eb;
}

footer {
  margin-top: 3rem;
  padding-top: 1rem;
  border-top: 1px solid #e5e7eb;
  color: #6b7280;
  font-size: 0.875rem;
}

.request-id { font-family: monospace; font-size: 0.8rem; color: #9ca3af; margin-top: 1rem; }
|}

let request_id _name =
  {|(* Request ID — Well.Context example *)
(* Middleware sets a unique ID, handlers read it via Request_id.get *)

module Ctx = Well.Context(struct
  type t = string
  let empty = ""
end)

let get = Ctx.get

let middleware : Well.middleware = fun next req ->
  let id = Printf.sprintf "%04x%04x"
    (Random.bits () land 0xffff)
    (Random.bits () land 0xffff) in
  next (Ctx.set id req)
|}

let note_access_impl _name =
  {|(* NoteAccess implementation — SQLite backend *)
(* IDesign: Access service — talks to database *)

type note_row = {
  id : int;
  title : string;
  body : string;
} [@@deriving table ~name:"notes"]

let%query all_notes = "SELECT id, title, body FROM notes ORDER BY id DESC"
let%query find_note = "SELECT id, title, body FROM notes WHERE id = :id"
let%query insert_note = "INSERT INTO notes (title, body) VALUES (:title, :body)"
let%query delete_note = "DELETE FROM notes WHERE id = :id"

let db = lazy (Well.Db.open_db ())
let get_db () = Lazy.force db

let note_of_row (r : All_notes.row) : Note_access.Note.t =
  { id = r.id; title = r.title; body = r.body }

let note_of_find (r : Find_note.row) : Note_access.Note.t =
  { id = r.id; title = r.title; body = r.body }

module Impl : Note_access.IMPL with type state = unit = struct
  type state = unit
  let init () = ()

  let list () _ctx (_req : Note_access.ListReq.t) =
    let db = get_db () in
    let rows = All_notes.query db in
    let notes = List.map note_of_row rows in
    Note_access.NoteList.make ~notes ()

  let get () _ctx (req : Note_access.IdReq.t) =
    let db = get_db () in
    match Find_note.query db ~id:req.id with
    | r :: _ -> note_of_find r
    | [] -> failwith "Note not found"

  let create () _ctx (req : Note_access.CreateReq.t) =
    let db = get_db () in
    Insert_note.exec db ~title:req.title ~body:req.body;
    let id = Int64.to_int (Sqlite3.last_insert_rowid db) in
    Note_access.Note.make ~id ~title:req.title ~body:req.body ()

  let delete () _ctx (req : Note_access.IdReq.t) =
    let db = get_db () in
    Delete_note.exec db ~id:req.id;
    Note_access.Ok.make ~ok:true ()
end

let spec = Note_access.make_spec (module Impl)
|}

let notes_page _name =
  {|(* Per-route middleware — only logged-in users can access /notes *)
let auth = [Well.require_auth ()]
;;

Well.get ~middleware:auth "/notes" @@ fun req ->
let open Html in
let ctx = Well.rpc_ctx req in
let result = Note_access.list ~ctx ~limit:0 in
<Layout title="Notes">
<div>
  <h1>(txt "Notes")</h1>
  <p>(txt "Type-safe SQLite queries, validated at compile time.")</p>
  <form action="/notes" method_="POST" class_="notes-form">
    (csrf_input (Well.csrf_token req))
    <input type_="text" name_="title" placeholder="Title" />
    <input type_="text" name_="body" placeholder="Write something..." />
    <button type_="submit">(txt "Add note")</button>
  </form>
  <ul class_="notes-list">
    (result.notes |> List.map (fun (n : Note_access.Note.t) ->
      <li>
        <strong>(txt n.title)</strong>
        (txt (" — " ^ n.body))
      </li>
    ) |> cat |> raw)
  </ul>
  <p><a href="/">(txt "← Back")</a></p>
</div>
</Layout>
;;

Well.post ~middleware:auth "/notes" @@ fun req ->
let ctx = Well.rpc_ctx req in
let title = Well.form req "title" in
let body = Well.form req "body" in
if title <> "" then
  ignore (Note_access.create ~ctx ~title ~body);
Well.redirect "/notes"
|}

let login_page _name =
  {|Well.get "/login" @@ fun req ->
let open Html in
let return_to = match Well.query req "return_to" with Some p -> p | None -> "/" in
<Layout title="Login">
<div>
  <h1>(txt "Login")</h1>
  <p>(txt "Enter any username to try the auth flow.")</p>
  <form action="/login" method_="POST" class_="login-form">
    (csrf_input (Well.csrf_token req))
    <input type_="hidden" name_="return_to" value=return_to />
    <input type_="text" name_="username" placeholder="Username" />
    <button type_="submit">(txt "Login")</button>
  </form>
  <p><a href="/">(txt "← Back")</a></p>
</div>
</Layout>
;;

Well.post "/login" @@ fun req ->
let username = Well.form req "username" in
let return_to = let r = Well.form req "return_to" in if r = "" then "/" else r in
if username <> "" then Well.session_set req "user_id" username;
Well.redirect return_to
;;

Well.post "/logout" @@ fun req ->
Well.session_delete req "user_id";
Well.redirect "/"
|}

let events _name =
  {|(* Events — typed pub/sub topics for the application *)
(* Each type defines a message shape; [@@deriving topic] generates a Well.topic value *)

(* ── Domain events (fixed channel, cross-LiveView) ───────────────── *)

type counter_event =
  [ `Incremented of string * int
  | `Decremented of string * int
  | `Reset ]
[@@deriving yojson, topic]

(* ── Keyed commands & responses (channel:key, request/reply) ─────── *)
(* Example: HTTP → Manager → response via Well.request *)

type echo_cmd = { text : string }
[@@deriving yojson, topic ~name:"echo:cmd"]

type echo_result = { reply : string }
[@@deriving yojson, topic ~name:"echo:result"]
|}

let counter_live _name =
  {|type model =
  { count: int
  ; step: int }
[@@deriving yojson]

type msg =
  | Increment
  | Decrement
  | Reset
[@@deriving yojson]

let persistence = Well.LiveView.Ephemeral
let subscriptions = []

let init _req props =
  let open Yojson.Safe.Util in
  let get_int key default =
    try props |> member key |> to_int with
    | _ -> (
      try props |> member key |> to_string |> int_of_string with
      | _ -> default )
  in
  {count= get_int "initial" 0; step= get_int "step" 1}

let update _req model = function
  | Increment ->
    let m = {model with count= model.count + model.step} in
    Well.publish Events.counter_event (`Incremented ("increment", m.count));
    m
  | Decrement ->
    let m = {model with count= model.count - model.step} in
    Well.publish Events.counter_event (`Decremented ("decrement", m.count));
    m
  | Reset ->
    Well.publish Events.counter_event (`Reset);
    {model with count= 0}

let handle_params _req model = model
let temporary_assigns model = model

let view model =
  let open Html in
  <div class_="counter">
    <div class_="counter-display">
      (dynamic "count" (string_of_int model.count))
    </div>
    <div class_="counter-controls">
      <button data_lv_click="Decrement" class_="counter-btn">
        (txt "-")
      </button>
      <button data_lv_click="Increment" class_="counter-btn">
        (txt "+")
      </button>
      <button data_lv_click="Reset" class_="counter-btn secondary">
        (txt "Reset")
      </button>
    </div>
    <div class_="counter-step">
      (txt "Step: ") (dynamic "step" (string_of_int model.step))
    </div>
  </div>
|}

let counter_page _name =
  {|Well.get "/counter" @@ fun _req ->
let open Html in
<Layout title="Counter">
<div>
  <h1>(txt "Counter — LiveView Demo")</h1>
  <p>(txt "Real-time server-side state with WebSocket updates.")</p>
  <Well.LiveView name="counter" />
  <p><a href="/">(txt "Back")</a></p>
</div>
</Layout>
|}

let activity_log_live _name =
  {|type entry =
  { id: int
  ; action: string
  ; value: int }
[@@deriving yojson]

type model =
  { entries: entry list
  ; next_id: int }
[@@deriving yojson]

type msg = Events.counter_event
[@@deriving yojson]

let persistence = Well.LiveView.Ephemeral
let subscriptions = [Well.topic_name Events.counter_event]

let init _req _props =
  {entries= []; next_id= 1}

let update _req model = function
  | `Incremented (action, value)
  | `Decremented (action, value) ->
    let entry = {id= model.next_id; action; value} in
    let entries = entry :: model.entries in
    let entries =
      if List.length entries > 20 then
        List.filteri (fun i _ -> i < 20) entries
      else entries
    in
    {entries; next_id= model.next_id + 1}
  | `Reset ->
    let entry = {id= model.next_id; action= "reset"; value= 0} in
    {entries= entry :: model.entries; next_id= model.next_id + 1}

let handle_params _req model = model
let temporary_assigns model = model

let view model =
  let open Html in
  <div class_="activity-log">
    <h2>(txt "Activity Log")</h2>
    <p class_="activity-hint">
      (dynamic "count" (string_of_int (List.length model.entries)))
      (txt " events captured")
    </p>
    (each ~id:"log-entries" ~tag_name:"ul" model.entries
       ~key:(fun e -> string_of_int e.id)
       (fun e ->
         <li class_="log-entry">
           <span class_=("log-action " ^ e.action)>(txt e.action)</span>
           (txt " → ")
           <span class_="log-value">(txt (string_of_int e.value))</span>
         </li>))
  </div>
|}

let dashboard_page _name =
  {|Well.get "/dashboard" @@ fun _req ->
let open Html in
<Layout title="Dashboard">
<div>
  <h1>(txt "Dashboard — LiveView Communication")</h1>
  <p>(txt "Two LiveViews on one page. Counter publishes events, Activity Log subscribes via Well.MessageBus.")</p>
  <div class_="dashboard-grid">
    <div class_="dashboard-panel">
      <h2>(txt "Counter")</h2>
      <Well.LiveView name="counter" />
    </div>
    <div class_="dashboard-panel">
      <Well.LiveView name="activity_log" />
    </div>
  </div>
  <p><a href="/">(txt "← Back")</a></p>
</div>
</Layout>
|}

let static_well_ts =
  {|// well.ts — Unified client for LiveView + Channels
// Replaces well-live.js with full TypeScript types

// ── Types ──────────────────────────────────────────────────────────

export interface HookDef {
  mounted?: (this: HookInstance) => void;
  updated?: (this: HookInstance) => void;
  destroyed?: (this: HookInstance) => void;
}

export interface HookInstance {
  el: Element;
  _topic: string | null;
  _handlers: Record<string, ((payload: unknown) => void)[]>;
  pushEvent(event: string, payload?: unknown): void;
  handleEvent(event: string, cb: (payload: unknown) => void): void;
}

export interface WellChannel {
  on(event: string, cb: (payload: unknown) => void): WellChannel;
  push(event: string, payload?: unknown): void;
  leave(): void;
}

// ── Well client ────────────────────────────────────────────────────

export class Well {
  // ── LiveView state ──
  private liveWs: WebSocket | null = null;
  private liveReconnectDelay = 500;
  private readonly maxReconnectDelay = 10000;
  private readonly liveViews = new Map<string, { el: Element; endpoint: string; props: Record<string, unknown> }>();

  // ── Channel state ──
  private channelWs: WebSocket | null = null;
  private channelReconnectDelay = 500;
  private readonly channels = new Map<string, ChannelInstance>();
  private channelConnected = false;

  // ── Hooks ──
  static hooks: Record<string, HookDef> = {};
  private hookInstances = new Map<Element, HookInstance>();

  // ── Debounce / Throttle ──
  private debounceTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private throttleTimers = new Map<string, number>();

  // ── Options ──
  private livePath: string;
  private wsPath: string;

  constructor(opts?: { livePath?: string; wsPath?: string }) {
    this.livePath = opts?.livePath ?? "/live";
    this.wsPath = opts?.wsPath ?? "/ws";
  }

  // ── Debounce / Throttle helpers ──────────────────────────────────

  private debouncedSend(key: string, ms: number, fn: () => void) {
    const prev = this.debounceTimers.get(key);
    if (prev !== undefined) clearTimeout(prev);
    this.debounceTimers.set(key, setTimeout(fn, ms));
  }

  private throttledSend(key: string, ms: number, fn: () => void) {
    const now = Date.now();
    if (now - (this.throttleTimers.get(key) ?? 0) >= ms) {
      this.throttleTimers.set(key, now);
      fn();
    }
  }

  private maybeSend(el: Element, fn: () => void) {
    const debounce = el.closest("[data-lv-debounce]");
    const throttle = el.closest("[data-lv-throttle]");
    if (debounce) {
      const ms = parseInt(debounce.getAttribute("data-lv-debounce") ?? "300", 10) || 300;
      const key = debounce.getAttribute("id") ?? debounce.getAttribute("data-lv-change") ?? "d";
      this.debouncedSend(key, ms, fn);
    } else if (throttle) {
      const ms = parseInt(throttle.getAttribute("data-lv-throttle") ?? "300", 10) || 300;
      const key = throttle.getAttribute("id") ?? throttle.getAttribute("data-lv-click") ?? "t";
      this.throttledSend(key, ms, fn);
    } else {
      fn();
    }
  }

  // ── Hooks ────────────────────────────────────────────────────────

  private mountHooks(container: Element) {
    const els = container.querySelectorAll("[data-lv-hook]");
    for (let i = 0; i < els.length; i++) {
      const el = els[i];
      if (this.hookInstances.has(el)) continue;
      const name = el.getAttribute("data-lv-hook");
      if (!name) continue;
      const hookDef = Well.hooks[name];
      if (!hookDef) continue;
      const topic = this.findLiveView(el);
      const self = this;
      const instance: HookInstance = {
        el,
        _topic: topic,
        _handlers: {},
        pushEvent(event: string, payload?: unknown) {
          if (this._topic) {
            self.sendLiveMsg(this._topic, ["HookEvent", { event, payload }]);
          }
        },
        handleEvent(event: string, cb: (payload: unknown) => void) {
          if (!this._handlers[event]) this._handlers[event] = [];
          this._handlers[event].push(cb);
        },
      };
      this.hookInstances.set(el, instance);
      if (hookDef.mounted) hookDef.mounted.call(instance);
    }
  }

  private updateHooks(container: Element) {
    this.hookInstances.forEach((instance, el) => {
      if (!container.contains(el)) {
        const name = el.getAttribute("data-lv-hook");
        if (name) {
          const hookDef = Well.hooks[name];
          if (hookDef?.destroyed) hookDef.destroyed.call(instance);
        }
        this.hookInstances.delete(el);
      }
    });
    this.hookInstances.forEach((instance, el) => {
      if (container.contains(el)) {
        const name = el.getAttribute("data-lv-hook");
        if (name) {
          const hookDef = Well.hooks[name];
          if (hookDef?.updated) hookDef.updated.call(instance);
        }
      }
    });
    this.mountHooks(container);
  }

  private dispatchHookEvent(topic: string, event: string, payload: unknown) {
    this.hookInstances.forEach((instance) => {
      if (instance._topic === topic && instance._handlers[event]) {
        instance._handlers[event].forEach((cb) => cb(payload));
      }
    });
  }

  // ── LiveView helpers ─────────────────────────────────────────────

  private findLiveView(el: Element): string | null {
    let node: Element | null = el;
    while (node) {
      if (node.tagName === "LIVE-VIEW") {
        return node.getAttribute("data-topic") ?? node.getAttribute("data-liveview");
      }
      node = node.parentElement;
    }
    return null;
  }

  private sendLiveMsg(topic: string, msg: unknown) {
    if (this.liveWs?.readyState === WebSocket.OPEN) {
      this.liveWs.send(JSON.stringify({ type: "msg", topic, msg }));
    }
  }

  private parseQueryParams(search: string): Record<string, string> {
    const params: Record<string, string> = {};
    if (!search || search.length <= 1) return params;
    const qs = search.charAt(0) === "?" ? search.substring(1) : search;
    const pairs = qs.split("&");
    for (const pair of pairs) {
      const [k, v] = pair.split("=");
      if (k) params[decodeURIComponent(k)] = v ? decodeURIComponent(v) : "";
    }
    return params;
  }

  // ── LiveView connection ──────────────────────────────────────────

  private connectLive() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const url = proto + "//" + location.host + this.livePath;
    this.liveWs = new WebSocket(url);

    this.liveWs.onopen = () => {
      this.liveReconnectDelay = 500;
      const queryParams = this.parseQueryParams(location.search);
      this.liveViews.forEach((lv, topic) => {
        lv.el.classList.add("lv-loading");
        const joinProps = { ...lv.props, _query: queryParams };
        this.liveWs!.send(JSON.stringify({
          type: "join", topic, endpoint: lv.endpoint, props: joinProps,
        }));
      });
    };

    this.liveWs.onmessage = (event: MessageEvent) => {
      let msg: Record<string, unknown>;
      try { msg = JSON.parse(event.data as string); } catch { return; }

      const topic = msg.topic as string;
      const lv = this.liveViews.get(topic);

      switch (msg.type) {
        case "full":
        case "restored":
          if (lv) {
            lv.el.innerHTML = msg.html as string;
            lv.el.classList.remove("lv-loading");
            this.mountHooks(lv.el);
          }
          break;

        case "patch":
          if (!lv) break;
          if (msg.changes) {
            const changes = msg.changes as Record<string, string>;
            for (const id of Object.keys(changes)) {
              const el = lv.el.querySelector('[data-lv="' + id + '"]');
              if (el) el.textContent = changes[id];
            }
          }
          if (msg.list_ops) {
            const listOps = msg.list_ops as Record<string, { order?: string[]; inserts?: Record<string, string> }>;
            for (const listId of Object.keys(listOps)) {
              const ops = listOps[listId];
              const container = lv.el.querySelector('[data-lv-each="' + listId + '"]');
              if (!container) continue;
              const existing = new Map<string, Element>();
              for (let j = 0; j < container.children.length; j++) {
                const key = container.children[j].getAttribute("data-lv-key");
                if (key) existing.set(key, container.children[j]);
              }
              if (ops.inserts) {
                for (const [ikey, html] of Object.entries(ops.inserts)) {
                  const tmp = document.createElement("div");
                  tmp.innerHTML = html;
                  const newEl = tmp.firstElementChild;
                  if (newEl) existing.set(ikey, newEl);
                }
              }
              if (ops.order) {
                while (container.firstChild) container.removeChild(container.firstChild);
                for (const okey of ops.order) {
                  const oel = existing.get(okey);
                  if (oel) container.appendChild(oel);
                }
              }
            }
          }
          this.updateHooks(lv.el);
          break;

        case "event":
          if (msg.event) {
            this.dispatchHookEvent(topic, msg.event as string, msg.payload ?? null);
          }
          break;

        case "navigate":
          if (msg.url && msg.html) {
            history.pushState({ wellNav: true }, "", msg.url as string);
            this.applyNavigationHtml(msg.html as string);
          }
          break;
      }
    };

    this.liveWs.onclose = () => {
      this.liveViews.forEach((lv) => lv.el.classList.add("lv-loading"));
      setTimeout(() => {
        this.liveReconnectDelay = Math.min(this.liveReconnectDelay * 2, this.maxReconnectDelay);
        this.connectLive();
      }, this.liveReconnectDelay);
    };

    this.liveWs.onerror = () => this.liveWs?.close();
  }

  // ── LiveView navigation ──────────────────────────────────────────

  private patchParams(url: string) {
    if (!this.liveWs || this.liveWs.readyState !== WebSocket.OPEN) {
      window.location.href = url;
      return;
    }
    history.replaceState({ wellNav: true }, "", url);
    const qmark = url.indexOf("?");
    const params = qmark >= 0 ? this.parseQueryParams(url.substring(qmark)) : {};
    this.liveViews.forEach((_lv, topic) => {
      this.liveWs!.send(JSON.stringify({ type: "params", topic, params }));
    });
  }

  private navigateTo(url: string) {
    if (!this.liveWs || this.liveWs.readyState !== WebSocket.OPEN) {
      window.location.href = url;
      return;
    }
    this.liveViews.forEach((_lv, topic) => {
      this.liveWs!.send(JSON.stringify({ type: "leave", topic }));
    });
    this.liveWs.send(JSON.stringify({ type: "navigate", url }));
  }

  private applyNavigationHtml(html: string) {
    this.hookInstances.forEach((instance, el) => {
      const name = el.getAttribute("data-lv-hook");
      if (name) {
        const hookDef = Well.hooks[name];
        if (hookDef?.destroyed) hookDef.destroyed.call(instance);
      }
    });
    this.hookInstances.clear();
    this.liveViews.clear();

    const tmp = document.createElement("html");
    tmp.innerHTML = html;
    const newMain = tmp.querySelector("main");
    const oldMain = document.querySelector("main");
    if (newMain && oldMain) {
      oldMain.innerHTML = newMain.innerHTML;
      const newTitle = tmp.querySelector("title");
      if (newTitle) document.title = newTitle.textContent ?? "";
    } else {
      const newBody = tmp.querySelector("body");
      if (newBody) document.body.innerHTML = newBody.innerHTML;
    }
    this.discoverAndJoin();
  }

  private discoverAndJoin() {
    const elements = document.querySelectorAll("live-view");
    if (elements.length === 0) return;

    elements.forEach((el) => {
      const endpoint = el.getAttribute("data-liveview") ?? "";
      const topic = el.getAttribute("data-topic") ?? endpoint;
      let props: Record<string, unknown> = {};
      try { props = JSON.parse(el.getAttribute("data-props") ?? "{}"); } catch { /* ignore */ }
      this.liveViews.set(topic, { el, endpoint, props });
    });

    if (this.liveWs?.readyState === WebSocket.OPEN) {
      const queryParams = this.parseQueryParams(location.search);
      this.liveViews.forEach((lv, topic) => {
        lv.el.classList.add("lv-loading");
        const joinProps = { ...lv.props, _query: queryParams };
        this.liveWs!.send(JSON.stringify({
          type: "join", topic, endpoint: lv.endpoint, props: joinProps,
        }));
      });
    }
  }

  // ── File Upload ──────────────────────────────────────────────────

  private uploadFile(topic: string, file: File) {
    const CHUNK_SIZE = 64 * 1024;
    const uploadId = Math.random().toString(36).substring(2) + Date.now().toString(36);
    const chunkCount = Math.ceil(file.size / CHUNK_SIZE);
    let chunkIndex = 0;

    const sendChunk = () => {
      if (chunkIndex >= chunkCount) return;
      const start = chunkIndex * CHUNK_SIZE;
      const end = Math.min(start + CHUNK_SIZE, file.size);
      const slice = file.slice(start, end);
      const reader = new FileReader();
      reader.onload = () => {
        const base64 = (reader.result as string).split(",")[1] ?? "";
        if (this.liveWs?.readyState === WebSocket.OPEN) {
          this.liveWs.send(JSON.stringify({
            type: "upload", topic, upload_id: uploadId,
            filename: file.name, content_type: file.type || "application/octet-stream",
            size: file.size, chunk_index: chunkIndex, chunk_count: chunkCount,
            chunk_data: base64,
          }));
        }
        chunkIndex++;
        sendChunk();
      };
      reader.readAsDataURL(slice);
    };
    sendChunk();
  }

  // ── Event delegation ─────────────────────────────────────────────

  private setupEventDelegation() {
    document.addEventListener("click", (e: MouseEvent) => {
      const target = e.target as Element;

      // Live navigation
      const navTarget = target.closest("[data-lv-navigate]");
      if (navTarget) {
        e.preventDefault();
        const url = navTarget.getAttribute("href") ?? navTarget.getAttribute("data-lv-navigate") ?? "";
        if (url) this.navigateTo(url);
        return;
      }

      // Patch navigation
      const patchTarget = target.closest("[data-lv-patch]");
      if (patchTarget) {
        e.preventDefault();
        const patchUrl = patchTarget.getAttribute("href") ?? patchTarget.getAttribute("data-lv-patch") ?? "";
        if (patchUrl) this.patchParams(patchUrl);
        return;
      }

      // Click action
      const clickTarget = target.closest("[data-lv-click]");
      if (!clickTarget) return;
      const action = clickTarget.getAttribute("data-lv-click");
      const topic = this.findLiveView(clickTarget);
      if (topic && action) {
        this.maybeSend(clickTarget, () => this.sendLiveMsg(topic, [action]));
      }
    });

    document.addEventListener("submit", (e: SubmitEvent) => {
      const form = (e.target as Element).closest("[data-lv-submit]") as HTMLFormElement | null;
      if (!form) return;
      e.preventDefault();
      const action = form.getAttribute("data-lv-submit");
      const topic = this.findLiveView(form);
      if (!topic || !action) return;

      const formData = new FormData(form);
      const data: Record<string, unknown> = {};
      formData.forEach((value, key) => { data[key] = value; });

      this.maybeSend(form, () => this.sendLiveMsg(topic, [action, data]));

      form.querySelectorAll('input:not([type="hidden"]):not([type="submit"])').forEach((input) => {
        (input as HTMLInputElement).value = "";
      });
    });

    document.addEventListener("input", (e: Event) => {
      const target = (e.target as Element).closest("[data-lv-change]");
      if (!target) return;
      const action = target.getAttribute("data-lv-change");
      const topic = this.findLiveView(target);
      if (topic && action) {
        this.maybeSend(e.target as Element, () => {
          this.sendLiveMsg(topic, [action, (e.target as HTMLInputElement).value]);
        });
      }
    });

    // Browser back/forward
    window.addEventListener("popstate", () => {
      if (this.liveWs?.readyState === WebSocket.OPEN) {
        this.liveViews.forEach((_lv, topic) => {
          this.liveWs!.send(JSON.stringify({ type: "leave", topic }));
        });
        this.liveWs.send(JSON.stringify({ type: "navigate", url: location.pathname + location.search }));
      } else {
        window.location.reload();
      }
    });
  }

  // ── Channel API ──────────────────────────────────────────────────

  channel(topic: string): WellChannel {
    if (!this.channelWs || this.channelWs.readyState !== WebSocket.OPEN) {
      this.connectChannel();
    }
    const ch = new ChannelInstance(topic, this);
    this.channels.set(topic, ch);
    if (this.channelConnected) ch._join();
    return ch;
  }

  /** @internal */
  _sendChannel(data: unknown) {
    if (this.channelWs?.readyState === WebSocket.OPEN) {
      this.channelWs.send(JSON.stringify(data));
    }
  }

  /** @internal */
  _removeChannel(topic: string) {
    this.channels.delete(topic);
  }

  private connectChannel() {
    if (this.channelWs && this.channelWs.readyState <= WebSocket.OPEN) return;

    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const url = proto + "//" + location.host + this.wsPath;
    this.channelWs = new WebSocket(url);

    this.channelWs.onopen = () => {
      this.channelReconnectDelay = 500;
      this.channelConnected = true;
      this.channels.forEach((ch) => ch._join());
    };

    this.channelWs.onmessage = (event: MessageEvent) => {
      let msg: Record<string, unknown>;
      try { msg = JSON.parse(event.data as string); } catch { return; }

      const ch = msg.channel as string;
      const type = msg.type as string;
      const channel = this.channels.get(ch);

      if (type === "event" && channel) {
        const eventName = (msg.event as string) ?? "message";
        channel._dispatch(eventName, msg.payload);
      }
    };

    this.channelWs.onclose = () => {
      this.channelConnected = false;
      if (this.channels.size > 0) {
        setTimeout(() => {
          this.channelReconnectDelay = Math.min(this.channelReconnectDelay * 2, this.maxReconnectDelay);
          this.connectChannel();
        }, this.channelReconnectDelay);
      }
    };

    this.channelWs.onerror = () => this.channelWs?.close();
  }

  // ── Connect (entry point) ────────────────────────────────────────

  connect() {
    this.setupEventDelegation();

    // Built-in FileUpload hook
    const self = this;
    Well.hooks.FileUpload = {
      mounted(this: HookInstance) {
        const input = this.el.querySelector('input[type="file"]') ?? this.el;
        if ((input as HTMLElement).tagName !== "INPUT") return;
        const hookTopic = this._topic;
        input.addEventListener("change", (e: Event) => {
          const files = (e.target as HTMLInputElement).files;
          if (!files || !hookTopic) return;
          for (let i = 0; i < files.length; i++) {
            self.uploadFile(hookTopic, files[i]);
          }
        });
      },
    };

    // Discover LiveViews and connect
    document.addEventListener("DOMContentLoaded", () => {
      const elements = document.querySelectorAll("live-view");
      if (elements.length === 0) return;
      elements.forEach((el) => {
        const endpoint = el.getAttribute("data-liveview") ?? "";
        const topic = el.getAttribute("data-topic") ?? endpoint;
        let props: Record<string, unknown> = {};
        try { props = JSON.parse(el.getAttribute("data-props") ?? "{}"); } catch { /* ignore */ }
        this.liveViews.set(topic, { el, endpoint, props });
      });
      this.connectLive();
    });
  }
}

// ── Channel instance ─────────────────────────────────────────────

class ChannelInstance implements WellChannel {
  private listeners = new Map<string, ((payload: unknown) => void)[]>();
  private joined = false;

  constructor(
    private topic: string,
    private well: Well,
  ) {}

  on(event: string, cb: (payload: unknown) => void): WellChannel {
    const cbs = this.listeners.get(event) ?? [];
    cbs.push(cb);
    this.listeners.set(event, cbs);
    return this;
  }

  push(event: string, payload?: unknown) {
    this.well._sendChannel({ type: "push", channel: this.topic, event, payload: payload ?? null });
  }

  leave() {
    this.well._sendChannel({ type: "leave", channel: this.topic });
    this.well._removeChannel(this.topic);
    this.joined = false;
  }

  /** @internal */
  _join() {
    if (this.joined) return;
    this.joined = true;
    this.well._sendChannel({ type: "join", channel: this.topic });
  }

  /** @internal */
  _dispatch(event: string, payload: unknown) {
    const cbs = this.listeners.get(event);
    if (cbs) cbs.forEach((cb) => cb(payload));
    // Also dispatch to "*" wildcard listeners
    const wildcardCbs = this.listeners.get("*");
    if (wildcardCbs) wildcardCbs.forEach((cb) => cb(payload));
  }
}

// ── Auto-initialize ────────────────────────────────────────────────
// For script tag usage: automatically connect LiveViews

const well = new Well();
well.connect();

// Expose globally for hooks and channels
(window as unknown as Record<string, unknown>).Well = Well;
(window as unknown as Record<string, unknown>).well = well;
|}

let notes_css =
  {|
/* Notes */
.notes-form { display: flex; gap: 0.5rem; margin: 1rem 0; }
.notes-form input { padding: 0.5rem; border: 1px solid #d1d5db; border-radius: 4px; flex: 1; font-size: 1rem; }
.notes-form button { padding: 0.5rem 1rem; background: #2563eb; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 1rem; }
.notes-form button:hover { background: #1d4ed8; }
.notes-list { list-style: none; margin-top: 1rem; }
.notes-list li { padding: 0.75rem 0; border-bottom: 1px solid #e5e7eb; }
|}

let counter_css =
  {|
/* LiveView Counter */
.counter { text-align: center; padding: 2rem; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); border-radius: 12px; color: white; margin: 1.5rem 0; }
.counter-display { font-size: 4rem; font-weight: bold; margin: 1rem 0; }
.counter-controls { display: flex; gap: 1rem; justify-content: center; margin: 1rem 0; }
.counter-btn { padding: 1rem 2rem; font-size: 1.5rem; min-width: 60px; background: rgba(255,255,255,0.2); border: 2px solid white; color: white; cursor: pointer; border-radius: 4px; }
.counter-btn:hover { background: rgba(255,255,255,0.3); }
.counter-btn.secondary { background: transparent; font-size: 1rem; padding: 0.5rem 1rem; }
.counter-step { font-size: 0.9rem; opacity: 0.8; }

/* LiveView indicator */
live-view { display: block; position: relative; }
live-view::before { content: ''; display: block; height: 3px; background: #28a745; margin-bottom: 1rem; border-radius: 2px; }
live-view.lv-loading { pointer-events: none; opacity: 0.5; }
live-view.lv-loading::after { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 3px; background: #007bff; border-radius: 2px; animation: lv-loading-bar 1s ease-in-out infinite; }
@keyframes lv-loading-bar { 0% { transform: scaleX(0); transform-origin: left; } 50% { transform: scaleX(1); transform-origin: left; } 50.1% { transform-origin: right; } 100% { transform: scaleX(0); transform-origin: right; } }
|}

let dashboard_css =
  {|
/* Dashboard */
.dashboard-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem; margin: 1.5rem 0; }
@media (max-width: 768px) { .dashboard-grid { grid-template-columns: 1fr; } }
.dashboard-panel { background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px; padding: 1.5rem; }

/* Activity Log */
.activity-log { min-height: 200px; }
.activity-log h2 { font-size: 1.1rem; margin-bottom: 0.5rem; }
.activity-hint { font-size: 0.85rem; color: #6b7280; margin-bottom: 0.75rem; }
.log-entry { display: flex; align-items: center; gap: 0.5rem; padding: 0.35rem 0; border-bottom: 1px solid #e5e7eb; font-size: 0.9rem; }
.log-action { font-weight: 600; text-transform: uppercase; font-size: 0.75rem; padding: 0.15rem 0.4rem; border-radius: 3px; }
.log-action.increment { color: #059669; background: #d1fae5; }
.log-action.decrement { color: #dc2626; background: #fee2e2; }
.log-action.reset { color: #7c3aed; background: #ede9fe; }
.log-value { font-family: monospace; font-weight: bold; }
|}

let tasks_css =
  {|
/* Tasks */
.tasks-container { margin: 1rem 0; }
.tasks-form { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
.tasks-form input { flex: 1; padding: 0.5rem; border: 1px solid #d1d5db; border-radius: 4px; font-size: 1rem; }
.tasks-form button { padding: 0.5rem 1rem; background: #2563eb; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 1rem; }
.tasks-form button:hover { background: #1d4ed8; }
.tasks-list { list-style: none; }
.task-item { display: flex; align-items: center; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid #e5e7eb; }
.task-item.completed span { text-decoration: line-through; color: #9ca3af; }
.task-item label { display: flex; align-items: center; gap: 0.5rem; cursor: pointer; flex: 1; }
.task-delete { background: none; border: none; color: #ef4444; cursor: pointer; font-size: 1.2rem; padding: 0 0.5rem; }
.task-delete:hover { color: #dc2626; }
.tasks-remaining { margin-top: 0.5rem; color: #6b7280; font-size: 0.875rem; }
.loading { color: #6b7280; }
|}

let auth_css =
  {|
/* Auth */
.auth-status { margin: 1rem 0; }
.inline-form { display: inline; }
.inline-form button { background: none; border: none; color: #2563eb; cursor: pointer; font-size: inherit; padding: 0; text-decoration: underline; }
.login-form { display: flex; flex-direction: column; gap: 0.5rem; max-width: 20rem; margin: 1rem 0; }
.login-form input[type="text"] { padding: 0.5rem; border: 1px solid #d1d5db; border-radius: 4px; font-size: 1rem; }
.login-form button { padding: 0.5rem 1rem; background: #2563eb; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 1rem; }
.login-form button:hover { background: #1d4ed8; }
|}

let contract_note_access_toml =
  {|[service.rpc]
list = "ListReq -> NoteList"
get = "IdReq -> Note"
create = "CreateReq -> Note"
delete = "IdReq -> Ok"

[msg.Note.struct]
id = "int"
title = "string"
body = "string"

[msg.ListReq.struct]
limit = "int"

[msg.IdReq.struct]
id = "int"

[msg.CreateReq.struct]
title = "string"
body = "string"

[msg.NoteList.struct]
notes = { type = "list", of = "Note" }

[msg.Ok.struct]
ok = "bool"
|}

let contract_task_access_toml =
  {|[service.rpc]
list = "ListReq -> TaskList"
get = "IdReq -> Task"
create = "CreateReq -> Task"
update = "UpdateReq -> Task"
delete = "IdReq -> Ok"

[msg.Task.struct]
id = "int"
title = "string"
completed = "bool"

[msg.ListReq.struct]
limit = "int"

[msg.IdReq.struct]
id = "int"

[msg.CreateReq.struct]
title = "string"

[msg.UpdateReq.struct]
id = "int"
title = { type = "string", optional = true }
completed = { type = "bool", optional = true }

[msg.TaskList.struct]
tasks = { type = "list", of = "Task" }

[msg.Ok.struct]
ok = "bool"
|}

let contract_task_manager_toml =
  {|[service.rpc]
list = "TaskAccess.ListReq -> TaskListRes"
add = "AddReq -> TaskRes"
toggle = "ToggleReq -> TaskRes"
delete = "DeleteReq -> StatusRes"

[msg.AddReq.struct]
title = "string"

[msg.ToggleReq.struct]
id = "int"

[msg.DeleteReq.struct]
id = "int"

[msg.TaskListRes.struct]
tasks = { type = "list", of = "TaskAccess.Task" }

[msg.TaskRes.struct]
task = "TaskAccess.Task"

[msg.StatusRes.struct]
ok = "bool"
|}

let contract_note_access_ml =
  {|[@@@warning "-32"]

module Note = struct
  type t = {
    id : int;
    title : string;
    body : string;
  }

  let make ~id ~title ~body () =
    { id; title; body }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `Int v.id;
      `String v.title;
      `String v.body;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let id = (match (_g 0) with `Int i -> i | _ -> 0) in
      let title = (match (_g 1) with `String s -> s | _ -> "") in
      let body = (match (_g 2) with `String s -> s | _ -> "") in
      { id; title; body }
    | _ -> failwith "Note.of_wire: expected JSON array"
end

module ListReq = struct
  type t = {
    limit : int;
  }

  let make ~limit () =
    { limit }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `Int v.limit;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let limit = (match (_g 0) with `Int i -> i | _ -> 0) in
      { limit }
    | _ -> failwith "ListReq.of_wire: expected JSON array"
end

module IdReq = struct
  type t = {
    id : int;
  }

  let make ~id () =
    { id }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `Int v.id;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let id = (match (_g 0) with `Int i -> i | _ -> 0) in
      { id }
    | _ -> failwith "IdReq.of_wire: expected JSON array"
end

module CreateReq = struct
  type t = {
    title : string;
    body : string;
  }

  let make ~title ~body () =
    { title; body }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `String v.title;
      `String v.body;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let title = (match (_g 0) with `String s -> s | _ -> "") in
      let body = (match (_g 1) with `String s -> s | _ -> "") in
      { title; body }
    | _ -> failwith "CreateReq.of_wire: expected JSON array"
end

module Ok = struct
  type t = {
    ok : bool;
  }

  let make ~ok () =
    { ok }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `Bool v.ok;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let ok = (match (_g 0) with `Bool b -> b | _ -> false) in
      { ok }
    | _ -> failwith "Ok.of_wire: expected JSON array"
end

module NoteList = struct
  type t = {
    notes : Note.t list;
  }

  let make ~notes () =
    { notes }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `List (List.map (fun item -> Note.to_wire item) v.notes);
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let notes = (match (_g 0) with `List items -> List.map (fun item -> Note.of_wire item) items | _ -> []) in
      { notes }
    | _ -> failwith "NoteList.of_wire: expected JSON array"
end

let _service_ref : (string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t) option ref = ref None

module type IMPL = sig
  type state
  val init : unit -> state
  val list : state -> Well.rpc_ctx -> ListReq.t -> NoteList.t
  val get : state -> Well.rpc_ctx -> IdReq.t -> Note.t
  val create : state -> Well.rpc_ctx -> CreateReq.t -> Note.t
  val delete : state -> Well.rpc_ctx -> IdReq.t -> Ok.t
end

let make_spec (type s) (module I : IMPL with type state = s) : Well.Service.spec =
  let state = ref (I.init ()) in
  { name = "NoteAccess"
  ; rpcs = []
  ; handler = (fun rpc_name ctx_json payload ->
      let ctx = Well.rpc_ctx_of_wire ctx_json in
      match rpc_name with
      | "list" ->
          NoteList.to_wire (I.list !state ctx (ListReq.of_wire payload))
      | "get" ->
          Note.to_wire (I.get !state ctx (IdReq.of_wire payload))
      | "create" ->
          Note.to_wire (I.create !state ctx (CreateReq.of_wire payload))
      | "delete" ->
          Ok.to_wire (I.delete !state ctx (IdReq.of_wire payload))
      | _ -> failwith ("Unknown RPC: " ^ rpc_name))
  ; set_ref = (fun f -> _service_ref := Some f)
  }

let list ~ctx ~limit =
  let ctx_wire = Well.rpc_ctx_to_wire ctx in
  let wire = ListReq.to_wire (ListReq.make ~limit ()) in
  NoteList.of_wire
    ((match !_service_ref with
      | Some f -> f "list" ctx_wire wire
      | None -> failwith "NoteAccess: service not registered"))

let get ~ctx ~id =
  let ctx_wire = Well.rpc_ctx_to_wire ctx in
  let wire = IdReq.to_wire (IdReq.make ~id ()) in
  Note.of_wire
    ((match !_service_ref with
      | Some f -> f "get" ctx_wire wire
      | None -> failwith "NoteAccess: service not registered"))

let create ~ctx ~title ~body =
  let ctx_wire = Well.rpc_ctx_to_wire ctx in
  let wire = CreateReq.to_wire (CreateReq.make ~title ~body ()) in
  Note.of_wire
    ((match !_service_ref with
      | Some f -> f "create" ctx_wire wire
      | None -> failwith "NoteAccess: service not registered"))

let delete ~ctx ~id =
  let ctx_wire = Well.rpc_ctx_to_wire ctx in
  let wire = IdReq.to_wire (IdReq.make ~id ()) in
  Ok.of_wire
    ((match !_service_ref with
      | Some f -> f "delete" ctx_wire wire
      | None -> failwith "NoteAccess: service not registered"))
|}

let contract_task_access_ml =
  {|[@@@warning "-32"]

module Task = struct
  type t = {
    id : int;
    title : string;
    completed : bool;
  }

  let make ~id ~title ~completed () =
    { id; title; completed }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `Int v.id;
      `String v.title;
      `Bool v.completed;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let id = (match (_g 0) with `Int i -> i | _ -> 0) in
      let title = (match (_g 1) with `String s -> s | _ -> "") in
      let completed = (match (_g 2) with `Bool b -> b | _ -> false) in
      { id; title; completed }
    | _ -> failwith "Task.of_wire: expected JSON array"
end

module ListReq = struct
  type t = {
    limit : int;
  }

  let make ~limit () =
    { limit }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `Int v.limit;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let limit = (match (_g 0) with `Int i -> i | _ -> 0) in
      { limit }
    | _ -> failwith "ListReq.of_wire: expected JSON array"
end

module IdReq = struct
  type t = {
    id : int;
  }

  let make ~id () =
    { id }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `Int v.id;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let id = (match (_g 0) with `Int i -> i | _ -> 0) in
      { id }
    | _ -> failwith "IdReq.of_wire: expected JSON array"
end

module CreateReq = struct
  type t = {
    title : string;
  }

  let make ~title () =
    { title }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `String v.title;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let title = (match (_g 0) with `String s -> s | _ -> "") in
      { title }
    | _ -> failwith "CreateReq.of_wire: expected JSON array"
end

module UpdateReq = struct
  type t = {
    id : int;
    title : string option;
    completed : bool option;
  }

  let make ~id ?title ?completed () =
    { id; title = (match title with Some v -> Some v | None -> None); completed = (match completed with Some v -> Some v | None -> None) }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `Int v.id;
      (let x = v.title in (match x with Some x -> `String x | None -> `Null));
      (let x = v.completed in (match x with Some x -> `Bool x | None -> `Null));
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let id = (match (_g 0) with `Int i -> i | _ -> 0) in
      let title = (match (_g 1) with `Null -> None | x -> Some ((match x with `String s -> s | _ -> ""))) in
      let completed = (match (_g 2) with `Null -> None | x -> Some ((match x with `Bool b -> b | _ -> false))) in
      { id; title; completed }
    | _ -> failwith "UpdateReq.of_wire: expected JSON array"
end

module Ok = struct
  type t = {
    ok : bool;
  }

  let make ~ok () =
    { ok }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `Bool v.ok;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let ok = (match (_g 0) with `Bool b -> b | _ -> false) in
      { ok }
    | _ -> failwith "Ok.of_wire: expected JSON array"
end

module TaskList = struct
  type t = {
    tasks : Task.t list;
  }

  let make ~tasks () =
    { tasks }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `List (List.map (fun item -> Task.to_wire item) v.tasks);
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let tasks = (match (_g 0) with `List items -> List.map (fun item -> Task.of_wire item) items | _ -> []) in
      { tasks }
    | _ -> failwith "TaskList.of_wire: expected JSON array"
end

let _service_ref : (string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t) option ref = ref None

module type IMPL = sig
  type state
  val init : unit -> state
  val list : state -> Well.rpc_ctx -> ListReq.t -> TaskList.t
  val get : state -> Well.rpc_ctx -> IdReq.t -> Task.t
  val create : state -> Well.rpc_ctx -> CreateReq.t -> Task.t
  val update : state -> Well.rpc_ctx -> UpdateReq.t -> Task.t
  val delete : state -> Well.rpc_ctx -> IdReq.t -> Ok.t
end

let make_spec (type s) (module I : IMPL with type state = s) : Well.Service.spec =
  let state = ref (I.init ()) in
  { name = "TaskAccess"
  ; rpcs = []
  ; handler = (fun rpc_name ctx_json payload ->
      let ctx = Well.rpc_ctx_of_wire ctx_json in
      match rpc_name with
      | "list" ->
          TaskList.to_wire (I.list !state ctx (ListReq.of_wire payload))
      | "get" ->
          Task.to_wire (I.get !state ctx (IdReq.of_wire payload))
      | "create" ->
          Task.to_wire (I.create !state ctx (CreateReq.of_wire payload))
      | "update" ->
          Task.to_wire (I.update !state ctx (UpdateReq.of_wire payload))
      | "delete" ->
          Ok.to_wire (I.delete !state ctx (IdReq.of_wire payload))
      | _ -> failwith ("Unknown RPC: " ^ rpc_name))
  ; set_ref = (fun f -> _service_ref := Some f)
  }

let list ~ctx ~limit =
  let ctx_wire = Well.rpc_ctx_to_wire ctx in
  let wire = ListReq.to_wire (ListReq.make ~limit ()) in
  TaskList.of_wire
    ((match !_service_ref with
      | Some f -> f "list" ctx_wire wire
      | None -> failwith "TaskAccess: service not registered"))

let get ~ctx ~id =
  let ctx_wire = Well.rpc_ctx_to_wire ctx in
  let wire = IdReq.to_wire (IdReq.make ~id ()) in
  Task.of_wire
    ((match !_service_ref with
      | Some f -> f "get" ctx_wire wire
      | None -> failwith "TaskAccess: service not registered"))

let create ~ctx ~title =
  let ctx_wire = Well.rpc_ctx_to_wire ctx in
  let wire = CreateReq.to_wire (CreateReq.make ~title ()) in
  Task.of_wire
    ((match !_service_ref with
      | Some f -> f "create" ctx_wire wire
      | None -> failwith "TaskAccess: service not registered"))

let update ~ctx ~id ?title ?completed () =
  let ctx_wire = Well.rpc_ctx_to_wire ctx in
  let wire = UpdateReq.to_wire (UpdateReq.make ~id ?title ?completed ()) in
  Task.of_wire
    ((match !_service_ref with
      | Some f -> f "update" ctx_wire wire
      | None -> failwith "TaskAccess: service not registered"))

let delete ~ctx ~id =
  let ctx_wire = Well.rpc_ctx_to_wire ctx in
  let wire = IdReq.to_wire (IdReq.make ~id ()) in
  Ok.of_wire
    ((match !_service_ref with
      | Some f -> f "delete" ctx_wire wire
      | None -> failwith "TaskAccess: service not registered"))
|}

let contract_task_manager_ml =
  {|[@@@warning "-32"]

module AddReq = struct
  type t = {
    title : string;
  }

  let make ~title () =
    { title }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `String v.title;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let title = (match (_g 0) with `String s -> s | _ -> "") in
      { title }
    | _ -> failwith "AddReq.of_wire: expected JSON array"
end

module ToggleReq = struct
  type t = {
    id : int;
  }

  let make ~id () =
    { id }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `Int v.id;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let id = (match (_g 0) with `Int i -> i | _ -> 0) in
      { id }
    | _ -> failwith "ToggleReq.of_wire: expected JSON array"
end

module DeleteReq = struct
  type t = {
    id : int;
  }

  let make ~id () =
    { id }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `Int v.id;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let id = (match (_g 0) with `Int i -> i | _ -> 0) in
      { id }
    | _ -> failwith "DeleteReq.of_wire: expected JSON array"
end

module TaskListRes = struct
  type t = {
    tasks : Task_access.Task.t list;
  }

  let make ~tasks () =
    { tasks }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `List (List.map (fun item -> Task_access.Task.to_wire item) v.tasks);
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let tasks = (match (_g 0) with `List items -> List.map (fun item -> Task_access.Task.of_wire item) items | _ -> []) in
      { tasks }
    | _ -> failwith "TaskListRes.of_wire: expected JSON array"
end

module TaskRes = struct
  type t = {
    task : Task_access.Task.t;
  }

  let make ~task () =
    { task }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      Task_access.Task.to_wire v.task;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let task = Task_access.Task.of_wire (_g 0) in
      { task }
    | _ -> failwith "TaskRes.of_wire: expected JSON array"
end

module StatusRes = struct
  type t = {
    ok : bool;
  }

  let make ~ok () =
    { ok }

  let to_wire (v : t) : Yojson.Safe.t =
    `List [
      `Bool v.ok;
    ]

  let of_wire (wire : Yojson.Safe.t) : t =
    match wire with
    | `List arr ->
      let a = Array.of_list arr in let _g i = if i < Array.length a then a.(i) else `Null in
      let ok = (match (_g 0) with `Bool b -> b | _ -> false) in
      { ok }
    | _ -> failwith "StatusRes.of_wire: expected JSON array"
end

let _service_ref : (string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t) option ref = ref None

module type IMPL = sig
  type state
  val init : unit -> state
  val list : state -> Well.rpc_ctx -> Task_access.ListReq.t -> TaskListRes.t
  val add : state -> Well.rpc_ctx -> AddReq.t -> TaskRes.t
  val toggle : state -> Well.rpc_ctx -> ToggleReq.t -> TaskRes.t
  val delete : state -> Well.rpc_ctx -> DeleteReq.t -> StatusRes.t
end

let make_spec (type s) (module I : IMPL with type state = s) : Well.Service.spec =
  let state = ref (I.init ()) in
  { name = "TaskManager"
  ; rpcs = []
  ; handler = (fun rpc_name ctx_json payload ->
      let ctx = Well.rpc_ctx_of_wire ctx_json in
      match rpc_name with
      | "list" ->
          TaskListRes.to_wire (I.list !state ctx (Task_access.ListReq.of_wire payload))
      | "add" ->
          TaskRes.to_wire (I.add !state ctx (AddReq.of_wire payload))
      | "toggle" ->
          TaskRes.to_wire (I.toggle !state ctx (ToggleReq.of_wire payload))
      | "delete" ->
          StatusRes.to_wire (I.delete !state ctx (DeleteReq.of_wire payload))
      | _ -> failwith ("Unknown RPC: " ^ rpc_name))
  ; set_ref = (fun f -> _service_ref := Some f)
  }

let list ~ctx req =
  let ctx_wire = Well.rpc_ctx_to_wire ctx in
  let wire = Task_access.ListReq.to_wire req in
  TaskListRes.of_wire
    ((match !_service_ref with
      | Some f -> f "list" ctx_wire wire
      | None -> failwith "TaskManager: service not registered"))

let add ~ctx ~title =
  let ctx_wire = Well.rpc_ctx_to_wire ctx in
  let wire = AddReq.to_wire (AddReq.make ~title ()) in
  TaskRes.of_wire
    ((match !_service_ref with
      | Some f -> f "add" ctx_wire wire
      | None -> failwith "TaskManager: service not registered"))

let toggle ~ctx ~id =
  let ctx_wire = Well.rpc_ctx_to_wire ctx in
  let wire = ToggleReq.to_wire (ToggleReq.make ~id ()) in
  TaskRes.of_wire
    ((match !_service_ref with
      | Some f -> f "toggle" ctx_wire wire
      | None -> failwith "TaskManager: service not registered"))

let delete ~ctx ~id =
  let ctx_wire = Well.rpc_ctx_to_wire ctx in
  let wire = DeleteReq.to_wire (DeleteReq.make ~id ()) in
  StatusRes.of_wire
    ((match !_service_ref with
      | Some f -> f "delete" ctx_wire wire
      | None -> failwith "TaskManager: service not registered"))
|}

let contract_boundary_dune =
  {|(include_subdirs no)
; Contract library lives in build/ocaml/
|}

let contract_dune_file =
  {|(library
 (name contract)
 (wrapped false)
 (libraries well.core yojson))

(rule
 (targets note_access.ml task_access.ml task_manager.ml)
 (deps
  (file ../../NoteAccess.toml)
  (file ../../TaskAccess.toml)
  (file ../../TaskManager.toml))
 (mode promote)
 (action (run %{bin:well} contract build ../../ ..)))
|}

let static_dune =
  {|; TypeScript → JavaScript (auto-promoted to source tree on build)
; Requires bun — install from https://bun.sh
(rule
 (targets well.js)
 (deps (file well.ts))
 (mode promote)
 (action (run bun build well.ts --outdir . --minify)))

(rule
 (targets tasks.js)
 (deps
  (source_tree ts)
  (source_tree ../lib/contract/build/ts))
 (mode promote)
 (action (run bun build ts/tasks.ts --outdir . --minify)))
|}

let task_access_impl _name =
  {|(* TaskAccess implementation — SQLite backend *)
(* IDesign: Access service — talks to database *)

type task_row = {
  id : int;
  title : string;
  completed : int;
} [@@deriving table ~name:"tasks"]

let%query all_tasks = "SELECT id, title, completed FROM tasks ORDER BY id DESC"
let%query find_task = "SELECT id, title, completed FROM tasks WHERE id = :id"
let%query insert_task = "INSERT INTO tasks (title, completed) VALUES (:title, 0)"
let%query update_completed = "UPDATE tasks SET completed = :completed WHERE id = :id"
let%query update_title = "UPDATE tasks SET title = :title WHERE id = :id"
let%query delete_task = "DELETE FROM tasks WHERE id = :id"

let db = lazy (Well.Db.open_db ())
let get_db () = Lazy.force db

let task_of_row (r : All_tasks.row) : Task_access.Task.t =
  { id = r.id; title = r.title; completed = r.completed <> 0 }

let task_of_find (r : Find_task.row) : Task_access.Task.t =
  { id = r.id; title = r.title; completed = r.completed <> 0 }

module Impl : Task_access.IMPL with type state = unit = struct
  type state = unit
  let init () = ()

  let list () _ctx (req : Task_access.ListReq.t) =
    let db = get_db () in
    let rows = All_tasks.query db in
    let tasks = List.map task_of_row rows in
    let tasks =
      if req.limit > 0 then
        List.filteri (fun i _ -> i < req.limit) tasks
      else tasks
    in
    Task_access.TaskList.make ~tasks ()

  let get () _ctx (req : Task_access.IdReq.t) =
    let db = get_db () in
    match Find_task.query db ~id:req.id with
    | r :: _ -> task_of_find r
    | [] -> failwith "Task not found"

  let create () _ctx (req : Task_access.CreateReq.t) =
    let db = get_db () in
    Insert_task.exec db ~title:req.title;
    let id = Int64.to_int (Sqlite3.last_insert_rowid db) in
    Task_access.Task.make ~id ~title:req.title ~completed:false ()

  let update () _ctx (req : Task_access.UpdateReq.t) =
    let db = get_db () in
    (match req.title with
     | Some t -> Update_title.exec db ~title:t ~id:req.id
     | None -> ());
    (match req.completed with
     | Some c -> Update_completed.exec db ~completed:(if c then 1 else 0) ~id:req.id
     | None -> ());
    match Find_task.query db ~id:req.id with
    | r :: _ -> task_of_find r
    | [] -> failwith "Task not found"

  let delete () _ctx (req : Task_access.IdReq.t) =
    let db = get_db () in
    Delete_task.exec db ~id:req.id;
    Task_access.Ok.make ~ok:true ()
end

let spec = Task_access.make_spec (module Impl)
|}

let task_manager_impl _name =
  {|(* TaskManager implementation — business logic *)
(* IDesign: Manager service — delegates to Access *)

module Impl : Task_manager.IMPL with type state = unit = struct
  type state = unit
  let init () = ()

  let list () ctx (req : Task_access.ListReq.t) =
    let result = Task_access.list ~ctx ~limit:req.limit in
    Task_manager.TaskListRes.make ~tasks:result.tasks ()

  let add () ctx (req : Task_manager.AddReq.t) =
    if String.trim req.title = "" then failwith "Title cannot be empty";
    let task = Task_access.create ~ctx ~title:req.title in
    Task_manager.TaskRes.make ~task ()

  let toggle () ctx (req : Task_manager.ToggleReq.t) =
    let current = Task_access.get ~ctx ~id:req.id in
    ignore (Task_access.update ~ctx ~id:req.id ~completed:(not current.completed) ());
    let updated = Task_access.get ~ctx ~id:req.id in
    Task_manager.TaskRes.make ~task:updated ()

  let delete () ctx (req : Task_manager.DeleteReq.t) =
    ignore (Task_access.delete ~ctx ~id:req.id);
    Task_manager.StatusRes.make ~ok:true ()
end

let spec = Task_manager.make_spec (module Impl)
|}

let tasks_page _name =
  {|Well.get "/tasks" @@ fun _req ->
let open Html in
<Layout title="Tasks">
<div>
  <h1>(txt "Tasks — Contract/RPC Demo")</h1>
  <p>(txt "Service contracts with TypeScript client and SQLite backend.")</p>
  <div id="tasks-app" class_="tasks-container">
    <p class_="loading">(txt "Loading...")</p>
  </div>
  <p><a href="/">(txt "← Back")</a></p>
  <script src="/static/tasks.js" />
</div>
</Layout>
|}

let tasks_ts =
  {|// tasks.ts — UI for TaskManager (types + RPC from generated contract)

import { Proxy, type TaskListRes } from '../../lib/contract/build/ts/TaskManager';
import type { Task } from '../../lib/contract/build/ts/TaskAccess';

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

let tasks: Task[] = [];

async function loadTasks() {
  const res: TaskListRes = await Proxy.list({ limit: 100 });
  tasks = res.tasks;
  render();
}

async function addTask(title: string) {
  await Proxy.add({ title });
  await loadTasks();
}

async function toggleTask(id: number) {
  await Proxy.toggle({ id });
  await loadTasks();
}

async function deleteTask(id: number) {
  await Proxy.delete({ id });
  await loadTasks();
}

function render() {
  const app = document.getElementById("tasks-app");
  if (!app) return;

  const remaining = tasks.filter((t) => !t.completed).length;
  let html = `<form class="tasks-form" onsubmit="return false">
    <input type="text" id="task-input" placeholder="What needs to be done?" />
    <button type="submit">Add</button>
  </form>
  <ul class="tasks-list">`;

  for (const t of tasks) {
    const checked = t.completed ? " checked" : "";
    html += `<li class="task-item${t.completed ? " completed" : ""}">
      <label>
        <input type="checkbox"${checked} data-id="${t.id}" class="task-toggle" />
        <span>${escapeHtml(t.title)}</span>
      </label>
      <button class="task-delete" data-id="${t.id}">\u00d7</button>
    </li>`;
  }

  html += `</ul>
  <p class="tasks-remaining">${remaining} task${remaining !== 1 ? "s" : ""} remaining</p>`;

  app.innerHTML = html;

  const form = app.querySelector(".tasks-form") as HTMLFormElement;
  const input = app.querySelector("#task-input") as HTMLInputElement;
  form?.addEventListener("submit", (e) => {
    e.preventDefault();
    const title = input.value.trim();
    if (title) {
      addTask(title);
      input.value = "";
    }
  });

  app.querySelectorAll(".task-toggle").forEach((el) => {
    el.addEventListener("change", () => {
      const id = parseInt((el as HTMLInputElement).dataset.id!);
      toggleTask(id);
    });
  });

  app.querySelectorAll(".task-delete").forEach((el) => {
    el.addEventListener("click", () => {
      const id = parseInt((el as HTMLButtonElement).dataset.id!);
      deleteTask(id);
    });
  });
}

document.addEventListener("DOMContentLoaded", () => loadTasks());
|}

let tasks_js =
  {|(function(){"use strict";async function rpc(s,m,p){const r=await fetch("/rpc/"+s+"/"+m,{method:"POST",headers:{"Content-Type":"application/json","X-Requested-With":"XMLHttpRequest"},body:JSON.stringify(p)});if(!r.ok)throw new Error("RPC "+s+"."+m+": "+r.status);return r.json()}function decTask(w){return{id:w[0],title:w[1],completed:w[2]}}function decTaskListRes(w){return{tasks:w[0].map(v=>decTask(v))}}function esc(s){return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;")}let tasks=[];async function load(){const r=decTaskListRes(await rpc("TaskManager","list",[100]));tasks=r.tasks;render()}async function add(t){await rpc("TaskManager","add",[t]);await load()}async function toggle(id){await rpc("TaskManager","toggle",[id]);await load()}async function del(id){await rpc("TaskManager","delete",[id]);await load()}function render(){const app=document.getElementById("tasks-app");if(!app)return;const rem=tasks.filter(t=>!t.completed).length;let h='<form class="tasks-form" onsubmit="return false"><input type="text" id="task-input" placeholder="What needs to be done?" /><button type="submit">Add</button></form><ul class="tasks-list">';for(const t of tasks){h+='<li class="task-item'+(t.completed?" completed":"")+'"><label><input type="checkbox"'+(t.completed?" checked":"")+' data-id="'+t.id+'" class="task-toggle" /><span>'+esc(t.title)+'</span></label><button class="task-delete" data-id="'+t.id+'">\u00d7</button></li>'}h+='</ul><p class="tasks-remaining">'+rem+" task"+(rem!==1?"s":"")+" remaining</p>";app.innerHTML=h;const form=app.querySelector(".tasks-form");const input=app.querySelector("#task-input");form?.addEventListener("submit",e=>{e.preventDefault();const t=input.value.trim();if(t){add(t);input.value=""}});app.querySelectorAll(".task-toggle").forEach(el=>{el.addEventListener("change",()=>{toggle(parseInt(el.dataset.id))})});app.querySelectorAll(".task-delete").forEach(el=>{el.addEventListener("click",()=>{del(parseInt(el.dataset.id))})})}document.addEventListener("DOMContentLoaded",()=>load())})();
|}

let upload_page _name =
  {|let upload_dir = "data/uploads"

let ensure_dir () =
  if not (Well.file_exists upload_dir) then
    Well.mkdir upload_dir
;;

Well.get "/upload" @@ fun req ->
let open Html in
let token = Well.csrf_token req in
let files = Well.list_dir upload_dir in
<Layout title="Upload">
<div>
  <h1>(txt "Upload — File Upload Demo")</h1>
  <p>(txt "Multipart form-data upload with streaming download.")</p>
  <form action="/upload" method_="POST" enctype="multipart/form-data" class_="upload-form">
    (csrf_input token)
    <label for_="file" class_="upload-label">(txt "Choose a file")</label>
    <input type_="file" name_="file" id="file" />
    <button type_="submit">(txt "Upload")</button>
  </form>
  (match files with
   | [] -> <p class_="upload-empty">(txt "No files uploaded yet.")</p>
   | _ ->
     <div>
       <h2>(txt "Uploaded files")</h2>
       <ul class_="upload-list">
         (files |> List.map (fun name ->
           <li>
             <a href=("/upload/download/" ^ name)>(txt name)</a>
           </li>
         ) |> cat |> raw)
       </ul>
     </div>)
  <p><a href="/">(txt "\xe2\x86\x90 Back")</a></p>
</div>
</Layout>
;;

Well.post "/upload" @@ fun req ->
ensure_dir ();
match Well.file req "file" with
| None -> Well.redirect "/upload"
| Some f ->
    let safe_name =
      String.map (fun c -> if c = '/' || c = '\\' || c = '\x00' then '_' else c) f.filename
    in
    let path = Filename.concat upload_dir safe_name in
    Well.write_file path f.data;
    Well.redirect "/upload"
;;

Well.get "/upload/download/:name" @@ fun req ->
let name = Well.param req "name" in
let safe_name =
  String.map (fun c -> if c = '/' || c = '\\' || c = '\x00' then '_' else c) name
in
let path = Filename.concat upload_dir safe_name in
if not (Well.file_exists path) then
  Well.text "Not found" |> Well.status 404
else
  Well.stream_file
    ~headers:[("Content-Disposition", "attachment; filename=\"" ^ safe_name ^ "\"")]
    path
|}

let upload_css =
  {|
/* Upload */
.upload-form { display: flex; gap: 0.5rem; align-items: center; margin: 1rem 0; flex-wrap: wrap; }
.upload-form input[type="file"] { flex: 1; min-width: 200px; }
.upload-form button { padding: 0.5rem 1rem; background: #2563eb; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 1rem; }
.upload-form button:hover { background: #1d4ed8; }
.upload-label { font-weight: 600; }
.upload-list { list-style: none; margin-top: 0.5rem; }
.upload-list li { padding: 0.4rem 0; border-bottom: 1px solid #e5e7eb; }
.upload-list a { text-decoration: none; }
.upload-list a:hover { text-decoration: underline; }
.upload-empty { color: #6b7280; margin: 1rem 0; }
|}

let tsconfig_json =
  {|{
  "compilerOptions": {
    "target": "ES2020",
    "strict": true,
    "noEmit": true
  },
  "include": ["static/ts", "lib/contract/build/ts"]
}
|}

let contract_ts_rpc =
  {|export async function rpc(service: string, method: string, payload: unknown[]): Promise<unknown> {
  const res = await fetch(`/rpc/${service}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest" },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`RPC ${service}.${method}: ${res.status}`);
  return res.json();
}
|}

let contract_ts_note_access =
  {|import { rpc } from './rpc';

export interface Note {
  id: number;
  title: string;
  body: string;
}

export function encodeNote(v: Note): unknown[] {
  return [v.id, v.title, v.body];
}

export function decodeNote(wire: unknown[]): Note {
  return {
    id: wire[0] as number,
    title: wire[1] as string,
    body: wire[2] as string,
  };
}

export interface ListReq {
  limit: number;
}

export function encodeListReq(v: ListReq): unknown[] {
  return [v.limit];
}

export interface IdReq {
  id: number;
}

export function encodeIdReq(v: IdReq): unknown[] {
  return [v.id];
}

export interface CreateReq {
  title: string;
  body: string;
}

export function encodeCreateReq(v: CreateReq): unknown[] {
  return [v.title, v.body];
}

export interface NoteList {
  notes: Note[];
}

export function decodeNoteList(wire: unknown[]): NoteList {
  return {
    notes: (wire[0] as unknown[]).map(v => decodeNote(v as unknown[])),
  };
}

export interface Ok {
  ok: boolean;
}

export function decodeOk(wire: unknown[]): Ok {
  return {
    ok: wire[0] as boolean,
  };
}

export interface Impl {
  list(req: ListReq): Promise<NoteList>;
  get(req: IdReq): Promise<Note>;
  create(req: CreateReq): Promise<Note>;
  delete(req: IdReq): Promise<Ok>;
}

export const Proxy: Impl = {
  async list(req) {
    return decodeNoteList(await rpc("NoteAccess", "list", encodeListReq(req)) as unknown[]);
  },
  async get(req) {
    return decodeNote(await rpc("NoteAccess", "get", encodeIdReq(req)) as unknown[]);
  },
  async create(req) {
    return decodeNote(await rpc("NoteAccess", "create", encodeCreateReq(req)) as unknown[]);
  },
  async delete(req) {
    return decodeOk(await rpc("NoteAccess", "delete", encodeIdReq(req)) as unknown[]);
  },
};
|}

let contract_ts_task_access =
  {|import { rpc } from './rpc';

export interface Task {
  id: number;
  title: string;
  completed: boolean;
}

export function encodeTask(v: Task): unknown[] {
  return [v.id, v.title, v.completed];
}

export function decodeTask(wire: unknown[]): Task {
  return {
    id: wire[0] as number,
    title: wire[1] as string,
    completed: wire[2] as boolean,
  };
}

export interface ListReq {
  limit: number;
}

export function encodeListReq(v: ListReq): unknown[] {
  return [v.limit];
}

export function decodeListReq(wire: unknown[]): ListReq {
  return {
    limit: wire[0] as number,
  };
}

export interface IdReq {
  id: number;
}

export function encodeIdReq(v: IdReq): unknown[] {
  return [v.id];
}

export function decodeIdReq(wire: unknown[]): IdReq {
  return {
    id: wire[0] as number,
  };
}

export interface CreateReq {
  title: string;
}

export function encodeCreateReq(v: CreateReq): unknown[] {
  return [v.title];
}

export function decodeCreateReq(wire: unknown[]): CreateReq {
  return {
    title: wire[0] as string,
  };
}

export interface UpdateReq {
  id: number;
  title: string | null;
  completed: boolean | null;
}

export function encodeUpdateReq(v: UpdateReq): unknown[] {
  return [v.id, v.title !== null ? v.title : null, v.completed !== null ? v.completed : null];
}

export function decodeUpdateReq(wire: unknown[]): UpdateReq {
  return {
    id: wire[0] as number,
    title: wire[1] === null ? null : (v => v as string)(wire[1]),
    completed: wire[2] === null ? null : (v => v as boolean)(wire[2]),
  };
}

export interface TaskList {
  tasks: Task[];
}

export function encodeTaskList(v: TaskList): unknown[] {
  return [v.tasks.map(v => encodeTask(v))];
}

export function decodeTaskList(wire: unknown[]): TaskList {
  return {
    tasks: (wire[0] as unknown[]).map(v => decodeTask(v as unknown[])),
  };
}

export interface Ok {
  ok: boolean;
}

export function encodeOk(v: Ok): unknown[] {
  return [v.ok];
}

export function decodeOk(wire: unknown[]): Ok {
  return {
    ok: wire[0] as boolean,
  };
}

export interface Impl {
  list(req: ListReq): Promise<TaskList>;
  get(req: IdReq): Promise<Task>;
  create(req: CreateReq): Promise<Task>;
  update(req: UpdateReq): Promise<Task>;
  delete(req: IdReq): Promise<Ok>;
}

export const Proxy: Impl = {
  async list(req) {
    return decodeTaskList(await rpc("TaskAccess", "list", encodeListReq(req)) as unknown[]);
  },
  async get(req) {
    return decodeTask(await rpc("TaskAccess", "get", encodeIdReq(req)) as unknown[]);
  },
  async create(req) {
    return decodeTask(await rpc("TaskAccess", "create", encodeCreateReq(req)) as unknown[]);
  },
  async update(req) {
    return decodeTask(await rpc("TaskAccess", "update", encodeUpdateReq(req)) as unknown[]);
  },
  async delete(req) {
    return decodeOk(await rpc("TaskAccess", "delete", encodeIdReq(req)) as unknown[]);
  },
};
|}

let contract_ts_task_manager =
  {|import { rpc } from './rpc';
import * as TaskAccess from './TaskAccess';

export interface AddReq {
  title: string;
}

export function encodeAddReq(v: AddReq): unknown[] {
  return [v.title];
}

export function decodeAddReq(wire: unknown[]): AddReq {
  return {
    title: wire[0] as string,
  };
}

export interface ToggleReq {
  id: number;
}

export function encodeToggleReq(v: ToggleReq): unknown[] {
  return [v.id];
}

export function decodeToggleReq(wire: unknown[]): ToggleReq {
  return {
    id: wire[0] as number,
  };
}

export interface DeleteReq {
  id: number;
}

export function encodeDeleteReq(v: DeleteReq): unknown[] {
  return [v.id];
}

export function decodeDeleteReq(wire: unknown[]): DeleteReq {
  return {
    id: wire[0] as number,
  };
}

export interface TaskListRes {
  tasks: TaskAccess.Task[];
}

export function encodeTaskListRes(v: TaskListRes): unknown[] {
  return [v.tasks.map(v => TaskAccess.encodeTask(v))];
}

export function decodeTaskListRes(wire: unknown[]): TaskListRes {
  return {
    tasks: (wire[0] as unknown[]).map(v => TaskAccess.decodeTask(v as unknown[])),
  };
}

export interface TaskRes {
  task: TaskAccess.Task;
}

export function encodeTaskRes(v: TaskRes): unknown[] {
  return [TaskAccess.encodeTask(v.task)];
}

export function decodeTaskRes(wire: unknown[]): TaskRes {
  return {
    task: TaskAccess.decodeTask(wire[0] as unknown[]),
  };
}

export interface StatusRes {
  ok: boolean;
}

export function encodeStatusRes(v: StatusRes): unknown[] {
  return [v.ok];
}

export function decodeStatusRes(wire: unknown[]): StatusRes {
  return {
    ok: wire[0] as boolean,
  };
}

export interface Impl {
  list(req: TaskAccess.ListReq): Promise<TaskListRes>;
  add(req: AddReq): Promise<TaskRes>;
  toggle(req: ToggleReq): Promise<TaskRes>;
  delete(req: DeleteReq): Promise<StatusRes>;
}

export const Proxy: Impl = {
  async list(req) {
    return decodeTaskListRes(await rpc("TaskManager", "list", TaskAccess.encodeListReq(req)) as unknown[]);
  },
  async add(req) {
    return decodeTaskRes(await rpc("TaskManager", "add", encodeAddReq(req)) as unknown[]);
  },
  async toggle(req) {
    return decodeTaskRes(await rpc("TaskManager", "toggle", encodeToggleReq(req)) as unknown[]);
  },
  async delete(req) {
    return decodeStatusRes(await rpc("TaskManager", "delete", encodeDeleteReq(req)) as unknown[]);
  },
};
|}

let well_skill =
  {well_skill|---
name: well
description: Use when building features, pages, routes, LiveViews, models, or services in a well framework application. Covers MLX syntax, route registration, LiveView patterns, type-safe SQL, contracts, and project conventions.
user-invocable: true
allowed-tools: Read, Edit, Write, Bash, Glob, Grep
---

# Well Framework — Code Generation Guide

You are generating code for a **well** application — a full-stack OCaml web framework with server-side rendering, LiveView, type-safe SQL, and service contracts.

## File Extensions

- `.ml` — pure OCaml (models, queries, logic, services)
- `.mlx` — OCaml + JSX (pages, components, layouts)

## MLX Syntax (CRITICAL)

MLX is JSX for OCaml. Children inside JSX tags follow OCaml `simple_expr` grammar:

```ocaml
(* CORRECT *)
<div>"literal string"</div>
<div>variable_name</div>
<div>(txt "hello")</div>
<div>(string_of_int count)</div>
<div>(if cond then <span>"yes"</span> else <span>"no"</span>)</div>
<Tag prop="value" prop2=variable />

(* WRONG — these are ALL syntax errors *)
<div>{txt "hello"}</div>     (* {..} is record syntax only! *)
<div>{string_of_int x}</div> (* use parentheses instead *)
<div>{42}</div>              (* not expression interpolation *)
```

Rules:
- `"string"` — literal string child
- `identifier` — bare variable
- `(expr)` — parenthesized expression for function calls, operators, anything complex
- `{...}` — record expression ONLY (e.g. `{name; age}`) — NOT for interpolation

### MLX Common Pitfalls

- **No `empty` node** — use `(txt "")` when you need to render nothing (e.g. in else branches)
- **`textarea` children must be `node`** — use `<textarea>(txt value)</textarea>`, NOT `<textarea>value</textarea>` (bare variable is string, not node) and NOT `<textarea>"default"</textarea>` (literal string is also not node)
- **All attribute values are strings** — use `value=(string_of_int n)` for numbers
- **`_` suffix for OCaml keywords** — `class_`, `type_`, `method_`, `name_`, `for_`

## HTML Attributes Reference

All HTML elements support these optional labeled parameters. There is no `empty` — there are no other attributes beyond this list.

### Available on ALL elements:
```
?id  ?class_  ?lang
?data_lv_click  ?data_lv_submit  ?data_lv_change
?data_lv_debounce  ?data_lv_throttle  ?data_lv_hook
?data_lv_navigate  ?data_lv_patch
?action  ?method_  ?href  ?type_  ?name_  ?placeholder
?value  ?charset  ?content  ?src  ?rel  ?enctype
?accept  ?for_  ?multiple (bool — only boolean attr)
```

### NOT supported (do NOT use):
`required`, `disabled`, `readonly`, `checked`, `selected`, `autofocus`, `autocomplete`, `min`, `max`, `step`, `rows`, `cols`, `width`, `height`, `target`, `alt`, `aria-*`, `role`, custom `data-*` (only `data-lv-*`)

### Available elements:
- **Tags**: `html`, `head`, `title`, `body`, `div`, `span`, `p`, `h1`–`h4`, `a`, `main`, `footer`, `header`, `nav`, `section`, `form`, `button`, `input`, `label`, `ul`, `ol`, `li`, `strong`, `em`, `b`, `i`, `small`, `pre`, `code`, `blockquote`, `table`, `thead`, `tbody`, `tr`, `th`, `td`, `textarea`, `select`, `option`, `script`
- **Void tags** (self-closing): `meta`, `link`
- **Not available**: `img` (use `raw` if needed)

## Project Structure

```
myapp/
├── bin/main.ml                         # Entry point → App.run ()
├── lib/
│   ├── app.ml                          # Middleware, services, routes, Well.run ()
│   ├── events.ml                       # Typed pub/sub topics
│   ├── note_access/note_access_impl.ml # NoteAccess service implementation
│   ├── task_access/task_access_impl.ml # TaskAccess service implementation
│   ├── task_manager/task_manager_impl.ml
│   ├── client/
│   │   ├── widgets/layout.mlx          # Layout component
│   │   ├── pages/home_page.mlx         # Routes: Well.get "/" ...
│   │   ├── live/counter_live.mlx       # LiveView module
│   │   └── request_id.ml              # Request ID middleware
│   └── contract/                       # Service contracts (TOML)
├── static/                             # CSS, JS, assets
└── test/myapp_test.ml                  # Tests
```

The app library uses `(include_subdirs unqualified)` and `(wrapped false)` — every file is a top-level module (e.g. `Layout`, `Counter_live`).

## Routes

Register routes in `.mlx` files. Handlers return `response` (polymorphic variant).

```ocaml
(* Simple page *)
Well.get "/about" @@ fun _req ->
let open Html in
<Layout title="About">
  <h1>(txt "About")</h1>
</Layout>

(* With path params *)
Well.get "/users/:id" @@ fun req ->
let id = Well.param req "id" in
Well.json (`Assoc [("id", `String id)])

(* Form handling *)
Well.post "/items" @@ fun req ->
let name = Well.form req "name" in
(* ... process ... *)
Well.redirect "/items"

(* Per-route middleware *)
let auth = [Well.require_auth ()]
;;
Well.get ~middleware:auth "/admin" @@ fun req ->
(* only logged-in users *)
```

Response types — all coerce automatically:
- `Html.node` — `<div>...</div>` (text/html)
- `` `Text "..." `` or `Well.text "..."` (text/plain)
- `` `Assoc [...] `` or `Well.json (...)` (application/json)
- `Well.redirect "/path"` (302)
- Pipeline: `<div/> |> Well.status 201 |> Well.header "X-Custom" "val"`

## Layout Component

```ocaml
(* layout.mlx *)
let createElement ?title:(page_title = "") ?(children = []) () =
  let open Html in
  <html lang="en">
    <head>
      <meta charset="utf-8" />
      <title>(txt page_title)</title>
      <link rel="stylesheet" href="/static/app.css" />
    </head>
    <body>
      <main>(children |> cat |> raw)</main>
      <script type_="module" src="/static/well.js" />
    </body>
  </html>
```

Use in pages: `<Layout title="My Page"><h1>(txt "Hello")</h1></Layout>`

## LiveView — Server-Side Reactive UI

LiveView uses Elm architecture: model -> update -> view. All state lives on the server, updates via WebSocket.

```ocaml
(* counter_live.mlx *)
type model = { count: int } [@@deriving yojson]
type msg = Increment | Decrement | Reset [@@deriving yojson]

let persistence = Well.LiveView.Ephemeral  (* or Session, User *)
let subscriptions = []  (* MessageBus channels — required field *)

let init _req _props = { count = 0 }

let update _req model = function
  | Increment -> { count = model.count + 1 }
  | Decrement -> { count = model.count - 1 }
  | Reset -> { count = 0 }

let handle_params _req model = model
let temporary_assigns model = model

let view model =
  let open Html in
  <div>
    <span>(dynamic "count" (string_of_int model.count))</span>
    <button data_lv_click="Increment">(txt "+")</button>
    <button data_lv_click="Decrement">(txt "-")</button>
  </div>
```

Register in `lib/app.ml`:
```ocaml
Well.live "/counter" (module Counter_live);
```

Embed in a page:
```ocaml
<Well.LiveView name="counter" />
(* with props: *)
<Well.LiveView name="counter" initial="10" step="5" />
```

Key LiveView patterns:
- `dynamic "key" value` — marks text that changes (diffing optimization)
- `each ~id:"list-id" items ~key:fn render_fn` — keyed list rendering
- `data_lv_click="MsgName"` — click sends msg to server
- `data_lv_submit="MsgName"` — form submit
- `data_lv_change="MsgName"` — input change (sends `[MsgName, input_value]`)
- `data_lv_debounce="300"` — debounce input (ms)
- `data_lv_navigate="/path"` — client-side navigation
- `data_lv_hook="HookName"` — attach JS hook

Variant encoding (ppx_deriving_yojson):
- `Increment` -> `["Increment"]` (JSON array)
- `SetValue of int` -> `["SetValue", 42]`
- Click handler sends array format: `data_lv_click="Increment"` sends `["Increment"]`
- Change handler sends: `data_lv_change="Search"` sends `["Search", "<input value>"]`

### LiveView View Constraints (CRITICAL)

The `view` function's DOM structure must be **stable across renders**. The patching mechanism only handles:
- `dynamic` — updates text content of marked elements
- `each` list_ops — adds, removes, reorders keyed list items

**It does NOT handle structural DOM changes.** If `if/else` in the view changes which elements exist, the patch silently fails and the UI does not update.

```ocaml
(* BAD — structural change breaks patching *)
let view model =
  let open Html in
  (if model.items = [] then
    <div class_="empty">(txt "Nothing here")</div>
  else
    <div class_="list">
      (each ~id:"items" model.items ~key:... (fun item -> ...))
    </div>)

(* GOOD — stable structure, conditional text via dynamic *)
let view model =
  let open Html in
  <div>
    <p>(dynamic "status" (if model.items = [] then "Nothing here" else ""))</p>
    <div class_="list">
      (each ~id:"items" model.items
        ~key:(fun item -> string_of_int item.id)
        (fun item -> ...))
    </div>
  </div>
```

Rules for LiveView views:
1. **Always render `each` containers** — even if the list is empty, the container stays in the DOM and list_ops clear it
2. **Use `dynamic` for conditional text** — not `if/else` that swaps elements
3. **Keep DOM tree shape identical** between renders — same elements, same nesting, same order
4. **Hide empty states with CSS** — use `:empty` or `display:none` when a `dynamic` value is empty, not structural conditionals

### LiveView Search/Filter Example

A complete example of a search LiveView with `data_lv_change`:

```ocaml
(* search_live.mlx *)
type item = { id: int; name: string } [@@deriving yojson]

type model = {
  query: string;
  results: item list;
  empty_msg: string;
} [@@deriving yojson]

type msg = Search of string [@@deriving yojson]

let persistence = Well.LiveView.Ephemeral
let subscriptions = []

let search query =
  let db = MyModel.get_db () in
  if query = "" then MyModel.All.query db |> List.map to_item
  else
    let q = "%" ^ query ^ "%" in
    MyModel.Search.query db ~q |> List.map to_item

let make_model query =
  let results = search query in
  { query; results;
    empty_msg = if results = [] then "No results" else "" }

let init _req _props = make_model ""

let update _req _model = function
  | Search q -> make_model q

let handle_params _req model = model
let temporary_assigns model = model

let view model =
  let open Html in
  <div>
    <input
      type_="text"
      placeholder="Search..."
      value=model.query
      data_lv_change="Search"
      data_lv_debounce="300" />
    <p>(dynamic "empty_msg" model.empty_msg)</p>
    <div>
      (each ~id:"results" model.results
        ~key:(fun r -> string_of_int r.id)
        (fun r ->
          <div>
            <span>(dynamic "name" r.name)</span>
          </div>
        ))
    </div>
  </div>
```

## Typed Pub/Sub (Well.MessageBus)

Define events in `events.ml` with typed topics:

```ocaml
(* events.ml *)
type counter_event = [`Incremented of string * int | `Decremented of string * int | `Reset]
[@@deriving yojson, topic]
```

Publish from any LiveView or handler:

```ocaml
Well.publish Events.counter_event (`Incremented ("increment", m.count))
```

Subscribe in a LiveView via `subscriptions`:

```ocaml
let subscriptions = [Well.topic_name Events.counter_event]
type msg = Events.counter_event [@@deriving yojson]
```

### Keyed Topics (channel:key) — Request/Reply Pattern

For dynamic channels with UUIDs (e.g. command sourcing), use keyed topics.
The topic's channel becomes a prefix, the key is appended after `:`.

```ocaml
(* events.ml — define command and response topics *)
type order_cmd = { items: string list } [@@deriving yojson, topic ~name:"order:cmd"]
type order_result = { order_id: string } [@@deriving yojson, topic ~name:"order:result"]
```

**Manager** subscribes to all `order:cmd:*`:
```ocaml
Well.subscribe_keyed Events.order_cmd (fun kev ->
  let cmd = kev.event.value in   (* typed: order_cmd *)
  let key = kev.key in           (* the UUID suffix *)
  let result = process cmd in
  Well.publish_keyed ~ephemeral:true Events.order_result ~key result)
```

**HTTP endpoint** sends command, awaits typed response:
```ocaml
Well.post "/orders" @@ fun req ->
let cmd = parse_body req in
let key = generate_uuid () in
let result = Well.request ~cmd:Events.order_cmd ~reply:Events.order_result
               ~key cmd in
Well.json (order_result_to_yojson result)
```

`Well.request` blocks the current fiber (not thread), default timeout 5s, raises `Well.Request_timeout`.

**Replay safety**: `~live_only:true` subscriptions are skipped during replay, and all `publish` calls during replay are automatically ephemeral:
```ocaml
(* Always runs — cross-Manager state update *)
Well.subscribe_keyed Events.order_cmd (fun kev -> process kev.event.value)

(* Only runs live — external side effect *)
Well.subscribe ~live_only:true Events.order_event (fun evt ->
  External_api.sync evt.value)
```

## Type-Safe SQL (well.ppx)

Define models and queries — compiler validates SQL at build time.

```ocaml
(* notes.ml *)
type note = {
  id : int;
  title : string;
  body : string;
} [@@deriving table ~name:"notes"]

let%query all_notes = "SELECT id, title, body FROM notes ORDER BY id DESC"
let%query insert_note = "INSERT INTO notes (title, body) VALUES (:title, :body)"
let%query find_note = "SELECT id, title, body FROM notes WHERE id = :id"
let%query delete_note = "DELETE FROM notes WHERE id = :id"

let db = lazy (Well.Db.open_db ())
let get_db () = Lazy.force db
```

Usage:
```ocaml
let db = Notes.get_db () in
let notes = Notes.All_notes.query db in
Notes.Insert_note.exec db ~title:"Hello" ~body:"World";
```

Parameter syntax: `:name` in SQL -> `~name` labeled arg in generated code.
- SELECT -> generates `Module.query db ~param1 ~param2` returning `row list`
- INSERT/UPDATE/DELETE -> generates `Module.exec db ~param1 ~param2` returning `unit`

Auto-migration: `Well.Db.open_db ()` automatically creates tables and adds new columns.

## Service Contracts (TOML)

Define service interfaces in TOML, generate OCaml + TypeScript:

```toml
# TaskAccess.toml
[service.rpc]
list = "ListReq -> TaskList"
create = "CreateReq -> Task"

[msg.Task.struct]
id = "int"
title = "string"
completed = "bool"

[msg.ListReq.struct]
limit = "int"

[msg.CreateReq.struct]
title = "string"

[msg.TaskList.struct]
tasks = { type = "list", of = "Task" }
```

Generate: `well contract build .`

Implement:
```ocaml
module Impl : Task_access.IMPL with type state = unit = struct
  type state = unit
  let init () = ()

  let list () _ctx (req : Task_access.ListReq.t) =
    Task_access.TaskList.make ~tasks ()

  let create () _ctx (req : Task_access.CreateReq.t) =
    Task_access.Task.make ~id ~title:req.title ~completed:false ()
end

let spec = Task_access.make_spec (module Impl)
```

Register in `lib/app.ml`:
```ocaml
Well.Service.register Task_access_impl.spec;
Well.Service.expose "TaskAccess";  (* creates HTTP routes *)
```

## Middleware

```ocaml
(* lib/app.ml *)
Well.use Well.error_handler;
Well.use Well.logger;
Well.use Well.csrf;
Well.use (Well.rate_limit ~max_requests:60 ~window_ms:60_000 ());

(* Custom middleware *)
Well.use (fun next req ->
  (* before *)
  let resp = next req in
  (* after *)
  resp);
```

## Request Context (Well.Context)

```ocaml
module Ctx = Well.Context(struct
  type t = string
  let empty = ""
end)

(* In middleware: set *)
let middleware : Well.middleware = fun next req ->
  next (Ctx.set "value" req)

(* In handler: get *)
let value = Ctx.get req
```

## Auth / Sessions

```ocaml
(* Login *)
Well.session_set req "user_id" username;

(* Logout *)
Well.session_delete req "user_id";

(* Check current user *)
let user = Well.current_user req  (* string option *)

(* Require auth middleware — session-based, redirects to login *)
let auth = [Well.require_auth ()]
Well.get ~middleware:auth "/protected" @@ fun req -> ...

(* Basic auth middleware — HTTP Basic Authentication *)
let api_auth = [Well.basic_auth ~check:(fun user pass ->
  user = "admin" && pass = "secret") ()]
Well.get ~middleware:api_auth "/api/data" @@ fun req -> ...

(* Basic auth with custom realm *)
let admin = [Well.basic_auth ~check:check_credentials ~realm:"Admin Panel" ()]
```

## Forms & File Upload

```ocaml
(* URL-encoded form data *)
let title = Well.form req "title" in

(* CSRF token in forms *)
<form action="/submit" method_="POST">
  (csrf_input (Well.csrf_token req))
  <input type_="text" name_="title" />
  <button type_="submit">(txt "Submit")</button>
</form>

(* Textarea — children must be node, not bare string *)
<textarea name_="body" placeholder="Write...">(txt "")</textarea>
(* with value: *) <textarea name_="body">(txt some_variable)</textarea>

(* File upload *)
Well.post "/upload" @@ fun req ->
match Well.file req "file" with
| None -> Well.redirect "/upload"
| Some f ->
    Well.write_file ("data/uploads/" ^ f.filename) f.data;
    Well.redirect "/upload"
```

## MessageBus & Channels

```ocaml
(* ── Typed topics (fixed channel) ── *)
Well.publish Events.counter_event (`Incremented ("increment", 42))
Well.subscribe Events.counter_event (fun evt -> ignore evt.value)

(* ── Keyed topics (channel:key — dynamic) ── *)
Well.publish_keyed Events.order_cmd ~key:"abc-123" { items = ["x"] }
Well.subscribe_keyed Events.order_cmd (fun kev ->
  let _uuid = kev.key in          (* "abc-123" *)
  let _cmd = kev.event.value in)  (* typed order_cmd *)

(* ── Request/reply (publish + await response) ── *)
let result = Well.request ~cmd:Events.order_cmd ~reply:Events.order_result
               ~key:"abc-123" { items = ["x"] }
(* Blocks fiber, 5s timeout, raises Well.Request_timeout *)

(* ── Replay safety ── *)
Well.subscribe ~live_only:true Events.x (fun _ -> send_email ())
(* live_only subscribers are skipped during replay *)
(* All publish calls during replay are automatically ephemeral *)

(* ── Low-level MessageBus (untyped) ── *)
Well.MessageBus.publish "orders/new" (`Assoc [("id", `Int 42)]);
Well.MessageBus.publish ~ephemeral:true "typing/user1" `Null;
Well.MessageBus.subscribe "orders/*" (fun event ->
  Printf.printf "Got: %s\n" event.channel);

(* ── Channel — authorized WS gateway ── *)
Well.channel "room:*" (fun req topic ->
  match Well.current_user req with
  | Some _ -> Ok { subscribe = [topic] }
  | None -> Error "unauthorized");
```

## S3 Storage

Environment variables: `AWS_ENDPOINT_URL`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `S3_BUCKET`.

```ocaml
(* Connect — reads env vars, with optional overrides *)
let s3 = Well.S3.connect ()
(* Or with explicit config: *)
let s3 = Well.S3.connect
  ~endpoint_url:"https://s3.amazonaws.com"
  ~region:"eu-central-1"
  ~bucket:"my-bucket" ()

(* Upload — auto-detects MIME from extension *)
let () = match Well.S3.put s3 ~key:"photos/cat.jpg" image_data with
  | Ok () -> ()
  | Error msg -> failwith msg

(* Upload with explicit content type *)
let () = match Well.S3.put s3 ~key:"data/export" ~content_type:"application/csv" csv with
  | Ok () -> ()
  | Error msg -> failwith msg

(* Download *)
let data = match Well.S3.get s3 ~key:"photos/cat.jpg" with
  | Ok body -> body
  | Error msg -> failwith msg

(* Delete *)
let () = match Well.S3.delete s3 ~key:"photos/cat.jpg" with
  | Ok () -> ()
  | Error msg -> failwith msg

(* Copy *)
let () = match Well.S3.copy s3 ~src:"photos/cat.jpg" ~dst:"backup/cat.jpg" with
  | Ok () -> ()
  | Error msg -> failwith msg

(* Head — returns (status, headers) *)
let () = match Well.S3.head s3 ~key:"photos/cat.jpg" with
  | Ok (_status, headers) ->
    let size = List.assoc_opt "content-length" headers in
    ignore size
  | Error msg -> failwith msg

(* Presigned URL — default 24h expiry *)
let url = Well.S3.presigned_url s3 ~key:"photos/cat.jpg" ()
let url = Well.S3.presigned_url s3 ~key:"photos/cat.jpg" ~expires_in:3600 ()

(* Create bucket on startup *)
let () = match Well.S3.create_bucket s3 with
  | Ok () -> ()
  | Error msg -> failwith msg
```

## Testing

```ocaml
open Well_test

let () =
  describe "Notes" (fun () ->
    it "creates a note" (fun () ->
      Well.Db.with_test_db (fun db ->
        Notes.Insert_note.exec db ~title:"Test" ~body:"Body";
        let notes = Notes.All_notes.query db in
        expect (List.length notes) |> to_equal_int 1
      )
    );
  );
  run ~source_file:__FILE__ () |> exit_with_result
```

Integration test with real HTTP:
```ocaml
it "serves homepage" (fun () ->
  Well.with_test_server (fun port ->
    let url = Printf.sprintf "http://localhost:%d/" port in
    let body = Well_test.Http.get url in
    expect body |> to_contain "Welcome"
  )
);
```

## CLI Commands

```bash
well init <name>        # Scaffold new project
well test [-w] [-f pat] # Run tests (watch, filter)
well docs [--open]      # Generate HTML documentation
well contract build .   # Generate from TOML contracts
well db diff            # Show pending migrations
well repl               # Interactive service shell
```

## Companion Skills

When working on this project, use these companion skills for specialized decisions:

- **idesign-architecture**: Use for ALL architectural decisions — decomposing the system into services, deciding where code should live, reviewing layer violations, designing service contracts. Routes/LiveViews (client layer) must NEVER call access layer directly — always go through a manager.
- **frontend-design**: Use when building or improving UI — pages, components, layouts, styling. Produces distinctive, production-grade interfaces instead of generic HTML.

Services must hide internal functions using `open struct ... end`. Only the contract-defined interface should be public.

## Common Patterns Checklist

When adding a new feature, you typically need:

1. **Static page**: Create `lib/client/pages/feature_page.mlx` with `Well.get "/path" @@ fun req -> ...`
2. **With data**: Create `lib/feature_access/feature_access.ml` with model type + `[@@deriving table]` + `let%query` + `let db = lazy (Well.Db.open_db ())`
3. **LiveView**: Create `lib/client/live/feature_live.mlx` with `model`/`msg` types + `[@@deriving yojson]` + `init`/`update`/`view`, register with `Well.live "/path" (module Feature_live)` in `lib/app.ml`
4. **Service**: Create TOML contract, run `well contract build`, implement `IMPL` module in `lib/feature_access/`, register in `lib/app.ml`
5. **Tests**: Add to `test/` with `Well.Db.with_test_db` or `Well.with_test_server`
|well_skill}

let idesign_skill_md = {idesign|---
name: idesign-architecture
description: >
  IDesign Method for system architecture based on Juval Lowy's "Righting Software".
  Use when designing system architecture, decomposing systems into services,
  reviewing architecture for anti-patterns, discussing volatility-based decomposition,
  layered architecture, service contracts, or composable design.
  Triggers: system design, architecture review, decomposition, microservices,
  service boundaries, layered architecture, volatility analysis, service contracts,
  system structure, anti-patterns, functional decomposition critique.
---

# IDesign Architecture Method

You are a software architect applying the IDesign Method from Juval Lowy's "Righting Software." Every recommendation you make MUST comply with the closed layered architecture, volatility-based decomposition, and the rules below. If you are unsure whether a recommendation complies, check it against the Design "Don'ts" and Interaction Rules before presenting it.

**The Method = System Design + Project Design**

This skill covers **System Design** -- the architecture half.

## The Design Prime Directive

**Never design against the requirements.**

There should never be a direct mapping between the requirements and the design. Requirements tell you WHAT the system must do. Design tells you HOW to structure it to accommodate change.

## Core Directives

1. **Avoid functional decomposition.** Never decompose a system based on its required functionality.
2. **Decompose based on volatility.** Identify areas of potential change and encapsulate them.
3. **Provide a composable design.** Find the smallest set of building blocks that satisfies all use cases.
4. **Offer features as aspects of integration, not implementation.** There is no feature -- features emerge from how components interact.
5. **Design iteratively, build incrementally.** Iterate on the design; build in vertical slices.

## Agent Decision Rules

When making architectural recommendations, you MUST follow these classification rules. Every component you recommend must fit into exactly one of the IDesign categories.

### Component Classification Decision Tree

When the user needs shared logic between multiple Managers:
1. **Is it a business activity (algorithm, calculation, validation, transformation)?** → Recommend a shared **Engine**. Engines are designed to be reused across Managers. Name it with a gerund prefix: `CalculatingEngine`, `ValidatingEngine`, `SearchEngine`.
2. **Is it access to a resource (database, external system, file store)?** → Recommend a shared **ResourceAccess**. Both Managers and Engines can call ResourceAccess. Name it with a noun prefix: `MembersAccess`, `PaymentsAccess`.
3. **Is it cross-cutting infrastructure (logging, security, messaging, diagnostics)?** → Recommend a **Utility**. The litmus test: could this component plausibly be used in any other system?
4. **Is it use-case orchestration (workflow, sequence of steps)?** → It belongs in a **Manager**. If two Managers need the same orchestration, reconsider your decomposition -- you may have too many Managers.

### NEVER Recommend These

- **NEVER** recommend shared libraries, shared modules, helper packages, or common code projects for business logic. In IDesign, ALL business logic lives in services (Managers, Engines, ResourceAccess). Shared business logic = shared Engine.
- **NEVER** recommend direct service-to-service calls that violate the closed architecture (calling up, calling sideways, skipping layers).
- **NEVER** recommend an open or semi-open architecture pattern.
- **NEVER** recommend services named after business domains or entities (OrderService, CustomerService, ProductService) -- this is domain/functional decomposition.
- **NEVER** recommend CRUD-based ResourceAccess contracts (Insert, Select, Delete). Use atomic business verbs (Credit, Debit, Enroll, Pay).
- **NEVER** recommend generic patterns (repository pattern, unit of work, mediator) as substitutes for proper IDesign classification. If you are tempted to suggest a pattern, first classify the component into an IDesign layer.

### Before Presenting Any Recommendation

Run this checklist:
1. **Layer check**: Does every component belong to exactly one layer (Client, Manager, Engine, ResourceAccess, Resource, Utility)?
2. **Naming check**: Managers have noun prefixes, Engines have gerund prefixes, ResourceAccess has noun prefixes. No gerunds outside Engines.
3. **Closed architecture check**: Does every call go to the adjacent lower layer only? Are there any up-calls, sideways calls, or skip-layer calls?
4. **Cardinality check**: Are there more than 5 Managers? Is the Manager-to-Engine ratio reasonable?
5. **Functional decomposition check**: Do any service names mirror requirements or business domains? If yes, reconsider.
6. **Reuse check**: If two Managers use different components for the same activity, you have functional decomposition. They should share one Engine.
7. **Symmetry check**: Do call chains across use cases follow similar patterns? Asymmetry is a design smell.

## What Is Wrong with Functional Decomposition

Functional decomposition (creating services that mirror requirements: InvoicingService, BillingService, ShippingService) is the most common and most damaging approach. It:

- **Couples services to requirements** -- any requirement change forces architecture change
- **Precludes reuse** -- services encode call ordering and cannot be used independently
- **Bloats clients** -- clients must orchestrate services, absorbing business logic
- **Creates either god services or service explosions** -- too few massive or too many tiny services
- **Maximizes the effect of change** -- changes ripple across multiple services
- **Makes systems untestable** -- regression testing becomes impractical

**Domain decomposition** (services per business domain: Sales, Accounting, Shipping) is functional decomposition in disguise with the same problems plus cross-domain duplication.

**The anti-design exercise:** Split the team. Ask one half for the best design, the other for the worst. They produce the same design -- because functional decomposition is both the natural approach AND the worst approach.

See [references/decomposition.md](references/decomposition.md) for full details.

## Volatility-Based Decomposition

The Method's core design directive: **decompose based on volatility.**

- Identify **areas of potential change** and encapsulate them into services
- Implement required behavior as the **interaction between encapsulated areas of volatility**
- Any change is contained within its vault -- no shrapnel flying everywhere
- What you encapsulate CAN be functional in nature but is hardly ever domain-functional

### Identifying Volatility

- Volatility is NOT variability. A tradesman gaining new attributes is variable. The membership management process changing is volatile.
- If identifying a volatility produces domain decomposition along entity lines, look further.
- You must clearly state: WHAT the volatility is, WHY it is volatile, WHAT RISK it poses.
- Volatility may reside outside the system (e.g., payments as external Resources).
- Solutions masquerading as requirements must be eliminated before identifying volatilities.

### Common Axes of Volatility

When examining a system, look for volatility in these areas:

| Axis | Examples |
|------|----------|
| **Client applications** | Different UIs, devices, APIs, connectivity models |
| **Business workflows** | Sequence of activities in use cases changing over time |
| **Business rules/activities** | How specific activities are performed (algorithms, regulations) |
| **Resource access** | Storage technology, location, access method |
| **Regulations/compliance** | Rules changing per locale, over time |
| **Integration** | External systems, protocols, data formats |
| **Security** | Authentication models, authorization schemes |
| **Deployment** | Cloud vs on-premise, data locality |

See [references/decomposition.md](references/decomposition.md) for full details.

## Layered Architecture (The Four Layers + Utilities)

The Method prescribes a **closed architecture** with four layers plus a Utilities bar.

```
  ┌─────────────────────────────────────────────┐
  │              CLIENT LAYER                    │  ← Who
  │  (Portals, Apps, APIs, Timers, Admin)       │
  ├─────────────────────────────────────────────┤
  │         BUSINESS LOGIC LAYER                │
  │  ┌──────────────┐  ┌──────────────┐         │
  │  │   Managers    │  │   Engines    │         │  ← What / How
  │  │ (sequence)    │  │ (activity)   │         │
  │  └──────────────┘  └──────────────┘         │
  ├─────────────────────────────────────────────┤  ┌──────────┐
  │         RESOURCE ACCESS LAYER               │  │          │
  │  (Atomic business verbs, NOT CRUDs)         │  │ UTILITIES│
  ├─────────────────────────────────────────────┤  │  BAR     │
  │            RESOURCE LAYER                   │  │(Security,│
  │  (Database, Files, Queues, External Systems)│  │ Logging, │
  └─────────────────────────────────────────────┘  │ Pub/Sub) │
                                                   └──────────┘
```

### Layer Roles

| Layer | Encapsulates | Component Type | Named As |
|-------|-------------|----------------|----------|
| **Client** | Volatility in WHO interacts | Client apps | N/A |
| **Manager** | Volatility in WHAT (use case sequence) | Managers | NounManager |
| **Engine** | Volatility in HOW (business activity) | Engines | GerundEngine |
| **ResourceAccess** | Volatility in HOW to access resources | ResourceAccess | NounAccess |
| **Resource** | WHERE system state lives | Resources | N/A |
| **Utilities** | Cross-cutting infrastructure | Utilities | Security, Logging, etc. |

### Key Properties

- **Volatility decreases top-down**: Clients are most volatile; Resources are least volatile
- **Reuse increases top-down**: Clients are least reusable; Resources are most reusable
- **Managers should be almost expendable**: If changing a Manager is expensive, it is too big. If trivial, it is pass-through (a flaw).
- **Closed architecture**: Components call only the adjacent lower layer. No up, no sideways, no skip-layer.
- **ResourceAccess exposes atomic business verbs** (Credit, Debit, Pay), NOT CRUDs (Select, Insert, Delete)

### Naming Rules

- Two-part compound words in PascalCase: prefix + type suffix
- **Managers**: noun prefix (AccountManager, MarketManager)
- **Engines**: gerund prefix (CalculatingEngine, SearchEngine, RegulationEngine)
- **ResourceAccess**: noun prefix associated with the Resource (MembersAccess, PaymentsAccess)
- Gerund prefixes ONLY on Engines. Gerunds elsewhere signal functional decomposition.

### Cardinality Guidelines

- **Max 5 Managers** in a system without subsystems
- **Max a handful of subsystems**
- **Max 3 Managers per subsystem**
- Golden ratio: 1 Manager: 0-1 Engines, 2 Managers: ~1 Engine, 3 Managers: ~2 Engines, 5 Managers: ~3 Engines
- **8+ Managers**: you have failed to produce a good design

See [references/structure.md](references/structure.md) for full details.

## Design "Don'ts"

These are **red flags indicating functional decomposition**. Violations must be investigated.

See [references/design-donts.md](references/design-donts.md) for the complete list (verbatim from the book).

## Composable Design

### Core Use Cases

Every system has 2-6 **core use cases** representing its raison d'etre. The composable design finds the **smallest set of ~10 components** that satisfies ALL core use cases. Non-core use cases (add member, create project, pay) are simple functionalities that any design can handle.

### "There Is No Feature"

Features are aspects of **integration**, not implementation. You do not implement features in individual services. Features emerge from how services interact. To add or change a feature, you change the workflows of the Managers, not the participating services.

### Handling Change

When a new requirement arrives, the correct response with a composable design is:
1. Mostly leave existing things alone
2. Extend the system by adding more slices or subsystems
3. Never destroy the first floor to add a second floor

See [references/composition.md](references/composition.md) for full details.

## Service Contract Design

Contracts are the public interfaces services present to clients. The basic element of reuse is the **contract, not the service**.

### Good Contracts Are:
1. **Logically consistent** -- no unrelated operations
2. **Cohesive** -- all aspects of the interaction, no more, no less
3. **Independent** -- each facet stands alone

### Contract Size Metrics
- **Optimal**: 3-5 operations per contract
- **Acceptable**: 6-9 operations
- **Poor design**: 12+ operations
- **Immediate reject**: 20+ operations
- **Red flag**: single-operation contracts

### Other Rules
- Avoid property-like operations (getters/setters)
- Limit contracts per service to 1 or 2
- Factor contracts down (base extraction), sideways (separate unrelated), up (shared hierarchy)

### Area of Minimum Cost
Total system cost = cost per service + integration cost. Both are nonlinear. There exists an **area of minimum cost** where services are not too big, not too small. Functional decomposition always lands at the expensive edges.

See [references/contract-design.md](references/contract-design.md) for full details.

## Design Validation

Validate the architecture BEFORE work begins:

1. Show the **call chain** or **sequence diagram** for each core use case
2. Demonstrate that the same components participate in multiple use cases in consistent patterns
3. Look for **self-similarity and symmetry** across call chains -- hallmark of good design
4. If validation is ambiguous, go back to the drawing board

## Business Alignment

Architecture must serve the business:

1. **Vision** -- terse, explicit, like a legal statement (e.g., "A platform for building applications to support the marketplace")
2. **Objectives** -- business perspective items derived from the vision (NOT technology objectives)
3. **Mission Statement** -- HOW you will deliver (e.g., "Design and build a collection of software components that the team can assemble into applications and features")
4. **Architecture** -- derived from mission statement, supporting all objectives

This chain (Vision -> Objectives -> Mission -> Architecture) reverses typical dynamics and gets the business on your side.

## Interaction Rules (Closed Architecture)

**Allowed:**
- All components can call Utilities
- Managers and Engines can call ResourceAccess
- Managers can call Engines
- Managers can queue calls to another Manager

**Forbidden** (see [Design "Don'ts"](references/design-donts.md)):
- No calling up
- No calling sideways (except queued Manager-to-Manager)
- No calling more than one layer down
- Resolve violations with queued calls or Pub/Sub

## Quick Reference Files

- [Decomposition](references/decomposition.md) -- Volatility-based decomposition, why functional/domain decomposition fail
- [Structure](references/structure.md) -- Layers, classification, naming, open/closed architectures, symmetry
- [Composition](references/composition.md) -- Composable design, core use cases, handling change
- [Design "Don'ts"](references/design-donts.md) -- VERBATIM list of architectural violations
- [Design Standard](references/design-standard.md) -- VERBATIM checklist of all directives and guidelines
- [Contract Design](references/contract-design.md) -- Service contracts, factoring, metrics, area of minimum cost
- [Design Example](references/design-example.md) -- TradeMe case study demonstrating the full method
|idesign}

let idesign_ref_decomposition = {idesign|# Decomposition (Ch. 2)

## Core Premise: Architecture = Decomposition

- **Software architecture** is the high-level design and structure of the software system.
- The essence of architecture is the breakdown of the system into its comprising components and how those components interact at run-time. This act is called **system decomposition**.
- **Wrong decomposition = wrong architecture**, which inflicts horrendous pain in the future, often leading to a complete rewrite.
- Services (in the service-orientation sense) are the most granular unit of architecture. Technology details (interfaces, operations, class hierarchies) are detailed design, NOT system decomposition.

## Avoid Functional Decomposition

Functional decomposition decomposes a system into building blocks based on its functionality. If the system needs invoicing, billing, and shipping, you create InvoicingService, BillingService, ShippingService.

### Why It Fails

1. **Couples services to requirements** -- any change in required functionality imposes a change on services. Such changes are inevitable over time.
2. **Precludes reuse** -- services encode call ordering (what comes before/after), forming a clique of tightly coupled services that cannot be independently reused.
3. **Too many or too big** -- leads to an explosion of services (hundreds of narrow functionalities) or bloated god monoliths. Both afflictions often appear side by side.
4. **Client bloat and coupling** -- someone must combine functional services into required behavior; that someone is the client. The client absorbs business logic (sequencing, ordering, error compensation). The client IS the system. Multiple clients (web, mobile) duplicate orchestration logic.
5. **Multiple points of entry** -- the client enters the system in multiple places, multiplying security, scalability, and cross-cutting concerns.
6. **Service chaining bloat** -- alternative: services call each other (A calls B calls C). Services become coupled to call order. Error compensation creates massive coupling (C must undo A and B on failure).
7. **Maximizes the effect of change** -- by definition, changes affect multiple (if not most) components. Accommodating change is THE reason to avoid functional decomposition.
8. **Makes systems untestable** -- coupling and complexity make only unit testing practical. Unit testing alone is borderline useless (defects are in interactions). Functional decomposition makes regression testing impractical, producing systems rife with defects.

### The TANSTAAFL Argument

Functional decomposition violates the first law of thermodynamics: the outcome (system design) should be high-value, but the process (mapping requirements to services) is fast, easy, mechanistic. **You cannot add value without effort.** The very attributes that make functional decomposition appealing preclude it from adding value.

### When TO Use Functional Decomposition

Functional decomposition IS a decent **requirements discovery technique** -- it helps discover hidden functionality areas, uncover requirements and their relationships. **Extending functional decomposition into a design is deadly.** There should never be a direct mapping between requirements and design.

## Avoid Domain Decomposition

Domain decomposition decomposes based on business domains (Sales, Engineering, Accounting). It is **even worse** than functional decomposition -- it is functional decomposition in disguise (Kitchen is where you do the cooking, Bedroom is where you do the sleeping).

Problems unique to domain decomposition:
- Each domain must duplicate functionality that occurs across domains
- Each domain devolves into an ugly grab bag of functionality
- Cross-domain communication reduced to CRUD-like state changes
- Building sequentially by domain is catastrophically wasteful (each new domain requires reworking all previous domains)
- There is no meaningful reuse between parts

## Volatility-Based Decomposition

### The Method's Design Directive

**Decompose based on volatility.**

### Definition

Volatility-based decomposition identifies **areas of potential change** and encapsulates those into services or system building blocks. You then implement the required behavior as the **interaction between the encapsulated areas of volatility**.

### The Vault Metaphor

Think of your system as a series of vaults. Any change is like a hand grenade with the pin pulled out. With volatility-based decomposition: open the appropriate vault's door, toss the grenade inside, close the door. Whatever was inside may be destroyed completely, but **there is no shrapnel flying everywhere**. You have contained the change.

### Encapsulation Is Not Necessarily Functional

What you encapsulate CAN be functional in nature but is hardly ever domain-functional (meaningful to the business). Example: Electricity in a house is an area of functionality AND an important area to encapsulate because power is highly volatile (AC/DC, 110V/220V, solar/generator/grid) and not specific to any domain. The receptacle encapsulates all that volatility.

### Identifying Volatility

- **Volatility vs. Variability**: A tradesman gaining new attributes is variable (data changes). The membership management process changing is volatile (behavior/structure changes). Only volatile things merit components.
- If identifying a volatility produces domain decomposition along entity lines, look further for the true underlying volatility.
- You must clearly state: WHAT the volatility is, WHY it is volatile, WHAT RISK it poses (likelihood and effect).
- There is nothing wrong with suggesting candidate volatilities, then examining the resultant architecture. If the result is a spiderweb of interactions or is asymmetric, the design is likely wrong.
- Volatility may reside outside the system entirely (e.g., payments handled by external systems as Resources).

### Solutions Masquerading as Requirements

Requirements often contain embedded solutions that constrain the design space unnecessarily. Before identifying volatilities, eliminate solutions masquerading as requirements:
- "The system shall use a SQL database" -- the real requirement is data persistence
- "The system shall send email notifications" -- the real requirement is user notification
- Strip away the "how" to reveal the "what"

### Benefits

- Changes are **contained in each module** -- no side effects outside the module boundary
- Lower complexity + easier maintenance = much improved quality
- **Reuse**: if something is encapsulated the same way in another system, you have a chance at reuse
- **Extensibility**: extend by adding more areas of encapsulated volatility or integrating existing areas differently
- **Resilience to feature creep**: changes during development are contained, giving a better chance of meeting the schedule

### VBD and Testing

Volatility-based decomposition lends well to regression testing. Fewer components, smaller components, and simpler interactions drastically reduce complexity. This makes it feasible to write regression testing that tests the system end to end, tests each subsystem individually, and eventually tests independent components. Since VBD contains changes inside building blocks, inevitable changes do not disrupt regression testing. You can test a change in isolation without interfering with inter-component and inter-subsystem testing.

### The Volatility Challenge

The main challenges in performing volatility-based decomposition have to do with **time, communication, and perception**:

- Volatility is often not self-evident. No customer will present requirements as areas of volatility -- they present functionality.
- VBD takes longer than functional decomposition. You must analyze requirements to recognize areas of volatility.
- The whole purpose of requirements analysis is to identify areas of volatility. This requires effort and sweat -- complying with the first law of thermodynamics (TANSTAAFL).
- **The 2% problem**: Architects decompose complete systems only every few years. The week-to-year ratio is roughly 1:50, or 2%. You will never be good at something you spend only 2% of your time on. Managers who spend an even smaller fraction managing architects during this critical phase will not understand why it takes time.
- **Dunning-Kruger effect**: People unskilled in a domain underestimate its complexity. When a manager says "just do A, then B, then C" they genuinely do not understand why proper decomposition takes time. Expect this and educate.
- **Fighting insanity**: If functional decomposition is all you have ever done, you will hear an irresistible pull to repeat it. You must resist. Your professional integrity is at stake.

### Resist the Siren Song

Just because you always had a reporting block, or because a reporting block already exists, does not mean you need a dedicated reporting component. If reporting is not a volatile area (from the business perspective), there is nothing to encapsulate. Adding such a component manifests functional decomposition.

You are Odysseus. Volatility-based decomposition is your mast. Resist the siren song of your previous bad habits. Plug the ears of the developers (they row/write code) and tie yourself to the method even when temptation strikes.

### Volatility and the Business

Not everything that could change should be encapsulated. Do **not** attempt to encapsulate the **nature of the business**.

Two indicators that a potential change is the nature of the business (and should NOT be encapsulated):
1. **The change is very rare** -- the likelihood of it happening is very low
2. **The encapsulation can only be done poorly** -- no practical amount of investment in time or effort will properly encapsulate it

A change to the nature of the business justifies killing the old system and starting from scratch (like razing a house to build a skyscraper on the same plot).

**Speculative design**: Once you embrace VBD, you may start seeing volatilities everywhere and try to encapsulate everything. This produces numerous building blocks -- a clear sign of bad design. If the use of an encapsulation is extremely unlikely, or it attempts to change the nature of the system, you have fallen into the speculative design trap.

### Design for Your Competitors

A useful technique for identifying volatilities: try to design a system for your competitor (or another division).

- Ask: Can your competitor use the system you are building? Can you use theirs?
- If not, list the barriers to reuse. Where both companies perform the same service differently, that activity is probably volatile -- encapsulate it.
- If both do something identically with no chance of divergence, there is no need for a component. Allocating one would be functional decomposition. Things competitors do identically likely represent the nature of the business.
- If you encapsulate a volatile activity and your competitor later adopts the same approach, the change is contained in a single component -- you have future-proofed your system.

### Volatility and Longevity

Volatility is intimately related to longevity. The longer things have been done a certain way, the longer they will likely continue -- but also the longer until they eventually change.

- You must put forward a design that accommodates changes even if at first glance they seem independent of current requirements.
- **Heuristic for time horizon**: If the projected system lifespan is 5-7 years, identify everything that changed in the application domain over the past 7 years. Similar changes will likely occur within a similar timespan.
- Examine the longevity of all involved systems and subsystems your design interacts with. If the ERP changes every 10 years and the last change was 8 years ago, encapsulate the ERP volatility.
- The more frequently things change, the more likely they will change again at the same rate.

### The Importance of Practicing

Identifying areas of volatility is an **acquired skill**. Hardly any architect is initially trained in VBD, and the vast majority use functional decomposition. The best way to master VBD is to practice:

- Practice on everyday software systems you are familiar with (insurance company, mobile app, bank, online store)
- Examine your own past projects -- what were the pain points? Was it functional decomposition? What would the volatility-based design look like?
- Practice on physical systems (house, car, airplane) -- the principles are universal
- Study existing well-designed systems and identify their encapsulated volatilities

## Red Flags / Anti-Patterns

1. Services named after business operations (InvoicingService, BillingService, BuyingStocks)
2. Client orchestrating multiple functional services
3. Services that know about call ordering (what comes before/after them)
4. Services chaining to each other with error compensation callbacks
5. Multiple points of entry to the system
6. Changes to one requirement requiring changes across multiple services
7. God services that are grab bags of related functionality
8. Explosion of tiny services each handling a narrow functional variation
9. Direct 1:1 mapping from requirements list to service list
10. Business logic residing in the client
11. Difficulty switching clients (web to mobile) due to embedded logic
12. Cross-cutting concern changes (notifications, storage) requiring changes to all services
|idesign}

let idesign_ref_structure = {idesign|# Structure (Ch. 3)

## Layers and Services

A layered approach to system design requires a handful of layers, terminating with a layer of actual physical resources (database, message queue, etc.). The preferred way of crossing layers is by calling services.

### Benefits of Using Services

1. **Scalability** -- services can be instantiated per-call, avoiding proportional back-end load
2. **Security** -- service-oriented platforms treat security as first-class; they authenticate and authorize all calls (not just from client, but between services)
3. **Throughput and availability** -- services can accept calls over queues, handling excess load; multiple instances can process the same queue
4. **Responsiveness** -- services can throttle calls into a buffer
5. **Reliability** -- can use reliable messaging protocols, handle network issues, order calls
6. **Consistency** -- services can participate in the same unit of work (transaction or coordinated business transaction with eventual consistency)
7. **Synchronization** -- calls can be automatically synchronized even if clients use multiple concurrent threads

## The Four Layers + Utilities

### Client Layer (Presentation Layer)

- The top layer. Elements can be end-user applications OR other systems interacting with your system.
- All Clients use the same entry points, subject to the same access security, data types, and interfacing requirements.
- Encapsulates the potential volatility in Clients: desktop apps, web portals, mobile apps, APIs, admin applications. These use different technologies, deploy differently, have their own versions and life cycles.
- Often the most volatile part of a typical software system.
- Changes in one Client component do not affect another.

### Business Logic Layer

Encapsulates the volatility in the system's business logic (required behavior, best expressed in use cases).

#### Managers
- Encapsulate the volatility in the **sequence** (orchestration of the workflow)
- Tend to encapsulate a **family of logically related use cases** within a particular subsystem
- Each Manager has its own related set of use cases to execute

#### Engines
- Encapsulate the volatility in the **activity** (business rules and activities)
- More restricted scope than Managers
- Managers may use zero or more Engines
- Engines may be shared between Managers (designed with reuse in mind)
- If two Managers use two different Engines for the same activity, you have functional decomposition

### Resource Access Layer

- Encapsulates the volatility in accessing a resource
- Must encapsulate both: (a) volatility in the method of access, and (b) volatility in the resource itself

**Critical Rule: Do NOT expose CRUD-like or I/O-like contracts.**
- If your ResourceAccess contract has Select(), Insert(), Delete() -- you are exposing that the resource is a database
- Avoid operations like Open(), Close(), Seek(), Read(), Write() -- these betray a file-based resource

**Use Atomic Business Verbs:**
- Activities decompose to indivisible activities called atomic business verbs
- Example: In a bank, "credit" and "debit" are atomic business verbs (atomic from the business perspective)
- Atomic business verbs are practically immutable because they relate to the nature of the business
- A well-designed ResourceAccess exposes atomic business verbs, converting them internally to CRUDs

### Resource Layer

- Contains actual physical Resources: database, file system, cache, message queue
- The Resource can be internal or external to the system
- Often the Resource is a whole system in its own right

### Utilities Bar

- A vertical bar on the side of the architecture containing Utility services
- Common infrastructure that nearly all systems require
- Examples: Security, Logging, Diagnostics, Instrumentation, Pub/Sub, Message Bus, Hosting
- **Litmus test**: Can the component plausibly be used in any other system, such as a smart cappuccino machine?

## Classification Guidelines

### Naming Rules

Names must be two-part compound words in PascalCase. The suffix is the service type.

| Type | Suffix | Prefix | Examples |
|------|--------|--------|----------|
| Manager | Manager | Noun associated with encapsulated use case volatility | AccountManager, MarketManager, MembershipManager |
| Engine | Engine | Gerund (noun from verb + "-ing") or noun describing activity | CalculatingEngine, SearchEngine, RegulationEngine |
| ResourceAccess | Access | Noun associated with the Resource | MembersAccess, PaymentsAccess, ProjectsAccess |

**Gerund rules:**
- Gerunds should ONLY be used as prefix with Engines. Gerunds elsewhere signal functional decomposition.
- Good: CalculatingEngine (Engines "do" things: aggregate, adapt, strategize, validate, rate, calculate, transform)
- Bad: BillingManager, BillingAccess -- the gerund conveys "doing" rather than orchestration or access volatility
- Good: AccountManager, AccountAccess

**Atomic business verbs should NOT be used in a prefix** for a service name. These verbs belong only in operation names in contracts at the resource access level.

### The Four Questions

| Question | Layer | Description |
|----------|-------|-------------|
| **Who** | Clients | Who interacts with the system |
| **What** | Managers | What is required of the system |
| **How** (Business) | Engines | How the system performs business activities |
| **How** (Resource) | ResourceAccess | How the system accesses Resources |
| **Where** | Resources | Where the system state is |

Use the four questions for **initiation** (start with a clean slate) and **validation** (check: are all Clients purely "who" with no "what"?).

### Managers-to-Engines Ratio

| Managers | Engines |
|----------|---------|
| 1 | 0 or at most 1 |
| 2 | likely 1 |
| 3 | 2 is likely best |
| 5 | may need as many as 3 |
| 8+ | you have already failed |

Most systems will never have many Managers because they will not have many truly independent families of use cases. A single Manager can support more than one family of use cases (different service contracts or facets).

### Key Observations

**Volatility decreases top-down:**
- Clients are the most volatile
- Managers change when use cases change, but less than Clients
- Engines are less volatile than Managers
- ResourceAccess is even less volatile
- Resources are the least volatile, changing at a glacial pace

This is extremely valuable: the most-depended-upon components (lower layers) are also the least volatile. If they were most volatile, the system would implode.

**Reuse increases top-down:**
- Clients are hardly ever reusable (platform-specific)
- Managers are reusable (same Manager from multiple Clients)
- Engines are even more reusable (same Engine called by multiple Managers)
- ResourceAccess components are very reusable
- Resources are the most reusable element

**Almost-Expendable Managers:**
1. **Expensive Manager** -- you fight the change, fear its cost. Too big, likely functional decomposition.
2. **Expendable Manager** -- you shrug it off, think nothing of it. Pass-through. Always a design flaw.
3. **Almost-Expendable Manager** -- you contemplate the change, think through specific ways to adapt. **This is the ideal.** The Manager merely orchestrates Engines and ResourceAccess, encapsulating sequence volatility.

## Subsystems and Services

### Vertical Slices
- A cohesive interaction between Manager, Engine, and ResourceAccess constitutes a logical subsystem -- a vertical slice
- Each vertical slice implements a corresponding set of use cases

### Sizing
- Avoid over-partitioning. Most systems: only a handful of subsystems.
- Limit Managers per subsystem to three.

### Incremental Construction
- **Incremental** = build components layer by layer within a correct architecture (foundation, walls, roof)
- **Iterative** = grow from a small version to a larger one (skateboard to car) -- wasteful and difficult
- Building incrementally is predicated on the architecture remaining constant. Only possible with volatility-based decomposition.
- Extensibility: mostly leave existing things alone, extend by adding more slices or subsystems.

## About Microservices

There are no microservices -- only services. Services are services regardless of size.

### Three Problems with Microservices (as commonly practiced)

1. **Implied constraint on the number of services** -- the building blocks within subsystems (Manager, Engine, ResourceAccess) should all be services too. Push the benefits of services as deep as possible.
2. **Widespread use of functional decomposition** -- dooms every microservices effort. Potentially the biggest failure in the history of software.
3. **Communication protocols** -- the vast majority use REST/HTTP for all communication. A well-designed system should NEVER use the same communication mechanism internally and externally. External: HTTP may be fine. Internal: use fast, reliable channels (TCP/IP, named pipes, IPC, message queues, etc.).

## Open and Closed Architectures

### Open Architecture (Avoid)
- Any component can call any other regardless of layer
- Trading encapsulation for flexibility is a bad trade
- Calling down multiple layers: when you switch a Resource, all Engines must change
- Calling up: Manager must respond to UI changes
- Calling sideways: Manager A calling Manager B -- almost always functional decomposition

### Closed Architecture (Preferred)
- Components in one layer can call those in the adjacent lower layer only
- Promotes decoupling by trading flexibility for encapsulation -- the better trade

### Semi-Closed/Semi-Open (Avoid)
- Allows calling more than one layer down
- Justified only in: (1) key infrastructure where every ounce of performance matters, (2) codebases that hardly ever change

## Relaxing the Rules

### Calling Utilities
Utilities reside in a vertical bar cutting across all layers. Any component can use any Utility.

### Calling ResourceAccess by Business Logic
Both Managers and Engines can call ResourceAccess without violating closed architecture.

### Managers Calling Engines
Managers can directly call Engines. Engines are really an expression of the Strategy design pattern.

### Queued Manager-to-Manager Calls
A Manager can queue a call to another Manager (the queue listener is effectively another Client). Business systems commonly have one use case triggering a deferred execution of another use case.

### Opening the Architecture (Handling Violations)
- Do NOT brush transgressions aside or demand blind compliance
- Nearly always, a transgression indicates an underlying need
- Address the need in a way that complies with closed architecture
- Sideways Manager call? -> Queue the call instead
- Manager calls up to Client? -> Use Pub/Sub Utility service

## Strive for Symmetry

- All good architectures are symmetric
- Symmetry appears as repeated call patterns across use cases
- Absence of symmetry is a cause for concern
- If a Manager implements four use cases and three publish events but the fourth does not -- why? Investigate.
- If only one of four use cases queues a call to another Manager -- that asymmetry is a design smell
- Symmetry is so fundamental you should see the same call patterns across Managers
|idesign}

let idesign_ref_composition = {idesign|# Composition (Ch. 4)

## Requirements and Changes

Requirements change -- that is what requirements do. The more requirements change, the higher the demand for software professionals. Embrace change; it is what keeps you employed.

### Resenting Change

Most developers design their system against the requirements, maximizing the affinity between requirements and architecture. When requirements change, the design must change too. This makes change painful, expensive, and destructive. People learn to resent change -- literally resenting the hand that feeds them.

### The Design Prime Directive

**Never design against the requirements.**

Any attempt at designing against the requirements will always guarantee pain. There should never be a direct mapping between requirements and design.

### Futility of Requirements

- A decent system has dozens of use cases; large systems have hundreds
- No one has ever had the time to correctly spec all use cases upfront
- Requirements specs contain duplicates, contradictions, missing items
- Requirements will change over time: new ones added, existing ones removed or modified
- Attempting to gather the complete set and design against them is an exercise in futility

## Composable Design

The goal of any system design is to satisfy ALL use cases -- present and future, known and unknown. A composable design does not aim to satisfy any use case in particular.

### Core Use Cases

Not all use cases are equal. There are only two types:
- **Core use cases**: represent the essence of the business (2-6 per system, rarely more)
- **Regular use cases**: variations and permutations of core use cases

Core use cases:
- Will hardly ever be presented explicitly in the requirements document
- Are not easy to find, and the small number does not make it simple to agree on what they are
- Will almost always be some kind of abstraction of other use cases
- May require a new term or name to differentiate them from the rest
- Even a flawed requirements document will contain them because they ARE the essence of the business

Finding core use cases is an iterative process between the architect and the requirements owner.

### The Architect's Mission

Your mission as architect: identify the **smallest set of components** that you can put together to satisfy all the core use cases. Since all other use cases are merely variations, regular use cases represent a different interaction between the components, not a different decomposition.

**When requirements change, your design does not.**

This is about decomposition into components, not implementation. The integration code inside Managers will change as requirements change -- but that is an implementation change, not an architectural change.

## Architecture Validation

Composable design enables **design validation**: produce an interaction between your services for each core use case.

### Call Chain Diagrams
- Superimpose the call chain onto the layered architecture diagram
- Components connected by arrows showing direction and type of call
- Solid black arrow = synchronous (request/response) call
- Dashed gray arrow = queued call
- Simple, quick, good for nontechnical audiences
- Downside: no notion of call order, duration, or multiple calls to same component

### Sequence Diagrams
- Similar to UML sequence diagrams with IDesign notational differences
- Lifelines colored according to architectural layers
- Each participating component has a vertical bar (lifeline)
- Time flows top to bottom; length of bars indicates relative duration
- Better for complex use cases and technical audiences
- Extremely useful for subsequent detailed design (interfaces, methods, parameters)

### Smallest Set

You want not just a set of components but the **smallest** set. Less is more in architecture.

- A monolith (1 component) is too few -- horrible internal complexity
- 300 components (one per use case) is too many -- high integration cost
- The order of magnitude for a typical system is ~10 services
- Using The Method: 2-5 Managers, 2-3 Engines, 3-8 ResourceAccess, plus Resources and Utilities = ~12 building blocks at most
- If larger, break into subsystems

**You cannot validate architectures with a single component or hundreds of components.** A single large component by definition does everything, and a component per use case also supports all use cases -- neither proves design merit.

### Duration of Design Effort

- Requirements gathering and analysis may take weeks or months -- that is NOT design
- Once you have the core use cases and areas of volatility, producing a valid design using The Method takes hours to a few days at most
- Design is not time-consuming if you know what you are doing

## There Is No Feature

**Features are always and everywhere aspects of integration, not implementation.**

This is a universal design rule governing all systems. You never see a "feature" as a discrete component in any well-designed system:
- A car transports you from A to B -- the feature emerges from integrating chassis, engine, gearbox, seats, dashboard, driver, road, insurance, and fuel
- A laptop provides word processing -- the feature emerges from integrating keyboard, screen, hard drive, bus, CPU, and memory
- This is fractal: every level of every system works the same way, down to the quarks

In software: you do not implement features in individual services. Features emerge from how services interact. To add or change a feature, you change the workflows of the Managers, not the participating services.

## Handling Change

With functional decomposition, change is spread across multiple components and aspects of the system. People defer changes, fight changes, or explain to customers that changes are bad ideas. Fighting change is tantamount to killing the system -- customers need the feature now, not in six months.

### Containing the Change

The trick is not to fight, postpone, or punt change -- it is to **contain its effects**.

With volatility-based decomposition:
- A change to a requirement is a change to a use case
- Some Manager implements the workflow executing that use case
- The Manager may be gravely affected -- perhaps you discard it entirely and create a new one
- But the underlying components (Engines, ResourceAccess, Resources, Utilities) are NOT affected

The bulk of effort in any system goes into the services the Manager uses:
- **Engines** are expensive: business activities vital to the system's workflows
- **ResourceAccess** is nontrivial: identifying atomic business verbs, translating them to resource access methods
- **Resources** must be scalable, reliable, highly performant: schemas, caching, replication, partitioning, connection management, indexing, transactions, etc.
- **Utilities** require top skills: world-class security, diagnostics, logging, messaging, hosting
- **Clients** are time and labor intensive: superior UX, convenient and reusable APIs

When a change happens to the Manager, you salvage and reuse ALL the effort that went into Clients, Engines, ResourceAccess, Resources, and Utilities. By reintegrating these services in the Manager, you contain the change and respond quickly and efficiently.

**This is the essence of agility.**
|idesign}

let idesign_ref_design_donts = {idesign|# Design "Don'ts" (Ch. 3 - Structure)

Red flags indicating functional decomposition or architectural violations. If you do any of these, treat it as a warning sign and investigate what you are missing.

## Call-Flow Violations

### Clients must not call multiple Managers in the same use case
- Doing so tightly couples Managers -- they no longer represent separate families of use cases, separate subsystems, or separate slices
- Chained Manager calls from the Client indicate functional decomposition: the Client is stitching together underlying functionalities
- Clients CAN call multiple Managers but NOT in the same use case (e.g., Client calls Manager A for use case 1, then Manager B for use case 2)

### Clients must not call Engines
- The only entry points to the business layer are the Managers
- Managers represent the system; Engines are an internal layer implementation detail
- If Clients call Engines, use case sequencing and associated volatility migrates to the Clients, polluting them with business logic
- Calls from Clients to Engines are the hallmark of functional decomposition

### Managers must not queue calls to more than one Manager in the same use case
- If two Managers receive a queued call, why not a third? Why not all of them?
- The need for multiple Managers to respond to a queued call is a strong indication you should use a Pub/Sub Utility service instead

### Engines must not receive queued calls
- Engines are utilitarian and exist to execute a volatile activity for a Manager
- They have no independent meaning on their own
- A queued call, by definition, executes independently from anything else in the system
- Performing just the activity of an Engine, disconnected from any use case or other activities, does not make any business sense

### ResourceAccess services must not receive queued calls
- Similar to the Engines guideline
- ResourceAccess services exist to service a Manager or an Engine and have no meaning on their own
- Accessing a Resource independently from anything else in the system does not make any business sense

### Engines never call each other
- Not only does this violate the closed architecture principle, it also does not make sense in a volatility-based decomposition
- The Engine should have already encapsulated everything to do with that activity
- Any Engine-to-Engine calls indicate functional decomposition

### ResourceAccess services never call each other
- If ResourceAccess services encapsulate the volatility of an atomic business verb, one atomic verb cannot require another
- Similar to the rule that Engines should not call each other
- Note: a 1:1 mapping between ResourceAccess and Resources is NOT required
- Often two or more Resources logically must be joined together to implement some atomic business verbs
- A single ResourceAccess service should perform the join rather than making inter-ResourceAccess calls

## Event/Pub-Sub Violations

### Clients must not publish events
- Events represent changes to the state of the system about which Clients (or Managers) may want to know
- A Client has no need to notify itself (or other Clients)
- Knowledge of the internals of the system is often required to detect the need to publish an event -- knowledge that the Clients should not have
- However, with functional decomposition the Client IS the system and needs to publish events

### Engines must not publish events
- Publishing an event requires noticing and responding to a change in the system
- This is typically a step in a use case executed by the Manager
- An Engine performing an activity has no way of knowing much about the context of the activity or the state of the use case

### ResourceAccess services must not publish events
- ResourceAccess services have no way of knowing the significance of the state of the Resource to the system
- Any such knowledge or responding behavior should reside in Managers

### Resources must not publish events
- The need for the Resource to publish events is often the result of a tightly coupled functional decomposition
- Similar to the case for ResourceAccess -- business logic of this kind should reside in Managers
- As a Manager modifies the state of the system, the Manager should also publish the appropriate events

### Engines, ResourceAccess, and Resources must not subscribe to events
- Processing an event is almost always the start of some use case, so it must be done in a Client or a Manager
- The Client may inform a user about the event, and the Manager may execute some back-end behavior
|idesign}

let idesign_ref_design_standard = {idesign|# Design Standard (Appendix C) -- System Design & Service Contract Parts

A consolidated checklist of all directives and guidelines from the book. A **directive** is a rule you should never violate -- doing so is certain to cause failure. A **guideline** is advice you should follow unless you have a strong and unusual justification for going against it. Violating a single guideline alone is not certain to cause failure, but too many violations will.

## The Prime Directive

**Never design against the requirements.**

## Directives (System Design)

1. Avoid functional decomposition.
2. Decompose based on volatility.
3. Provide a composable design.
4. Offer features as aspects of integration, not implementation.
5. Design iteratively, build incrementally.

## System Design Guidelines

### 1. Requirements

a. Capture required behavior, not required functionality.
b. Describe required behavior with use cases.
c. Document all use cases that contain nested conditions with activity diagrams.
d. Eliminate solutions masquerading as requirements.
e. Validate the system design by ensuring it supports all core use cases.

### 2. Cardinality

a. Avoid more than five Managers in a system without subsystems.
b. Avoid more than a handful of subsystems.
c. Avoid more than three Managers per subsystem.
d. Strive for a golden ratio of Engines to Managers.
e. Allow ResourceAccess components to access more than one Resource if necessary.

### 3. Attributes

a. Volatility should decrease top-down.
b. Reuse should increase top-down.
c. Do not encapsulate changes to the nature of the business.
d. Managers should be almost expendable.
e. Design should be symmetric.
f. Never use public communication channels for internal system interactions.

### 4. Layers

a. Avoid open architecture.
b. Avoid semi-closed/semi-open architecture.
c. Prefer a closed architecture.
   - i. Do not call up.
   - ii. Do not call sideways (except queued calls between Managers).
   - iii. Do not call more than one layer down.
   - iv. Resolve attempts at opening the architecture by using queued calls or asynchronous event publishing.
d. Extend the system by implementing subsystems.

### 5. Interaction Rules

a. All components can call Utilities.
b. Managers and Engines can call ResourceAccess.
c. Managers can call Engines.
d. Managers can queue calls to another Manager.

### 6. Interaction Don'ts

a. Clients do not call multiple Managers in the same use case.
b. Managers do not queue calls to more than one Manager in the same use case.
c. Engines do not receive queued calls.
d. ResourceAccess components do not receive queued calls.
e. Clients do not publish events.
f. Engines do not publish events.
g. ResourceAccess components do not publish events.
h. Resources do not publish events.
i. Engines, ResourceAccess, and Resources do not subscribe to events.

## Service Contract Design Guidelines

1. Design reusable service contracts.
2. Comply with service contract design metrics:
   - a. Avoid contracts with a single operation.
   - b. Strive to have 3 to 5 operations per service contract.
   - c. Avoid service contracts with more than 12 operations.
   - d. Reject service contracts with 20 or more operations.
3. Avoid property-like operations.
4. Limit the number of contracts per service to 1 or 2.
5. Avoid junior hand-offs.
6. Have only the architect or competent senior developers design the contracts.
|idesign}

let idesign_ref_contract_design = {idesign|# Service Contract Design (Appendix B)

## Modularity and Cost

Total system cost is the sum of two nonlinear cost elements:

### Cost per Service
- As the number of services decreases, their size increases (toward a monolith)
- Complexity increases nonlinearly with size: a service 2x as big may be 4x more complex; 4x as big may be 20-100x more complex
- Increased complexity induces nonlinear increases in cost
- Result: cost per service is a compounded, nonlinear, monotonically increasing function of size

### Integration Cost
- As the number of services increases, the complexity of possible interactions increases
- With n services, interaction complexity grows in proportion to n^2 or even n^n
- Integration cost is also a nonlinear curve, shooting up with more services

### Area of Minimum Cost
- The total system cost curve (sum of both) has a flat region: the **area of minimum cost**
- Services are not too big, not too small; not too many, not too few
- You do not need the absolute minimum -- just stay in the flat region (diminishing returns beyond that)
- What you MUST avoid: the nonlinear edges (monolith or explosion of services), which are many multiples more expensive
- **Functional decomposition always lands at the expensive edges** -- either a few massive accumulations or an explosion of small services
- Systems designed outside the area of minimum cost have already failed before anyone writes the first line of code -- because the tools organizations have (add another developer, another month) are linear, and the problem is nonlinear

## Services and Contracts

A **contract** is the public interface that the service presents to its clients -- a set of operations that clients can call. Not all interfaces are service contracts; service contracts are formal interfaces the service commits to support, unchanged.

### Contracts as Facets
- A contract represents a facet of the service (like an employment contract is one facet of a person)
- A single service can support more than one contract (multiple facets)
- The first reduction: assume a one-to-one ratio between services and contracts, then the cost curve behavior remains unchanged

### Attributes of Good Contracts

Good contracts are:

1. **Logically consistent** -- no unrelated operations bundled together. Every operation in the contract must logically belong with the others.
2. **Cohesive** -- all the aspects required to describe the interaction, no more, no less. Nothing missing, nothing extra.
3. **Independent** -- each contract (facet) stands alone and operates independently of other contracts.

**The basic element of reuse is the contract, not the service.** Good interfaces are reusable while the underlying services never are (like the tool-hand interface reused from stone axe to computer mouse).

Logically consistent, cohesive, and independent contracts ARE reusable contracts. Reusability is not binary -- it is a spectrum. The more a contract has these three attributes, the more reusable it is.

## Factoring Contracts

Design contracts as if they will be reused countless times across multiple systems including your competitors'. The degree of actual reuse is immaterial -- the obligation to design reusable contracts keeps you in the area of minimum cost.

### Factoring Down (Base Extraction)
- Extract a base contract from a more specific contract
- When a contract has operations that are not universally applicable, factor the general operations into a base contract and keep the specific ones in a derived contract
- Example: `IScannerAccess` has `ScanCode()` and `AdjustBeam()` -- but `AdjustBeam()` is scanner-specific. Factor down to `IReaderAccess` (base with `ReadCode()`) and `IScannerAccess : IReaderAccess` (derived with `AdjustBeam()`)
- This enables non-optical devices (keypads, RFID readers) to implement `IReaderAccess`

### Factoring Sideways (Separating Concerns)
- Separate logically unrelated operations into independent contracts
- When a contract is not logically consistent (grab-bag of unrelated operations), split it
- Example: `IReaderAccess` with `ReadCode()`, `OpenPort()`, `ClosePort()` -- port management is a different concern than code reading. Factor sideways into `IReaderAccess` and `ICommunicationDevice`
- Services implement both contracts; other devices (conveyer belts) can reuse just `ICommunicationDevice`
- Every change in business domain should NOT lead to a reflected change in the design -- that is the hallmark of bad design

### Factoring Up (Contract Hierarchy)
- Create a shared base contract when identical operations appear in multiple unrelated contracts
- Example: all devices need `Abort()` and `RunDiagnostics()` -- factor up to `IDeviceControl` base contract
- Both `IReaderAccess` and `IBeltAccess` derive from `IDeviceControl`

## Contract Design Metrics

Metrics are **evaluation tools, not validation tools**. Complying does not guarantee a good design, but violating implies a bad design.

### Size Metrics (Operations per Contract)

| Operations | Assessment |
|-----------|------------|
| 1 | Red flag -- investigate. A single-operation facet is suspect |
| 2 | Possibly fine, but examine carefully |
| **3-5** | **Optimal range** |
| 6-9 | Acceptable, but starting to drift from area of minimum cost |
| 12+ | Very likely a poor design -- look for ways to factor |
| 20+ | **Immediately reject** -- no possible circumstances where this is benign |

### Avoid Properties
- Do not expose property-like operations (getters/setters) in service contracts
- Properties imply state and implementation details -- when the service changes, the client must change
- Good interactions are always behavioral: `DoSomething()`, `Abort()` -- not `GetName()`, `SetName()`
- Keep data where the data is; only invoke operations on it

### Limit the Number of Contracts per Service
- A service should support no more than 1 or 2 contracts
- If a service supports 3+ independent facets, the service may be too big
- In order of magnitude: 1-4 contracts per service, with PERT estimate of ~2.2
- In practice: most well-designed services have 1 or 2 contracts
- Tip: if your architecture has 8+ Managers, represent some Managers as additional independent facets (contracts) on other Managers to reduce the count

### Using Metrics
- Do NOT try to design to the metrics -- contract design is iterative
- Spend time identifying the reusable contract, keep examining if they are logically consistent, cohesive, and independent
- If you violate the metrics, keep working until you have decent contracts
- Once you have devised good contracts, you will find that they match the metrics naturally

## The Contract Design Challenge

- Designing contracts is an acquired skill requiring practice and mentorship
- The ideas are simple but not simplistic
- The real challenge is not designing the contracts but getting management support for the time investment
- Rushing to implementation with poor contracts will cause the project to fail (nonlinear cost consequences)
- With junior teams: the architect must design the contracts or closely guide the process
- Make contract design part of each service life cycle
|idesign}

let idesign_ref_design_example = {idesign|# System Design Example: TradeMe (Ch. 5)

A complete case study demonstrating The Method applied to a real system. Focus on the **thought process and rationale**, not on copying the specific outcome -- every system is different.

## System Overview

**TradeMe** is a marketplace system for matching tradesmen (plumbers, electricians, etc.) to contractors and construction projects. Think of it as a brokerage platform.

- **Tradesmen**: Self-employed skilled workers with skill levels, certifications, geographic areas, expected pay rates
- **Contractors**: Need tradesmen on an ad hoc basis (days to weeks), list projects with required trades, skills, location, rates, duration
- **Revenue model**: Spread between tradesman ask rate and contractor bid rate + membership fees
- **Operations**: 9 call centers across Europe, ~220 account reps, locale-specific regulations
- **Legacy system**: Two-tier desktop app, 5 disconnected subsystems, business logic in clients, no security design, change-resistant

**Goals for new system**: Automate work, single system across all locales, deploy beyond Europe, compete with more flexible competitors.

## Use Cases and Core Use Case Identification

The customer provided 8 use cases (mostly reflecting legacy behavior):
1. Add Tradesman/Contractor
2. Request Tradesman
3. Match Tradesman
4. Assign Tradesman
5. Terminate Tradesman
6. Pay Tradesman
7. Create Project
8. Close Project

### Finding the Core Use Case

Most provided use cases were simple functionalities (add member, create project, pay someone) that any design can handle. The system's raison d'etre is **matching tradesmen to contractors and projects**. Only **Match Tradesman** resembles the core purpose.

**Principles**:
- Core use cases represent the essence of the business (2-6 per system)
- They are rarely presented explicitly in requirements
- They are almost always abstractions of other use cases
- Even flawed requirements contain them because they ARE the business
- Do NOT ignore non-core use cases -- demonstrating that the design easily supports them shows the design's versatility

### Simplifying Use Cases

**Swim lanes technique**: Show flow of control between roles. For TradeMe, three role types were identified:
- **Client** (users -- back-office reps or system admins)
- **Market** (core marketplace logic)
- **Member** (tradesmen and contractors)

Swim lanes help clarify required behavior, add decision boxes or synchronization bars, and are later used to seed and validate the design.

## The Anti-Design Effort

Deliberately produce the **worst possible design** through functional decomposition, to expose what NOT to do.

### Anti-Design #1: The Monolith
A single god service -- dumping ground of all functionalities. No encapsulation. Cannot validate.

### Anti-Design #2: Granular Building Blocks (Services Explosion)
Every activity in the use cases becomes a component. Results in either:
- **Fat client**: Client absorbs all business logic (orchestration, sequencing, error compensation)
- **Chained services**: Services call each other up and sideways -- tight coupling, open architecture

### Anti-Design #3: Domain Decomposition
Decompose along entity lines (Tradesman service, Contractor service, Project service). Nearly limitless possible domain boundaries with no principled selection criteria. Impossible to validate -- a request touches multiple domains. Has all drawbacks from Chapter 2.

## Business Alignment

### The Vision
> *A platform for building applications to support the TradeMe marketplace.*

- Terse and explicit -- read like a legal statement
- "Platform" (not just "application") addresses business need for diversity and extensibility
- Powerful tool for **repelling irrelevant demands** that do not serve the vision

### The Business Objectives (7 items)
1. Unify repositories and applications
2. Quick turnaround for new requirements
3. High degree of customization across countries/markets
4. Full business visibility and accountability (fraud detection, audit)
5. Forward looking on technology and regulations
6. Integrate well with external systems
7. Streamline security

**Note**: Development cost was NOT an objective. The pain was in the items above.

### The Mission Statement
> *Design and build a collection of software components that the development team can assemble into applications and features.*

Deliberately does NOT identify developing features as the mission. The mission is to **build components** -- making volatility-based decomposition the natural approach.

### The Chain
```
Vision → Objectives → Mission Statement → Architecture
```
This **reverses typical dynamics**: instead of the architect pleading with management, you compel the business to instruct you to design the right architecture. Once they agree on the chain, they are on your side.

## Volatility Identification

### Glossary (Who/What/How/Where)
Before decomposing, answer four questions to seed the effort:

- **Who**: Tradesmen, Contractors, Reps, Education centers, Background processes (timers)
- **What**: Membership, Marketplace of projects, Certificates/training
- **How**: Searching, Complying with regulations, Accessing resources
- **Where**: Local database, Cloud, Other systems

The "what" list hints strongly at possible subsystems. Use it to **seed decomposition** as you look for volatilities.

### Rejected/Reframed Volatility Candidates

| Candidate | Verdict | Reason |
|-----------|---------|--------|
| **Tradesman** | Rejected | Variable, not volatile. Adding attributes doesn't change architecture. Signals domain decomposition. Real volatility is *membership management*. |
| **Education certificates** | Reframed | Certification itself is just an attribute. Real volatility is in the *workflow of matching regulations with certifications* (→ Regulation Engine). |
| **Projects** | Reframed | A `Project Manager` implies domain decomposition. A `Market Manager` is better -- many activities don't require a project context. Core volatility is *the marketplace*. |
| **Payments** | Outside system | Volatile but ancillary. TradeMe is not a payment system. Handled as external *Resources*. |
| **Notification** | Weak | Message Bus Utility suffices. Only if notification transport became strongly volatile would a dedicated Manager be needed. |
| **Analysis** | Rejected | Speculative design. The company is not in the optimization business. Folded into Market Manager if ever needed. |

**Principle**: If identifying a volatility produces domain decomposition along entity lines, look further. You must clearly state: WHAT the volatility is, WHY it is volatile, WHAT RISK it poses.

### Accepted Areas of Volatility

| Volatility Area | Encapsulated In | Notes |
|---|---|---|
| Client applications | Individual Client apps | Each client environment evolves independently |
| Managing membership | `Membership Manager` | Adding/removing members, benefits, discounts |
| Fees | `Market Manager` | All ways TradeMe makes money |
| Projects | `Market Manager` | NOT a separate Project service |
| Disputes | `Membership Manager` | Misunderstandings, fraud |
| Matching and approvals | `Search Engine` + `Market Manager` | Two sub-volatilities: algorithm + criteria definition |
| Education | `Education Manager` + `Search Engine` | Training workflow + class searching |
| Regulations | `Regulation Engine` | Changes per country and over time |
| Reports | `Regulation Engine` | Reporting and auditing requirements |
| Localization | `Clients` (UI) + `Regulation Engine` (rules) | Two distinct sub-volatilities |
| Resources (storage) | `ResourceAccess` + `Resources` | Storage nature is volatile |
| Deployment model | Subsystem composition + `Message Bus` | Cloud vs on-premise, data locality |
| Authentication/authorization | `Security` Utility | Credential models, identity, roles |

**Key**: The mapping of volatilities to components is NOT 1:1. A single Manager can encapsulate multiple related volatilities.

## Static Architecture

```
CLIENT TIER:
  Tradesman Portal | Contractors Portal | Education Portal | Marketplace App | Timer

UTILITIES (vertical bar):
  Security | Logging | Message Bus

BUSINESS LOGIC TIER:
  Membership Manager | Market Manager | Education Manager
  Regulation Engine | Search Engine

RESOURCE ACCESS TIER:
  Regulations Access | Payments Access | Members Access
  Projects Access | Contractors Access | Education Access | Workflows Access

RESOURCES TIER:
  Regulations | Payments | Members | Projects | Contractors | Education | Workflows
```

### Key Observations
- **3 Managers** (Membership, Market, Education) -- within cardinality guidelines
- **2 Engines** (Regulation, Search) -- golden ratio to Managers
- **Timer** is in Client tier because it initiates behavior even though it's not part of the system
- **ResourceAccess** converts atomic business verbs (e.g., "pay") into resource access
- **3 Utilities**: Security, Message Bus, Logging

## Operational Concepts

### All Communication via Message Bus
All Client-to-Manager communication happens over the Message Bus. Clients and Managers never interact directly -- they are unaware of each other, fostering extensibility and independent evolution.

### Message Bus Properties
- Queued Pub/Sub mechanism: N:M communication
- Messages queue if bus or publisher is down, process when connectivity restores
- Private queue per subscriber handles subscriber downtime
- Minimum features: queuing, multicast, security, headers/context propagation, offline work, failure handling, transactional processing, high throughput, multiple-protocol support, reliable messaging

### "The Message Is the Application" Pattern

The most important operational concept. There is no single collection of components you can point to as "the application." The system is a loose collection of services posting and receiving messages. Each service processes a message, does local work, posts back to the bus. Behavior changes are induced by changing how services respond to messages, not by changing the architecture.

**When NOT to use**: Adds complexity. A simpler design where Clients just queue calls to Managers may suffice. Calibrate to the capability of the developers and management.

## Workflow Manager Pattern

A Manager that can create, store, retrieve, and execute workflows using a third-party workflow execution tool.

**How it operates**:
1. For each Client call, load the correct workflow type AND specific instance (with state/context)
2. Execute the workflow
3. Persist the workflow instance back to the workflow store
4. No session with the Client -- state-aware through workflow persistence
5. Each call carries the unique workflow instance ID

**Benefits**:
- To add/change a feature, change the *workflows*, not the participating services
- Product owners or end users can edit workflows (with safeguards)
- Enables high degree of customization across markets
- Software team focuses on core services rather than chasing requirement changes

## Design Validation

Validate the architecture BEFORE work commences by showing the call chain for each use case.

### Validation Pattern (Self-Similar Across All Use Cases)
1. A Client posts to the Message Bus
2. A Manager (workflow-based) picks up the message and loads the appropriate workflow
3. The Manager consults Engines and/or ResourceAccess components
4. The Manager posts results back to the Message Bus
5. Other Managers and/or Clients respond to the posted message

### Use Case Validations Summary

**Add Tradesman/Contractor**: Client → Message Bus → Membership Manager (loads workflow from Workflows Access) → Regulation Engine + Payments Access + Members Access

**Request Tradesman**: Client → Message Bus → Market Manager (loads workflow) → Regulation Engine + Projects Access. Posts back to bus triggering Match Tradesman.

**Match Tradesman** (core use case): Client/Timer → Message Bus → Market Manager → Search Engine + Members Access + Projects Access + Contractors Access. Posts to bus → triggers Membership Manager for Assign.

**Assign Tradesman**: Message Bus → Membership Manager → Regulation Engine + Members Access. Posts to bus → Market Manager → Projects Access. Collaborative execution between two Managers via bus.

**Terminate Tradesman**: Client → Message Bus → Market Manager → Projects Access. Posts to bus → Membership Manager → Regulation Engine + Members Access. Flow can also run in **reverse direction** (tradesman-initiated).

**Pay Tradesman**: Timer → Message Bus → Market Manager → Workflows Access + Payments Access (→ external payment system).

**Create Project**: Client → Message Bus → Market Manager → Workflows Access + Projects Access. Simple, handled entirely by one Manager.

**Close Project**: Client → Message Bus → Market Manager → Projects Access. Posts to bus → Membership Manager → Regulation Engine + Members Access. Same pattern as Terminate Tradesman -- reinforces self-similarity.

### Cross-Cutting Patterns

- **Self-similarity and symmetry**: Every call chain follows the same structural pattern. This is a hallmark of good design.
- **Use case chaining**: Request → Match → Assign → Pay. Each operates independently, chaining through messages on the bus.
- **Bidirectional flow**: Same architecture supports flows from different initiators (contractor-initiated vs tradesman-initiated termination).
- **Composability**: New capabilities added by subscribing new services to existing messages or adding new workflows -- no modification of existing components.

## Principles Demonstrated

1. Design takes hours to days, not months (TradeMe: less than a week, two-person team)
2. Always transform, clarify, and consolidate raw requirements
3. The anti-design effort exposes what NOT to do
4. Business alignment (Vision → Objectives → Mission → Architecture) gets the business on your side
5. Candidate volatilities must be rigorously challenged -- entities as volatilities signal domain decomposition
6. Distinguish variable (data changes) from volatile (behavior/structure changes)
7. Volatility may reside outside the system (payments as external Resources)
8. The mapping of volatilities to components is not 1:1
9. Self-similarity and symmetry in call chains validate the design
10. The design is open-ended -- extend by adding more services or workflows, never by modifying existing ones
|idesign}

let frontend_design_skill = {frontend|---
name: frontend-design
description: Create distinctive, production-grade frontend interfaces with high design quality. Use this skill when the user asks to build web components, pages, or applications. Generates creative, polished code that avoids generic AI aesthetics.
license: Complete terms in LICENSE.txt
---

This skill guides creation of distinctive, production-grade frontend interfaces that avoid generic "AI slop" aesthetics. Implement real working code with exceptional attention to aesthetic details and creative choices.

The user provides frontend requirements: a component, page, application, or interface to build. They may include context about the purpose, audience, or technical constraints.

## Design Thinking

Before coding, understand the context and commit to a BOLD aesthetic direction:
- **Purpose**: What problem does this interface solve? Who uses it?
- **Tone**: Pick an extreme: brutally minimal, maximalist chaos, retro-futuristic, organic/natural, luxury/refined, playful/toy-like, editorial/magazine, brutalist/raw, art deco/geometric, soft/pastel, industrial/utilitarian, etc. There are so many flavors to choose from. Use these for inspiration but design one that is true to the aesthetic direction.
- **Constraints**: Technical requirements (framework, performance, accessibility).
- **Differentiation**: What makes this UNFORGETTABLE? What's the one thing someone will remember?

**CRITICAL**: Choose a clear conceptual direction and execute it with precision. Bold maximalism and refined minimalism both work - the key is intentionality, not intensity.

Then implement working code (HTML/CSS/JS, React, Vue, etc.) that is:
- Production-grade and functional
- Visually striking and memorable
- Cohesive with a clear aesthetic point-of-view
- Meticulously refined in every detail

## Frontend Aesthetics Guidelines

Focus on:
- **Typography**: Choose fonts that are beautiful, unique, and interesting. Avoid generic fonts like Arial and Inter; opt instead for distinctive choices that elevate the frontend's aesthetics; unexpected, characterful font choices. Pair a distinctive display font with a refined body font.
- **Color & Theme**: Commit to a cohesive aesthetic. Use CSS variables for consistency. Dominant colors with sharp accents outperform timid, evenly-distributed palettes.
- **Motion**: Use animations for effects and micro-interactions. Prioritize CSS-only solutions for HTML. Use Motion library for React when available. Focus on high-impact moments: one well-orchestrated page load with staggered reveals (animation-delay) creates more delight than scattered micro-interactions. Use scroll-triggering and hover states that surprise.
- **Spatial Composition**: Unexpected layouts. Asymmetry. Overlap. Diagonal flow. Grid-breaking elements. Generous negative space OR controlled density.
- **Backgrounds & Visual Details**: Create atmosphere and depth rather than defaulting to solid colors. Add contextual effects and textures that match the overall aesthetic. Apply creative forms like gradient meshes, noise textures, geometric patterns, layered transparencies, dramatic shadows, decorative borders, custom cursors, and grain overlays.

NEVER use generic AI-generated aesthetics like overused font families (Inter, Roboto, Arial, system fonts), cliched color schemes (particularly purple gradients on white backgrounds), predictable layouts and component patterns, and cookie-cutter design that lacks context-specific character.

Interpret creatively and make unexpected choices that feel genuinely designed for the context. No design should be the same. Vary between light and dark themes, different fonts, different aesthetics. NEVER converge on common choices (Space Grotesk, for example) across generations.

**IMPORTANT**: Match implementation complexity to the aesthetic vision. Maximalist designs need elaborate code with extensive animations and effects. Minimalist or refined designs need restraint, precision, and careful attention to spacing, typography, and subtle details. Elegance comes from executing the vision well.

Remember: Claude is capable of extraordinary creative work. Don't hold back, show what can truly be created when thinking outside the box and committing fully to a distinctive vision.
|frontend}

let systemd_unit name =
  Printf.sprintf
    {|[Unit]
Description=%s (well app)
After=network.target

[Service]
Type=simple
WorkingDirectory=/srv/%s
ExecStart=/srv/%s/bin/%s
Restart=on-failure
RestartSec=3

# Environment
Environment=PORT=4000
Environment=WELL_CAP_PASS=
# Environment=WELL_DOMAIN=example.com

# Hardening
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/srv/%s/data
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
|}
    name name name name name

type file = {
  path : string;
  content : string;
}

let project_files name =
  [
    { path = "README.md"; content = readme name };
    { path = "dune-project"; content = dune_project name };
    { path = "dune"; content = root_dune };
    { path = "Makefile"; content = makefile };
    { path = ".gitignore"; content = gitignore };
    { path = ".ocamlformat"; content = ocamlformat };
    (* bin/ *)
    { path = "bin/dune"; content = bin_dune name };
    { path = "bin/main.ml"; content = bin_main name };
    (* lib/ — app library with include_subdirs *)
    { path = "lib/dune"; content = lib_app_dune name };
    { path = "lib/app.ml"; content = app_ml name };
    { path = "lib/events.ml"; content = events name };
    (* lib/note_access/ *)
    { path = "lib/note_access/note_access_impl.ml"; content = note_access_impl name };
    (* lib/task_access/ *)
    { path = "lib/task_access/task_access_impl.ml"; content = task_access_impl name };
    (* lib/task_manager/ *)
    { path = "lib/task_manager/task_manager_impl.ml"; content = task_manager_impl name };
    (* lib/client/widgets/ *)
    { path = "lib/client/widgets/layout.mlx"; content = layout name };
    (* lib/client/pages/ *)
    { path = "lib/client/pages/home_page.mlx"; content = home_page name };
    { path = "lib/client/pages/counter_page.mlx"; content = counter_page name };
    { path = "lib/client/pages/dashboard_page.mlx"; content = dashboard_page name };
    { path = "lib/client/pages/notes_page.mlx"; content = notes_page name };
    { path = "lib/client/pages/tasks_page.mlx"; content = tasks_page name };
    { path = "lib/client/pages/upload_page.mlx"; content = upload_page name };
    { path = "lib/client/pages/login_page.mlx"; content = login_page name };
    (* lib/client/live/ *)
    { path = "lib/client/live/counter_live.mlx"; content = counter_live name };
    { path = "lib/client/live/activity_log_live.mlx"; content = activity_log_live name };
    (* lib/client/ *)
    { path = "lib/client/request_id.ml"; content = request_id name };
    (* lib/contract/ — separate dune library *)
    { path = "lib/contract/dune"; content = contract_boundary_dune };
    { path = "lib/contract/build/ocaml/dune"; content = contract_dune_file };
    { path = "lib/contract/NoteAccess.toml"; content = contract_note_access_toml };
    { path = "lib/contract/TaskAccess.toml"; content = contract_task_access_toml };
    { path = "lib/contract/TaskManager.toml"; content = contract_task_manager_toml };
    { path = "lib/contract/build/ocaml/note_access.ml"; content = contract_note_access_ml };
    { path = "lib/contract/build/ocaml/task_access.ml"; content = contract_task_access_ml };
    { path = "lib/contract/build/ocaml/task_manager.ml"; content = contract_task_manager_ml };
    { path = "lib/contract/build/ts/rpc.ts"; content = contract_ts_rpc };
    { path = "lib/contract/build/ts/NoteAccess.ts"; content = contract_ts_note_access };
    { path = "lib/contract/build/ts/TaskAccess.ts"; content = contract_ts_task_access };
    { path = "lib/contract/build/ts/TaskManager.ts"; content = contract_ts_task_manager };
    (* test/ *)
    { path = "test/dune"; content = test_dune name };
    { path = Printf.sprintf "test/%s_test.ml" name; content = test_main name };
    (* static/ *)
    { path = "static/dune"; content = static_dune };
    { path = "static/ts/tasks.ts"; content = tasks_ts };
    { path = "static/tasks.js"; content = tasks_js };
    { path = "static/app.css"; content = static_app_css ^ notes_css ^ counter_css ^ dashboard_css ^ auth_css ^ tasks_css ^ upload_css };
    { path = "static/well.ts"; content = static_well_ts };
    { path = "tsconfig.json"; content = tsconfig_json };
    { path = "data/.gitkeep"; content = "" };
    { path = "data/uploads/.gitkeep"; content = "" };
    { path = Printf.sprintf "%s.service" name; content = systemd_unit name };
    { path = ".claude/skills/well/SKILL.md"; content = well_skill };
    (* .claude/skills/idesign-architecture/ *)
    { path = ".claude/skills/idesign-architecture/SKILL.md"; content = idesign_skill_md };
    { path = ".claude/skills/idesign-architecture/references/decomposition.md"; content = idesign_ref_decomposition };
    { path = ".claude/skills/idesign-architecture/references/structure.md"; content = idesign_ref_structure };
    { path = ".claude/skills/idesign-architecture/references/composition.md"; content = idesign_ref_composition };
    { path = ".claude/skills/idesign-architecture/references/design-donts.md"; content = idesign_ref_design_donts };
    { path = ".claude/skills/idesign-architecture/references/design-standard.md"; content = idesign_ref_design_standard };
    { path = ".claude/skills/idesign-architecture/references/contract-design.md"; content = idesign_ref_contract_design };
    { path = ".claude/skills/idesign-architecture/references/design-example.md"; content = idesign_ref_design_example };
    (* .claude/skills/frontend-design/ *)
    { path = ".claude/skills/frontend-design/SKILL.md"; content = frontend_design_skill };
  ]
