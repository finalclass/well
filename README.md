# well

Full-stack OCaml web framework with LiveView. Server-side reactive UI, type-safe routing, single binary deployment.

## Features

- **LiveView** — Server-side reactive UI with Elm architecture. All state on server, only diffs over WebSocket.
- **MLX** — JSX syntax for OCaml. Write HTML components with full type safety.
- **Single binary** — Deploy by copying one directory. No Docker, no Nix.
- **EIO** — Effect-based concurrency. One fiber per connection, no callback hell.
- **SQLite** — Bundled. No external database server needed.

## Quick start

```bash
well init myapp
cd myapp
dune pkg lock
dune build
dune exec bin/main.exe
```

Open http://localhost:4000

## Routing

```ocaml
(* lib/myapp_web/home_page.mlx *)

Well.get "/" @@ fun _req ->
let open Html in
<Layout title="My App">
  <div>
    <h1>(txt "Hello, world!")</h1>
  </div>
</Layout>
```

Routes support parameters and query strings:

```ocaml
Well.get "/users/:id" @@ fun req ->
  let id = Well.param req "id" in
  Well.json (`Assoc [("id", `String id)])
```

## LiveView

Define a reactive component:

```ocaml
(* lib/myapp_web/counter_live.mlx *)

type model = { count: int } [@@deriving yojson]
type msg = Increment | Decrement [@@deriving yojson]

let persistence = Well.LiveView.Ephemeral

let init _ctx _props = { count = 0 }

let update _ctx model = function
  | Increment -> { count = model.count + 1 }
  | Decrement -> { count = model.count - 1 }

let render model =
  let open Html in
  <div>
    <span>(dynamic "count" (string_of_int model.count))</span>
    <button data_lv_click="Increment">(txt "+")</button>
    <button data_lv_click="Decrement">(txt "-")</button>
  </div>
```

Register and embed it:

```ocaml
(* bin/main.ml *)
let () =
  Well.live "/counter" (module Counter_live);
  Well.static "/static" "static";
  Well.run ()
```

```ocaml
(* lib/myapp_web/counter_page.mlx *)
Well.get "/counter" @@ fun _req ->
let open Html in
let module LiveView = Well.LiveView in
<Layout title="Counter">
  <LiveView name="counter" />
</Layout>
```

The server renders initial HTML, then sends only diffs over WebSocket. No JavaScript to write.

## Response types

Handlers return polymorphic variants — the compiler picks the right content type:

```ocaml
(* HTML *)
Well.get "/" @@ fun _req -> Html.(<h1>(txt "hello")</h1>)

(* JSON *)
Well.get "/api" @@ fun _req -> `Assoc [("ok", `Bool true)]

(* Text *)
Well.get "/health" @@ fun _req -> `Text "ok"

(* Redirect *)
Well.get "/old" @@ fun _req -> `Redirect "/new"

(* Status + headers *)
Well.post "/api" @@ fun _req ->
  `Assoc [("created", `Bool true)] |> Well.status 201
```

## Project structure

After `well init myapp`:

```
myapp/
  bin/main.ml                    # entry point
  lib/myapp/myapp.ml             # app config
  lib/myapp_web/
    layout.mlx                   # HTML layout component
    home_page.mlx                # home page route
    counter_live.mlx             # LiveView component
    counter_page.mlx             # counter page route
  test/myapp_test.ml             # tests
  static/
    app.css                      # styles
    well-live.js                 # LiveView client
```

## Tech stack

- OCaml 5.4 with [MLX](https://github.com/ocaml-mlx/mlx) for JSX
- [EIO](https://github.com/ocaml-multicore/eio) for async I/O
- SQLite for persistence
- TLS via tls-eio
- dune 3.17 for builds

## Build from source

```bash
git clone https://github.com/finalclass/well.git
cd well
make lock
make build
make install   # copies to ~/.local/bin/well
```

## License

MIT
