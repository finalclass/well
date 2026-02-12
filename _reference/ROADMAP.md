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

### 2.4 System kontraktów i usług (aktorów)

System inspirowany Erlang/OTP + kontraktami z dg. Kontrakty TOML definiują interfejsy,
usługi (aktorzy) je implementują z izolacją crashy i mailboxami.

Szczegóły → sekcja 9.

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

## 9. Kontrakty i usługi (aktorzy)

### 9.1 Wizja

System inspirowany trzema źródłami:
- **Erlang/OTP** — izolacja procesów, mailboxy, let-it-crash, supervisory
- **dg/contract** — TOML kontrakty → codegen (OCaml, TS, Go, Dart)
- **IDesign / SOA** — volatility-based decomposition, warstwy usług

**Kluczowa idea:** kontrakt TOML definiuje interfejs usługi. Usługa (aktor) implementuje
ten interfejs. Framework zapewnia izolację crashy (`try...with` wokół każdego komunikatu),
mailbox (kolejkę wiadomości), supervision (restart po awarii).

W przeciwieństwie do Erlanga nie mamy izolacji na poziomie VM — używamy EIO fiber +
`try...with` jako granicy izolacji. Crash jednej usługi nie zabija reszty systemu.

### 9.2 Kontrakty — TOML → codegen

Wzorzec z dg, wbudowany w framework jako standard.

```toml
# contract/UserManager.toml

[service.rpc]
create = "CreateRequest -> CreateResponse"
find = "FindRequest -> UserResponse"
list = "ListRequest -> ListResponse"
authenticate = "AuthRequest -> AuthResponse"

[msg.CreateRequest.struct]
name = "string"
email = "string"
password = "string"

[msg.CreateResponse.variant]
Ok = "User"
AlreadyExists = "void"
ValidationError = "string"

[msg.User.struct]
id = "int"
name = "string"
email = "string"
active = "bool"
```

**Format TOML (sprawdzony w dg):**
- `[service.rpc]` — endpointy: `nazwa = "Request -> Response"`
- `[msg.Name.struct]` — typy produktowe (rekordy)
- `[msg.Name.variant]` — typy sumowe (tagged unions)
- Typy prymitywne: `string`, `int`, `float`, `bool`, `void`, `date`, `record`
- Typy złożone: `{ type = "list", of = "Item" }`, `{ type = "string", optional = true }`
- Referencje między kontraktami: `Common.UserCtx`, `UserManager.User`

**Common.toml** — współdzielone typy (jak w dg):
```toml
# contract/Common.toml
[msg.UserCtx.struct]
session_id = "string"
user_id = { type = "int", optional = true }

[msg.OkResponse.variant]
Ok = "void"
Failed = "string"
```

### 9.3 Codegen — generowany kod

`well contract build` czyta `contract/*.toml` i generuje:

**OCaml (primary):**
```ocaml
(* _build/contract/user_manager.ml — wygenerowane *)
module CreateRequest = struct
  type t = { name : string; email : string; password : string }
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end

module CreateResponse = struct
  type t = Ok of User.t | AlreadyExists | ValidationError of string
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end

(* Interfejs usługi — to musi zaimplementować aktor *)
module type SERVICE = sig
  val create : CreateRequest.t -> CreateResponse.t
  val find : FindRequest.t -> UserResponse.t
  val list : ListRequest.t -> ListResponse.t
  val authenticate : AuthRequest.t -> AuthResponse.t
end
```

**TypeScript (opcjonalnie):**
```typescript
// _build/contract/user_manager.ts
interface CreateRequest { name: string; email: string; password: string }
type CreateResponse = { tag: "Ok"; value: User } | { tag: "AlreadyExists" } | ...
```

### 9.4 Usługi (aktorzy) — Erlang-inspired na EIO

Każda usługa to aktor z:
- **Mailbox** — kolejka wiadomości (EIO Stream lub Mutex + Queue)
- **Stan** — prywatny, mutowalny w obrębie aktora
- **Izolacja** — `try...with` wokół obsługi każdego komunikatu
- **Supervision** — restart po crash, backoff, circuit breaker

```ocaml
(* Definicja usługi — implementuje kontrakt *)
module UserService = Well.Service.Make(UserManager_contract)(struct
  type state = {
    db : Sqlite3.db;
    cache : (int, User.t) Hashtbl.t;
  }

  let init _ctx =
    { db = Sqlite3.db_open "users.db"; cache = Hashtbl.create 256 }

  (* Każdy handler wywoływany w try...with — crash nie zabija usługi *)
  let create state req =
    match validate req with
    | Error msg -> UserManager.CreateResponse.ValidationError msg
    | Ok () ->
      let user = insert_user state.db req in
      Hashtbl.replace state.cache user.id user;
      UserManager.CreateResponse.Ok user

  let find state req = ...
  let list state req = ...
  let authenticate state req = ...
end)
```

