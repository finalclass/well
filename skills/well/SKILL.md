---
name: well
description: Use when building features, pages, routes, LiveViews, models, or services in a well framework application. Covers MLX syntax, route registration, LiveView patterns, type-safe SQL, contracts, and project conventions.
user-invocable: true
allowed-tools: Read, Edit, Write, Bash, Glob, Grep
---

# Well Framework — Comprehensive Reference

You are generating code for a **well** application — a batteries-included, type-safe, server-first OCaml web framework. Single binary deployment, no JavaScript for business logic. Inspired by Phoenix LiveView, Rails, and the OCaml ecosystem.

**Tech stack**: OCaml 5.4 + EIO (fiber-per-connection), MLX for JSX, SQLite (bundled), dune 3.17, bun (frontend assets).

## File Extensions

- `.ml` — pure OCaml (models, queries, logic, services)
- `.mlx` — OCaml + JSX (pages, components, layouts)

---

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
- **All attribute values are strings** — use `attrs=[("value", string_of_int n)]` for numbers
- **All attributes use `attrs=[...]` and `bool_attrs=[...]`** — no labeled attribute params

---

## HTML Library (well.html)

Module `Html` — `(wrapped false)`, imported directly.

### Core Types & Functions

```ocaml
type node = [ `Html of string ]  (* coerces to Well.response via :> *)

val txt : string -> node        (* escaped text — safe *)
val raw : string -> node        (* raw HTML — unescaped, use with care *)
val escape_html : string -> string
val cat : node list -> string   (* concatenate nodes to string *)
val element_to_string : node -> string
```

### Tag Functions

All tag functions accept two optional attribute parameters:

- `?attrs:(string * string) list` — all string attributes (class, id, href, data-lv-click, etc.)
- `?bool_attrs:string list` — all boolean attributes (hidden, disabled, checked, etc.)

Use standard HTML attribute names as strings: `"class"`, `"type"`, `"method"`, `"name"`, `"for"`, `"data-lv-click"`, `"data-lv-submit"`, etc.

```ocaml
<button
  attrs=[("class", "btn"); ("data-lv-click", "close");
         ("aria-label", "Close"); ("data-tooltip", "Dismiss")]
  bool_attrs=["aria-expanded"]>"X"</button>
```

**All tags** (full HTML5 coverage):
- **Document**: `html`, `head`, `title`, `body`, `base`
- **Sections**: `main`, `header`, `footer`, `nav`, `section`, `article`, `aside`, `address`
- **Headings**: `h1`–`h6`
- **Grouping**: `div`, `p`, `pre`, `blockquote`, `figure`, `figcaption`, `hr`, `br`, `wbr`
- **Lists**: `ul`, `ol`, `li`, `dl`, `dt`, `dd`
- **Inline**: `span`, `a`, `strong`, `em`, `b`, `i`, `u`, `s`, `small`, `mark`, `del`, `ins`, `sub`, `sup`, `abbr`, `time`, `cite`, `q`, `dfn`, `var`, `samp`, `kbd`, `code`, `data`, `ruby`, `rt`, `rp`, `bdi`, `bdo`
- **Tables**: `table`, `thead`, `tbody`, `tfoot`, `tr`, `th`, `td`, `caption`, `colgroup`, `col`
- **Forms**: `form`, `button`, `input`, `label`, `textarea`, `select`, `option`, `optgroup`, `fieldset`, `legend`, `datalist`, `output`, `progress`, `meter`
- **Interactive**: `details`, `summary`, `dialog`
- **Media**: `img`, `video`, `audio`, `source`, `track`, `canvas`, `picture`, `iframe`, `embed`, `object_`, `map`, `area`
- **Metadata**: `meta`, `link`, `script`, `noscript`, `template`, `slot`

**Void elements** (self-closing): `input`, `img`, `br`, `hr`, `meta`, `link`, `source`, `track`, `embed`, `col`, `area`, `wbr`, `base`

### Form Helpers

```ocaml
val csrf_input : string -> node
(* Generates: <input type="hidden" name="_csrf_token" value="token" /> *)

val field_error : (string * string) list -> string -> node
(* Renders error message for a form field if present in errors list *)
```

### List Rendering

```ocaml
(* Render a list of nodes via cat (fragment node): *)
items |> List.map render_item |> cat
```

---

## Project Structure

```
myapp/
├── bin/main.ml                              # Entry point → App.run ()
├── lib/
│   ├── app.ml                               # Middleware, services, routes, Well.run ()
│   ├── events.ml                            # Typed pub/sub topics
│   ├── layout.mlx                           # Layout component
│   ├── request_id.ml                        # Request ID context middleware
│   ├── pages/home_page.mlx                  # Pages.Home_page — routes: Well.get "/" ...
│   ├── live/counter_live.mlx                # Live.Counter_live — LiveView module
│   ├── services/note_access_impl.ml         # Services.Note_access_impl
│   └── contract/                            # Service contracts (TOML)
├── static/                                  # CSS, JS, assets
└── test/myapp_test.ml                       # Tests
```

The app library uses `(include_subdirs qualified)` — subdirectories become submodules (e.g. `Pages.Home_page`, `Live.Counter_live`, `Services.Note_access_impl`).

---

## Core Types

```ocaml
type request = {
  meth : string;
  path : string;
  headers : (string * string) list;
  body : string;
  params : (string * string) list;  (* path params *)
  query : (string * string) list;   (* query string *)
  session_id : string;
  _context : (int * Obj.t) list;    (* typed context storage *)
}

type response = [
  | `Null | `Bool of bool | `Int of int | `Float of float
  | `String of string | `Intlit of string
  | `List of Yojson.Safe.t list | `Assoc of (string * Yojson.Safe.t) list
  | `Html of string | `Text of string | `Redirect of string
  | `Custom of custom | `Stream of stream_config
]

type handler = request -> response
type middleware = handler -> handler

type uploaded_file = { filename: string; content_type: string; size: int; data: string }
type fetch_response = { status: int; headers: (string * string) list; body: string }
```

---

## Routing

### Route Registration

```ocaml
Well.get  : ?middleware:middleware list -> string -> (request -> [< response]) -> unit
Well.post : ?middleware:middleware list -> string -> (request -> [< response]) -> unit
Well.put  : ?middleware:middleware list -> string -> (request -> [< response]) -> unit
Well.delete : ?middleware:middleware list -> string -> (request -> [< response]) -> unit
Well.ws   : string -> (request -> Websocket.t -> unit) -> unit
```

Path params via `:param` segments: `"/users/:id"`.
Wildcard `*name` as last segment catches the rest of the URL:
`"/files/*path"` → `Well.param req "path"` = `"a/b/c"`.
`*` must be the last segment (e.g. `"/api/*rest/foo"` is invalid).
Routes matched in registration order. No match → 404. Handler exception → 500.

### Route Scoping

```ocaml
Well.scope : ?middleware:middleware list -> string -> (unit -> unit) -> unit

(* Groups routes under a prefix with shared middleware *)
Well.scope ~middleware:[Well.require_auth ()] "/admin" (fun () ->
  Well.get "/dashboard" @@ fun req -> (* /admin/dashboard *) ...;
  Well.get "/users" @@ fun req -> (* /admin/users *) ...
)
```

### Response Constructors & Transformers

```ocaml
Well.html : string -> response
Well.text : string -> response
Well.json : Yojson.Safe.t -> response
Well.redirect : string -> response
Well.stream : ?content_type:string -> ?status:int -> ?headers:(string*string) list
           -> ((string -> unit) -> unit) -> response

(* Pipeable transformers — wrap in `Custom *)
Well.status : int -> response -> response
Well.header : string -> string -> response -> response

