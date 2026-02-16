---
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

## Project Structure

```
myapp/
├── bin/main.ml              # Entry point: middleware + Well.run ()
├── lib/myapp/myapp.ml       # App name + version
├── lib/myapp_web/           # (wrapped false) — all modules top-level
│   ├── layout.mlx           # Layout component
│   ├── home_page.mlx        # Routes: Well.get "/" ...
│   ├── counter_live.mlx     # LiveView module
│   └── notes.ml             # Models + queries
├── lib/contract/            # Service contracts (TOML)
├── static/                  # CSS, JS, assets
└── test/myapp_test.ml       # Tests
```

The web library is `(wrapped false)` — every file is a top-level module (e.g. `Layout`, `Counter_live`).

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
      <script src="/static/well.js" />
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

Register in `bin/main.ml`:
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
- `data_lv_change="MsgName"` — input change
- `data_lv_debounce="300"` — debounce input (ms)
- `data_lv_navigate="/path"` — client-side navigation
- `data_lv_hook="HookName"` — attach JS hook

Variant encoding (ppx_deriving_yojson):
- `Increment` -> `["Increment"]` (JSON array)
- `SetValue of int` -> `["SetValue", 42]`
- Click handler sends array format: `data_lv_click="Increment"` sends `["Increment"]`

## Cross-LiveView Communication

Use `Well.LiveView.broadcast` to send messages between LiveViews:

```ocaml
(* In sender's update *)
let update _req model = function
  | Increment ->
    let m = { count = model.count + 1 } in
    Well.LiveView.broadcast "/live/activity_log"
      (`List [`String "CounterEvent"; `String "increment"; `Int m.count]);
    m

(* Receiver's msg type must match the broadcast format *)
type msg = CounterEvent of string * int [@@deriving yojson]
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
    (* ... query db ... *)
    Task_access.TaskList.make ~tasks ()

  let create () _ctx (req : Task_access.CreateReq.t) =
    (* ... insert ... *)
    Task_access.Task.make ~id ~title:req.title ~completed:false ()
end

let spec = Task_access.make_spec (module Impl)
```

Register in `bin/main.ml`:
```ocaml
Well.Service.register Task_access_impl.spec;
Well.Service.expose "TaskAccess";  (* creates HTTP routes *)
```

## Middleware

```ocaml
(* bin/main.ml *)
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

(* Require auth middleware *)
let auth = [Well.require_auth ()]
Well.get ~middleware:auth "/protected" @@ fun req -> ...
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
(* Publish persistent event *)
Well.MessageBus.publish "orders/new" (`Assoc [("id", `Int 42)]);

(* Publish ephemeral (skip SQLite) *)
Well.MessageBus.publish ~ephemeral:true "typing/user1" `Null;

(* Subscribe with wildcard *)
Well.MessageBus.subscribe "orders/*" (fun event ->
  Printf.printf "Got: %s\n" event.channel);

(* Channel — authorized WS gateway *)
Well.channel "room:*" (fun req topic ->
  match Well.current_user req with
  | Some _ -> Ok { subscribe = [topic] }
  | None -> Error "unauthorized");
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
well test --coverage    # With bisect_ppx coverage
well docs [--open]      # Generate HTML documentation
well contract build .   # Generate from TOML contracts
well db diff            # Show pending migrations
well repl               # Interactive service shell
```

## Common Patterns Checklist

When adding a new feature, you typically need:

1. **Static page**: Create `feature_page.mlx` with `Well.get "/path" @@ fun req -> ...`
2. **With data**: Create `feature.ml` with model type + `[@@deriving table]` + `let%query` + `let db = lazy (Well.Db.open_db ())`
3. **LiveView**: Create `feature_live.mlx` with `model`/`msg` types + `[@@deriving yojson]` + `init`/`update`/`view`, register with `Well.live "/path" (module Feature_live)` in `bin/main.ml`
4. **Service**: Create TOML contract, run `well contract build`, implement `IMPL` module, register with `Well.Service.register` + `Well.Service.expose`
5. **Tests**: Add to `test/` with `Well.Db.with_test_db` or `Well.with_test_server`
