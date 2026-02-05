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
|}

let bin_dune name =
  Printf.sprintf
    {|(executable
 (name main)
 (link_flags -linkall)
 (libraries %s_web well.core eio_main))
|}
    name

let bin_main _name =
  {|let () =
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
 (libraries %s well.core well.html eio yojson)
 (preprocess (pps ppx_deriving_yojson)))
|}
    name name

let home_page name =
  Printf.sprintf
    {|Well.get "/" @@ fun _req ->
let open Html in
<Layout title="%s">
<div>
    <h1>(txt "Welcome to %s")</h1>
    <p>(txt "Edit lib/%s_web/home_page.mlx to get started.")</p>
    <p><a href="/counter">(txt "Counter — LiveView demo")</a></p>
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

let init _ctx props =
  let open Yojson.Safe.Util in
  let get_int key default =
    try props |> member key |> to_int with
    | _ -> (
      try props |> member key |> to_string |> int_of_string with
      | _ -> default )
  in
  {count= get_int "initial" 0; step= get_int "step" 1}

let update _ctx model = function
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
    { path = "static/app.css"; content = static_app_css ^ counter_css };
    { path = "static/well-live.js"; content = static_well_live_js };
  ]