(* Stream a file with chunked transfer *)
Well.stream_file : ?content_type:string -> ?headers:(string*string) list -> string -> response
```

Response types coerce automatically:
- `Html.node` — `<div>...</div>` (text/html)
- `` `Text "..." `` or `Well.text "..."` (text/plain)
- `` `Assoc [...] `` or `Well.json (...)` (application/json)
- `Well.redirect "/path"` (302)
- Pipeline: `<div/> |> Well.status 201 |> Well.header "X-Custom" "val"`

### Request Helpers

```ocaml
Well.param : request -> string -> string option      (* path param *)
Well.query : request -> string -> string option      (* query param *)
Well.form  : request -> string -> string option      (* form field *)
Well.form_params : request -> (string * string) list (* all form fields *)
Well.file  : request -> string -> uploaded_file option (* single file upload *)
Well.files : request -> string -> uploaded_file list   (* multiple files *)
Well.all_files : request -> (string * uploaded_file) list
Well.request_id : request -> string                  (* unique request ID *)
Well.csrf_token : request -> string                  (* CSRF token for forms *)
Well.current_user : request -> string option         (* user_id from session *)
```

### Static Files

```ocaml
Well.static "/static" "static"
(* Serves files from "static/" dir at /static/* URL prefix *)
(* Auto-detects MIME type from extension *)
```

### Examples

```ocaml
(* Simple page *)
Well.get "/about" @@ fun _req ->
let open Html in
<Layout title="About">
  <h1>(txt "About")</h1>
</Layout>

(* JSON API with path params *)
Well.get "/users/:id" @@ fun req ->
let id = Option.value ~default:"" (Well.param req "id") in
Well.json (`Assoc [("id", `String id)])

(* Form handling *)
Well.post "/items" @@ fun req ->
let name = Option.value ~default:"" (Well.form req "name") in
(* ... process ... *)
Well.redirect "/items"

(* Wildcard catch-all *)
Well.get "/files/*path" @@ fun req ->
let path = Option.value ~default:"" (Well.param req "path") in  (* "docs/readme.txt" *)
serve_file path

(* Per-route middleware *)
Well.get ~middleware:[Well.require_auth ()] "/admin" @@ fun req -> ...

(* Streaming response *)
Well.get "/export" @@ fun _req ->
Well.stream ~content_type:"text/csv" (fun write ->
  write "id,name\n";
  List.iter (fun row -> write (format_csv row)) rows)
```

---

## Layout Component

```ocaml
(* layout.mlx *)
let createElement ?title:(page_title = "") ?(children = []) () =
  let open Html in
  <html attrs=[("lang", "en")]>
    <head>
      <meta attrs=[("charset", "utf-8")] />
      <title>(txt page_title)</title>
      <link attrs=[("rel", "stylesheet"); ("href", "/static/app.css")] />
      (Well.LiveView.live_preconnect_script ())
    </head>
    <body>
      <main>(children |> cat)</main>
      <script attrs=[("type", "module"); ("src", "/static/well.js")] />
    </body>
  </html>
```

Use in pages: `<Layout title="My Page"><h1>(txt "Hello")</h1></Layout>`

---

## LiveView — Server-Side Reactive UI

Elm architecture: model -> update -> view. All state on server, updates via WebSocket.

### VIEW Module Type

Every LiveView module must satisfy this interface:

```ocaml
module type VIEW = sig
  type model
  type msg

  val persistence : persistence      (* Ephemeral | Session | User *)

  val init : request -> Yojson.Safe.t -> model * string list
    (* Returns (initial_model, subscriptions).
       Subscriptions are MessageBus channels to auto-subscribe.
       Dynamic — can depend on init props (e.g. keyed topics). *)
  val update : request -> model -> msg -> model
  val handle_params : request -> model -> model  (* URL query param changes *)
  val view : model -> Html.node
  val temporary_assigns : model -> model  (* reset data after each render *)

  (* Required — generated by [@@deriving yojson] *)
  val model_to_yojson : model -> Yojson.Safe.t
  val model_of_yojson : Yojson.Safe.t -> (model, string) result
  val msg_of_yojson : Yojson.Safe.t -> (msg, string) result
end
```

**Persistence modes**:
- `Ephemeral` — fresh state per connection
- `Session` — in-memory per session (survives reconnect, 5 min timeout)
- `User` — SQLite per user (survives restart, syncs across devices)

### Complete LiveView Example

```ocaml
(* counter_live.mlx *)
type model = { count: int } [@@deriving yojson]
type msg = Increment | Decrement | Reset [@@deriving yojson]

let persistence = Well.LiveView.Ephemeral

let init _req _props = ({ count = 0 }, [])
(* Returns (model, subscriptions). Empty list = no MessageBus subscriptions. *)

let update _req model = function
  | Increment -> { count = model.count + 1 }
  | Decrement -> { count = model.count - 1 }
  | Reset -> { count = 0 }

let handle_params _req model = model
let temporary_assigns model = model

let view model =
  let open Html in
  <div>
    <span>(txt (string_of_int model.count))</span>
    <button attrs=[("data-lv-click", "Increment")]>(txt "+")</button>
    <button attrs=[("data-lv-click", "Decrement")]>(txt "-")</button>
  </div>
```

### Registration & Embedding

**Two steps to create a LiveView page:**

**Step 1.** Register the LiveView module in `lib/app.ml`:
```ocaml
Well.live "/counter" (module Live.Counter_live)
```
This registers `Live.Counter_live` in the WS view registry under endpoint `"/live/counter"`.
It does NOT create a GET route — you must create the page yourself.

**Step 2.** Create a GET page that embeds the LiveView using MLX JSX:
```ocaml
(* lib/pages/counter_page.mlx *)
Well.get "/counter" @@ fun _req ->
  let open Html in
  <Layout title="Counter">
    <div>
      <h1>(txt "Counter")</h1>
      <Well.LiveView name="counter" />
    </div>
  </Layout>
```

`<Well.LiveView name="counter" />` renders a `<live-view data-liveview="/live/counter">` custom element.
The `name` becomes the endpoint path: `"/live/" ^ name`.

With props (passed to `init` as `Yojson.Safe.t`):
```ocaml
<Well.LiveView name="counter" props=[("initial", "10"); ("step", "5")] />
```

Multiple LiveViews on one page:
```ocaml
<Well.LiveView name="counter" />
<Well.LiveView name="activity_log" />
```

**How it works under the hood:**
1. `Well.live "/counter" (module M)` registers `M` under endpoint `"/live/counter"`
2. `<Well.LiveView name="counter" />` renders `<live-view data-liveview="/live/counter">`
3. Client JS discovers `<live-view>` elements on page load
4. Client connects via WebSocket to `/live` and sends `join` for each endpoint
5. Server sends initial HTML (`full`), then incremental binary patches on each `msg`

**IMPORTANT**: `Well.live` does NOT create a GET route. You MUST create a page
with `Well.get` and embed `<Well.LiveView name="..." />` inside it.
The `name` must match the path from `Well.live` (without leading `/`).
```

### LiveView Attributes

| Attribute | Description | Wire format |
|-----------|-------------|-------------|
| `attrs=[("data-lv-click", "Msg")]` | Click sends msg (no args) | `["Msg"]` |
| `attrs=[("data-lv-click", {|["Msg","val"]|})]` | Click with payload (JSON array in attr) | `["Msg", "val"]` |
| `attrs=[("data-lv-submit", "Msg")]` | Form submit (fields as object) | `["Msg", {field: value, ...}]` |
| `attrs=[("data-lv-change", "Msg")]` | Input change (single value) | `["Msg", input_value]` |
| `attrs=[("data-lv-debounce", "300")]` | Debounce (ms) | — |
| `attrs=[("data-lv-throttle", "300")]` | Throttle (ms) | — |
| `attrs=[("data-lv-navigate", "/path")]` | Live navigation (pushState) | — |
| `attrs=[("data-lv-patch", "/path?q=x")]` | Update query params only | — |
| `attrs=[("data-lv-hook", "HookName")]` | Attach JS hook | — |

### Variant encoding (ppx_deriving_yojson)

- `Increment` → `["Increment"]` (JSON array, NOT string)
- `SetValue of int` → `["SetValue", 42]`
- `SubmitForm of { name: string; email: string }` → `["SubmitForm", {"name": "...", "email": "..."}]`
- `` `Incremented (s, n) `` → `["Incremented", "s", 42]`

### Click with payload

`data_lv_click` tries `JSON.parse` on the attribute value. If it parses as an array, it's sent as-is.
Otherwise the string is wrapped in `["string"]`.

```ocaml
(* No payload — simple variant *)
<button attrs=[("data-lv-click", "Increment")]>(txt "+")</button>
(* sends: ["Increment"] → decoded as: Increment *)

(* With payload — encode JSON array in attribute *)
<button attrs=[("data-lv-click", Printf.sprintf {|["SetPage", "%s"]|} (Html.escape_html page))]>
  (txt page)
</button>
(* sends: ["SetPage", "cennik.html"] → decoded as: SetPage "cennik.html" *)

(* Static payload — use raw JSON string *)
<button attrs=[("data-lv-click", {|["SelectTab", "settings"]|})]>(txt "Settings")</button>
```

### Form submissions (`data_lv_submit`)

The client collects all form inputs into a JSON object and sends `["MsgName", {"field1": "value1", ...}]`.
Use **inline record variants** for form messages — ppx_deriving_yojson decodes them correctly:

```ocaml
(* CORRECT — inline record matches form JSON {"author":"...","body":"..."} *)
type msg =
  | Increment
  | SubmitComment of { author: string; body: string }
[@@deriving yojson]

(* WRONG — tuple variant expects ["SubmitComment", "v1", "v2"] but form sends object *)
type msg = SubmitComment of string * string [@@deriving yojson]
```

Input `name` attributes must match record field names:
```ocaml
<form attrs=[("data-lv-submit", "SubmitComment")]>
  <input attrs=[("type", "text"); ("name", "author"); ("placeholder", "Name")] />
  <textarea attrs=[("name", "body")]>(txt "")</textarea>
  <button attrs=[("type", "submit")]>(txt "Send")</button>
</form>
```

### View Rendering

The `view` function returns HTML that is morphed into the DOM on each update.
No annotation required — structural changes (if/else, conditional elements) are
handled automatically by the client-side morphdom algorithm.

```ocaml
(* Conditional rendering — works fine *)
let view model =
  let open Html in
  <div>
    (if model.items = [] then
      <p>(txt "Nothing here")</p>
    else
      <div attrs=[("class", "list")]>
        (each ~id:"items" model.items
          ~key:(fun item -> string_of_int item.id)
          (fun item -> ...))
      </div>)
  </div>
```

Tips:
1. Use `data-lv-key` or `id` on list items for stable element matching
2. Use `data-lv-ignore` to skip morphing on specific elements
3. Focused form inputs preserve their value during morphing

### LiveView with Subscriptions (Cross-View Communication)

```ocaml
(* activity_log_live.mlx — subscribes to events from other LiveViews *)
type model = { entries: string list } [@@deriving yojson]
type msg = Events.counter_event [@@deriving yojson]  (* reuse event type *)

(* Subscriptions returned from init — can be dynamic based on props *)
let init _req _props =
  ({ entries = [] }, [Well.topic_name Events.counter_event])

let update _req model = function
  | `Incremented (_, n) -> { entries = (Printf.sprintf "+%d" n) :: model.entries }
  | `Reset -> { entries = "reset" :: model.entries }
  | _ -> model
```

### Server Push to Hooks

```ocaml
(* Push event from server to a JS hook *)
Well.LiveView.send_event "topic" "event_name" (`Assoc [("key", `String "val")])
```

### JS Hooks

```javascript
// In your JS — hooks run client-side
Well.hooks.Chart = {
  mounted() {
    this.handleEvent("update", (data) => {
      renderChart(this.el, data);
    });
  },
  updated() { /* DOM was patched */ },
  destroyed() { /* element removed */ }
};
```

### pushLive — Send Messages from External JS

```javascript
// Send a message to the first LiveView on the page
well.pushLive(["SetPage", "index.html"]);

