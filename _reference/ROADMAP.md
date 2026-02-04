# Roadmap: Framework fullstackowy z gateway_client_v2

## Status quo

Mamy działający POC: LiveView engine (Elm architecture), JSX rendering, WebSocket diffing, HTTP framework (Blossom), keyed list reconciliation, 3 tryby persystencji, cross-device sync. Obecnie w Reason na EIO.

Brakuje dużo rzeczy aby to był pełnoprawny framework.

---

## 0. Migracja Reason → OCaml + MLX

### Decyzja: porzucamy Reason, przechodzimy na czysty OCaml z MLX

**Dlaczego:**
- Reason jest utrzymywany ale niszowy — JS-side ekosystem przeszedł na ReScript
- OCaml 5 jest aktywnie rozwijany (efekty, multicore, EIO) — to tam dzieje się rozwój
- PPX ekosystem (`let%query`, `[@@deriving table]`) jest natywny OCaml
- Reason dodaje ryzyko — dodatkowa warstwa kompilacji, mniejsza społeczność
- MLX daje JSX w czystym OCaml — nie potrzebujemy Reason tylko dla składni JSX

### MLX — JSX dla OCaml
- https://github.com/ocaml-mlx/mlx (aktywny, v0.10 na opam)
- Pliki `.mlx` = OCaml + JSX
- Wsparcie edytora (VSCode OCaml Platform 2.0+)
- Integracja z dune (dialect w `dune-project`)

```ocaml
(* plik: counter.mlx *)
let render ~count ~on_increment =
  <div class_="counter">
    <span class_="display">{string_of_int count}</span>
    <button data_lv_click={on_increment}>"+"</button>
  </div>

(* plik: page.mlx *)
let layout ~title ~children =
  <html>
    <head><title>{title}</title></head>
    <body>{children}</body>
  </html>
```

### Rozszerzenia plików
- `.ml` — czysty OCaml (logika, modele, update, typy)
- `.mlx` — OCaml + JSX (widoki, komponenty, layouty)
- `.mli` — interfejsy (opcjonalnie, preferujemy `open struct ... end`)

### Plan migracji (gateway_client_v2)

| Plik | Obecny | Docelowy | Uwagi |
|------|--------|----------|-------|
| `main.re` | Reason + JSX | `main.mlx` | Routing, SSR, JSX → MLX |
| `liveview.re` | Reason | `liveview.ml` | Zero JSX, czysta logika |
| `html.re` | Reason | `html.ml` + adapter MLX | Biblioteka HTML |
| `counter.re` | Reason + JSX | `counter.mlx` | Komponent LiveView |
| `todo.re` | Reason + JSX | `todo.mlx` | Komponent LiveView |
| `blossom.ml` | OCaml | `blossom.ml` | Bez zmian |
| `websocket.ml` | OCaml | `websocket.ml` | Bez zmian |
| `liveview_store.ml` | OCaml | `liveview_store.ml` | Bez zmian |

Pliki `.ml` (blossom, websocket, liveview_store) — bez zmian.
Pliki `.re` z JSX → `.mlx`. Pliki `.re` bez JSX → `.ml`.
Koszt migracji niski — ten sam AST, zmienia się tylko syntax.

### Konfiguracja dune

```lisp
;; dune-project
(lang dune 3.x)
(dialect
 (name mlx)
 (implementation
  (extension mlx)
  (preprocess (run mlx-pp %{input-file}))))
```

---

## 1. Infrastruktura sieciowa

### 1.1 SSL/TLS bezpośrednio (bez nginx)
- Obsługa certyfikatów (PEM/key) w Blossom
- Let's Encrypt / ACME automatyczny renewal
- Redirect HTTP → HTTPS
- Biblioteka: `tls-eio` lub `ocaml-tls`

