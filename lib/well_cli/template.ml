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
	dune exec bin/main.exe
|}

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
 (libraries well.core eio yojson))
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
 (preprocess (pps ppx_deriving_yojson well.ppx)))
|}
    name name

let home_page name =
  Printf.sprintf
    {|Well.get "/" @@ fun req ->
let open Html in
let user = Well.current_user req in
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
      <script src="/static/well-live.js" />
    </body>
  </html>
|}
    name

let test_dune name =
  Printf.sprintf
    {|(test
 (name %s_test)
 (libraries %s well.test))
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
  run () |> exit_with_result
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

let db =
  lazy
    (let d = Sqlite3.db_open "data/app.sqlite" in
     ignore (Sqlite3.exec d "PRAGMA journal_mode=WAL");
     ignore (Sqlite3.exec d "PRAGMA synchronous=NORMAL");
     ignore (Sqlite3.exec d note_create_table_sql);
     d)

let get_db () = Lazy.force db
|}

let notes_page _name =
  {|(* Per-route middleware — only logged-in users can access /notes *)
let auth = [Well.require_auth ()]

let () =
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

let () =
  Well.post ~middleware:auth "/notes" @@ fun req ->
  let db = Notes.get_db () in
  let title = Well.form req "title" in
  let body = Well.form req "body" in
  if title <> "" then
    Notes.Insert_note.exec db ~title ~body;
  Well.redirect "/notes"
|}

let login_page _name =
  {|let () =
  Well.get "/login" @@ fun req ->
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

let () =
  Well.post "/login" @@ fun req ->
  let username = Well.form req "username" in
  let return_to = let r = Well.form req "return_to" in if r = "" then "/" else r in
  if username <> "" then Well.login req username;
  Well.redirect return_to

let () =
  Well.post "/logout" @@ fun req ->
  Well.logout req;
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

let render model =
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
let module LiveView = Well.LiveView in
<Layout title="Counter">
<div>
    <h1>(txt "Counter — LiveView Demo")</h1>
    <p>(txt "Real-time server-side state with WebSocket updates.")</p>
    <LiveView name="counter" />
    <p><a href="/">(txt "Back")</a></p>
</div>
</Layout>
|}

let static_well_live_js =
  {|// well-live.js — LiveView client
// Handles WebSocket connection, DOM patching, and event delegation

(function () {
  "use strict";

  let ws = null;
  let reconnectDelay = 500;
  const maxReconnectDelay = 10000;
  const liveViews = new Map();

  function connect() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const url = proto + "//" + location.host + "/live";
    ws = new WebSocket(url);

    ws.onopen = function () {
      reconnectDelay = 500;
      liveViews.forEach(function (lv, topic) {
        lv.el.classList.add("lv-loading");
        ws.send(JSON.stringify({
          type: "join", topic: topic,
          endpoint: lv.endpoint, props: lv.props,
        }));
      });
    };

    ws.onmessage = function (event) {
      let msg;
      try { msg = JSON.parse(event.data); } catch (e) { return; }
      const topic = msg.topic;
      const lv = liveViews.get(topic);
      if (!lv) return;

      switch (msg.type) {
        case "full":
        case "restored":
          lv.el.innerHTML = msg.html;
          lv.el.classList.remove("lv-loading");
          break;
        case "patch":
          if (msg.changes) {
            const keys = Object.keys(msg.changes);
            for (let i = 0; i < keys.length; i++) {
              const id = keys[i];
              const el = lv.el.querySelector('[data-lv="' + id + '"]');
              if (el) el.textContent = msg.changes[id];
            }
          }
          if (msg.list_ops) {
            const listIds = Object.keys(msg.list_ops);
            for (let i = 0; i < listIds.length; i++) {
              const listId = listIds[i];
              const ops = msg.list_ops[listId];
              const container = lv.el.querySelector('[data-lv-each="' + listId + '"]');
              if (!container) continue;
              const existing = new Map();
              for (let j = 0; j < container.children.length; j++) {
                const key = container.children[j].getAttribute("data-lv-key");
                if (key) existing.set(key, container.children[j]);
              }
              if (ops.inserts) {
                const insertKeys = Object.keys(ops.inserts);
                for (let j = 0; j < insertKeys.length; j++) {
                  const key = insertKeys[j];
                  const tmp = document.createElement("div");
                  tmp.innerHTML = ops.inserts[key];
                  const newEl = tmp.firstElementChild;
                  if (newEl) existing.set(key, newEl);
                }
              }
              if (ops.order) {
                while (container.firstChild) container.removeChild(container.firstChild);
                for (let j = 0; j < ops.order.length; j++) {
                  const el = existing.get(ops.order[j]);
                  if (el) container.appendChild(el);
                }
              }
            }
          }
          break;
      }
    };

    ws.onclose = function () {
      liveViews.forEach(function (lv) { lv.el.classList.add("lv-loading"); });
      setTimeout(function () {
        reconnectDelay = Math.min(reconnectDelay * 2, maxReconnectDelay);
        connect();
      }, reconnectDelay);
    };

    ws.onerror = function () { ws.close(); };
  }

  function sendMsg(topic, msg) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: "msg", topic: topic, msg: msg }));
    }
  }

  function findLiveView(el) {
    let node = el;
    while (node) {
      if (node.tagName === "LIVE-VIEW") {
        return node.getAttribute("data-topic") || node.getAttribute("data-liveview");
      }
      node = node.parentElement;
    }
    return null;
  }

  document.addEventListener("click", function (e) {
    const target = e.target.closest("[data-lv-click]");
    if (!target) return;
    const action = target.getAttribute("data-lv-click");
    const topic = findLiveView(target);
    if (topic && action) sendMsg(topic, [action]);
  });

  document.addEventListener("submit", function (e) {
    const target = e.target.closest("[data-lv-submit]");
    if (!target) return;
    e.preventDefault();
    const action = target.getAttribute("data-lv-submit");
    const topic = findLiveView(target);
    if (!topic || !action) return;
    const formData = new FormData(target);
    const data = {};
    formData.forEach(function (value, key) { data[key] = value; });
    sendMsg(topic, [action, data]);
    target.querySelectorAll('input:not([type="hidden"]):not([type="submit"])').forEach(function (input) { input.value = ""; });
  });

  document.addEventListener("input", function (e) {
    const target = e.target.closest("[data-lv-change]");
    if (!target) return;
    const action = target.getAttribute("data-lv-change");
    const topic = findLiveView(target);
    if (topic && action) sendMsg(topic, [action, e.target.value]);
  });

  document.addEventListener("DOMContentLoaded", function () {
    const elements = document.querySelectorAll("live-view");
    if (elements.length === 0) return;
    elements.forEach(function (el) {
      const endpoint = el.getAttribute("data-liveview");
      const topic = el.getAttribute("data-topic") || endpoint;
      let props = {};
      try { props = JSON.parse(el.getAttribute("data-props") || "{}"); } catch (e) {}
      liveViews.set(topic, { el: el, endpoint: endpoint, props: props });
    });
    connect();
  });
})();
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