**Lifecycle aktora:**

```
spawn → init → [loop: receive → try handle with _ → log + continue] → terminate
                  ↑                                                         |
                  └── supervisor restart (backoff: 1s, 2s, 4s, max 30s) ←──┘
```

### 9.5 Mailbox i komunikacja

```ocaml
(* Wywołanie synchroniczne — czeka na odpowiedź *)
let result = Well.Service.call UserService.ref (fun svc -> svc.create request)

(* Wywołanie asynchroniczne — fire-and-forget *)
Well.Service.cast Logger.ref (fun svc -> svc.log entry)

(* Broadcast do wszystkich instancji *)
Well.Service.broadcast Notification.ref (fun svc -> svc.notify event)
```

**Mailbox internals:**
- EIO `Stream.t` jako kolejka (bounded, backpressure)
- Fiber per aktor — blokuje się na `Stream.take`
- `call` = send + `Promise.await` (synchroniczne)
- `cast` = send (asynchroniczne, fire-and-forget)

### 9.6 Supervision

```ocaml
(* Supervisor tree — deklaratywny *)
let () = Well.Supervisor.start [
  Well.Supervisor.worker UserService.spec;
  Well.Supervisor.worker OrderService.spec ~restart:`Permanent;
  Well.Supervisor.worker Logger.spec ~restart:`Permanent;
  Well.Supervisor.worker EmailWorker.spec ~restart:`Transient;
]
```

**Strategie restartu:**
- `Permanent` — zawsze restartuj (usługi krytyczne)
- `Transient` — restartuj tylko po crash (nie po normalnym zakończeniu)
- `Temporary` — nigdy nie restartuj (jednorazowe zadania)

**Backoff:** 1s → 2s → 4s → 8s → 16s → 30s (max)
**Circuit breaker:** po N crashów w M sekund → usługa oznaczona jako `down`

### 9.7 Izolacja — granice crashy

```ocaml
(* Wewnętrznie, pętla aktora: *)
let rec loop state mailbox =
  let msg = Eio.Stream.take mailbox in
  let state' =
    try handle_message state msg
    with exn ->
      (* Crash izolowany — log + kontynuacja z poprzednim stanem *)
      Log.error "Service %s crashed: %s" name (Printexc.to_string exn);
      Telemetry.increment ~tags:[("service", name)] "service.crash";
      state (* zachowaj poprzedni stan *)
  in
  loop state' mailbox
```

**Co izolujemy:**
- Każdy `call`/`cast` w `try...with` — crash nie propaguje się do callera
- Caller dostaje `Error` wariant zamiast wyjątku
- Stan usługi przeżywa crash pojedynczego requestu
- Pełny restart (z `init`) tylko gdy supervisor zdecyduje

### 9.8 Integracja z resztą frameworka

**Routes → Services:**
```ocaml
(* Route handler wywołuje usługę — izolacja automatyczna *)
let () = Well.post "/api/users" (fun req ->
  let body = parse_json req.body in
  match Well.Service.call UserService.ref (fun s -> s.create body) with
  | Ok (UserManager.CreateResponse.Ok user) ->
    Well.json (User.to_yojson user) |> Well.status 201
  | Ok (UserManager.CreateResponse.ValidationError msg) ->
    Well.json (`Assoc [("error", `String msg)]) |> Well.status 422
  | Error _ ->
    Well.json (`Assoc [("error", `String "service unavailable")]) |> Well.status 503
)
```

**LiveView → Services:**
```ocaml
(* LiveView update bezpośrednio woła usługi *)
let update ctx model = function
  | CreateUser form_data ->
    (* EIO: blokuje tę fiberę, reszta systemu działa *)
    let result = Well.Service.call UserService.ref (fun s -> s.create form_data) in
    { model with users = result :: model.users; loading = false }