### 1.2 Serwowanie plików statycznych z cache
- Middleware do serwowania z katalogu (np. `static/`)
- ETag / If-None-Match (304 Not Modified)
- Cache-Control / Expires headers
- Content-Type detection (MIME types)
- Gzip/Brotli compression
- Opcjonalny fingerprinting (hash w nazwie pliku)

### 1.3 HTTP/2
- Multiplexing, server push
- Wymaga SSL (punkt 1.1)

---

## 2. Ekstrakcja frameworka jako osobny projekt

### 2.1 Podział na bibliotekę vs aplikację
Obecny układ - wszystko razem. Docelowy:

```
blossom/                          # framework (osobne repo / opam package)
  ├── blossom.ml                  # HTTP server + routing
  ├── blossom_static.ml           # static file serving
  ├── blossom_ssl.ml              # TLS termination
  ├── blossom_middleware.ml        # middleware pipeline
  ├── blossom_session.ml          # session management
  ├── html.ml                     # HTML library (programmatic API)
  ├── liveview.ml                 # LiveView engine
  ├── liveview_store.ml           # persistence backends
  ├── websocket.ml                # WebSocket implementation
  ├── ppx/
  │   ├── ppx_table.ml            # [@@deriving table] PPX
  │   └── ppx_query.ml            # let%query PPX (type-safe SQL)
  └── client/
      └── live-view.js            # client-side JS (must ship with framework)

my-app/                           # aplikacja użytkownika (.ml + .mlx)
  ├── main.mlx                    # entry point, routes, layouts (JSX)
  ├── models/
  │   └── user.ml                 # [@@deriving table] (czysty OCaml)
  ├── components/
  │   ├── counter.mlx             # LiveView komponent (JSX)
  │   └── todo.mlx                # LiveView komponent (JSX)
  ├── queries/
  │   └── user_queries.ml         # let%query (czysty OCaml)
  ├── static/
  └── dune-project
```

### 2.2 System budowania i dystrybucji

**Bez Nix.** Podejście jak w `dg` - shipowane binaries + bundled .so:

```
my-app/
  bin/
    my-app              # unified binary (patchelf'd)
    bun                 # JS runtime
    lib/
      ld-linux-x86-64.so.2
      libc.so.6
      libsqlite3.so.0
      libgmp.so.10
      libz.so.1
      ...
  data/                 # SQLite databases
  static/               # assets
```

- **patchelf** na binarce: `--set-interpreter bin/lib/ld-linux-x86-64.so.2 --set-rpath $ORIGIN/lib`
- Działa na dowolnym Linux x86_64 bez zależności systemowych
- Deploy = kopiowanie katalogu

**Komendy:**
- `well init my-app` - scaffold nowego projektu
- `well dev` - dev server (lokalne biblioteki, hot reload)
- `well build` - build produkcyjny (dune build + patchelf + bundle .so)
- `well release` - archiwum gotowe do deployu

### 2.3 Ekstrakcja CLI (`dg` → `blossom`)
- Osobne narzędzie CLI dla frameworka
- Generatory: `blossom gen component MyComponent`
- Generatory CRUD: `blossom gen crud User name:string email:string`
  - Generuje: model, LiveView list/form/show, routes, migracje
  - Wzorowany na `rails generate scaffold`
- Dev server: `blossom dev --port 4000`
- REPL: `blossom repl`
- Migracje: `blossom db migrate`

### 2.4 Ekstrakcja kontraktów
- Ujednolicenie mechanizmu kontraktów (dziś: TOML → Go generator → OCaml/TS)
- Opcje:
  - A) Kontrakty w samym Reason (derive z typów OCaml → klient TS)
  - B) Oddzielny IDL (Protocol Buffers, własny DSL)
  - C) Uproszczony TOML jak dziś, ale generator jako część frameworka
- Generowanie klienta TypeScript z definicji OCaml
- Walidacja kontraktów w compile time

---

## 3. Braki w warstwie HTTP (Blossom)

