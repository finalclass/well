---
name: well-front
description: Build client-side interactive UI with well.web — The Elm Architecture (TEA) in OCaml compiled to Web Components via js_of_ocaml. Use whenever adding interactive client components, custom elements (<well-*>), or anything needing state/updates on the client (counters, reactive forms, search-as-you-type, live filters, toggles). NOT for server-side LiveView (that's the `well` skill).
user-invocable: true
allowed-tools: Read, Edit, Write, Bash, Glob, Grep
---

# Well.Web — Client-Side Components (TEA)

You are building **client-side interactive UI** for a well app using **well.web**: The Elm Architecture (TEA) in OCaml, compiled to **Web Components** (custom elements) via js_of_ocaml.

State lives **on the client**. The runtime runs **in the browser** — no server round-trip per interaction. This is the modern replacement for the older LiveView system.

## When to use which skill

- **well-front** (this) — client-side interactivity: counters, reactive forms, search-as-you-type, live toggles, anything where the DOM updates from local state. Uses well.web / `<well-*>` custom elements.
- **`well`** — server-rendered pages, routes, LiveView (string-diff-over-WebSocket), models, services, SQL. The default for static and server-side content.
- **frontend-design** — visual aesthetics (typography, color, layout, motion). Pair it with well-front when a component also needs to *look* distinctive.

well.web is the intended long-term successor to LiveView. For new interactive UI, prefer well.web.

## Architecture in one line

```
DOM click → handler (dispatch msg) → update → new state → view → vdom → DOM
```

- **Model**: `state` record (immutable)
- **View**: pure function `state -> vdom`
- **Update**: pure function `state -> msg -> state * cmd`

All logic is OCaml, type-checked at compile time. The component ships as a custom element (e.g. `<well-counter>`), usable from any HTML page including server-rendered MLX.

## Project layout & build

```
myapp/
├── web/
│   ├── dune                    # (executable (name register) (modes js) ...)
│   ├── <feature>.mlx           # one component per file (the module IS the component)
│   └── register.ml             # entry: Well_web.component calls + app.js bundle root
└── static/
    └── dune                    # rule copies ../web/register.bc.js → static/app.js
```

- `web/dune` compiles `register.ml` (and the listed component modules) to `register.bc.js` via **js_of_ocaml**.
- `static/dune` copies that to `/static/app.js` (single bundle).
- Load it on any page: `<script type="module" src="/static/app.js" />`.

### Adding a new component

1. Create `web/<feature>.mlx` (a `COMPONENT` module — see contract below).
2. In `web/register.ml`, add `Well_web.component ~module_:(module <Feature>) ~tag_name:"well-<feature>" ()`.
3. In `web/dune`, add the module name to `(modules register <feature> ...)`.
4. Rebuild. Use `<well-<feature>></well-<feature>>` on any page.

## The COMPONENT contract

Every component is a module (the file) implementing:

```ocaml
module type COMPONENT = sig
  type state                      (* immutable record; [@@deriving js] recommended *)
  type msg                        (* internal messages *)
  type emits                      (* declared outputs to parent *)

  val props  : msg Props.t        (* declared, typed inputs (attributes) *)
  val init   : dispatch:(msg -> unit) -> state * (msg, emits) Cmd.t
  val update : state -> msg -> state * (msg, emits) Cmd.t
  val view   : state -> (msg -> unit) -> Vdom.t -> Vdom.t
                                  (* 3rd arg = projected children from parent *)
end
```

Register it:
```ocaml
(* register.ml *)
let () =
  Well_web.component
    ~module_:(module Counter)
    ~tag_name:"well-counter"
    ?shadow_dom            (* optional, default false = light DOM (global CSS applies) *)
    ()
```

`Vdom` is the `Html` module re-exported — the same type used by server-rendered MLX, generic over `'msg` so handlers carry the component's message type.

### Structural rules (non-negotiable)

1. **File = module.** Do NOT nest `module Counter = struct ... end` inside the file. The file's top-level declarations ARE the component.
2. **Registration = top-level statement.** Use `let () = Well_web.component ...` in `register.ml`, not `let component = ...`.
3. **`module_` label has a trailing underscore** — `module` is an OCaml keyword.
4. **`view` takes 3 args:** `state`, `dispatch`, and `projected_children` (children passed in from the parent's HTML). If your component ignores projected children, name it `_children`.
5. **`state`/`msg`/`emits` are types declared at the top of the file**; OCaml infers them from `init`/`update`/`view`.

## Typed event handlers (Elm-style)

Handlers come from the `Html` module (re-exported as `Well_web.Vdom`):

```ocaml
type +'msg handler =
  | Msg of 'msg                        (* dispatch msg, ignore event *)
  | On_key of (string -> 'msg)         (* read event.key *)
  | On_value of (string -> 'msg)       (* read event.target.value *)
  | On_event of (Obj.t -> 'msg option) (* whole event, optional — generic fallback *)
```

### MLX desugaring

| MLX attribute | Handler variant | Value type |
|---|---|---|
| `on_click=EXPR` | `Msg EXPR` | bare `msg` value |
| `on_submit=EXPR` | `Msg EXPR` | `msg` |
| `on_blur=EXPR`, `on_focus=EXPR` | `Msg EXPR` | `msg` |
| `on_keydown=EXPR` | `On_key EXPR` | `string -> msg` (named function) |
| `on_keyup=EXPR`, `on_keypress=EXPR` | `On_key EXPR` | `string -> msg` |
| `on_input=EXPR`, `on_change=EXPR` | `On_value EXPR` | `string -> msg` |
| `on_<other>=EXPR` | `On_event EXPR` | `Obj.t -> msg option` |

```mlx
(* Known event with bare msg value — NO Some/None boilerplate *)
<button on_click=Increment>(txt "+")</button>

(* Known events extracting a string — named function *)
let handle_key k = if k = "Enter" then Save else NoOp
let handle_value v = SetName v

<input on_keydown=handle_key on_input=handle_value />

(* Generic fallback for unknown events — returns msg option *)
let on_wheel _ev = Some Scrolled
<div on_wheel=on_wheel>(txt "")</div>
```

### ⚠ MLX limitation (CRITICAL)

**Inline `fun` is NOT accepted as an attribute value.** Always name the handler first:

```mlx
(* WRONG — parse error *)
<button on_click=(fun _ -> Increment)>(txt "+")</button>

(* RIGHT — bare msg value or named handler *)
<button on_click=Increment>(txt "+")</button>
```

For `on_keydown`/`on_input` this means you MUST define `let handle_key k = ...` before using `on_keydown=handle_key`.

### Programmatic API (in `.ml` files without MLX)

```ocaml
let open Html in
element
  ~handlers:[ ("click", on_click Increment) ]
  ~text:"+"
  "button" ()
```

`Html.on_click : 'msg -> 'msg handler` is the `Msg` constructor.

## Props — typed inputs (attributes)

```ocaml
module Props : sig
  type 'msg decl
  type 'msg t = 'msg decl list
  val int    : string -> on:(int    -> 'msg) -> ?default:int    -> unit -> 'msg decl
  val float  : string -> on:(float  -> 'msg) -> ?default:float  -> unit -> 'msg decl
  val bool   : string -> on:(bool   -> 'msg) -> ?default:bool   -> unit -> 'msg decl
  val string : string -> on:(string -> 'msg) -> ?default:string -> unit -> 'msg decl
  val list   : string -> eq:('a -> 'a -> bool) -> on:('a list -> 'msg) -> 'msg decl
  val of_eq  : string -> eq:('a -> 'a -> bool) -> on:('a      -> 'msg) -> 'msg decl
end
```

The string is the HTML attribute name; the runtime parses the attribute value into the declared type and dispatches the `~on` message. No manual `JSON.parse` or string parsing in component code.

```ocaml
let props : msg Well_web.Props.t = [
  Well_web.Props.int "step" ~default:1 ~on:(fun v -> Set_step v);
]
```

In HTML: `<well-counter step="2"></well-counter>` → dispatches `Set_step 2` on connect.

## Cmd — effects going out

```ocaml
module Cmd : sig
  type ('msg, 'emits) t
  val none     : ('msg, 'emits) t
  val msg      : 'msg -> ('msg, 'emits) t
  val emit     : 'emits -> ('msg, 'emits) t
  val emit_dom : name:string -> ?detail:'a -> unit -> ('msg, 'emits) t
  val focus    : string -> ('msg, 'emits) t
  val batch    : ('msg, 'emits) t list -> ('msg, 'emits) t
  val perform  : (dispatch:('msg -> unit) -> unit) -> ('msg, 'emits) t
  val is_none  : ('msg, 'emits) t -> bool
end
```

- `Cmd.none` — no effect (the common case).
- `Cmd.emit (CountChanged n)` — typed emit → host `CustomEvent` **`well-emit`** with `detail = emits`. Parent may also use `Cmd.emit_dom ~name:"…"` for a specific event name.
- `Cmd.msg m` — schedule a self-message (async bus hop through EffectsManager → LoopManager).
- `Cmd.focus "selector"` — rAF + `querySelector` on host + `.focus()`.
- `Cmd.batch [c1; c2]` — run commands in order (nested OK).
- `Cmd.perform (fun ~dispatch -> …)` — general effect. Keep `update` pure; schedule XHR/timeout inside `perform` and `dispatch` completion msgs from callbacks:

```ocaml
| Submit ->
    ({ state with loading = true },
     Well_web.Cmd.perform (fun ~dispatch ->
       Http.post ~url ~fields ~on_done:(fun r -> dispatch (Got_result r))))
| Got_result r ->
    (* pure map result → state / Cmd.emit / Cmd.msg *)
```

`init`'s returned cmd is flushed after mount; `init ~dispatch` is a **live**
dispatch (not a no-op). Do not stash `dispatch` in a `ref` as the primary async
pattern — use `Cmd.perform`.

## Contract RPC from the browser (Proxy)

For service contracts, **use the generated OCaml browser Proxy** — do not hand-roll
`Http.get/post` or JSON wire under a contract.

- Generate: `well contract build` → `lib/contract/build/ocaml_browser/`
  (`rpc.ml` + per-service modules with `module Proxy`).
- Mirror of TS `Proxy` / `rpc.ts`: same `POST /rpc/<Service>/<method>`, same
  positional `to_wire`/`of_wire` arrays.
- Headers: `Content-Type: application/json`, `X-Requested-With: XMLHttpRequest`
  (Well CSRF middleware may skip token check for this header). Optional
  `X-CSRF-Token` from `<meta name="csrf-token">` or `window.__WELL_CSRF`
  (not `__DG_CSRF` — set meta/`__WELL_CSRF` if migrating DG).
- Callback is `(response, string) result`. **Always handle `Error`**: HTTP
  non-2xx, network failure, non-JSON body, Well service body
  `{"error":"..."}` on 2xx, and `of_wire` decode failures — all surface as
  `Error msg` (no uncaught exception into `Cmd.perform` / EffectsManager).
- Call site (inside `Cmd.perform`):

```ocaml
Cmd.perform (fun ~dispatch ->
  Security.Proxy.initiate_otp_login req ~on_done:(function
    | Ok resp -> dispatch (Got_ok resp)
    | Error msg -> dispatch (Got_err msg)))
```

Link the app jsoo executable against the generated `contract_browser` library
(and `yojson` / jsoo). Server in-process clients stay on `build/ocaml/`.

## emits — declared outputs

A typed variant listing what the component may emit up. This is the component's contract with its parent:

```ocaml
type emits = CountChanged of int | Reset
```

The parent listens (in shell HTML or a parent component) and reacts. Direction is **always up**; the component never reaches into the parent's state.

## Reference example: `web/counter.mlx`

```mlx
(* Counter — config-driven step counter.
   @input  step : int (default 1)
   @output CountChanged : int — new count after each change *)

type state = { count : int; step : int }
type msg = Increment | Decrement | Reset | Set_step of int
type emits = CountChanged of int

let props : msg Well_web.Props.t = [
  Well_web.Props.int "step" ~default:1 ~on:(fun v -> Set_step v);
]

let init ~dispatch:_ = ({ count = 0; step = 1 }, Well_web.Cmd.none)

let update state : msg -> state * (msg, emits) Well_web.Cmd.t = function
  | Increment ->
    let s = { state with count = state.count + state.step } in
    (s, Well_web.Cmd.emit (CountChanged s.count))
  | Decrement ->
    let s = { state with count = state.count - state.step } in
    (s, Well_web.Cmd.emit (CountChanged s.count))
  | Reset -> ({ count = 0; step = state.step }, Well_web.Cmd.none)
  | Set_step v -> ({ state with step = v }, Well_web.Cmd.none)

let view state _dispatch _children =
  let open Html in
  <div class'="counter" style="display:flex; gap:8px; align-items:center;">
    <button on_click=Decrement>(Html.txt "-")</button>
    <span class'="count" style="font-family:monospace; width:32px; text-align:center;">
      (Html.txt (string_of_int state.count))
    </span>
    <button on_click=Increment>(Html.txt "+")</button>
    <button on_click=Reset>(Html.txt "reset")</button>
  </div>
```

Register in `web/register.ml`:
```ocaml
let () =
  Well_web.component ~module_:(module Counter) ~tag_name:"well-counter" ()
```

Use on a page (`lib/pages/<x>_page.mlx`):
```mlx
Well.get "/counter" @@ fun _req ->
<Layout title="Counter">
  <well-counter step="2"></well-counter>
  <script attrs=[("type", "module"); ("src", "/static/app.js")] />
</Layout>
```

## MLX pitfalls

- **`class'`, not `class`** — `class` is reserved. `style` works bare.
- **Bare-string children are auto-wrapped** to `Html.txt`. For any other expression, wrap in parens: `(txt x)`, `(string_of_int n |> txt)`.
- **`(txt "")` for empty output** — there is no `empty` node. Use it in conditional else-branches.
- **`{...}` is record syntax ONLY** — not interpolation. Use `(expr)` for function calls.
- **No inline `fun` in attribute values** — name handlers first (see typed handlers above).

## Verification

After writing/changing a component:
```bash
dune build          # web/ → register.bc.js, then static/dune copies it to static/app.js
```
Open the page that embeds `<well-*>` and confirm the custom element renders and reacts to clicks/inputs.

## Companion skills

- **`well`** — backend: routes, models, services, LiveView (legacy), SQL.
- **`frontend-design`** — visual design quality when a component must look distinctive.
- **`idesign-architecture`** — decomposition (parent = Manager of state; this component = leaf with declared inputs/outputs).
