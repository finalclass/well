# well — Full-stack OCaml Web Framework

## What is well

A batteries-included, type-safe, server-first web framework for OCaml 5.
Single binary deployment. No JavaScript for business logic.

Inspired by Phoenix LiveView, Rails, and the OCaml ecosystem (camels, dune, well...).

## Language & Conventions

- Code (variables, functions, comments) — English
- Documentation — English
- User-facing UI — Polish (for now, this is inherited from dg project)
- Framework name: `well` (lowercase, like `dune`)

## Tech Stack

- **Language**: OCaml 5 with MLX dialect for JSX (NOT Reason)
- **Async**: EIO (effect-based concurrency, fiber-per-connection)
- **Database**: SQLite (bundled)
- **Build**: dune
- **JS Runtime**: bun (for building frontend assets)
- **Deployment**: patchelf + bundled .so (no Nix, no Docker required)

## File Extensions

- `.ml` — pure OCaml (logic, models, queries, types)
- `.mlx` — OCaml + JSX (views, components, layouts)
- `.mli` — interfaces (prefer `open struct ... end` for private definitions)

## Architecture

```
well-core          HTTP server (raw EIO), WebSocket (RFC 6455), Router,
                   Request/Response, Middleware, Session, Auth, Static files

well-liveview      LiveView engine (Elm architecture), persistence (Ephemeral/Session/User),
                   keyed list diffing, cross-device sync, HTML library with LiveView helpers

well-orm           SQLite ORM, query builder, migrations, seeds
                   (future: PPX type-safe SQL — killer feature)

well-test          Jest-like testing DSL (describe/it/expect), parallel runner

well-contract      TOML contract parser → OCaml/TS code generators

well (cli)         CLI tool: init, dev, build, test, db, gen, release
```

## MLX — JSX for OCaml

Uses https://github.com/ocaml-mlx/mlx (v0.10+, active project).

```ocaml
(* file: my_page.mlx *)
let page ~title ~children =
  <html>
    <head><title>{title}</title></head>
    <body>{children}</body>
  </html>

let counter ~count =
  <div class_="counter">
    <span>{string_of_int count}</span>
    <button data_lv_click="increment">"+"</button>
  </div>
```

Dune dialect config:
```lisp
(dialect
 (name mlx)
 (implementation
  (extension mlx)
  (preprocess (run mlx-pp %{input-file}))))
```

## LiveView — Server-side Reactive UI

Elm architecture: model → update → render. All state on server.
WebSocket sends only diffs (changed text values + keyed list operations).

```ocaml
(* Component signature *)
module type VIEW = sig
  type model
  type msg

  val persistence : persistence  (* Ephemeral | Session | User *)
  val init : ctx -> Yojson.Safe.t -> model
  val update : ctx -> model -> msg -> model
  val render : model -> Html.element

  (* JSON serialization via [@@deriving yojson] *)
  val model_to_yojson : model -> Yojson.Safe.t
  val model_of_yojson : Yojson.Safe.t -> (model, string) result
  val msg_of_yojson : Yojson.Safe.t -> (msg, string) result
end
```

**Persistence modes:**
- `Ephemeral` — fresh state per connection
- `Session` — in-memory per session (survives reconnect, 5 min timeout)
- `User` — SQLite per user (survives restart, syncs across devices)

**Diffing protocol (WebSocket JSON):**
- `join` → client subscribes (endpoint, topic, props)
- `full` → server sends complete HTML
- `restored` → server recovered state from session/DB
- `msg` → client sends action (click, submit)
- `patch` → server sends only changes:
  - `changes`: `{"lv-id": "new value"}` (text updates)
  - `list_ops`: `{"list-id": {order: [...], inserts: {key: html}}}` (keyed lists)

**EIO advantage over Elm/Phoenix cmd:**
No need for `cmd` pattern. EIO allows blocking I/O directly in `update` —
blocks one fiber, rest of system continues. Loading state solved by sending
patch before operation, then patch after.

## Type-safe SQL — KILLER FEATURE (planned)

Write normal SQL. Compiler checks it.

```ocaml
(* 1. Define model — PPX generates schema *)
module User = struct
  type t = {
    id : int;
    name : string;
    email : string;
    active : bool;
  } [@@deriving table { name = "users" }]
end

(* 2. Write NORMAL SQL — validated at COMPILE TIME *)
let%query (module ActiveUsers) = "select id, name from users where active = true"

(* 3. Fully typed result *)
let* users = ActiveUsers.query db in
(* users : { id: int; name: string } list *)

(* 4. Compile error if SQL is wrong *)
let%query (module Bad) = "select nonexistent from users"
(* ^^^ COMPILE ERROR: column "nonexistent" not found in table "users" *)
```

