# well — Full-stack OCaml Web Framework

## Rules

- Do NOT add "Co-Authored-By" to git commits

## What is well

A batteries-included, type-safe, server-first web framework for OCaml 5.
Single binary deployment. No JavaScript for business logic.

Inspired by Phoenix LiveView, Rails, and the OCaml ecosystem (camels, dune, well...).

## Language & Conventions

- Code (variables, functions, comments) — English
- Documentation — English
- User-facing UI — Polish (for now, inherited from dg project)
- Framework name: `well` (lowercase, like `dune`)

## Tech Stack

- **Language**: OCaml 5.4 with MLX dialect for JSX (NOT Reason)
- **Async**: EIO (effect-based concurrency, fiber-per-connection)
- **Database**: SQLite (bundled)
- **Build**: dune 3.17 (vendored at `./vendor/dune`)
- **JS Runtime**: bun (for building frontend assets — planned)
- **Deployment**: patchelf + bundled .so (no Nix, no Docker required)

## File Extensions

- `.ml` — pure OCaml (logic, models, queries, types)
- `.mlx` — OCaml + JSX (views, components, layouts)
- `.mli` — interfaces (prefer `open struct ... end` for private definitions)

## Current Project Structure

```
well/
├── bin/
│   ├── dune                      # executable: well (links well, well_cli)
│   └── main.ml                   # entry point → Well_cli.run Sys.argv
├── lib/
│   ├── well/                     # core library (module: Well, public: well.core)
│   │   ├── dune                  # (libraries eio eio_main yojson tls-eio ...)
│   │   └── well.ml               # version + EIO runtime wrapper
│   ├── well_cli/                 # CLI library (module: Well_cli, public: well.cli)
│   │   ├── dune                  # (libraries well unix)
│   │   ├── command.ml            # Command.t record type
│   │   ├── well_cli.ml           # command registry, dispatcher, help
│   │   ├── cmd_init.ml           # `well init <name>` implementation
│   │   └── template.ml           # project scaffold templates (15 files)
│   └── well_html/                # HTML library (module: Html, public: well.html)
│       ├── dune                  # (wrapped false) — exports Html directly
│       └── html.ml               # tag functions, escape_html, txt, raw
├── vendor/
│   ├── dune                      # vendored dune binary
│   └── lib/                      # bundled .so for release (libc, libsqlite3, etc.)
├── ROADMAP.md                    # full roadmap and design decisions (Polish)
├── dune-project                  # MLX dialect, package deps
├── dune                          # (dirs :standard \ vendor)
├── Makefile                      # build, check, test, dev, install, release
├── CLAUDE.md
└── .gitignore
```

## Libraries & Modules

### `well` (public: `well.core`) — lib/well/

HTTP server with global route registration. Raw EIO-based (no Cohttp).

```ocaml
(* Types *)
type request = {
  meth : string; path : string; headers : (string * string) list;
  body : string; params : (string * string) list; query : (string * string) list;
}

type custom = { status : int option; headers : (string * string) list; body : response }
and response = [
  (* JSON — auto content-type: application/json *)
  | `Null | `Bool of bool | `Int of int | `Float of float
  | `String of string | `Intlit of string
  | `List of Yojson.Safe.t list | `Assoc of (string * Yojson.Safe.t) list
  (* Framework *)
  | `Html of string      (* text/html *)
  | `Text of string      (* text/plain *)
  | `Redirect of string  (* 302 + Location *)
  | `Custom of custom    (* status/header override *)
]

(* Convenience constructors *)
val html : string -> response
val text : string -> response
val json : Yojson.Safe.t -> response   (* coerces Yojson.Safe.t → response *)
val redirect : string -> response

(* Response transformers — pipeable *)
val status : int -> response -> response
val header : string -> string -> response -> response

(* Request helpers *)
val param : request -> string -> string         (* path param, "" if missing *)
val query : request -> string -> string option  (* query param *)

(* Route registration — handler returns any subtype of response, coerced via :> *)
val get : string -> (request -> [< response]) -> unit
val post : string -> (request -> [< response]) -> unit
val put : string -> (request -> [< response]) -> unit
val delete : string -> (request -> [< response]) -> unit

(* Server entry point — blocks forever *)
val run : ?port:int -> ?cert:string -> ?key:string -> unit -> unit
(* default port 4000, listens on 0.0.0.0 *)
(* ~cert and ~key: paths to PEM files for TLS/HTTPS — both required together *)
```

