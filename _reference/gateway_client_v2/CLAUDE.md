# Gateway Client v2 - Experiment

Server-side reactive UI framework in Reason/OCaml, inspired by Phoenix LiveView.
Zero JavaScript for business logic - all state lives on the server.

## Architecture

```
Browser
  ├─ SSR HTML (initial render)
  └─ WebSocket (/v2/live) ──► LiveView engine (Elm architecture)
                                  ├─ model/msg/update/render
                                  ├─ diff engine (dynamics + keyed lists)
                                  ├─ persistence (Ephemeral / Session / User)
                                  └─ cross-device broadcast
```

## Files

| File | Purpose |
|------|---------|
| `main.re` | HTTP server, routes (`/v2/*`), SSR, CSS styles |
| `liveview.re` | Core framework - Elm architecture, diffing, WS protocol |
| `liveview_store.ml` | SQLite persistence for User mode (`data/liveview.sqlite`) |
| `websocket.ml` | Custom RFC 6455 WebSocket implementation on EIO |
| `blossom.ml` | Lightweight HTTP framework on EIO + Cohttp |
| `html.re` | JSX-compatible HTML library with XSS protection |
| `counter.re` | Demo: stateful counter with step |
| `todo.re` | Demo: todo list with keyed list diffing + inline edit |

## Key concepts

### LiveView component (VIEW module signature)
```reason
module type VIEW = {
  type model;                                    // state
  type msg;                                      // actions
  let persistence: persistence;                  // Ephemeral | Session | User
  let init: (ctx, Yojson.Safe.t) => model;       // initialize from props
  let update: (ctx, model, msg) => model;        // pure state transition
  let render: model => Html.element;             // model -> HTML
  // + yojson derivations for model and msg
};
```

### Persistence modes
- **Ephemeral** - fresh state per connection, no saving
- **Session** - in-memory per session_id, survives reconnect (5 min timeout)
- **User** - SQLite per user_id, survives server restart, syncs across devices

### Diffing protocol (WebSocket JSON)
- **join** → client subscribes to component (endpoint, topic, props)
- **full** → server sends initial complete HTML
- **restored** → server recovered state from session/DB
- **msg** → client sends user action (click, submit)
- **patch** → server sends only changes:
  - `changes`: `{ "lv-id": "new text value" }` (dynamic text spans)
  - `list_ops`: `{ "list-id": { order: [...keys], inserts: { key: html } } }` (keyed lists)

### HTML library (html.re)
- JSX syntax: `<div className="foo"> {txt("Hello")} </div>`
- `txt(s)` - safe text (HTML-escaped)
- `raw(html)` - raw HTML (no escaping)
- `dynamic(id, value)` - reactive text span (`<span data-lv="id">value</span>`)
- `each(~id, ~tag, items, ~key, render_fn)` - keyed list with diffing
- `lvClick(action)` / `lvSubmit(action)` - LiveView event attributes
- `liveView(~endpoint, ~props, ~children)` - embed LiveView component with SSR

### Blossom HTTP framework (blossom.ml)
- Routes with `:param` placeholders
- Response body as polymorphic variant: `` `Html ``, `` `Text ``, `` `Redirect ``, Yojson
- Composable: `Blossom.status(400, body)`, `Blossom.headers([...], body)`
- Unix socket listener
- Form + JSON body parsing

### Cross-device sync
When User persistence is active:
1. User action arrives via WS on device A
2. State updated, patch computed, sent to device A
3. Same patch broadcast to all other open connections of same user_id
4. All devices stay in sync

## Build

```bash
dune build   # builds as library gateway_client_v2_service
```

Dependencies (dune): `base`, `eio`, `eio_main`, `cohttp`, `cohttp-eio`, `yojson`, `uri`, `base64`, `digestif`, `infra`, `contract`, `ppx_deriving_yojson`

## Routes

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v2/health` | Health check (JSON) |
| GET | `/v2` | Dashboard |
| GET | `/v2/gateway/login` | Login page |
| POST | `/v2/gateway/login` | Login handler (POC, not connected to Security) |
| GET | `/v2/liveview` | Counter demo |
| GET | `/v2/todo` | Todo list demo |
| WS | `/v2/live` | Multiplexed WebSocket for all LiveView components |

## Creating a new LiveView component

1. Create `my_component.re`:
```reason
open Base;

type model = { value: int } [@@deriving yojson];
type msg = Increment | Decrement [@@deriving yojson];

let persistence = Liveview.User;

let init = (_ctx, _props) => { value: 0 };

let update = (_ctx, model, msg) =>
  switch (msg) {
  | Increment => { value: model.value + 1 }
  | Decrement => { value: model.value - 1 }
  };

let render = (model) =>
  Html.(
    <div>
      {dynamic("val", string_of_int(model.value))}
      {lvButton(~click="Increment", ~children=[txt("+")], ())}
    </div>
  );
```

2. Register in `main.re`:
```reason
let () = Liveview.register_view("/v2/live/my-component", (module My_component));
```

3. Add SSR + route if needed.

## Testing framework (`test/`)

Jest-like testing DSL in pure OCaml. Library name: `blossom_test`.

### Usage
```ocaml
open Well_test

let () =
  describe "My feature" (fun () ->
    it "works" (fun () ->
      expect 2 |> to_equal_int 2
    );

    it "handles strings" (fun () ->
      expect "hello" |> to_contain "ell"
    );

    skip "not ready yet" (fun () -> ());
  );

  let result = run () in
  exit_with_result result
```

### Available matchers
- `to_equal` - structural equality (polymorphic)
- `to_equal_string`, `to_equal_int`, `to_equal_float`, `to_equal_bool` - typed equality
- `to_be_true`, `to_be_false`
- `to_be_some`, `to_be_none`
- `to_be_greater_than`, `to_be_less_than` (int and float variants)
- `to_contain` - substring match
- `to_match` - regex match
- `to_have_length` - list length
- `to_raise`, `to_raise_with` - exception testing
- `not_` - negate any matcher

### Hooks
- `before_each`, `after_each` - per test
- `before_all`, `after_all` - per suite
- `skip` - skip a test

### Runner (`Runner` module)
- `find_test_files()` - autodiscovery of `*_test.ml`
- `run_tests_parallel` - parallel execution via `Unix.fork`
- `run_tests_sequential` - sequential execution
- `watch_mode` - rerun on file changes with debouncing

## Status

This is an **experiment / proof of concept**. Not connected to the production system.
Login is not wired to the Security service. Session ID = user ID for simplicity.
