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

### MLX Common Pitfalls

- **No `empty` node** — use `(txt "")` when you need to render nothing (e.g. in else branches)
- **`textarea` children must be `node`** — use `<textarea>(txt value)</textarea>`, NOT `<textarea>value</textarea>` (bare variable is string, not node) and NOT `<textarea>"default"</textarea>` (literal string is also not node)
- **All attribute values are strings** — use `value=(string_of_int n)` for numbers
- **`_` suffix for OCaml keywords** — `class_`, `type_`, `method_`, `name_`, `for_`

## HTML Library — Complete Reference

All tag functions share the same optional labeled parameters.

### String attributes (default `""`):
- **Global**: `?id`, `?class_`, `?lang`, `?title`, `?style`, `?role`, `?tabindex`, `?dir`
- **LiveView**: `?data_lv_click`, `?data_lv_submit`, `?data_lv_change`, `?data_lv_debounce`, `?data_lv_throttle`, `?data_lv_hook`, `?data_lv_navigate`, `?data_lv_patch`
- **Link**: `?href`, `?target`, `?rel`, `?download`
- **Media**: `?src`, `?alt`, `?width`, `?height`, `?loading`, `?srcset`, `?sizes`, `?poster`, `?preload`, `?crossorigin`, `?integrity`
- **Form**: `?action`, `?method_`, `?type_`, `?placeholder`, `?value`, `?name_`, `?enctype`, `?accept`, `?for_`, `?autocomplete`, `?min`, `?max`, `?step`, `?pattern`, `?maxlength`, `?minlength`, `?rows`, `?cols`, `?wrap`, `?size`, `?formaction`, `?formmethod`
- **Meta**: `?charset`, `?content`, `?http_equiv`, `?media`
- **Table**: `?colspan`, `?rowspan`, `?scope`
- **Other**: `?datetime`, `?start`

### Boolean attributes (default `false`):
`?hidden`, `?disabled`, `?readonly`, `?required`, `?checked`, `?selected`, `?multiple`, `?autofocus`, `?novalidate`, `?open_`, `?defer`, `?async_`, `?autoplay`, `?controls`, `?loop`, `?muted`, `?draggable`, `?reversed`

### Escape hatch — `~attrs` and `~bool_attrs`
For `aria-*`, `data-*`, and any attribute not listed above:
- `?attrs:(string * string) list` — extra string attributes
- `?bool_attrs:string list` — extra boolean attributes

```ocaml
<button
  ~attrs:[("aria-label", "Close"); ("data-tooltip", "Dismiss"); ("data-lv-ignore", "")]
  ~bool_attrs:["aria-expanded"]
  data_lv_click="close">"X"</button>
```

### Available elements (full HTML5 coverage):
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
- `data_lv_click="MsgName"` — click sends msg (no payload)
- `data_lv_click={|["Msg","val"]|}` — click with payload (JSON array in attribute)
- `data_lv_submit="MsgName"` — form submit (fields as object)
- `data_lv_change="MsgName"` — input change (sends `["MsgName", input_value]`)
- `data_lv_debounce="300"` — debounce input (ms)
- `data_lv_navigate="/path"` — client-side navigation
- `data_lv_hook="HookName"` — attach JS hook

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
<button data_lv_click="Increment">(txt "+")</button>
(* sends: ["Increment"] *)

(* With payload — encode JSON array in attribute *)
<button data_lv_click=(Printf.sprintf {|["SetPage", "%s"]|} (Html.escape_html page))>
  (txt page)
</button>
(* sends: ["SetPage", "cennik.html"] → decoded as: SetPage "cennik.html" *)

(* Static payload *)
<button data_lv_click={|["SelectTab", "settings"]|}>(txt "Settings")</button>
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
<form data_lv_submit="SubmitComment">
  <input type_="text" name_="author" placeholder="Name" />
  <textarea name_="body">(txt "")</textarea>
  <button type_="submit">(txt "Send")</button>
</form>
```

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

## Cross-LiveView Communication

Use typed topics via `Well.publish` / `Well.subscribe` (through `events.ml`):

```ocaml
(* In sender's update — publish typed event *)
let update _req model = function
  | Increment ->
    let m = { count = model.count + 1 } in
    Well.publish Events.counter_event (`Incremented ("increment", m.count));
    m

(* Receiver subscribes via subscriptions field *)
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

## Deployment

Well apps are single-binary deployments. The scaffold generates a `.service` file for systemd.

### `well build` — Production build with bundled libraries

```bash
well build    # requires: patchelf
```

Runs `dune build`, discovers all `.so` via `ldd`, copies binary + libs to `_release/`,
runs `patchelf` (interpreter + rpath). Works on any Linux x86_64.

### `well release` — Create deployable archive

```bash
well release    # runs well build, then creates .tar.gz
```

Deploy: `scp myapp.tar.gz server:/srv/myapp/ && ssh server "cd /srv/myapp && tar xzf myapp.tar.gz"`

**HTTPS**: `Well.run ~domain:"myapp.example.com" ~port:443 ()` — auto Let's Encrypt, no nginx needed.

## CLI Commands

```bash
well init <name>        # Scaffold new project
well build              # Production build (patchelf + bundle .so → _release/)
well release            # Build + .tar.gz archive
well test [-w] [-f pat] # Run tests (watch, filter)
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