### 3.1 Middleware pipeline
- Brak jakiegokolwiek systemu middleware
- Potrzebne: `request -> (request -> response) -> response`
- Composable: `app |> use(logger) |> use(cors) |> use(auth)`
- Middleware per-route i globalne

### 3.2 Potrzebne middleware
- **Logging** - request/response logging z timing
- **CORS** - konfigurowalny cross-origin
- **CSRF** - ochrona formularzy (token w sesji)
- **Rate limiting** - per IP / per user
- **Auth** - session-based, JWT, API keys
- **Error handler** - custom error pages, formatowanie błędów

### 3.3 Routing
- Brak nested routes / route groups
- Brak middleware per-group (np. `/admin/*` wymaga auth)
- Brak named routes (reverse routing: `url_for(:login)`)
- Brak route constraints (`:id` musi być int)

### 3.4 Session management
- Dziś: session_id generowany poprawnie (SHA1), ale user_id = session_id (świadomy skrót w POC)
- W prawdziwej aplikacji: resolve user z sesji po zalogowaniu
- Potrzebne: session store (memory / SQLite)
- Flash messages (one-time data between requests)
- Secure session cookies (signed, encrypted)

### 3.5 Request/Response
- Brak streaming responses (SSE, chunked transfer)
- Brak file upload handling (multipart/form-data)
- Brak content negotiation (Accept header)
- Brak cookie helpers (set/delete/expire)

---

## 4. Braki w LiveView

### 4.1 Update i side effects
- Dziś: `update` jest pure (`model → model`)
- **NIE potrzebujemy cmd pattern jak w Elm** - to jest przewaga EIO
- EIO pozwala na blokujące I/O bezpośrednio w `update` (sieć, DB, pliki)
- Blokuje jedną fiberę, reszta systemu działa dalej
- Loading state: wyślij patch "loading" → wykonaj operację → wyślij patch z wynikiem
- Jedyne co może być potrzebne: `handle_info` dla PubSub / timerów zewnętrznych

### 4.2 Lifecycle hooks
- `mount` - po połączeniu WS (nie to samo co init)
- `unmount` - przed rozłączeniem
- `handle_info` - external messages (PubSub, timers)
- `handle_params` - URL query params change

### 4.3 Live navigation
- `live_navigate(url)` - pushState bez full page reload
- `live_patch(url)` - zmiana query params bez remount
- Zachowanie stanu komponentów przy nawigacji
- Animacje przejść między stronami

### 4.4 JS hooks / interop
- `data-lv-hook="MyHook"` equivalent
- Pozwala na integrację z JS libraries (charty, mapy, edytory)
- `mounted()`, `updated()`, `destroyed()` callbacks
- `pushEvent(name, payload)` - JS → server
- `handleEvent(name, callback)` - server → JS

### 4.5 Uploads przez LiveView
- File upload z progress bar
- Drag & drop
- Preview przed uploadem
- Server-side validation (typ, rozmiar)
- Direct-to-S3 upload z pre-signed URLs

### 4.6 Form handling
- CRUD generator (`blossom gen crud`) generuje gotowe formularze
- Walidacja w real-time (data-lv-change z debounce)
- Inline error messages
- Generator tworzy: list view, form view, show view, delete confirmation

### 4.7 Debounce / throttle
- `lvChange` z debounce (np. search input)
- `lvClick` z throttle (zapobieganie double-submit)
- Konfiguracja per-event: `data-lv-debounce="300"`

### 4.8 Temporary assigns
- Dane widoczne tylko w jednym renderze (flash, duże listy)
- Po patch reset do wartości domyślnej
- Zmniejsza pamięć na serwerze

### 4.9 Components (nested LiveViews)
- Stateless components (function components)
- Stateful nested LiveViews z własnym stanem
- Komunikacja parent ↔ child
- Slots (content injection)

---

## 5. Baza danych — KILLER FEATURE: Type-safe SQL

