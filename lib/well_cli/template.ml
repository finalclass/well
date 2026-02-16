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
  (ocaml (>= 5.2))
  mlx
  well
  eio
  eio_main
  yojson
  sqlite3
  bisect_ppx
  ppx_deriving_yojson))
|}
    name

let root_dune = {|(dirs :standard \ _build)
|}

let makefile =
  {|.PHONY: build check test clean lock dev coverage

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

coverage:
	dune test --instrument-with bisect_ppx --force
	dune exec -- bisect-ppx-report html -o _coverage/
	dune exec -- bisect-ppx-report summary
	@echo "Coverage report: _coverage/index.html"
	@rm -f *.coverage
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
bin/main.ml                  # entry point
lib/%s/                      # app module (name, version)
lib/%s_web/                  # routes, pages, LiveViews
  home_page.mlx              # welcome page
  counter_live.mlx           # LiveView example (counter)
  notes.ml + notes_page.mlx  # CRUD example with type-safe SQL
  layout.mlx                 # HTML layout
lib/contract/                # service contracts (TOML → generated code)
static/                      # CSS, JS, assets
test/                        # tests
data/                        # SQLite databases (gitignored)
```

## File types

- `.ml` — OCaml (logic, models, queries)
- `.mlx` — OCaml + JSX (views, components)
- `.ts` — TypeScript (compiled to JS via bun, wired through dune)
|} name name name

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
_coverage/
*.coverage
|}

let bin_dune name =
  Printf.sprintf
    {|(executable
 (name main)
 (link_flags -linkall)
 (libraries %s_web contract well.core eio_main))
|}
    name

let bin_main _name =
  {|let () =
  (* Middleware — executed top-to-bottom on every request *)
  Well.use Well.error_handler;
  Well.use Well.logger;
  Well.use Well.csrf;
  Well.use (Well.rate_limit ~max_requests:60 ~window_ms:60_000 ());
  Well.use Request_id.middleware;

  (* Per-route middleware: see notes_page.mlx for require_auth example *)

  (* Services — IDesign: Manager → Access → DB *)
  Well.Service.register Task_access_impl.spec;
  Well.Service.register Task_manager_impl.spec;
  Well.Service.expose "TaskManager";

  Well.live "/counter" (module Counter_live);
  Well.static "/static" "static";
  Well.run ()
|}

let lib_dune name =
  Printf.sprintf
    {|(library
 (name %s)
 (libraries well.core eio yojson)
 (instrumentation (backend bisect_ppx)))
|}
    name

let lib_main name =
  Printf.sprintf {|let name = "%s"
let version = "0.1.0"
|}
    name

let lib_web_dune name =
  Printf.sprintf
    {|(library
 (name %s_web)
 (wrapped false)
 (libraries %s contract well.core well.html eio yojson sqlite3)
 (preprocess (pps ppx_deriving_yojson well.ppx))
 (instrumentation (backend bisect_ppx)))
|}
    name name

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
    <p>(txt "Edit lib/%s_web/home_page.mlx to get started.")</p>
    auth_section
    <p><a href="/counter">(txt "Counter — LiveView demo")</a></p>
    <p><a href="/notes">(txt "Notes — SQLite demo (login required)")</a></p>
    <p><a href="/tasks">(txt "Tasks — Contract/RPC demo")</a></p>
    <p><a href="/upload">(txt "Upload — File upload demo")</a></p>
    <p class_="request-id">(txt ("Request: " ^ Request_id.get req))</p>
</div>
</Layout>
|}
    name name name

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
      <script src="/static/well.js" />
    </body>
  </html>
|}
    name

let test_dune name =
  Printf.sprintf
    {|(test
 (name %s_test)
 (libraries %s well.test)
 (instrumentation (backend bisect_ppx)))
|}
    name name

let test_main name =
  let cap = String.capitalize_ascii name in
  Printf.sprintf
    {|open Well_test

let () =
  describe "%s" (fun () ->
    it "has a name" (fun () ->
      expect %s.name |> to_equal_string "%s"
    );
    it "has a version" (fun () ->
      expect (String.length %s.version > 0) |> to_be_true
    );
  );
  run ~source_file:__FILE__ () |> exit_with_result
|}
    cap cap name cap

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

let notes _name =
  {|(* Notes — type-safe SQLite example *)
(* Queries below are validated at compile time by well.ppx *)

type note = {
  id : int;
  title : string;
  body : string;
} [@@deriving table ~name:"notes"]

let%query all_notes = "SELECT id, title, body FROM notes ORDER BY id DESC"
let%query insert_note = "INSERT INTO notes (title, body) VALUES (:title, :body)"
let%query delete_note = "DELETE FROM notes WHERE id = :id"

let db = lazy (Well.Db.open_db ())
let get_db () = Lazy.force db
|}

let notes_page _name =
  {|(* Per-route middleware — only logged-in users can access /notes *)
let auth = [Well.require_auth ()]
;;

Well.get ~middleware:auth "/notes" @@ fun req ->
let open Html in
let db = Notes.get_db () in
let notes = Notes.All_notes.query db in
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
    (notes |> List.map (fun (n : Notes.All_notes.row) ->
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
let db = Notes.get_db () in
let title = Well.form req "title" in
let body = Well.form req "body" in
if title <> "" then
  Notes.Insert_note.exec db ~title ~body;
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
  | Increment -> {model with count= model.count + model.step}
  | Decrement -> {model with count= model.count - model.step}
  | Reset -> {model with count= 0}

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
      let a = Array.of_list arr in
      let id = (match a.(0) with `Int i -> i | _ -> 0) in
      let title = (match a.(1) with `String s -> s | _ -> "") in
      let completed = (match a.(2) with `Bool b -> b | _ -> false) in
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
      let a = Array.of_list arr in
      let limit = (match a.(0) with `Int i -> i | _ -> 0) in
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
      let a = Array.of_list arr in
      let id = (match a.(0) with `Int i -> i | _ -> 0) in
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
      let a = Array.of_list arr in
      let title = (match a.(0) with `String s -> s | _ -> "") in
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
      let a = Array.of_list arr in
      let id = (match a.(0) with `Int i -> i | _ -> 0) in
      let title = (match a.(1) with `Null -> None | x -> Some ((match x with `String s -> s | _ -> ""))) in
      let completed = (match a.(2) with `Null -> None | x -> Some ((match x with `Bool b -> b | _ -> false))) in
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
      let a = Array.of_list arr in
      let ok = (match a.(0) with `Bool b -> b | _ -> false) in
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
      let a = Array.of_list arr in
      let tasks = (match a.(0) with `List items -> List.map (fun item -> Task.of_wire item) items | _ -> []) in
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
      let a = Array.of_list arr in
      let title = (match a.(0) with `String s -> s | _ -> "") in
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
      let a = Array.of_list arr in
      let id = (match a.(0) with `Int i -> i | _ -> 0) in
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
      let a = Array.of_list arr in
      let id = (match a.(0) with `Int i -> i | _ -> 0) in
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
      let a = Array.of_list arr in
      let tasks = (match a.(0) with `List items -> List.map (fun item -> Task_access.Task.of_wire item) items | _ -> []) in
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
      let a = Array.of_list arr in
      let task = Task_access.Task.of_wire a.(0) in
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
      let a = Array.of_list arr in
      let ok = (match a.(0) with `Bool b -> b | _ -> false) in
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

let contract_dune_file =
  {|(library
 (name contract)
 (wrapped false)
 (libraries well.core yojson))

(rule
 (targets task_access.ml task_manager.ml)
 (deps
  (file ../../TaskAccess.toml)
  (file ../../TaskManager.toml))
 (mode promote)
 (action (run %{bin:well} contract build ../../ ..)))
|}

let static_dune =
  {|; To rebuild after editing TypeScript: rm *.js && dune build
; Requires bun — install from https://bun.sh
(rule
 (targets well.js)
 (deps (file well.ts))
 (mode fallback)
 (action (run bun build well.ts --outdir . --minify)))

(rule
 (targets tasks.js)
 (deps
  (source_tree ts)
  (source_tree ../lib/contract/build/ts))
 (mode fallback)
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
    { path = "bin/dune"; content = bin_dune name };
    { path = "bin/main.ml"; content = bin_main name };
    { path = Printf.sprintf "lib/%s/dune" name; content = lib_dune name };
    { path = Printf.sprintf "lib/%s/%s.ml" name name; content = lib_main name };
    { path = Printf.sprintf "lib/%s_web/dune" name; content = lib_web_dune name };
    {
      path = Printf.sprintf "lib/%s_web/home_page.mlx" name;
      content = home_page name;
    };
    {
      path = Printf.sprintf "lib/%s_web/layout.mlx" name;
      content = layout name;
    };
    {
      path = Printf.sprintf "lib/%s_web/request_id.ml" name;
      content = request_id name;
    };
    {
      path = Printf.sprintf "lib/%s_web/notes.ml" name;
      content = notes name;
    };
    {
      path = Printf.sprintf "lib/%s_web/notes_page.mlx" name;
      content = notes_page name;
    };
    {
      path = Printf.sprintf "lib/%s_web/login_page.mlx" name;
      content = login_page name;
    };
    {
      path = Printf.sprintf "lib/%s_web/counter_live.mlx" name;
      content = counter_live name;
    };
    {
      path = Printf.sprintf "lib/%s_web/counter_page.mlx" name;
      content = counter_page name;
    };
    { path = "test/dune"; content = test_dune name };
    {
      path = Printf.sprintf "test/%s_test.ml" name;
      content = test_main name;
    };
    {
      path = Printf.sprintf "lib/%s_web/task_access_impl.ml" name;
      content = task_access_impl name;
    };
    {
      path = Printf.sprintf "lib/%s_web/task_manager_impl.ml" name;
      content = task_manager_impl name;
    };
    {
      path = Printf.sprintf "lib/%s_web/tasks_page.mlx" name;
      content = tasks_page name;
    };
    { path = "lib/contract/TaskAccess.toml"; content = contract_task_access_toml };
    { path = "lib/contract/TaskManager.toml"; content = contract_task_manager_toml };
    { path = "lib/contract/build/ocaml/task_access.ml"; content = contract_task_access_ml };
    { path = "lib/contract/build/ocaml/task_manager.ml"; content = contract_task_manager_ml };
    { path = "lib/contract/build/ocaml/dune"; content = contract_dune_file };
    { path = "lib/contract/build/ts/rpc.ts"; content = contract_ts_rpc };
    { path = "lib/contract/build/ts/TaskAccess.ts"; content = contract_ts_task_access };
    { path = "lib/contract/build/ts/TaskManager.ts"; content = contract_ts_task_manager };
    { path = "static/dune"; content = static_dune };
    { path = "static/ts/tasks.ts"; content = tasks_ts };
    { path = "static/tasks.js"; content = tasks_js };
    { path = "static/app.css"; content = static_app_css ^ notes_css ^ counter_css ^ auth_css ^ tasks_css ^ upload_css };
    { path = "static/well.ts"; content = static_well_ts };
    { path = "tsconfig.json"; content = tsconfig_json };
    { path = "data/.gitkeep"; content = "" };
    { path = "data/uploads/.gitkeep"; content = "" };
    {
      path = Printf.sprintf "lib/%s_web/upload_page.mlx" name;
      content = upload_page name;
    };
  ]