// Send to a specific LiveView topic
well.pushLive(["UpdateFilter", "active"], "/live/dashboard");
```

### LiveView Uploads

```ocaml
(* MLX: file input with hook *)
<input attrs=[("type", "file"); ("data-lv-hook", "FileUpload")] />

(* Server side: consume uploaded file *)
match Well.LiveView.consume_upload upload_id with
| Some (filename, content_type, data) ->
    let oc = open_out_bin ("data/" ^ filename) in output_string oc data; close_out oc
| None -> ()
```

### LiveView Search/Filter Example

```ocaml
(* lib/live/search_live.mlx — the LiveView module *)
(* Then register: Well.live "/search" (module Search_live) in app.ml *)
(* And create page: Well.get "/search" with <Well.LiveView name="search" /> *)
type item = { id: int; name: string } [@@deriving yojson]
type model = { query: string; results: item list; empty_msg: string } [@@deriving yojson]
type msg = Search of string [@@deriving yojson]

let persistence = Well.LiveView.Ephemeral

let make_model query =
  let results = search query in
  { query; results; empty_msg = if results = [] then "No results" else "" }

let init _req _props = (make_model "", [])
let update _req _model = function Search q -> make_model q
let handle_params _req model = model
let temporary_assigns model = model

let view model =
  let open Html in
  <div>
    <input attrs=[("type", "text"); ("placeholder", "Search..."); ("value", model.query); ("data-lv-change", "Search"); ("data-lv-debounce", "300")] />
    <p>(txt model.empty_msg)</p>
    <div>(each ~id:"results" model.results
      ~key:(fun r -> string_of_int r.id)
      (fun r -> <div><span>(txt r.name)</span></div>))</div>
  </div>
```

---

## Type-Safe SQL (well.ppx)

Write normal SQL. Compiler validates it at build time using registered table schemas. No database connection needed at compile time.

### Define Models

```ocaml
type note = {
  id : int;
  title : string;
  body : string;
  active : bool;
  score : float option;  (* nullable column *)
} [@@deriving table ~name:"notes"]
```

`[@@deriving table]` generates:
- `CREATE TABLE IF NOT EXISTS` SQL
- Schema registration for compile-time validation
- Auto-migration: `Well.Db.create_pool ()` creates tables + adds new columns

Type mapping: `int`→INTEGER, `float`→REAL, `string`→TEXT, `bool`→INTEGER, `'a option`→nullable

### Define Queries

```ocaml
let%query all_notes = "SELECT id, title, body FROM notes ORDER BY id DESC"
let%query insert_note = "INSERT INTO notes (title, body) VALUES (:title, :body)"
let%query find_note = "SELECT id, title, body FROM notes WHERE id = :id"
let%query delete_note = "DELETE FROM notes WHERE id = :id"
let%query search_notes = "SELECT id, title FROM notes WHERE title LIKE :q"
let%query update_note = "UPDATE notes SET title = :title, body = :body WHERE id = :id"

(* IN (:list) — list parameter, expands to ?,?,? at runtime *)
let%query notes_by_ids = "SELECT id, title FROM notes WHERE id IN (:ids)"
(* → Notes_by_ids.query : Sqlite3.db -> ids:int list -> row list *)

(* :param? — optional parameter, binds NULL when None *)
let%query update_score = "UPDATE notes SET score = :score? WHERE id = :id"
(* → Update_score.exec : Sqlite3.db -> score:float option -> id:int -> unit *)

(* Mixed: list + optional *)
let%query filtered = "SELECT id, title FROM notes WHERE id IN (:ids) AND title = :title?"
```