### 5.1 Wizja: SQL sprawdzany w compile time

Inspiracja: octane.ml (brak licencji → piszemy od zera, ale podejście jest genialne).

**Piszesz normalny SQL. Kompilator go sprawdza.**

```ocaml
(* 1. Model = typ OCaml + PPX generuje schema *)
module User = struct
  type t = {
    id : int;
    name : string;
    email : string;
    active : bool;
  } [@@deriving table { name = "users" }]
end

(* 2. Query = NORMALNY SQL, sprawdzany w COMPILE TIME *)
let%query (module ActiveUsers) = "select id, name from users where active = true"
(*
   Kompilator wie że:
   - "users" → module User (z [@@deriving table { name = "users" }])
   - kolumny id, name, active istnieją w User.t
   - active jest bool → porównanie z true jest poprawne
   - wynik ma typ: { id: int; name: string } list
*)

(* 3. Użycie - w pełni typowane, zero runtime reflection *)
let* users = ActiveUsers.query db in
List.iter users ~f:(fun user ->
  (* user.id : int, user.name : string - kompilator wie! *)
  printf "%d: %s\n" user.id user.name
)

(* 4. Błąd kompilacji jeśli SQL jest niepoprawny *)
let%query (module Bad) = "select nonexistent from users"
(* ^^^ COMPILE ERROR: column "nonexistent" not found in table "users" (User.t) *)

let%query (module Bad2) = "select id from users where active = 'text'"
(* ^^^ COMPILE ERROR: "users.active" is bool, cannot compare with string *)
```

### 5.2 Architektura — 3 warstwy

```
Warstwa 1: PPX (compile time)
  [@@deriving table]     → rejestruje schema (tabele, kolumny, typy)
  let%query              → parsuje SQL, waliduje vs schema, generuje typowany kod

Warstwa 2: Query engine (runtime)
  Prepared statements    → bezpieczne parametry (no SQL injection)
  Connection pool        → zarządzanie połączeniami
  Transactions           → begin/commit/rollback
  Migrations             → schema versioning

Warstwa 3: Driver (runtime)
  SQLite driver          → domyślny, wbudowany
  (PostgreSQL driver)    → później, ten sam SQL walidowany w compile time
```

### 5.3 PPX `[@@deriving table]`

Generuje z typu OCaml:
- Schema info dostępne w compile time (nazwa tabeli, kolumny, typy)
- `create_table` - SQL CREATE TABLE
- `insert` / `update` / `delete` - typowane CRUD
- `of_row` / `to_row` - konwersja row ↔ typ OCaml

```ocaml
module Post = struct
  type t = {
    id : int;
    title : string;
    body : string;
    user_id : int;        (* FK do users *)
    published : bool;
    created_at : string;  (* timestamp *)
  } [@@deriving table { name = "posts" }]
end

(* Wygenerowane automatycznie: *)
Post.create_table db        (* create table posts (...) *)
Post.insert db { ... }      (* insert into posts values (?, ?, ...) *)
Post.find_by_id db 1        (* select * from posts where id = ? *)

(* PPX rejestruje mapping: "posts" → module Post *)
(* Dzięki temu let%query wie, że "from posts" odnosi się do Post.t *)
```

### 5.4 PPX `let%query` — parser SQL w compile time

**Decyzja: NORMALNY SQL**

Piszesz zwykły SQL — taki sam jak w sqlite3 REPL, Stack Overflow, czy output LLMa.
PPX mapuje nazwy tabel na moduły przez registry z `[@@deriving table { name = "..." }]`.