**Why this is special:**
- Write real SQL (copy from sqlite3 REPL → paste → compiler checks)
- No new DSL to learn
- LLM generates standard SQL → paste → works
- Unlike Rust/sqlx: no database connection needed at compile time
- Refactor fearlessly: change column type → compiler shows ALL broken queries

## Deployment Model

No Nix. Patchelf + bundled .so (proven pattern from dg project):

```
my-app/
  bin/
    my-app                    # ELF binary (patchelf'd)
    lib/
      ld-linux-x86-64.so.2   # bundled dynamic linker
      libc.so.6
      libsqlite3.so.0
      libgmp.so.10
      libz.so.1
  data/                       # SQLite databases
  static/                     # assets
```

Deploy = copy directory. Works on any Linux x86_64.

```bash
patchelf --set-interpreter bin/lib/ld-linux-x86-64.so.2 --set-rpath '$ORIGIN/lib' bin/my-app
```

## CLI Commands (planned)

```bash
well init my-app              # scaffold new project
well dev                      # dev server with hot reload
well build                    # production build (dune + patchelf)
well release                  # bundle binary + .so for deployment
well test [--filter PATTERN]  # run tests
well db migrate               # run migrations
well db rollback              # rollback last migration
well db seed                  # seed data
well gen crud User name:string email:string  # generate model + views + migration
well new component Counter    # generate LiveView component (.mlx)
well new model User           # generate model (.ml with [@@deriving table])
```

## Testing Framework

Jest-like DSL in pure OCaml:

```ocaml
open Well_test

let () =
  describe "Users" (fun () ->
    it "creates a user" (fun () ->
      expect (String.length "hello") |> to_equal_int 5
    );

    it "validates email" (fun () ->
      expect "user@example.com" |> to_contain "@"
    );

    skip "not ready" (fun () -> ());
  );

  run () |> exit_with_result
```

**Matchers:** `to_equal`, `to_equal_string`, `to_equal_int`, `to_equal_float`,
`to_be_true`, `to_be_false`, `to_be_some`, `to_be_none`,
`to_be_greater_than`, `to_be_less_than`, `to_contain`, `to_match`,
`to_have_length`, `to_raise`, `to_raise_with`, `not_`

**Runner:** autodiscovery `*_test.ml`, parallel via `Unix.fork`, watch mode, CI output

## Reference Files

`_reference/` contains source material from the proof-of-concept:
- `_reference/ROADMAP.md` — full roadmap with all planned features and phases
- `_reference/gateway_client_v2/` — working POC code (Reason, currently):
  - `liveview.re` — LiveView engine with keyed list diffing + cross-device sync
  - `websocket.ml` — RFC 6455 WebSocket implementation
  - `blossom.ml` — HTTP framework on EIO + Cohttp
  - `html.re` — JSX-compatible HTML library
  - `counter.re`, `todo.re` — demo LiveView components
  - `main.re` — routes, SSR, CSS
  - `liveview_store.ml` — SQLite persistence
  - `test/` — testing framework (well_test.ml + runner.ml)

**Important:** Reference code is in Reason. New code must be OCaml + MLX.
Reference code uses Cohttp. New code should use raw EIO HTTP (fewer deps).

## Build & Verify

```bash
dune build                    # build everything
dune build @check             # type-check only (faster)
```

Target dependencies (minimal):
- `eio`, `eio_main` — async I/O
- `yojson` — JSON
- `sqlite3` — database
- `str` — regex
- `mlx` — JSX dialect
- `ppx_deriving_yojson` — JSON serialization

Avoid heavy deps: no Cohttp, no Conduit, no Jane Street Base.

## Priorities

See `_reference/ROADMAP.md` for full roadmap. Summary:

1. **Faza 0** — Project setup (dune-project, MLX, basic structure)
2. **Faza 1** — Core HTTP + WebSocket + Router + LiveView (port from reference)
3. **Faza 2** — Type-safe SQL PPX (killer feature)
4. **Faza 3** — CLI + generators + static files + sessions
5. **Faza 4** — Maturity (contracts, components, frontend build)
6. **Faza 5** — Production (clustering, telemetry, HTTP/2)