**Parameter kinds**:
- `:param` — required, type inferred from column (e.g. `:id` → `int` from `id INTEGER`)
- `:param?` — optional, binds NULL when None (e.g. `:score?` → `float option`)
- `IN (:param)` — list, expands to `?,?,?` at runtime (e.g. `IN (:ids)` → `int list`)
  - Type inferred from comparison column: `id IN (:ids)` → `int list` (from `id INTEGER`)
  - Empty list → `IN (SELECT NULL WHERE 0)` (matches nothing)

**Generated code**:

For SELECT → module with `type row` + `query`:
```ocaml
module All_notes : sig
  type row = { id: int; title: string; body: string }
  val sql : string
  val query : Sqlite3.db -> row list
end

module Find_note : sig
  type row = { id: int; title: string; body: string }
  val sql : string
  val query : Sqlite3.db -> id:string -> row list  (* :param → ~param labeled arg *)
end
```

For INSERT/UPDATE/DELETE → module with `exec`:
```ocaml
module Insert_note : sig
  val sql : string
  val exec : Sqlite3.db -> title:string -> body:string -> unit
end
```

### Database Access Pattern

```ocaml
(* notes.ml — standard pattern *)
type note = { id: int; title: string; body: string } [@@deriving table ~name:"notes"]
let%query all = "SELECT id, title, body FROM notes ORDER BY id DESC"
let%query insert = "INSERT INTO notes (title, body) VALUES (:title, :body)"

let pool = lazy (Well.Db.create_pool ())
let with_db f = Well.Db.with_conn (Lazy.force pool) f
```

Usage:
```ocaml
Notes.with_db (fun db ->
  let notes = Notes.All.query db in
  Notes.Insert.exec db ~title:"Hello" ~body:"World";
  ...)
```

### Well.Db Module

```ocaml
(* Connection pool — use for concurrent access *)
Well.Db.create_pool : ?size:int -> ?filename:string -> unit -> Well.Db.pool
(* Creates pool of N SQLite connections (default 8). Auto-migrates on first use. *)

Well.Db.with_conn : Well.Db.pool -> (Sqlite3.db -> 'a) -> 'a
(* Borrows a connection from pool, runs f, returns connection *)

Well.Db.close_pool : Well.Db.pool -> unit
(* Closes all connections in pool *)

(* Single connection — for simple scripts or backward compat *)
Well.Db.open_db : ?filename:string -> unit -> Sqlite3.db

Well.Db.with_test_db : (Sqlite3.db -> 'a) -> 'a
(* Opens :memory: SQLite, runs auto_migrate, perfect for tests *)

Well.Db.transaction : Sqlite3.db -> (Sqlite3.db -> 'a) -> 'a
Well.Db.transaction_result : Sqlite3.db -> (Sqlite3.db -> ('a, string) result) -> ('a, string) result

Well.Db.table_exists : Sqlite3.db -> string -> bool
Well.Db.diff : Sqlite3.db -> diff_entry list  (* pending migrations *)
Well.Db.auto_migrate : Sqlite3.db -> unit      (* run manually if needed *)
Well.Db.backup : string -> unit                (* backup db file *)
Well.Db.rollback : string -> unit              (* restore from .bak *)

Well.Db.data_dir : string ref  (* default "data", set before create_pool *)
```

### Dynamic SQL Helpers

When `let%query` PPX can't be used (dynamic WHERE, conditional ORDER BY, etc.),
use these helpers instead of raw Sqlite3:

```ocaml
(* Params: Null | Int n | Float f | Text s | Blob s *)

(* SELECT → list with mapper *)
Well.Db.query db "SELECT id, name FROM users WHERE age > ?"
  [Int 25]
  (fun r -> (r.int 0, r.text 1))
(* : (int * string) list *)

(* SELECT → option (0 or 1 row) *)
Well.Db.query_one db "SELECT id, name FROM users WHERE id = ?"
  [Int user_id]
  (fun r -> (r.int 0, r.text 1))
(* : (int * string) option *)

(* INSERT/UPDATE/DELETE → affected rows *)
Well.Db.exec db "DELETE FROM users WHERE active = ?" [Int 0]
(* : int *)

(* SELECT → Yojson.Safe.t list (works with [@@deriving yojson]) *)
Well.Db.fetch_yojson db "SELECT id, name FROM users" []
(* : Yojson.Safe.t list — each row is `Assoc [("id", `Int ...); ...] *)
```

Row accessors: `r.int`, `r.float`, `r.text`, `r.bool` — and nullable variants
`r.int_opt`, `r.float_opt`, `r.text_opt`, `r.bool_opt`.

Dynamic query example:
```ocaml
let search ?status ~order db =
  let where, params = match status with
    | Some s -> "WHERE status = ?", [Well.Db.Text s]
    | None -> "", []
  in
  let sql = Printf.sprintf "SELECT id, title FROM tasks %s ORDER BY %s" where order in
  Well.Db.query db sql params (fun r -> (r.int 0, r.text 1))
```

---

## Typed Pub/Sub (Well.MessageBus)

Single unified pub/sub system. SQLite-backed (persistent by default), in-memory (ephemeral).

### Typed Topics

```ocaml
(* types *)
type 'a topic = { t_channel: string; to_yojson: ...; of_yojson: ... }
type 'a event = { id: int; value: 'a; created_at: float }
type 'a keyed_event = { key: string; event: 'a event }
```

### Define Topics with PPX

```ocaml
(* events.ml *)
type counter_event = [`Incremented of string * int | `Decremented of string * int | `Reset]
[@@deriving yojson, topic]
(* Generates: val counter_event : counter_event topic *)
(* Channel name defaults to type name: "counter_event" *)

type echo_cmd = { text: string } [@@deriving yojson, topic ~name:"echo:cmd"]
(* Custom channel name: "echo:cmd" *)
```

**Requires** `[@@deriving yojson]` on same type (explicit, not auto-added).

### Core Pub/Sub API

```ocaml
Well.topic : string -> ('a -> Yojson.Safe.t) -> (Yojson.Safe.t -> ('a, string) result) -> 'a topic
Well.topic_name : 'a topic -> string

Well.publish : ?ephemeral:bool -> 'a topic -> 'a -> unit
(* Default: persistent (stored in SQLite). ephemeral: in-memory only *)

Well.subscribe : ?live_only:bool -> 'a topic -> ('a event -> unit) -> int
(* Returns subscription id. live_only: skipped during replay *)

Well.replay : ?since_id:int -> 'a topic -> ('a event -> unit) -> unit
(* Replays stored events from SQLite *)

Well.is_replaying : unit -> bool
Well.prune : int -> unit  (* delete old events *)
```

### Keyed Topics (channel:key)

For dynamic channels with UUIDs (e.g. command sourcing):

```ocaml
Well.publish_keyed : ?ephemeral:bool -> 'a topic -> key:string -> 'a -> unit
(* Publishes to "channel:key" *)

Well.subscribe_keyed : ?live_only:bool -> 'a topic -> ('a keyed_event -> unit) -> int
(* Subscribes to "channel:*", callback receives { key; event } *)
```

### Request/Reply Pattern

```ocaml
Well.request : cmd:'a topic -> reply:'b topic -> key:string -> ?timeout:float -> 'a -> 'b
(* Blocks fiber (not thread), default timeout 5s, raises Well.Request_timeout *)
```

Example:
```ocaml
(* events.ml *)
type order_cmd = { items: string list } [@@deriving yojson, topic ~name:"order:cmd"]
type order_result = { order_id: string } [@@deriving yojson, topic ~name:"order:result"]

(* Manager subscribes to all commands *)
Well.subscribe_keyed Events.order_cmd (fun kev ->
  let cmd = kev.event.value in
  let result = process cmd in
  Well.publish_keyed ~ephemeral:true Events.order_result ~key:kev.key result)