**Response type** — polymorphic variant, superset of `Yojson.Safe.t`:
- `` `Html`` → text/html (Html module `tag`/`txt`/`raw` return `` [`Html of string] `` which coerces automatically)
- `` `Text`` → text/plain
- JSON variants (`` `Null``, `` `Assoc``, etc.) → application/json
- `` `Redirect`` → 302 + Location header
- `status`/`header` wrap in `` `Custom `` variant: `Html.(<div/>) |> status 201`
- Handler return type uses `:>` coercion — can return `Html.node`, `response`, or any subset

Route paths support `:param` segments: `"/users/:id"` extracts `id` from the URL.
Routes are matched in registration order. No match → 404. Handler exception → 500.

Dependencies: `eio`, `eio_main`, `yojson`, `tls-eio`, `mirage-crypto-rng.unix`

### `well_cli` (public: `well.cli`) — lib/well_cli/

Command registry with dispatch. Currently one command: `well init`.

```ocaml
(* Command.t *)
type t = { name: string; summary: string; usage: string; description: string; run: string list -> unit }

(* Well_cli *)
val run : string array -> unit   (* main entry point *)
```

Dependencies: `well`, `unix`

### `well_html` (public: `well.html`) — lib/well_html/

HTML generation. `(wrapped false)` so the module is `Html` directly.

```ocaml
type node = [ `Html of string ]

val escape_html : string -> string
val txt : string -> node             (* escaped text node *)
val raw : string -> node             (* raw/unescaped HTML *)
val tag : string -> ... -> ?children:node list -> unit -> node
val void_tag : string -> ... -> ?children:node list -> unit -> node

(* Tag functions: html, head, title, body, div, span, p, h1-h4,
   a, main, footer, header, nav, section, form, button, input,
   label, ul, ol, li, meta *)
```

Tag functions return `node = [`Html of string]` — a concrete polymorphic variant
that coerces to `Well.response` via `:>` in route handlers (automatic).

Tag functions accept optional labeled args: `?id`, `?class_`, `?lang`, `?href`,
`?data_lv_click`, `?data_lv_submit`, `?action`, `?method_`, `?type_`,
`?placeholder`, `?value`, `?name_`, `?charset`, `?content`, `?children`.

No dependencies (no external libs).

## Build Commands

The Makefile uses vendored dune: `DUNE := ./vendor/dune`

```bash
make build        # dune build
make check        # dune build @check (type-check only, faster)
make test         # dune test
make dev          # dune exec bin/main.exe
make install      # copy binary to ~/.local/bin/well
make release      # bundle binary + .so with patchelf → _release/
make lock         # dune pkg lock
make clean        # dune clean
```

## CLI — What Works Now

```bash
well init <name>    # scaffold new project (validates name, creates 15 files)
well init .         # init in current directory
well --help         # usage
well --version      # version
```

### Scaffold Output (`well init myapp`)

Creates a ready-to-build project with:
- `dune-project` — MLX dialect, pins `well` from local path
- `bin/main.ml` — entry point: `let () = Well.run ()`
- `lib/myapp/myapp.ml` — app name + version
- `lib/myapp_web/home_page.mlx` — welcome page (MLX/JSX), registers route via `Well.get`
- `lib/myapp_web/layout.mlx` — HTML layout (MLX/JSX)
- `test/myapp_test.ml` — basic test
- Makefile, .gitignore, .ocamlformat, static/.gitkeep

## MLX — JSX for OCaml

Uses https://github.com/ocaml-mlx/mlx (v0.11, active project).

**IMPORTANT — children syntax:**
- `"string"` — string literal child (raw `string` in OCaml)
- `identifier` — bare variable child
- `(expr)` — **parenthesized expression** for function calls, operators, etc.
- `<Tag />` — nested JSX child
- `{x}` — **record expression only** (NOT general expression interpolation!)

`{f x}`, `{(expr)}`, `{42}` are ALL syntax errors. Use `(f x)` instead.

```ocaml
(* file: my_page.mlx *)
let page ~title ~children =
  <html>
    <head><title>(txt title)</title></head>
    <body>children</body>
  </html>

let counter ~count =
  <div class_="counter">
    <span>(txt (string_of_int count))</span>
    <button data_lv_click="increment">"+"</button>
  </div>
```

Dune dialect config (in `dune-project`):
```lisp
(dialect
 (name mlx)
 (implementation
  (extension mlx)
  (merlin_reader mlx)
  (preprocess (run mlx-pp %{input-file}))))
```

## Architecture (Planned)

```
well.core          Core: EIO runtime, HTTP server, WebSocket, Router,
                   Request/Response, Middleware, Session, Auth, Static files

well.liveview      LiveView engine (Elm architecture), persistence,
                   keyed list diffing, cross-device sync

well.html          HTML tag library (exists), LiveView helpers (planned)