```ocaml
(* Normalny SQL — kopiujesz z sqlite3 REPL, wklejasz, działa *)
let%query (module FindUserPosts) =
  "select p.id, p.title, u.name as author
   from posts p
   join users u on p.user_id = u.id
   where u.id = $user_id and p.published = true
   order by p.created_at desc
   limit $limit"

(* Wygenerowany moduł: *)
(* module FindUserPosts : sig
     type t = { id: int; title: string; author: string }
     val query : db -> user_id:int -> limit:int -> t list result
   end *)

(* Użycie: *)
let* posts = FindUserPosts.query db ~user_id:42 ~limit:10 in
List.iter posts ~f:(fun { id; title; author } ->
  printf "%d: %s by %s\n" id title author
)
```

**Dlaczego normalny SQL a nie referencje do modułów:**
- Zero learning curve — każdy developer zna SQL
- Kopiujesz query z sqlite3 REPL → wklejasz do kodu → kompilator sprawdza
- LLM generuje standardowy SQL → wklejasz → działa
- Stack Overflow odpowiedzi działają bez tłumaczenia
- Mapping `"users"` → `module User` jest trywialny (~20 LOC w PPX)
  - `[@@deriving table { name = "users" }]` już deklaruje tę relację
  - PPX buduje hashtable `table_name → module` w compile time

Co musi obsługiwać:
- **SELECT**: kolumny, `table.col`, aliasy (`as`), `*`, functions (COUNT, SUM, MAX...)
- **FROM**: nazwa tabeli, alias opcjonalny
- **JOIN**: INNER, LEFT, RIGHT + ON warunek (sprawdzany vs schema)
- **WHERE**: porównania, AND/OR, IN, LIKE, IS NULL, BETWEEN
- **ORDER BY**, **GROUP BY**, **HAVING**, **LIMIT**, **OFFSET**
- **INSERT INTO**: `insert into users (name, email) values ($name, $email)`
- **UPDATE**: `update users set name = $name where id = $id`
- **DELETE**: `delete from users where id = $id`
- **Parametry**: `$name` → type-safe named binding

### 5.5 Implementacja PPX — plan

1. **SQL Parser** (OCaml, ~1000 LOC)
   - Tokenizer: keywords, identifiers, operators, strings, numbers, parameters
   - Parser: recursive descent, wystarczy subset SQL (nie pełna gramatyka)
   - AST: `Select`, `Insert`, `Update`, `Delete` z typowanymi node'ami

2. **Schema registry** (compile time)
   - `[@@deriving table]` rejestruje schema w globalnym stanie PPX
   - Każda tabela: nazwa, lista kolumn z typami
   - Dostępne dla `let%query` do walidacji

3. **Validator** (~500 LOC)
   - Resolve table references (FROM, JOIN)
   - Resolve column references vs schema
   - Type-check WHERE/ON expressions
   - Infer result type (SELECT columns → OCaml record type)
   - Check parameter types z kontekstu

4. **Code generator** (~500 LOC)
   - Generuje prepared statement
   - Generuje bind parameters (typed)
   - Generuje row decoder (column → OCaml value)
   - Generuje result type (anonymous record lub named module)

### 5.6 Migracje

```ocaml
(* Migracje jako OCaml, nie raw SQL — type-checked! *)
let%migration "2024-01-15_create_users" = {
  up = "CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE,
    active BOOLEAN NOT NULL DEFAULT true
  )";
  down = "DROP TABLE users";
}

(* Lub generowane z modelu: *)
(* well db generate migration add_users --from User *)
```

- `well db migrate` / `well db rollback`
- Tracking w tabeli `_migrations`
- Seed data: `well db seed`
- Generator CRUD automatycznie tworzy migracje

### 5.7 Dlaczego to jest killer feature

