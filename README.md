# well

Full-stack OCaml web framework. Single binary. No JavaScript for business logic.

## Quick start

```bash
well init myapp
cd myapp
make dev
```

Open http://localhost:4000. Done.

## The scaffold IS the tutorial

`well init` generates a working application with every feature of the framework demonstrated in real code:

| File | What it teaches |
|------|----------------|
| `home_page.mlx` | Routes, HTML rendering, sessions |
| `notes.ml` + `notes_page.mlx` | Type-safe SQL, CRUD, form handling |
| `counter_live.mlx` | LiveView (server-side reactive UI) |
| `activity_log_live.mlx` | Keyed lists, cross-LiveView communication |
| `dashboard_page.mlx` | Multiple LiveViews on one page |
| `login_page.mlx` | Auth, sessions, middleware |
| `upload_page.mlx` | File upload, streaming download |
| `request_id.ml` | Custom middleware, request context |
| `task_access_impl.ml` | Service contracts, RPC, SQLite |
| `task_manager_impl.ml` | Service layers (Manager -> Access -> DB) |
| `TaskAccess.toml` | Contract definitions (TOML -> OCaml + TypeScript) |
| `layout.mlx` | Layout component, MLX/JSX syntax |

Don't read docs. Read the scaffold. It compiles, it runs, it's the source of truth.

## Learn with AI

The framework ships with a `/well` skill for coding agents. Every scaffolded project includes it at `.agents/skills/well/SKILL.md`.

```
# In your project directory, with your coding agent:
/well
# Then ask Claude to build whatever you need
```

The skill contains complete reference for routes, LiveView, type-safe SQL, contracts, middleware, sessions, testing — everything. Claude generates correct well code because it has the full context.

This is how you learn a framework in 2026. You don't read documentation that goes stale the moment it's written. You work with an AI that has the real patterns, verified against the real codebase. The scaffold is the working example. The skill is the knowledge. The compiler catches the rest.

## What's in the box

- **OCaml 5 + EIO** — effect-based concurrency, fiber-per-connection
- **MLX** — JSX syntax for OCaml (`.mlx` files)
- **LiveView** — server-side reactive UI over WebSocket (like Phoenix LiveView)
- **Type-safe SQL** — write real SQL, compiler validates it (`let%query`, `[@@deriving table]`)
- **Service contracts** — TOML -> OCaml + TypeScript code generation
- **Registry Forms** — TOML-declared admin CRUD for low-volatility reference tables
- **MessageBus** — SQLite-backed persistent pub/sub
- **Channels** — authorized WebSocket gateway
- **Auto-TLS** — `Well.run ~domain:"myapp.com" ()` and Let's Encrypt certificates just happen
- **Single binary deployment** — patchelf + bundled .so, no Docker needed

## Auto-TLS (Let's Encrypt)

One line. No nginx, no certbot, no cron, no config files.

```ocaml
let () = Well.run ~domain:"myapp.com" ()
```

That's it. On first start:
- Port auto-switches to 443
- Certificate is provisioned from Let's Encrypt via ACME HTTP-01
- Port 80 starts automatically (challenges + HTTPS redirect)
- Cert and key saved to `data/certs/`
- Background fiber renews before expiry

For testing against Let's Encrypt staging:

```ocaml
let () = Well.run ~domain:"myapp.com" ~acme_staging:true ()
```

Manual TLS still works:

```ocaml
let () = Well.run ~cert:"cert.pem" ~key:"key.pem" ~port:443 ()
```

Dev mode (no TLS, localhost:4000) remains the default:

```ocaml
let () = Well.run ()
```

## CLI

```bash
well init <name>         # new project
well test [-w] [-f pat] [--jobs n]  # run tests (watch, filter, concurrency)
well docs [--open]       # generate HTML documentation
well contract build .    # generate from TOML contracts
well db diff             # show pending migrations
well repl                # interactive service shell
```

## Registry Forms

Registry Forms are for low-volatility back-office reference tables:
dictionaries, company lists, and simple admin tables. They are deliberately not
a public API layer or a workflow engine.

Declare registries in TOML:

```toml
[registry.company]
table = "companies"
title = "Companies"
display = ["name", "nip", "address"]
soft_delete = true

[registry.company.fields.name]
type = "string"
label = "Name"
required = true
unique = true

[registry.company.fields.nip]
type = "string"
label = "NIP"

[registry.company.fields.address]
type = "text"
label = "Address"
```

Register them before opening the app database:

```ocaml
let () =
  Well.Registry.setup_from_toml_file
    ~base_path:"/planner/registry"
    "well.toml"
```

The registry registers SQLite tables for Well auto-migration and exposes list,
new, edit and archive routes under the selected base path.

## Build from source

```bash
git clone https://github.com/anthropics/well.git
cd well
make lock
make build
make install   # copies to ~/.local/bin/well
```

## Stack

OCaml 5.4, MLX 0.11, EIO, SQLite, dune 3.17. No Cohttp, no Conduit, no Jane Street Base.

Deploy = copy directory. Works on any Linux x86_64.

## License

MIT