(* HTTP endpoint sends command, awaits response *)
Well.post "/orders" @@ fun req ->
let key = generate_uuid () in
let result = Well.request ~cmd:Events.order_cmd ~reply:Events.order_result
               ~key { items = ["x"] } in
Well.json (order_result_to_yojson result)
```

### Replay Safety

```ocaml
(* Always runs — cross-Manager state update *)
Well.subscribe_keyed Events.order_cmd (fun kev -> process kev.event.value)

(* Only runs live — external side effect (skipped during replay) *)
Well.subscribe ~live_only:true Events.order_event (fun evt ->
  External_api.sync evt.value)
(* All publish calls during replay are automatically ephemeral *)
```

### LiveView Subscriptions

```ocaml
(* In LiveView module — subscriptions returned from init *)
let init _req _props =
  (initial_model, [Well.topic_name Events.counter_event])
type msg = Events.counter_event [@@deriving yojson]
(* Events arrive as msg in update function *)
```

### Low-Level MessageBus (Untyped)

```ocaml
Well.MessageBus.publish : ?ephemeral:bool -> string -> Yojson.Safe.t -> int
Well.MessageBus.subscribe : ?live_only:bool -> string -> (event -> unit) -> int
(* Supports wildcard: "orders/*" matches "orders/new", "orders/cancel" *)
Well.MessageBus.unsubscribe : int -> unit
Well.MessageBus.once : string -> (event -> unit) -> int  (* auto-unsubscribe after first *)
Well.MessageBus.replay : ?since_id:int -> string -> (event -> unit) -> unit
```

---

## Channels — Authorized WS Gateway

Client-facing WebSocket pub/sub with authorization. Runs on `/ws`.

```ocaml
Well.Channel.channel : string -> (request -> string -> (join_result, string) result) -> unit

(* Example: authorize room access *)
Well.Channel.channel "room:*" (fun req topic ->
  match Well.current_user req with
  | Some _ -> Ok { subscribe = [topic] }
  | None -> Error "unauthorized")
```

Client-side (TypeScript):
```javascript
const ch = well.channel("room:general");
ch.on("message", (payload) => console.log(payload));
ch.push("send", { text: "hello" });
ch.leave();
```

WS protocol: `join/leave/push` (C→S), `ok/error/event` (S→C).

---

## Middleware

### Built-in Middleware

```ocaml
Well.use : middleware -> unit  (* register global middleware *)

(* Available middleware *)
Well.error_handler : middleware    (* catches exceptions, returns 500 *)
Well.logger : middleware           (* request logging *)
Well.csrf : middleware             (* CSRF token validation *)
Well.session_middleware : middleware (* session cookie management — auto-registered *)

Well.rate_limit : max_requests:int -> window_ms:int -> unit -> middleware
Well.cors : ?origins:string list -> ?methods:string list -> ?headers:string list
         -> ?max_age:int -> unit -> middleware
Well.require_auth : ?login_path:string -> unit -> middleware  (* redirects to login *)
Well.basic_auth : check:(string -> string -> bool) -> ?realm:string -> unit -> middleware
Well.allowed_hosts : hosts:string list -> unit -> middleware
Well.secure_headers : ?csp:string -> ?frame_options:string -> ?content_type_options:string
                   -> ?referrer_policy:string -> ?hsts:string -> unit -> middleware
```

### Custom Middleware

```ocaml
Well.use (fun next req ->
  (* before handler *)
  let resp = next req in
  (* after handler *)
  resp)
```

### Per-Route and Scoped Middleware

```ocaml
(* Per-route *)
Well.get ~middleware:[Well.require_auth ()] "/admin" @@ fun req -> ...

(* Scoped *)
Well.scope ~middleware:[Well.require_auth ()] "/admin" (fun () ->
  Well.get "/dashboard" @@ fun req -> ...;
  Well.get "/settings" @@ fun req -> ...
)
```

---

## Sessions

SQLite-backed, thread-safe session store.

```ocaml
Well.Session.get : session_id:string -> key:string -> string option
Well.Session.set : session_id:string -> key:string -> value:string -> unit
Well.Session.delete : session_id:string -> key:string -> unit
Well.Session.clear : session_id:string -> unit
Well.session_regenerate : request -> (request * (response -> response))
(* Returns new request + response transformer that sets new cookie *)
```

### Flash Messages

```ocaml
Well.put_flash : request -> string -> string -> unit
Well.get_flash : request -> string -> string option

(* Usage *)
Well.put_flash req "success" "Item created!";
let msg = Well.get_flash req "success"  (* string option *)
```

---

## Request Context (Well.Context)

Type-safe, per-request context via functor. Each context type gets a unique slot.

```ocaml
module type CONTEXT = sig
  type t
  val empty : t
end

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

---

## Auth (Well.Auth) — Password-Based Authentication

PBKDF2-SHA256, 100k iterations. Stored in `data/well.sqlite`.

```ocaml
type user = {
  id: int; email: string; first_name: string; last_name: string;
  language: string; phone_number: string; is_archived: bool; created_at: string
}

(* User management *)
Well.Auth.register : email:string -> password:string -> ?first_name:string -> ?last_name:string -> unit -> (user, string) result
Well.Auth.login : email:string -> password:string -> ?ip:string -> unit -> (user, string) result
Well.Auth.get_user : int -> user option
Well.Auth.edit_profile : id:int -> ?first_name:string -> ?last_name:string -> ?language:string -> ?phone_number:string -> unit -> (unit, string) result
Well.Auth.archive_user : id:int -> is_archived:bool -> unit -> unit
Well.Auth.find_users : ?current:int -> ?ids:int list -> ?email:string -> ?include_archived:bool -> unit -> user list

(* Session integration *)
Well.Auth.login_and_set_session : request -> email:string -> password:string -> (user, string) result
Well.Auth.logout : request -> unit

(* OTP *)
Well.Auth.initiate_otp : email:string -> unit -> (string, string) result  (* returns code *)
Well.Auth.verify_otp : email:string -> code:string -> ?ip:string -> unit -> (user, string) result

(* User settings — JSON blob per user *)
Well.Auth.get_settings : user_id:int -> unit -> Yojson.Safe.t option
Well.Auth.set_settings : user_id:int -> settings:Yojson.Safe.t -> unit -> unit

(* Brute-force protection *)
Well.Auth.reset_attempts : email:string -> unit -> unit
Well.Auth.configure : ?login_failures_limit:int -> ?login_failure_window_seconds:int -> ?otp_lifetime_seconds:int -> ... -> unit -> unit

(* Grants — flat permission system *)
Well.Auth.grant : user_id:int -> string -> unit
Well.Auth.revoke : user_id:int -> string -> unit
Well.Auth.has_grant : user_id:int -> string -> bool
Well.Auth.user_grants : user_id:int -> string list

(* Handler wrapper — checks grant, raises Auth_denied *)
Well.Auth.require_grant : string -> (request -> 'a) -> (request -> 'a)
```

Example:
```ocaml
(* Login page *)
Well.post "/login" @@ fun req ->
let email = Option.value ~default:"" (Well.form req "email") in
let password = Option.value ~default:"" (Well.form req "password") in
match Well.Auth.login_and_set_session req ~email ~password with
| Ok _user -> Well.redirect "/"
| Error msg -> render_login_page ~error:msg

(* Logout *)
Well.post "/logout" @@ fun req ->
  Well.Auth.logout req;
  Well.redirect "/login"

(* Protected route with grant check *)
Well.get "/admin" @@ Well.Auth.require_grant "admin" (fun req -> ...)

(* Check current user in handler *)
let user_id = Well.current_user req  (* reads "user_id" from session *)
```

---

## OAuth (Well.OAuth) — Social Login