well.orm           SQLite ORM, query builder, migrations, seeds
                   (future: PPX type-safe SQL — killer feature)

well.test          Jest-like testing DSL (describe/it/expect), parallel runner

well.contract      TOML contract parser → OCaml/TS code generators

well.cli           CLI tool: init (exists), dev, build, test, db, gen, release
```

## LiveView — Server-side Reactive UI (planned)

Elm architecture: model → update → render. All state on server.
WebSocket sends only diffs (changed text values + keyed list operations).

```ocaml
module type VIEW = sig
  type model
  type msg

  val persistence : persistence  (* Ephemeral | Session | User *)
  val init : ctx -> Yojson.Safe.t -> model
  val update : ctx -> model -> msg -> model
  val render : model -> Html.element

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
blocks one fiber, rest of system continues.

## Type-safe SQL — KILLER FEATURE (planned)

Write normal SQL. Compiler checks it.

```ocaml
module User = struct
  type t = {
    id : int;
    name : string;
    email : string;
    active : bool;
  } [@@deriving table { name = "users" }]
end

let%query (module ActiveUsers) = "select id, name from users where active = true"

let* users = ActiveUsers.query db in
(* users : { id: int; name: string } list *)

let%query (module Bad) = "select nonexistent from users"
(* ^^^ COMPILE ERROR: column "nonexistent" not found in table "users" *)
```

**Why this is special:**
- Write real SQL (copy from sqlite3 REPL → paste → compiler checks)
- No new DSL to learn
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

## Testing Framework (planned)

Jest-like DSL in pure OCaml:

```ocaml
open Well_test

let () =
  describe "Users" (fun () ->
    it "creates a user" (fun () ->
      expect (String.length "hello") |> to_equal_int 5
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

## Dependencies (from dune.lock)

**Core:** `eio` 1.3, `eio_main` 1.3, `eio_posix`, `eio_linux`
**Language:** `mlx` 0.11, `ppxlib` 0.37.0, `ocaml` 5.4.0
**Data:** `yojson` 3.0.0, `sqlite3` 5.3.1
**TLS:** `tls` 2.0.3, `tls-eio` 2.0.3, `x509` 1.0.6, `mirage-crypto` 2.0.2, `mirage-crypto-rng` 2.0.2
**Other:** `cstruct`, `fmt`, `mtime`, `str`

Avoid heavy deps: no Cohttp, no Conduit, no Jane Street Base.

## Priorities

See `ROADMAP.md` for full roadmap and design decisions. All phases complete:

1. **Faza 0** — Project setup ✅
2. **Faza 1** — Core HTTP + WebSocket + Router + LiveView ✅
3. **Faza 2** — Type-safe SQL PPX ✅
4. **Faza 3** — LiveView gaps + Claude skills ✅
5. **Faza 4** — Maturity (test runner, snapshots, coverage, docs) ✅
6. **Faza 5** — Production (graceful shutdown, auto-TLS) ✅

## Implementation Status

### Done (Faza 0)
- [x] dune-project with MLX dialect + merlin_reader
- [x] Package structure: `well.core`, `well.cli`, `well.html`
- [x] CLI framework (command registry, dispatch, help)
- [x] `well init` command with full project scaffolding (15 files)
- [x] HTML tag library with XSS protection (`escape_html`, `txt`, `raw`)
- [x] Makefile with build/check/test/dev/install/release
- [x] Release bundling with patchelf
- [x] Vendored .so libraries for deployment

### Done (Faza 1 — partial)
- [x] Raw EIO HTTP/1.1 server (no Cohttp) with request parsing + response writing
- [x] Global route registration (`Well.get`, `Well.post`, `Well.put`, `Well.delete`)
- [x] Route matching with `:param` segments + query string parsing
- [x] Polymorphic variant response type (superset of Yojson.Safe.t)
- [x] Response constructors (`Well.html`, `Well.text`, `Well.json`, `Well.redirect`)
- [x] Response transformers (`Well.status`, `Well.header`) wrapping in `` `Custom ``
- [x] Html returns `node = [`Html of string]` — coerces to response via `:>`
- [x] `Well.run ?port ()` entry point (default port 4000)
- [x] TLS/HTTPS support via `tls-eio` (`Well.run ~cert ~key ~port:4443 ()`)

### Next (Faza 1 — remaining)
- [ ] Port `websocket.ml` → WebSocket in `well.core`
- [ ] Port `liveview.re` → `well.liveview` (Reason → OCaml)
- [ ] Port `html.re` → enhance `well.html` with LiveView helpers
- [ ] Middleware pipeline
- [ ] Static file serving
- [ ] Session management
- [ ] Port testing framework from reference