let _service_ref : (string -> Yojson.Safe.t -> Yojson.Safe.t) option ref = ref None

module type IMPL = sig
  type state
  val init : unit -> state
  val list : state -> ListReq.t -> TaskList.t
  val get : state -> IdReq.t -> Task.t
  val create : state -> CreateReq.t -> Task.t
  val update : state -> UpdateReq.t -> Task.t
  val delete : state -> IdReq.t -> Ok.t
end

let make_spec (type s) (module I : IMPL with type state = s) : Well.Service.spec =
  let state = ref (I.init ()) in
  { name = "TaskAccess"
  ; rpcs = ["list"; "get"; "create"; "update"; "delete"]
  ; handler = (fun rpc_name payload ->
      match rpc_name with
      | "list" ->
          TaskList.to_wire (I.list !state (ListReq.of_wire payload))
      | "get" ->
          Task.to_wire (I.get !state (IdReq.of_wire payload))
      | "create" ->
          Task.to_wire (I.create !state (CreateReq.of_wire payload))
      | "update" ->
          Task.to_wire (I.update !state (UpdateReq.of_wire payload))
      | "delete" ->
          Ok.to_wire (I.delete !state (IdReq.of_wire payload))
      | _ -> failwith ("Unknown RPC: " ^ rpc_name))
  ; set_ref = (fun f -> _service_ref := Some f)
  }

let list ~limit =
  let wire = ListReq.to_wire (ListReq.make ~limit ()) in
  TaskList.of_wire
    ((match !_service_ref with
      | Some f -> f "list" wire
      | None -> failwith "TaskAccess: service not registered"))

let get ~id =
  let wire = IdReq.to_wire (IdReq.make ~id ()) in
  Task.of_wire
    ((match !_service_ref with
      | Some f -> f "get" wire
      | None -> failwith "TaskAccess: service not registered"))

let create ~title =
  let wire = CreateReq.to_wire (CreateReq.make ~title ()) in
  Task.of_wire
    ((match !_service_ref with
      | Some f -> f "create" wire
      | None -> failwith "TaskAccess: service not registered"))

let update ~id ?title ?completed () =
  let wire = UpdateReq.to_wire (UpdateReq.make ~id ?title ?completed ()) in
  Task.of_wire
    ((match !_service_ref with
      | Some f -> f "update" wire
      | None -> failwith "TaskAccess: service not registered"))