OAuth 2.0 with PKCE for Google, GitHub, Microsoft, Facebook. Stored in `data/well.sqlite` (_well_oauth_identities table).

```ocaml
type provider_config

(* Pre-configured providers *)
Well.OAuth.google    : client_id:string -> client_secret:string -> provider_config
Well.OAuth.github    : client_id:string -> client_secret:string -> provider_config
Well.OAuth.microsoft : client_id:string -> client_secret:string -> provider_config
Well.OAuth.facebook  : client_id:string -> client_secret:string -> provider_config

(* Setup — registers /auth/:provider and /auth/:provider/callback routes *)
Well.OAuth.setup : base_url:string -> provider_config list -> unit

(* Query configured providers (for rendering login buttons) *)
Well.OAuth.configured_providers : unit -> string list

(* Get linked identities for a user *)
Well.OAuth.user_identities : user_id:int -> (string * string) list
```

Setup in `lib/app.ml` (reads from env vars):
```ocaml
let oauth_providers = List.filter_map Fun.id [
  (match Sys.getenv_opt "GOOGLE_CLIENT_ID", Sys.getenv_opt "GOOGLE_CLIENT_SECRET" with
   | Some id, Some secret -> Some (Well.OAuth.google ~client_id:id ~client_secret:secret)
   | _ -> None);
  (* same for GITHUB_, MICROSOFT_, FACEBOOK_ *)
] in
if oauth_providers <> [] then
  Well.OAuth.setup ~base_url:"https://myapp.com" oauth_providers;
```

Env vars: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`,
`MICROSOFT_CLIENT_ID`, `MICROSOFT_CLIENT_SECRET`, `FACEBOOK_CLIENT_ID`, `FACEBOOK_CLIENT_SECRET`, `BASE_URL`.

Security: PKCE S256 on all providers, state bound to session (single-use, 10-min expiry, constant-time compare), session regeneration after login, verified-email-only account linking.

---

## Form Validation (Well.Form)

Applicative form validation with chainable validators.

```ocaml
type 'a t = { field: string; value: 'a option; errors: (string * string) list }

Well.Form.get : (string * string) list -> string -> string t
Well.Form.trim : string t -> string t
Well.Form.required : 'a t -> 'a t
Well.Form.min_length : int -> string t -> string t
Well.Form.max_length : int -> string t -> string t
Well.Form.format_ : string -> string t -> string t  (* regex pattern *)
Well.Form.number : string t -> int t
Well.Form.decimal : string t -> float t
Well.Form.custom : ('a -> string option) -> 'a t -> 'a t
Well.Form.validate : 'a t -> ('a, (string * string) list) result

(* Applicative operators *)
val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t
```

Example:
```ocaml
let open Well.Form in
let params = Well.form_params req in
let result =
  let+ title = get params "title" |> trim |> required |> min_length 3
  and+ email = get params "email" |> trim |> required |> format_ ".*@.*\\..*"
  and+ age = get params "age" |> required |> number in
  (title, email, age)
  |> validate
in
match result with
| Ok (title, email, age) -> (* process *)
| Error errors ->
  (* errors: (string * string) list — [(field_name, error_message); ...] *)
  (* Use Html.field_error errors "title" to render error messages *)
```

---

## Mailer (Well.Mailer)

Multi-adapter email system.

```ocaml
type adapter =
  | Log                                              (* prints to stdout *)
  | SMTP of { host: string; port: int; username: string; password: string }
  | Resend of { api_key: string }
  | Zeptomail of { api_url: string; token: string }
  | SES of { region: string; access_key_id: string; secret_access_key: string }

type mail = { to_: (string * string) list; subject: string; html: string; text: string }

Well.Mailer.setup : { from_email: string; from_name: string; adapter: adapter } -> unit
Well.Mailer.send : mail -> (unit, string) result
```

Example:
```ocaml
Well.Mailer.setup { from_email = "noreply@example.com"; from_name = "MyApp"; adapter = Log };

match Well.Mailer.send {
  to_ = [("User", "user@example.com")];
  subject = "Welcome!";
  html = "<h1>Hello</h1>";
  text = "Hello";
} with
| Ok () -> ()
| Error msg -> Well.log ~level:"error" "Mail error: %s" msg
```

---

## HTTP Client (Well.fetch)

```ocaml
Well.fetch : ?method_:string -> ?headers:(string*string) list -> ?body:string
          -> string -> fetch_response

(* fetch_response = { status: int; headers: (string * string) list; body: string } *)

(* GET *)
let resp = Well.fetch "https://api.example.com/data" in
Printf.printf "Status: %d\n" resp.status

(* POST with JSON body *)
let resp = Well.fetch ~method_:"POST"
  ~headers:[("Content-Type", "application/json")]
  ~body:{|{"key":"value"}|}
  "https://api.example.com/data" in
```

---

## S3 Storage (Well.S3)

AWS S3 client with Signature V4 authentication.

```ocaml
Well.S3.connect : ?endpoint_url:string -> ?region:string -> ?access_key_id:string
               -> ?secret_access_key:string -> ?bucket:string -> unit -> S3.t
(* Reads from env: AWS_ENDPOINT_URL, AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, S3_BUCKET *)

Well.S3.put : S3.t -> key:string -> data:string -> (unit, string) result
Well.S3.get : S3.t -> key:string -> (string, string) result
Well.S3.delete : S3.t -> key:string -> (unit, string) result
Well.S3.list : S3.t -> prefix:string -> (string list, string) result
Well.S3.head : S3.t -> key:string -> (int, string) result  (* returns size *)
Well.S3.presigned_url : S3.t -> method_:string -> key:string -> ?expires_in_secs:int -> unit -> string
Well.S3.create_bucket : S3.t -> (unit, string) result
```

Example:
```ocaml
let s3 = Well.S3.connect ~bucket:"my-bucket" () in
match Well.S3.put s3 ~key:"photos/cat.jpg" ~data:image_data with
| Ok () -> ()
| Error msg -> failwith msg;

let url = Well.S3.presigned_url s3 ~method_:"GET" ~key:"photos/cat.jpg" ~expires_in_secs:3600 ()
```

---

## Service Contracts (TOML)

Define service interfaces in TOML, generate OCaml + TypeScript + Go + Dart.

```toml
# contract/TaskAccess.toml
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
module Impl : Task_access.IMPL = struct
  let list _ctx (req : Task_access.ListReq.t) =
    Task_access.TaskList.make ~tasks ()

  let create _ctx (req : Task_access.CreateReq.t) =
    Task_access.Task.make ~id ~title:req.title ~completed:false ()
end