- **Zero runtime type errors z bazy** — jeśli się kompiluje, SQL jest poprawny
- **Refactoring bez strachu** — zmień typ kolumny → kompilator pokaże WSZYSTKIE broken queries
- **Piszesz normalny SQL** — nie uczysz się nowego query DSL, to jest SQL który znasz
- **IDE support** — kompilator zna typy, autocomplete działa
- **Bezpieczeństwo** — prepared statements by default, SQL injection niemożliwy
- **LLM-friendly** — LLM generuje SQL, kompilator sprawdza poprawność
- **Przewaga nad innymi frameworkami**:
  - Rails/Phoenix: runtime errors z bazy, Ecto ma swój DSL
  - Django: ORM ukrywa SQL, raw queries niesprawdzane
  - Rust/sqlx: sprawdza SQL ale wymaga połączenia z bazą w compile time
  - **Nasz**: sprawdza SQL z samych typów OCaml, zero połączenia z bazą w compile time
  - Piszesz NORMALNY SQL — nie uczysz się nowego DSL, kopiujesz z sqlite3 REPL

---

## 6. Testing framework

Istniejąca implementacja: `~/Documents/well/test/` (~600 LOC)

### 6.0 Co już jest (well/test)
- DSL w stylu Jest/Bun: `describe`, `it`, `before_each`, `after_each`, `before_all`, `after_all`, `skip`
- Matchery: `expect x |> to_equal y`, `to_be_true`, `to_have_length`, `to_match`, `to_raise`, `not_`
- Runner z autodiscovery plików `*_test.ml`
- Parallel execution przez `Unix.fork`
- Watch mode z debouncing
- CI output format
- Timing per test

### 6.1 Co trzeba dodać / zmienić
- **Integracja z frameworkiem**: test helpers do stawiania serwera HTTP w testach
  - `test_server(routes)` → startuje serwer na losowym porcie, zwraca URL
  - `test_client()` → HTTP client do robienia requestów w testach
  - `test_ws()` → WebSocket client do testowania LiveView
- **LiveView testing**: render komponentu bez przeglądarki
  - `render_live(module Counter)` → symulacja mount + events + assert na HTML
  - `send_event(view, Click("increment"))` → symulacja kliknięcia
  - `assert_html(view, ~selector=".count", "5")` → assert na wyrenderowanym HTML
- **Database testing**:
  - Automatyczny sandbox (transakcja per test, rollback po teście)
  - Fixtures / factories
  - `with_test_db(fun db -> ...)` → tymczasowa baza in-memory
- **Snapshot testing**:
  - `expect html |> to_match_snapshot` → porównanie z zapisanym snapshotem
  - Automatyczny update snapshotów (`--update-snapshots`)
- **Coverage**:
  - Integracja z bisect_ppx
  - `blossom test --coverage` → raport HTML

---

## 7. Developer experience

### 6.1 Hot reload
- Automatyczny rebuild + restart przy zmianie plików
- LiveView: reconnect po restarcie (dziś już jest reconnect logic)
- Bez utraty stanu przeglądarki (HMR-like)

### 6.2 Error pages
- Dev mode: szczegółowy stack trace w przeglądarce
- Prod mode: custom error pages (404, 500)
- Error logging z context (request, session, params)

### 6.3 Dev toolbar
- Request inspector (params, headers, cookies)
- LiveView state inspector
- WebSocket message log
- SQL query log z timing

### 6.4 Dokumentacja - WORLD CLASS

Podejście jak ExDoc w Elixirze - dokumentacja W KODZIE.

**Dlaczego:**
- Najlepsze dla LLMs (kontekst przy kodzie)
- Dokumentacja nie rozjeżdża się z kodem
- Jeden source of truth

**Implementacja:**
- Atrybuty doc w OCaml/Reason: `[@doc "..."]` lub komentarze `(** ... *)`
- Generator: `blossom docs` → statyczna strona HTML z dokumentacją
- Dokumentacja modułów, funkcji, typów - wyciągana z kodu
- Przykłady kodu w doc commentach (testowane!)
- Guides/tutorials jako osobne pliki markdown, ale linkowane z kodu
- Wersjonowanie dokumentacji (per release)
- Wbudowany search
- Każdy projekt na frameworku automatycznie dostaje narzędzie do dokumentacji