```

### 9.9 Implementacja — plan

**Krok 1: Contract parser + codegen (~800 LOC)**
- TOML parser (użyć biblioteki `toml` z opam lub wbudowany)
- AST kontraktu: `Service`, `Msg` (Struct | Variant), typy
- Codegen OCaml: typy, to/of_yojson, module type SERVICE
- Codegen TS (opcjonalnie)
- CLI: `well contract build`

**Krok 2: Actor runtime (~600 LOC)**
- `Well.Service.Make` funktor — kontrakt → aktor
- Mailbox na `Eio.Stream.t`
- Pętla aktora z `try...with`
- `call` (sync), `cast` (async)
- Ref type (jak Erlang pid)

**Krok 3: Supervision (~400 LOC)**
- Supervisor tree (deklaratywny)
- Strategie restartu (Permanent, Transient, Temporary)
- Backoff + circuit breaker
- Telemetria crashy

**Krok 4: Integracja (~200 LOC)**
- `Well.Service.call` w route handlerach
- Error handling (service down → 503)
- Health check endpoint (status usług)

---

## Status implementacji (aktualizacja)

### ✅ Zrobione

**Faza 0 — Setup projektu:**
- [x] dune-project z MLX dialect + merlin_reader
- [x] Struktura pakietów: `well.core`, `well.cli`, `well.html`
- [x] CLI framework (registry komend, dispatch, help)
- [x] `well init` z walidacją i scaffoldem (15 plików)
- [x] HTML library z XSS protection (`escape_html`, `txt`, `raw`)
- [x] Makefile (build/check/test/dev/install/release)
- [x] Release bundling z patchelf
- [x] Vendored .so libraries

**Faza 1 — Core HTTP + WebSocket + LiveView (częściowo):**
- [x] Raw EIO HTTP/1.1 server (bez Cohttp), request parsing, response writing
- [x] Routing: `Well.get/post/put/delete`, `:param` segments, query string
- [x] Response types: JSON/HTML/Text/Redirect/Custom + `status`/`header` transformers
- [x] Static file serving: MIME types, ETag/304, path safety, text/binary
- [x] WebSocket: RFC 6455 handshake, frames, masking, ping/pong, `Well.ws`
- [x] LiveView engine: Elm arch, diffing (values + keyed lists), persistence (Ephemeral/Session/User)
- [x] LiveView store: SQLite persistence, session store z timeout
- [x] TLS/HTTPS: `Well.run ~cert ~key ()` via tls-eio
- [x] HTTP client: `Well.fetch` z chunked encoding + TLS
- [x] Html: tagi, LiveView helpers (`dynamic`, `each`), key registry
- [x] Testing DSL: describe/it/expect/matchery (well_test.ml, 402 LOC)
- [x] PPX: `[@@deriving table]` + `let%query` — parsowanie i generowanie typów (500 LOC)

### 🔨 Do zrobienia

**Faza 1 — dokończenie bazy:**
- [x] Middleware pipeline (`request -> (request -> response) -> response`)
- [x] Middleware: logging, CORS, CSRF, rate limiting, auth, error handler
- [ ] Session persistence (teraz in-memory, potrzebny SQLite/signed cookie store)
- [ ] Flash messages (one-time data between requests)
- [x] Routing: scope (nested routes + route groups + middleware per-group)
- [ ] Routing: named routes, route constraints (`:id` musi być int)
- [ ] Test runner: autodiscovery `*_test.ml`, parallel via fork, watch mode
- [ ] Test helpers: `test_server`, `test_client`, `test_ws` do testów HTTP/LiveView
- [ ] Streaming responses (SSE, chunked transfer)
- [ ] File upload (multipart/form-data)
- [ ] Compression (gzip/brotli) dla static + responses

**Faza 2 — Type-safe SQL runtime:**
- [ ] SQL runtime: execute query, bind params, map results → OCaml types
- [ ] Connection pool (EIO-based)
- [ ] Transactions (begin/commit/rollback)
- [ ] Migracje: `well db migrate`, `well db rollback`, tracking w `_migrations`
- [ ] Seed data: `well db seed`
- [ ] Database testing: sandbox (transakcja per test, rollback)

**Faza 2.5 — Kontrakty i usługi (NOWE):**
- [ ] Contract parser: TOML → AST kontraktu (Service, Msg, types)
- [ ] Contract codegen OCaml: typy, to/of_yojson, `module type SERVICE`
- [ ] Contract codegen TypeScript (opcjonalnie)
- [ ] CLI: `well contract build`
- [ ] Actor runtime: `Well.Service.Make` funktor, mailbox (`Eio.Stream.t`)
- [ ] Actor loop z `try...with` izolacją crashy
- [ ] `call` (sync z Promise), `cast` (async fire-and-forget)
- [ ] Supervision tree: deklaratywny, strategie restartu (Permanent/Transient/Temporary)
- [ ] Backoff + circuit breaker
- [ ] Integracja: `Well.Service.call` w route handlerach i LiveView update
- [ ] Health check endpoint (status usług)

**Faza 3 — Ekstrakcja i CLI:**
- [ ] Podział framework / app (osobne pakiety)
- [ ] CLI generatory: `well gen route`, `well gen model`, `well gen component`
- [ ] CRUD generator: `well gen crud User name:string email:string`
- [ ] `well dev` — dev server z hot reload
- [ ] `well build` — build produkcyjny
- [ ] `well release` — archiwum gotowe do deployu

**Faza 3 — LiveView gaps:**
- [ ] Lifecycle hooks: mount, unmount, handle_info, handle_params
- [ ] Live navigation: `live_navigate`, `live_patch`, pushState
- [ ] JS hooks: `data-lv-hook`, mounted/updated/destroyed, pushEvent/handleEvent
- [ ] Debounce / throttle: `data-lv-debounce="300"`
- [ ] Nested components (stateless function + stateful z własnym stanem)
- [ ] Temporary assigns (flash, duże listy — reset po render)

**Faza 4 — Dojrzałość:**
- [ ] Frontend build system z bun (JS/TS/CSS)
- [ ] Dokumentacja w kodzie + generator (`well docs`)
- [ ] Hot reload z LiveView reconnection
- [x] Error pages (dev: stack trace, prod: custom 404/500) — `Well.error_handler` + `Well.on_error`
- [ ] Snapshot testing (`to_match_snapshot`)
- [ ] Coverage z bisect_ppx

**Faza 5 — Produkcja:**
- [ ] Clustering: broadcast between nodes (PubSub)
- [ ] Telemetria: metryki, Prometheus/OpenTelemetry, health checks
- [ ] Graceful shutdown: drain connections, save sessions, close WS
- [ ] HTTP/2: multiplexing, server push
- [ ] Dev toolbar: request inspector, LiveView state, WS log, SQL log
- [ ] Let's Encrypt / ACME automatyczny renewal

---

## Priorytety (sugerowana kolejność)

### Faza 0 - Setup ✅ DONE
- Migracja Reason → OCaml + MLX
- Struktura projektu, CLI, HTML library, Makefile

### Faza 1 - Solidna baza (OBECNA)
1. Middleware pipeline + middleware (logging, CORS, CSRF, auth)
2. Session persistence (SQLite store, signed cookies, flash messages)
3. Test runner z autodiscovery + test helpers HTTP/LiveView
4. Routing: nested routes, groups, named routes
5. Compression (gzip/brotli)
6. File upload (multipart/form-data)

### Faza 2 - Type-safe SQL (killer feature)
7. SQL runtime — execute, bind, map results
8. Connection pool (EIO)
9. Transactions
10. Migracje + seed
11. Database testing sandbox

### Faza 2.5 - Kontrakty i usługi (aktorzy)
12. Contract parser (TOML → AST)
13. Contract codegen (OCaml types, yojson, module type)
14. Actor runtime (mailbox, loop, try...with isolation)
15. call/cast + Ref type
16. Supervision tree (restart strategies, backoff, circuit breaker)
17. Integracja z routes + LiveView
18. CLI: `well contract build`

### Faza 3 - Ekstrakcja + LiveView
19. CLI generatory + CRUD generator
20. LiveView lifecycle (mount, unmount, handle_info)
21. Live navigation (pushState)
22. JS hooks / interop
23. Debounce / throttle
24. Nested components

### Faza 4 - Dojrzałość
25. Frontend build z bun
26. Dokumentacja + generator
27. Hot reload
28. Error pages (dev/prod)

### Faza 5 - Produkcja
29. Clustering + PubSub
30. Telemetria + OpenTelemetry
31. Graceful shutdown
32. HTTP/2
33. Dev toolbar
34. Let's Encrypt / ACME

---

## Powiązane projekty

| Projekt | Lokalizacja | Rola |
|---------|-------------|------|
| gateway_client_v2 | `_reference/gateway_client_v2/` | POC (LiveView, HTTP, WebSocket, HTML) |
| dg | `~/Documents/dg/` | Wzorzec: deployment (patchelf), kontrakty (TOML → codegen) |

**Zasady:**
- **Bez Nix** — patchelf + bundled .so (jak dg)
- **OCaml + MLX** — nie Reason
- **Type-safe SQL** — `let%query` + `[@@deriving table]`
- **Kontrakty TOML** — sprawdzony format z dg, wbudowane w framework
- **Aktorzy** — Erlang-inspired na EIO fibers, izolacja crashy