let spec = Task_access.make_spec (module Impl)
```

Register in `lib/app.ml`:
```ocaml
Well.Service.register Services.Task_access_impl.spec;
Well.Service.expose "TaskAccess";  (* creates /rpc/TaskAccess/* HTTP routes *)
```

### Service Module

```ocaml
Well.Service.register : spec -> unit  (* concurrent, stateless *)
Well.Actor.register : ?restart:restart -> spec -> unit  (* sequential, stateful *)
(* restart: Permanent (always restart) | Transient (restart on error) | Temporary (no restart) *)

Well.Service.expose : string -> unit  (* expose as HTTP RPC *)
Well.Service.list_services : unit -> (string * string list) list
Well.Service.full_health : unit -> (string * string) list
Well.Service.cast : (unit -> unit) -> unit  (* fire-and-forget async *)
```

### Periodic Background Tasks

```ocaml
Well.every ~name:"kicker" ~sleep:5.0 (fun () ->
  (* runs in loop: execute → sleep 5s → execute → ... *)
  (* crashes are logged, loop continues *)
  (* cancelled automatically on shutdown *)
)
```

Register before `Well.run` (like routes). Each task runs in its own EIO fiber.

---

## WebSocket (Raw)

For custom WebSocket handlers (not LiveView or Channel).

```ocaml
Well.ws "/ws/custom" (fun req ws ->
  (* ws : Websocket.t *)
  match Websocket.receive ws with
  | Some msg ->
    Websocket.send ws ("echo: " ^ msg);
    Websocket.send_json ws (`Assoc [("type", `String "ack")])
  | None -> ()  (* connection closed *)
)
```

```ocaml
Websocket.receive : t -> string option
Websocket.receive_json : t -> Yojson.Safe.t option
Websocket.send : t -> string -> unit
Websocket.send_json : t -> Yojson.Safe.t -> unit
Websocket.close : t -> unit
Websocket.is_open : t -> bool
```

---

## File I/O

Use standard OCaml / EIO for file operations:

```ocaml
Sys.file_exists : string -> bool
Sys.readdir : string -> string array
Sys.mkdir : string -> int -> unit
(* For writing: open_out_bin / output_string / close_out *)
(* For reading: open_in_bin / really_input_string / close_in *)
Well.ext_to_mime : string -> string  (* "jpg" → "image/jpeg" *)
```

---

## Logging

```ocaml
Well.log : ?level:string -> ?ctx:(string*string) list -> ('a, unit, string) format -> 'a

Well.log "Server started on port %d" port;
Well.log ~level:"error" "Failed: %s" msg;
Well.log ~level:"debug" ~ctx:[("user_id", uid)] "Action performed";
```

Levels: `debug`, `info` (default), `warn`, `error`. Logs to stdout + `data/well.log` with rotation (10MB, 5 files).

---

## Configuration

```ocaml
Well.max_body_size : int -> unit       (* max request body *)
Well.keep_alive_timeout : float -> unit
Well.request_timeout : float -> unit
Well.ws_rate_limit : float -> unit
Well.ws_max_frame_size : int -> unit   (* default 10MB *)
Well.max_upload_size : int -> unit
Well.dev_mode : bool -> unit           (* enables dev error pages *)
Well.on_error : (exn -> request -> response) -> unit  (* custom error handler *)
```

---

## Server

```ocaml
Well.run : ?port:int -> ?workers:int -> ?cert:string -> ?key:string
        -> ?domain:string -> ?acme_staging:bool -> ?disable_cap:bool -> unit -> unit
(* Default: port 4000, listens 0.0.0.0. Blocks forever. *)
(* ~cert/~key: PEM files for manual TLS *)
(* ~domain: enables Let's Encrypt auto-TLS (mutually exclusive with cert/key) *)
(* ~acme_staging: use LE staging for testing *)
(* ~disable_cap: disable Cap admin panel *)

Well.with_test_server : ?port:int -> ?disable_cap:bool -> (int -> 'a) -> 'a
(* Starts server on random port, passes port to function *)
```

### Auto-TLS (Let's Encrypt)

```ocaml
Well.run ~domain:"myapp.example.com" ~port:443 ()
(* Automatically provisions certificate via HTTP-01 challenge *)
(* Stores certs in data/certs/ *)
```

### Well.Env — EIO Environment Access

```ocaml
Well.env : unit -> Eio_unix.Stdenv.base  (* full EIO env, set by Well.run *)
Well.net : unit -> _ Eio.Net.t           (* network *)
Well.clock : unit -> float Eio.Time.clock (* monotonic clock *)
Well.cwd : unit -> _ Eio.Path.t          (* working directory *)
Well.fs : unit -> _ Eio.Path.t           (* filesystem root *)

Well.Env.sleep : float -> unit                    (* sleep seconds *)
Well.Env.with_timeout : float -> (unit -> 'a) -> 'a  (* timeout in seconds *)
Well.Env.domain_mgr : unit -> _ Eio.Domain_manager.t
```

Available inside `Well.run` (and route handlers, services, actors). Avoids passing `env` through every function.

---

## Testing

### Test Framework (Well_test)

```ocaml
open Well_test

describe : ?timeout:float -> string -> (unit -> unit) -> unit
it : ?timeout:float -> string -> (unit -> unit) -> unit   (* alias: test *)
skip : string -> (unit -> unit) -> unit
default_timeout : float -> unit   (* global default, initially 5s *)

before_each : (unit -> unit) -> unit
after_each : (unit -> unit) -> unit
before_all : (unit -> unit) -> unit
after_all : (unit -> unit) -> unit

expect : 'a -> expectation
not_ : expectation -> expectation

(* Matchers *)
to_equal_string : string -> expectation -> unit
to_equal_int : int -> expectation -> unit
to_equal_float : ?epsilon:float -> float -> expectation -> unit
to_equal_bool : bool -> expectation -> unit
to_be_true / to_be_false : expectation -> unit
to_be_some / to_be_none : expectation -> unit
to_be_greater_than / to_be_less_than : int -> expectation -> unit
to_contain : string -> expectation -> unit       (* substring *)
to_match : string -> expectation -> unit         (* regex *)
to_have_length : int -> expectation -> unit      (* list *)
to_raise : expectation -> unit
to_raise_with : string -> expectation -> unit
to_match_snapshot : expectation -> unit          (* snapshot testing *)

run : ?filter:string option -> ?ci_mode:bool -> ?source_file:string -> unit -> run_result
exit_with_result : run_result -> unit
```

### Database Tests

```ocaml
it "creates a note" (fun () ->
  Well.Db.with_test_db (fun db ->
    Notes.Insert.exec db ~title:"Test" ~body:"Body";
    let notes = Notes.All.query db in
    expect (List.length notes) |> to_equal_int 1
  )
);
```

### Integration Tests

```ocaml
it "serves homepage" (fun () ->
  Well.with_test_server (fun port ->
    let url = Printf.sprintf "http://localhost:%d/" port in
    let resp = Well.fetch url in
    expect resp.body |> to_contain "Welcome"
  )
);
```

### Snapshot Testing

```ocaml
it "renders correctly" (fun () ->
  let html = element_to_string (render_page ()) in
  expect html |> to_match_snapshot
);
(* Snapshots stored in __snapshots__/*.snap alongside test file *)
(* Update: WELL_UPDATE_SNAPSHOTS=1 or well test -u *)
(* IMPORTANT: run ~source_file:__FILE__ () — needed for snapshot location *)
```

### Timeouts

Default: 5 seconds per test. Cascade: `it ~timeout` > `describe ~timeout` > global default.

```ocaml
(* Override global default *)
let () = default_timeout 30.0

(* Suite-level — all tests in this describe get 10s *)
describe ~timeout:10.0 "database" (fun () ->
  it "migrates" (fun () -> ...);              (* 10s from describe *)
  it ~timeout:60.0 "imports CSV" (fun () -> ...);  (* 60s override *)
);
```

On timeout: test fails with `"Timeout: test exceeded 5.0s limit"`.

---

## RPC Context

For service-to-service calls with user context:

```ocaml
type rpc_ctx = {
  session_id: string; request_id: string;
  user_id: string option; user_name: string option; locale: string
}

Well.rpc_ctx : request -> rpc_ctx
Well.rpc_ctx_to_wire : rpc_ctx -> Yojson.Safe.t  (* JSON array format *)
Well.rpc_ctx_of_wire : Yojson.Safe.t -> rpc_ctx
```

---

## Telemetry (Well.Telemetry)

```ocaml
Well.Telemetry.snapshot_counters : unit -> counter_snapshot
(* { total_requests; errors_5xx; avg_latency_us; ws_messages; bus_events } *)

Well.Telemetry.requests_per_sec : unit -> float
Well.Telemetry.cpu_percent : unit -> float
Well.Telemetry.rss_kb : unit -> int
Well.Telemetry.system_snapshot : unit -> system_snapshot
```

---

## URL Encoding

```ocaml
Well.url_encode : string -> string  (* "hello world" → "hello%20world" *)
Well.url_decode : string -> string
```

---

## Deployment

Well apps are single-binary deployments. The scaffold generates a `.service` file for systemd.

### `well build` — Production build with bundled libraries

```bash
well build    # requires: patchelf (pacman -S patchelf / apt install patchelf)
```

1. Runs `dune build`
2. Auto-discovers all shared libraries via `ldd`
3. Copies binary + all `.so` to `_release/`
4. Runs `patchelf` — sets interpreter to `bin/lib/ld-linux-*.so` and rpath to `$ORIGIN/lib`
5. Copies `static/` if present, creates `data/` directory

Output:
```
_release/
  bin/myapp          # relocatable binary (patchelf'd)
  bin/lib/           # all bundled .so (libc, libsqlite3, libgmp, libz, ...)
  static/            # CSS, JS, assets
  data/              # runtime databases (created empty)
```

Run locally: `cd _release && ./bin/myapp`

### `well release` — Create deployable archive

```bash
well release    # runs well build, then creates .tar.gz
```

Creates `myapp.tar.gz` — a single archive ready to deploy:
```bash
scp myapp.tar.gz server:/srv/myapp/
ssh server "cd /srv/myapp && tar xzf myapp.tar.gz && ./bin/myapp"
```

### Server setup

**Directory structure on server:**
```
/srv/myapp/
  bin/myapp              # relocatable binary (patchelf'd)
  bin/lib/               # bundled .so
  data/                  # SQLite databases (app.sqlite, well.sqlite)
  data/certs/            # auto-TLS certificates (managed by Well)
  static/                # CSS, JS, assets
```

The generated `.service` file uses `WorkingDirectory=/srv/myapp` and `ReadWritePaths=/srv/myapp/data`.

**HTTPS**: Use `Well.run ~domain:"myapp.example.com" ~port:443 ()` — auto-provisions Let's Encrypt
certificate via HTTP-01 challenge, stores certs in `data/certs/`, auto-renews. No nginx/reverse proxy needed.
The server also listens on port 80 for ACME challenges and HTTP→HTTPS redirects.

---

## CLI Commands

```bash
well init <name>              # Scaffold new project
well build                    # Production build (dune + patchelf + bundle .so → _release/)
well release                  # Build + create .tar.gz archive for deployment
well test [-w] [-f pat] [--jobs n] [-u]  # Run tests (watch, filter, concurrency, snapshots)
well docs [--open] [-o dir]   # Generate HTML documentation from (** *) comments
well contract build [dir]     # Generate OCaml/TS/Go/Dart + OCaml browser Proxy
                              # Browser: build/ocaml_browser (use Proxy, not Http)
well db diff                  # Show pending schema migrations
well db rollback [path]       # Restore from .bak backup
well repl [-s socket] [-e expr]  # Interactive service query shell
```

### REPL Syntax

```
Service.method param:value      # Call RPC
let x = Service.method ...      # Bind result
x.field                         # Field access
expr | map .field               # Pipeline: map, filter, count, first, sort
"hello {x.name}"                # String interpolation
```

---

## Client-Side TypeScript (well.ts)

Compiled by bun to `well.js`. Auto-initializes as `window.well`.

**Build**: `static/dune` has rules that run `bun build` with `(mode promote)` — output JS lands in source tree.
Just run `dune build` (or `make build`) to rebuild TS. Add new `.ts` files by adding a `(rule ...)` to `static/dune`:
```lisp
(rule
 (targets my-script.js)
 (deps (source_tree ts))       ; if importing from ts/ subdirectory
 (mode promote)
 (action (run bun build ts/my-script.ts --outdir . --minify)))
```

### LiveView (automatic)

Discovers `<live-view>` elements, manages WebSocket connection on `/live`.
Event delegation: `data-lv-click`, `data-lv-submit`, `data-lv-change`, etc.

### Channel API

```javascript
const ch = well.channel("room:general");
ch.on("message", (payload) => { /* handle */ });
ch.push("send", { text: "hello" });
ch.leave();
```

### JS Hooks

```javascript
Well.hooks.MyHook = {
  mounted() {
    // this.el — DOM element
    // this.pushEvent("event", payload) — send to server
    // this.handleEvent("event", (data) => { ... }) — receive from server
  },
  updated() { /* after DOM patch */ },
  destroyed() { /* cleanup */ }
};
```

### File Upload Hook (built-in)

```html
<input type="file" data-lv-hook="FileUpload" />
```
Automatically uploads via base64 chunks over WebSocket.

---

## Forms & File Upload

```ocaml
(* URL-encoded form data *)
let title = Option.value ~default:"" (Well.form req "title") in
let all_params = Well.form_params req in

