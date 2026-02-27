# Changelog

## v1.3.0 — 2026-02-27

### Breaking changes
- Cap admin panel URL prefix changed from `/_well/` to `/_cap/`
- LiveView `subscriptions` field removed — `init` now returns `(model, string list)` tuple with dynamic subscriptions

### New features
- `well.pushLive(msg, topic?)` — send messages to LiveView from external JS
- Dynamic LiveView subscriptions (can depend on init props, e.g. keyed topics)

### Fixes
- `well build` — fix package name detection when dune-project has inline `(package` in pins

## v1.2.0 — 2026-02-27

### New features
- `well build` — production build with patchelf + bundled .so → `_release/`
- `well release` — build + versioned `.tar.gz` archive (`<name>-v<version>.tar.gz`)
- OAuth 2.0 — Google, GitHub, Microsoft, Facebook providers
- Auth + Mailer modules
- S3 client
- Telemetry system
- Cap admin panel — routes, connections, REPL, log viewer, user management
- Keyed topics, request/reply pattern in MessageBus
- Basic auth middleware
- Typed events in MessageBus (`subscribe`, `replay_typed`, `prune`)

### Improvements
- Replace full HTML morph with binary diff patches (smaller WS payloads)
- Full HTML5 tag/attribute coverage + wildcard routes
- Consolidate framework SQLite into single `well.sqlite`
- WS preconnect script (avoids HTTP/1.1 connection pool exhaustion)
- Version-tagged releases (reads `(version ...)` from `dune-project`)
- Scaffold pins well from GitHub instead of local path
- Production hardening: security, reliability, correctness (23 fixes)
- Structured logging, system stats in Cap admin
- Rate limiter skips static files, fix connection timeouts

### Tests
- 437 tests total

## v1.1.0

### New features
- `Well.Form` — applicative form validation with `let+`/`and+`
- `Well.Console` — built-in admin panel at `/_cap/`
- Unified pub/sub system (typed MessageBus)

### Improvements
- Fix MIME types for static files
- Upgrade to OCaml 5.4

## v1.0.0

Initial release — core HTTP server, WebSocket, LiveView engine, HTML library,
test framework, static file serving, CLI with `well init` scaffold.