let delete ~id =
  let wire = IdReq.to_wire (IdReq.make ~id ()) in
  Ok.of_wire
    ((match !_service_ref with
      | Some f -> f "delete" wire
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

let _service_ref : (string -> Yojson.Safe.t -> Yojson.Safe.t) option ref = ref None

module type IMPL = sig
  type state
  val init : unit -> state
  val list : state -> Task_access.ListReq.t -> TaskListRes.t
  val add : state -> AddReq.t -> TaskRes.t
  val toggle : state -> ToggleReq.t -> TaskRes.t
  val delete : state -> DeleteReq.t -> StatusRes.t
end

let make_spec (type s) (module I : IMPL with type state = s) : Well.Service.spec =
  let state = ref (I.init ()) in
  { name = "TaskManager"
  ; rpcs = ["list"; "add"; "toggle"; "delete"]
  ; handler = (fun rpc_name payload ->
      match rpc_name with
      | "list" ->
          TaskListRes.to_wire (I.list !state (Task_access.ListReq.of_wire payload))
      | "add" ->
          TaskRes.to_wire (I.add !state (AddReq.of_wire payload))
      | "toggle" ->
          TaskRes.to_wire (I.toggle !state (ToggleReq.of_wire payload))
      | "delete" ->
          StatusRes.to_wire (I.delete !state (DeleteReq.of_wire payload))
      | _ -> failwith ("Unknown RPC: " ^ rpc_name))
  ; set_ref = (fun f -> _service_ref := Some f)
  }

let list req =
  let wire = Task_access.ListReq.to_wire req in
  TaskListRes.of_wire
    ((match !_service_ref with
      | Some f -> f "list" wire
      | None -> failwith "TaskManager: service not registered"))

let add ~title =
  let wire = AddReq.to_wire (AddReq.make ~title ()) in
  TaskRes.of_wire
    ((match !_service_ref with
      | Some f -> f "add" wire
      | None -> failwith "TaskManager: service not registered"))

let toggle ~id =
  let wire = ToggleReq.to_wire (ToggleReq.make ~id ()) in
  TaskRes.of_wire
    ((match !_service_ref with
      | Some f -> f "toggle" wire
      | None -> failwith "TaskManager: service not registered"))

let delete ~id =
  let wire = DeleteReq.to_wire (DeleteReq.make ~id ()) in
  StatusRes.of_wire
    ((match !_service_ref with
      | Some f -> f "delete" wire
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
  {|; To rebuild after editing TypeScript: rm tasks.js && dune build
; Requires bun — install from https://bun.sh
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

let db =
  lazy
    (let d = Sqlite3.db_open "data/app.sqlite" in
     ignore (Sqlite3.exec d "PRAGMA journal_mode=WAL");
     ignore (Sqlite3.exec d "PRAGMA synchronous=NORMAL");
     ignore (Sqlite3.exec d task_row_create_table_sql);
     d)

let get_db () = Lazy.force db

let task_of_row (r : All_tasks.row) : Task_access.Task.t =
  { id = r.id; title = r.title; completed = r.completed <> 0 }

let task_of_find (r : Find_task.row) : Task_access.Task.t =
  { id = r.id; title = r.title; completed = r.completed <> 0 }

module Impl : Task_access.IMPL with type state = unit = struct
  type state = unit
  let init () = ()

  let list () (req : Task_access.ListReq.t) =
    let db = get_db () in
    let rows = All_tasks.query db in
    let tasks = List.map task_of_row rows in
    let tasks =
      if req.limit > 0 then
        List.filteri (fun i _ -> i < req.limit) tasks
      else tasks
    in
    Task_access.TaskList.make ~tasks ()

  let get () (req : Task_access.IdReq.t) =
    let db = get_db () in
    match Find_task.query db ~id:req.id with
    | r :: _ -> task_of_find r
    | [] -> failwith "Task not found"

  let create () (req : Task_access.CreateReq.t) =
    let db = get_db () in
    Insert_task.exec db ~title:req.title;
    let id = Int64.to_int (Sqlite3.last_insert_rowid db) in
    Task_access.Task.make ~id ~title:req.title ~completed:false ()

  let update () (req : Task_access.UpdateReq.t) =
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

  let delete () (req : Task_access.IdReq.t) =
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

  let list () (req : Task_access.ListReq.t) =
    let result = Task_access.list ~limit:req.limit in
    Task_manager.TaskListRes.make ~tasks:result.tasks ()

  let add () (req : Task_manager.AddReq.t) =
    if String.trim req.title = "" then failwith "Title cannot be empty";
    let task = Task_access.create ~title:req.title in
    Task_manager.TaskRes.make ~task ()

  let toggle () (req : Task_manager.ToggleReq.t) =
    let current = Task_access.get ~id:req.id in
    ignore (Task_access.update ~id:req.id ~completed:(not current.completed) ());
    let updated = Task_access.get ~id:req.id in
    Task_manager.TaskRes.make ~task:updated ()

  let delete () (req : Task_manager.DeleteReq.t) =
    ignore (Task_access.delete ~id:req.id);
    Task_manager.StatusRes.make ~ok:true ()
end

let spec = Task_manager.make_spec (module Impl)
|}

let tasks_page _name =
  {|let () =
  Well.get "/tasks" @@ fun _req ->
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
    { path = "static/app.css"; content = static_app_css ^ notes_css ^ counter_css ^ auth_css ^ tasks_css };
    { path = "static/well-live.js"; content = static_well_live_js };
    { path = "tsconfig.json"; content = tsconfig_json };
    { path = "data/.gitkeep"; content = "" };
  ]