(* CSRF token in forms — REQUIRED for POST *)
<form attrs=[("action", "/submit"); ("method", "POST")]>
  (csrf_input (Well.csrf_token req))
  <input attrs=[("type", "text"); ("name", "title")] />
  <button attrs=[("type", "submit")]>(txt "Submit")</button>
</form>

(* Textarea — children must be node, not bare string *)
<textarea attrs=[("name", "body")]>(txt "")</textarea>
<textarea attrs=[("name", "body")]>(txt some_variable)</textarea>

(* File upload — multipart *)
Well.post "/upload" @@ fun req ->
match Well.file req "file" with
| None -> Well.redirect "/upload"
| Some f ->
    let oc = open_out_bin ("data/uploads/" ^ f.filename) in
    output_string oc f.data; close_out oc;
    Well.redirect "/upload"

(* Multiple files *)
let all = Well.files req "files" in  (* uploaded_file list *)
let everything = Well.all_files req in  (* (string * uploaded_file) list *)
```

---

## Route Introspection

```ocaml
Well.list_routes : unit -> (string * string * string) list
(* Returns [(method, path, kind)] where kind = "handler" | "liveview" | "websocket" | "cap" *)
```

---

## Cap Admin Panel

Built-in admin dashboard at `/_cap/`. Default login: `cap` / `admin`.

Disable with `Well.run ~disable_cap:true ()`.

Features: system stats, request telemetry, log viewer with filtering, route list, WebSocket connections, user management.

---

## Companion Skills

When working on this project, use these companion skills for specialized decisions:

- **idesign-architecture**: Use for ALL architectural decisions — decomposing the system into services, deciding where code should live, reviewing layer violations, designing service contracts. Routes/LiveViews (client layer) must NEVER call access layer directly — always go through a manager.
- **frontend-design**: Use when building or improving UI — pages, components, layouts, styling. Produces distinctive, production-grade interfaces instead of generic HTML.

Services must hide internal functions using `open struct ... end`. Only the contract-defined interface should be public.

---

## Common Patterns Checklist

When adding a new feature, you typically need:

1. **Static page**: Create `lib/pages/feature_page.mlx` with `Well.get "/path" @@ fun req -> ...`
2. **With data**: Create model file with `[@@deriving table]` + `let%query` + `let pool = lazy (Well.Db.create_pool ())`
3. **LiveView**: Create `lib/live/feature_live.mlx` with `model`/`msg` types + `[@@deriving yojson]` + all VIEW fields. Register with `Well.live "/feature" (module Live.Feature_live)` in `lib/app.ml`. Then create a GET page that embeds `<Well.LiveView name="feature" />`. Both steps are required — `Well.live` only registers the WS handler, not the page.
4. **Pub/Sub**: Define event types in `events.ml` with `[@@deriving yojson, topic]`, publish/subscribe in handlers or LiveViews
5. **Service**: Create TOML contract, run `well contract build`, implement `IMPL` module, register + expose in `lib/app.ml`
6. **Auth-protected**: Add `~middleware:[Well.require_auth ()]` or wrap handler with `Well.Auth.require_grant`
7. **Tests**: Add to `test/` with `Well.Db.with_test_db` for DB tests or `Well.with_test_server` for integration tests