### 6.5 Frontend build system
- Wbudowany system budowania frontu oparty na `bun`
- `blossom build:js` - buduje assety JS/TS/CSS
- Automatyczne generowanie kontraktów TS z definicji OCaml
- Automatyczny setup struktury katalogów
- **Nie narzucamy frameworka frontendowego** (jak Phoenix)
  - Domyślnie: vanilla JS + LiveView (wystarczy dla 90% przypadków)
  - JS hooks dla integracji z zewnętrznymi bibliotekami
  - Jeśli ktoś chce React/Vue/Svelte - może, ale to jego wybór
- Tailwind CSS lub własny system design tokens
- Asset pipeline: fingerprinting, minification, bundle

---

## 8. Produkcyjność

### 8.1 Telemetria
- Metryki (request count, latency, WS connections)
- Prometheus/OpenTelemetry integration
- Health checks (liveness, readiness)

### 8.2 Graceful shutdown
- Drain active connections
- Save session state
- Close WebSocket connections cleanly

### 8.3 Clustering
- Dziś: single-node only
- Potrzebne: broadcast between nodes (PubSub)
- Distributed session store
- Load balancing aware (sticky sessions for WS)

---

## Priorytety (sugerowana kolejność)

### Faza 0 - Migracja
1. Migracja Reason → OCaml + MLX (0)
   - `.re` bez JSX → `.ml`
   - `.re` z JSX → `.mlx`
   - Konfiguracja dune dialect
   - Weryfikacja że wszystko buduje się i działa

### Faza 1 - Solidna baza
2. Testing framework - port z well/test + integracja z HTTP/LiveView (6.0, 6.1)
3. Middleware pipeline (3.1, 3.2)
4. Static file serving z cache (1.2)
5. Session management (3.4)
6. JS hooks (4.4)
7. Debounce / throttle (4.7)

### Faza 2 - Type-safe SQL (killer feature)
8. PPX `[@@deriving table]` - schema z typów OCaml (5.3)
9. SQL parser w compile time (5.5 krok 1)
10. PPX `let%query` - walidacja SQL vs schema (5.4, 5.5 krok 2-3)
11. Code generator - typed queries (5.5 krok 4)
12. Migracje (5.6)

### Faza 3 - Ekstrakcja
13. Podział framework / app (2.1)
14. CLI narzędzie z generatorami + CRUD generator (2.3, 4.6)
15. SSL/TLS (1.1)
16. Live navigation (4.3)
17. Dokumentacja w kodzie + generator (7.4)

### Faza 4 - Dojrzałość
18. Ekstrakcja kontraktów (2.4)
19. Nested components (4.9)
20. Frontend build system z bun (7.5)
21. Hot reload (7.1)

### Faza 5 - Produkcja
22. Clustering (8.3)
23. Telemetria (8.1)
24. Uploads (4.5)
25. HTTP/2 (1.3)
26. Dev toolbar (7.3)
27. Build system + dystrybucja (2.2)

---

## Powiązane projekty

| Projekt | Lokalizacja | Rola |
|---------|-------------|------|
| gateway_client_v2 | `src/gateway_client_v2/` | POC frameworka (LiveView, Blossom, HTML, WebSocket) |
| well | `~/Documents/well/` | Prototyp frameworka (CLI, testing, ORM, kontrakty, views) |
| dg | `~/Documents/dg/` | Wzorzec deploymentu (patchelf + bundled .so, unified binary) |

Docelowo: merge well + gateway_client_v2 → jeden framework.
- LiveView, Blossom, HTML, WebSocket ← z gateway_client_v2
- CLI, testing, ORM, kontrakty, views ← z well
- Deployment model (patchelf + .so bundle) ← z dg
- **Bez Nix** — shipujemy .so jak w dg
- **OCaml + MLX** — nie Reason (JSX przez mlx dialect, reszta czysty .ml)
- **Type-safe SQL** — `let%query` + `[@@deriving table]` (killer feature)
