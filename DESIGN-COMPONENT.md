# Design: API runtime'u komponentów TEA (Faza 1 — decyzje wstępne)

> Kontynuacja `HANDOFF-FRONTEND.md`. Tu lądują decyzje projektowe API
> przyjęte w sesji 2026-07-07, zanim powstanie pełny spec (skill `/axe`)
> i spike toolchainu (Faza 0). Każda decyzja ma uzasadnienie — nie
> relitiguj bez powodu.

## Kontekst (w jednym akapicie)

Portujemy `stm` (TS, Preact) do OCaml: TEA (Model-View-Update) produkujące
Web Components (light DOM, atrybuty w dół, eventy w górę). Generyczność przez
first-class module. Plik `.mlx` = jeden komponent = jeden moduł OCaml.
Pełna intencja i historia w `HANDOFF-FRONTEND.md`.

## PODJĘTE DECYZJE (z uzasadnieniem)

### D1. Plik = moduł, bez wewnętrznego `module Counter = struct ... end`

Skoro konwencja to „jeden plik = jeden komponent", plik `.mlx` JEST już
modułem (`counter.mlx` → `Counter`). Zewnętrzna otoczka `module Counter =
struct ... end` jest duplikatem. Cała logika (state/msg/init/update/view)
żyje na poziomie pliku; rejestracja na dole odnosi się self-ref:
`(module Counter)`.

### D2. Rejestracja = top-level expression statement, nie `let () =`

```ocaml
component
  ~module_:(module Counter)
  ~tag_name:"well-counter"
  ~shadow_dom:false
  ~prop_types:[ "step", `Int ]
  ()
;;
```

`;;` zamiast `let () =` jest czytelniejsze przy celowym side-effect.
(`let () =` wymuszałoby typ `unit` — overkill, gdy `component` zwraca `unit`.)

### D3. Podział: moduł = logika, rejestracja = metadane ekspozycji

W module: `state`, `msg`, `init`, `update`, `view`, `attribute_change`
(wszytko sprzężone z abstrakcyjnymi typami state/msg — musi być w module).

W rejestracji: `tag_name`, `shadow_dom`, `prop_types` (czysta metadana o
ekspozycji w DOM, niezależna od logiki).

Bonus D3: ten sam moduł logiki można zarejestrować pod wieloma tagami
bez kopiowania:

```ocaml
component ~module_:(module Counter) ~tag_name:"well-counter" () ;;
component ~module_:(module Counter) ~tag_name:"well-readout" () ;;
```

### D4. `module` jest słowem kluczowym → etykieta `module_`

`(module X)` to first-class module; `~module:` się nie sparsuje. Etykieta
musi być `module_:` (z podkreślnikiem). Stały zgrzyt, akceptowany.

### D5. `__MODULE__` NIE działa — nazwa modułu musi być wpisana raz

`__MODULE__` rozwija się do **stringa** (`"Counter"`), nie do nazwy modułu.
`(module __MODULE__)` jest błędem typu. OCaml nie ma mechanizmu „zapakuj
bieżący moduł bez nazwania". Więc `Counter` powtarza się raz w
`~module_:(module Counter)`. Usunięcie tej jednej powtórki wymaga
preprocesora (dyrektywa `@@component` w MLX, emitująca
`(module <NazwaPliku>)`) — odłożone do Fazy 4 (meta-poziom dla AI).

### D6. `update` bez trailing `unit`

```ocaml
val update : state -> msg -> state * msg Cmd.t
```

Szkic z handoffa (`state -> msg -> unit -> ...`) był bez sensu — `update`
bierze (state, msg), nie trzeciego `unit`. Cukier `let update state = function`
zamiast `let update state msg = match msg with`.

### D7. `attribute_change` tuplowane, jeden stopień (NIE karrynowane)

> **⚠ UNIEWAŻNIONE przez D18.** Zachowane jako historia. Aktualny kształt:
> deklaratywne `props : msg Props.t` zastępuje `attribute_change`.

```ocaml
val attribute_change : string * string -> msg option
```

**Było (odrzucone):** `string -> string -> msg option` albo
`string -> (string -> msg) option` — zagnieżdżona funkcja bez wartości,
bo runtime i tak ma (name, value) naraz z DOM-u, nigdy nie woła „czy
obsługujesz ten name?" bez wartości.

Tuplowanie `string * string -> msg option` usuwa martwy stopień pośredni
i czyta się naturalnie:

```ocaml
let attribute_change = function
  | "step", v     -> Some (Set_step (try int_of_string v with _ -> 1))
  | "disabled", _ -> Some Set_disabled   (* atrybut-flaga też czytelny *)
  | _             -> None
```

Pole wymagane w `COMPONENT` (komponenty nie reagujące na atrybuty piszą
`let attribute_change _ = None`). Opcjonalność przez `(… -> msg option) option`
dałaby podwójne `Some` — brzydsze.

## `Cmd.t` — moduł z konstruktorami (D8)

> **⚠ ZMIENIONE przez D18.** `Cmd.t` jest teraz **dwuparametrowy**
> `('msg, 'emits) Cmd.t`, a `Cmd.emit` bierze typowany wariant `emits`,
> nie string. Poniższy szkic jest historyczny; aktualny w D18.

Port `Cmd<Msg>` z `state-mgr.ts:11-17`. Realizacja w TS (`runNext`, linia
123–165): `CombinedCmds` → batch, `['Focus', sel]` → rAF+querySelector+focus,
`Event` → dispatchEvent, reszta → `Promise.resolve(x).then(dispatch)`.

W OCaml wariant **prywatny**, ergonomiczne konstruktory (zamiast jawnego
pisania `Batch [Emit (...); ...]`):

```ocaml
module Cmd : sig
  type 'msg t

  val none  : 'msg t
  val msg   : 'msg -> 'msg t                              (* natychmiastowy kolejny cykl update *)
  val emit  : ?bubbles:bool -> ?detail:Yojson.t -> string -> 'msg t   (* CustomEvent w górę *)
  val focus : string -> 'msg t                            (* rAF + querySelector(sel).focus() *)
  val batch : 'msg t list -> 'msg t                       (* CombinedCmds *)
  val then_ : unit Js.promise -> (unit -> 'msg) -> 'msg t (* Promise<Msg> *)
end
```

Runtime mapuje 1:1 na `runNext`. `then_` to FFI do `Promise.resolve`
(Melange/jsoo mają tu czyste wsparcie — do potwierdzenia w spike Fazy 0).

## Event-w-górę: `Cmd.emit`, NIE hook (D9)

> **⚠ ZMIENIONE przez D18.** Semantyka (komponent jawnie decyduje, runtime
> nie emituje automatycznie) zostaje; API się zmienia — `Cmd.emit` bierze
> typowany wariant `emits`, nie string z detail.

Kod TS jest jednoznaczny — `Event` to osobny Cmd (`runNext`, linia 144).
Komponent **jawnie** decyduje, kiedy emitować, w `update`:

```ocaml
let update state = function
  | Increment ->
      let state = { state with count = state.count + state.step } in
      (state, Cmd.emit "counter-change" ~detail:(`Int state.count))
  | ...
```

Runtime **nie** emituje automatycznie po każdej zmianie state — bo wtedy
komponent traciłby kontrolę nad payloadem (a TS stm daje ją jawnie).

`Cmd.batch` rozwiązuje „emit + kolejny msg":

```ocaml
(state, Cmd.batch [ Cmd.emit "counter-change" ~detail:(`Int state.count)
                  ; Cmd.msg Save_to_server ])
```

## `prop_type` — prosty wariant (D10)

> **⚠ UNIEWAŻNIONE przez D18.** Osobny wariant `prop_type` niepotrzebny —
> typy siedzą w deklaracji `Props.t`. Zachowane jako historia.

TS: `String | Number | Object | Array | Boolean`. Ale light-DOM atrybut HTML
jest zawsze string — `Object`/`Array` mają sens tylko w props preact-custom-element,
nie jako wire format. Przycinamy do:

```ocaml
type prop_type = [ `String | `Int | `Float | `Bool ]
```

Default (atrybut nie w `prop_types`) = `String`. `Bool` = obecny/brak (jak
`disabled`), `Int`/`Float` = parse.

## Różnice względem TS `stm` (D11)

Trzy arg-pary, które przegapiliśmy w początkowym szkicu:

| | TS `stm` | Nasz port | Powód |
|---|---|---|---|
| **`update` arg** | `(state, msg, cmp, dispatch)` | `(state, msg)` | TS przekazuje `cmp` (ref do elementu) — tylko do skomplikowanych przypadków (focus zewnętrzny, pomiar DOM). Pomijamy; jeśli komponent musi dotknąć DOM, robi to przez `Cmd.focus` albo ref-callback (Faza 1). |
| **`init` arg** | `(dispatch, func)` gdzie `func` rejestruje `onRefChange` | `(dispatch)` | `onRefChange` służy do mierzenia wymiarów po mount. Pomijamy na start, dodamy jako `?on_ref_change` w lifecycle, jeśli spike pokaże potrzebę. |
| **`view` arg** | `(state, children)` | `(state, dispatch, children)` | **Trzymane**, ale rozszerzone o `dispatch` (TEA wymaga). Light-DOM children projektują się do komponentu jak slot — bez tego komponenty nie komponują się (Elm/TEA standard). |

## FINALNA SYGNATURA (stan po D18)

> Sekcje D7–D11 oraz D17 są **historyczne** (reprezentują postęp myślenia);
> zostały unieważnione przez D18. Patrz notki „unieważnione przez D18".

```ocaml
module type COMPONENT = sig
  type state
  type msg
  type emits
  val props  : msg Props.t                            (* deklaratywne wejścia; zastępuje attribute_change *)
  val init   : dispatch:(msg -> unit) -> state * (msg, emits) Cmd.t
  val update : state -> msg -> state * (msg, emits) Cmd.t
  val view   : state -> (msg -> unit) -> Vdom.t -> Vdom.t   (* 3. arg = projected children *)
end

val component :
  module_:(module COMPONENT) ->
  tag_name:string ->
  ?shadow_dom:bool ->                  (* default false = light DOM *)
  unit -> unit
```

## REFERENCYJNY PRZYKŁAD: `counter.mlx` (stan po D18)

```mlx
(** Counter — prosty licznik z konfigurowalnym krokiem.

    @input  step : int (default 1) — krok inkrementacji
    @output CountChanged : int — nowa wartość licznika po zmianie *)

open Well_web

type state = { count : int; step : int }
type msg =
  | Increment
  | Decrement
  | Reset
  | Set_step of int

(* deklarowane wyjścia — kontrakt IDesign *)
type emits = CountChanged of int

(* deklarowane wejścia — typowane, runtime rozstrzyga parsowanie *)
let props : msg Props.t =
  let open Props in [
    int "step" ~default:1 ~on:(fun v -> Set_step v);
  ]

let init ~dispatch:_ = ({ count = 0; step = 1 }, Cmd.none)

let update state : msg -> state * (msg, emits) Cmd.t = function
  | Increment  ->
      let state = { state with count = state.count + state.step } in
      (state, Cmd.emit (CountChanged state.count))
  | Decrement  ->
      let state = { state with count = state.count - state.step } in
      (state, Cmd.emit (CountChanged state.count))
  | Reset      -> ({ count = 0; step = state.step }, Cmd.none)
  | Set_step s -> ({ state with step = s }, Cmd.none)

(* view : state -> dispatch -> projected_children -> Vdom.t
   Counter ignoruje projected children (nic między <well-counter>...</well-counter>) *)
let view state dispatch _children =
  <div class'="flex gap-2 items-center">
    <button on_click=(fun _ -> dispatch Decrement)>"−"</button>
    <span class'="font-mono w-8 text-center">
      (txt (string_of_int state.count))
    </span>
    <button on_click=(fun _ -> dispatch Increment)>"+"</button>
    <button on_click=(fun _ -> dispatch Reset)>"reset"</button>
  </div>

component
  ~module_:(module Counter)
  ~tag_name:"well-counter"
  ~shadow_dom:false
  ()
;;
```

Użycie w HTML shella (rodzic = Manager stanu):

```html
<well-counter step="2"></well-counter>
<script>
  document.querySelector("well-counter")
    .addEventListener("counter-change", e => console.log("nowy:", e.detail));
</script>
```

## UWAGI DO DOPRECYZOWANIA W FAZIE 1 (spec)

1. **Event-handler w MLX (`on_click=...`) jeszcze nie istnieje.** Dzisiejsze
   `Html.tag` bierze `attrs:(string*string) list` — handler-funkcja nie
   przejdzie. To rozstrzyga decyzję (c) z handoffa (vdom vs string)
   **na korzyść vdom**: `view` musi zwracać `Vdom.t` (gdzie handler jest
   częścią node'a), żeby MLX `on_*` miało sens. Spike fazy 0 to potwierdzi.

2. **`{x}` w MLX to NIE interpolacja** — tylko record-expression.
   `<span>{state.count}</span>` to błąd; musi być
   `<span>(txt (string_of_int state.count))</span>`. Udokumentować w
   skillu `/well` dla AI-juniora.

3. **`Cmd` i `Vdom` jeszcze niezdefiniowane.** `Cmd.t`, `Cmd.none`,
   `Cmd.emit_event` (dla event-w-górę) — semantyka do sklonowania z
   `state-mgr.ts`. `Vdom.t` zależy od decyzji vdom (własny minimalny vs
   ocaml-vdom).

4. **`prop_type`** (`\`Int` etc.) — typ metadanych wire-format dla atrybutów.
   Prawdopodobnie mirror kontrakt-codegen, do powiązania z Fazy 3.

## D12 — Jeden app bundle, brak auto-detekcji DOM

- **Odrzucona** auto-detekcja `well-*` w DOM (skanowanie + MutationObserver
  = wolne i kruche, HTML nie jest na to gotowy).
- **Odrzucony** lazy-load per komponent (bez HTTP/2 = seryjne requesty).
- **Decyzja:** jeden bundle, serwowany statycznie. Ale rozdzielony na dwa
  pliki (patrz D13), nie auto-wykrywany.

## D13 — Podział artefaktów JS

- **`well.js`** — statyczny, serwowany razem z wellem (jak React/Lit z CDN).
  Zawiera:
  1. **Runtime TEA** (`component`, `Cmd`, `Vdom`) — nowość.
  2. **Channels** (WS `/ws`, `class ChannelInstance`, `on`/`push`/`leave`) —
     przejęte z obecnego `well.js`. **Warunek spełniony:** Channels są
     agnostyczne wobec wiadomości aplikacji (payload = opaque JSON,
     `on_push`/`on_join` to callbacki aplikacji — patrz D14).
  3. **MessageBus client** (część Channels — subscribe po stronie klienta).

  Brak LiveView (TEA go zastępuje).
- **`app.js`** — generowany z aplikacji well. Zawiera: proxy RPC (z
  `contract_codegen`) + wszystkie komponenty (kod wołający `component`).

Skutek: `well.js` cache'uje się długo (zmienia się tylko przy release
frameworka), `app.js` cache-bust per build. Strona wstawia:
```html
<script src="/static/well.js" defer>
<script src="/static/app.js" defer>
```
`well.js` pierwszy (definicja `component` musi być dostępna, gdy `app.js`
rejestruje komponenty).

## D14 — Channels: silnik w `well.js`, użycie typowane w `app.js`

Audyt `channel.ml` (210 linii) + `message_bus.ml` (247 linii) +
`static/well.ts` potwierdza, że Channels runtime jest wolny od wiedzy
o typach wiadomości aplikacji. Refinujemy podział:

- **`well.js` = silnik WS** (transport, nie wiedza domenowa):
  - połączenie `/ws`, keepalive, rate-limit
  - parsing frame'ów `{type, channel, event, payload}`
  - niskopoziomowe `channel(topic).push(event, opaque)` / `.on(event, cb)`
    / `.leave()` — payload jako opaque JSON
  - MessageBus routing (fan-out)

- **`app.js` = użycie channeli z typami** (na potem): opakowania typowane,
  np. `channel("notifications").on<Notification>("new", decodeNotification)`.
  Tu wchodzą znane aplikacji typy wiadomości.

Dla spike'a Fazy 0 ląduje w `well.js` **tylko silnik**. Typowane wrappery w
`app.js` to decyzja na później, gdy komponenty faktycznie będą chciały
subscribe'ować.

Dowód app-agnostyczności silnika:
- **Serwer:** payload = `Yojson.Safe.t` (opaque JSON). Framework definiuje
  `on_join`/`on_push` jako callbacki aplikacji (`channel.ml:11-28`).
  Runtime parsuje `{type, channel, event, payload}` → woła callback →
  fan-out przez MessageBus. Zero hardcoded event names, zero typów domenowych.
- **Klient:** `WellChannel` interface ma `payload: unknown` (`well.ts:20-24`).
- **MessageBus:** SQLite-backed pub/sub, opaque payload, wildcard matching.
  LiveView zależy od MessageBus, nie odwrotnie (grep `liveview|view|patch`
  w `message_bus.ml` = zero trafień).

Strukturalnie Channels (210 linii, czysty transport) to naturalny
ocalały z zastąpienia LiveView (900+ linii, view factory + state +
patching).

## D16 — vdom: pełna implementacja Elm-style (NIE html-string, NIE hybryda)

Decyzja z sesji 2026-07-07: „Trzeba to robić tak jak to robi ELM. Bez dwóch
zdań. I to musi być dobra implementacja i pełna."

- `view : state -> (msg -> unit) -> Vdom.t -> Vdom.t` — vdom z diff+patch
  (keyed-children diff jak Elm/Preact).
- **Odrzucona** Droga 2 (html-string + event delegation) — to jest model
  LiveView, który zastępujemy (string-diff = powód porażki).
- **Odrzucona** Droga 3 (full-rebuild light-DOM) — psuje focus/scroll/animacje.
- Runtime: pierwszy render → build DOM, kolejne update → diff+patch.
- Komponent-z dziecko **własny swój DOM** — parent vdom kontroluje tylko
  element + properties + projected children, NIE wnętrze dziecka.

## D17 — Typed properties (attributes vs properties, model Lit)

> **⚠ UNIEWAŻNIONE przez D18.** Intencja (typed values, Lit model) zostaje
> i jest zrealizowana przez deklaratywne `Props.t`. Szczegóły poniżej są
> historyczne; `prop_change`/`prop_value` nie istnieją w aktualnym API.

W vdom, właściwości komponentu to **wartości OCaml**, nie stringi.
`<well-button num=(42)/>` w vdom = węzeł z property `num = 42` (int).
Runtime robi `el.num = 42` (property na DOM), nie `setAttribute("num","42")`.
To jest model Lit: attributes (string, z HTML) vs properties (typowane, z vdom).

**API zmiana:** `attribute_change` → `prop_change`, wartości typowane:

```ocaml
type prop_value = [ `Int of int | `String of string | `Float of float | `Bool of bool ]
val prop_change : string * prop_value -> msg option
```

Handler pattern-matches na typowanych wartościach:

```ocaml
let prop_change = function
  | "num", `Int n      -> Some (Set_num n)
  | "step", `Int n     -> Some (Set_step n)
  | "disabled", `Bool b -> Some (Set_disabled b)
  | _ -> None
```

**`prop_types` podwójna rola:**
1. Deklaruje oczekiwane typy (dokumentacja, przyszły type-checking w MLX).
2. Runtime parsuje string-atrybuty z plain HTML (komponent użyty bez
   vdom-parenta, np. server-rendered) na typowane wartości **ZANIM** woła
   `prop_change`. Handler zawsze widzi typowane wartości.

**MLX implikacja:** `jsx_helper.ml` musi rozróżnić:
- `step="2"` (string literal) → atrybut (string), runtime parsuje via prop_types.
- `step=(expr)` (wyrażenie) → property (typowane, wrapped w `prop_value`).
- Tagi lowercase HTML (`<div>`, `<a>`): wszystko string-atrybuty (HTML semantics).
- Custom elements (`<well-*>`) / Capitalized (`<Well.Button>`): expr = property.

## D18 — Deklaratywny kontrakt: `Props.t` + `emits` jako wariant

Sesja 2026-07-07, przełomowa decyzja projektowa. Przechodzimy z modelu
*reaktywnego* (handler reaguje na `prop_change`) na **kontraktowy**: architekt
deklaruje wejścia i wyjścia upfront (IDesign Method), runtime egzekwuje.

**Unieważnia / zmienia:**
- **D7** (`attribute_change` tuplowane) — **ZASTĄPIONE** przez
  `props : msg Props.t`. Nazwa `attribute_change` znika z API.
- **D9** (`Cmd.emit "name" ~detail:...` z magicznym stringiem) — **ZASTĄPIONE**
  przez `Cmd.emit : 'emits -> cmd` — emit bierze typowany wariant `emits`.
- **D10** (`prop_type` wariant) — **ZASTĄPIONE** — typy siedzą w deklaracji
  `Props.t`, osobny wariant `prop_type` niepotrzebny.
- **D11** (`attribute_change` w sygnaturze COMPONENT) — aktualizacja poniżej.
- **COMPONENT** ma teraz **trzy** typy abstrakcyjne: `state`, `msg`, `emits`.
- **`Cmd.t`** staje się dwuparametrowy: `('msg, 'emits) Cmd.t`.

**Jedyny nieunikniony kompromis vs pierwotna koncepcja:** w OCaml typ wartości
nie przepływa przez pattern-match na "rodzaju" (List/String/Int). Dlatego typowany
handler `~on` ląduje **w deklaracji propa** (gdzie typ jest znany z annotacji
callbacka), a nie w jednej centralnej funkcji `attr_change`. To standardowy
wzorzec OCaml dla heterogenicznych typowanych deklaracji.

### `Props` — deklaratywne, typowane wejścia

```ocaml
module Props : sig
  type 'msg decl              (* egzystencjalny: ukrywa typ wartości, trzyma `on` *)
  type 'msg t = 'msg decl list

  (* primitives — eq wbudowane, parsują się z HTML stringa ORAZ z vdom *)
  val int    : string -> ?default:int    -> on:(int    -> 'msg) -> 'msg decl
  val float  : string -> ?default:float  -> on:(float  -> 'msg) -> 'msg decl
  val bool   : string -> ?default:bool   -> on:(bool   -> 'msg) -> 'msg decl
  val string : string -> ?default:string -> on:(string -> 'msg) -> 'msg decl

  (* złożone — property-only (tylko z vdom-source; nie z plain HTML) *)
  val list   : string -> eq:('a -> 'a -> bool) -> on:('a list -> 'msg) -> 'msg decl
  val of_eq  : string -> eq:('a -> 'a -> bool) -> on:('a      -> 'msg) -> 'msg decl
end
```

Runtime zachowanie:
- Dostał typed value z vdom → woła `on v` z typowaną wartością.
- Dostał string z HTML → parsuje (wg declared kind) → woła `on parsed`.
- Handler **zawsze** widzi typowaną wartość. Dwie gałęzie List/String znikają
  — runtime rozstrzyga sam z deklaracji.

Non-primitives (`list`, `of_eq`) są property-only: atrybut HTML jest zawsze
string, nie da się przekazać `todo list` przez plain HTML. `int`/`string`/`bool`/
`float` mogą przyjść z obu źródeł. Model Lit (attributes vs properties).

### `Cmd` — dwuparametrowy (type-safe emit)

```ocaml
module Cmd : sig
  type ('msg, 'emits) t
  val none  : ('msg, 'emits) t
  val msg   : 'msg -> ('msg, 'emits) t
  val emit  : 'emits -> ('msg, 'emits) t     (* type-safe: wymaga konstruktora z `emits` *)
  val batch : ('msg, 'emits) t list -> ('msg, 'emits) t
  val focus : string -> ('msg, 'emits) t
end
```

`Cmd.emit (Renamed "Hello")` czyta się jak zdanie. Nie da się wyemitować
nazwy, której nie ma w `emits` — kompilator pilnuje.

### Zaktualizowana sygnatura `COMPONENT` (TRZY typy abstrakcyjne)

```ocaml
module type COMPONENT = sig
  type state
  type msg
  type emits
  val props  : msg Props.t                            (* ZASTĘPUJE attribute_change *)
  val init   : dispatch:(msg -> unit) -> state * (msg, emits) Cmd.t
  val update : state -> msg -> state * (msg, emits) Cmd.t
  val view   : state -> (msg -> unit) -> Vdom.t -> Vdom.t
end

val component :
  module_:(module COMPONENT) ->
  tag_name:string ->
  ?shadow_dom:bool ->
  unit -> unit
```

`prop_types` **znika** z `component` — typy siedzą w `props`.

### Referencyjny `todo_list.mlx` (kompletny kontrakt)

```mlx
open Well_web

(* ── domena ── *)
type todo = { title : string; done : bool } [@@deriving eq]
(* equal_todo : todo -> todo -> bool  — za darmo z deriving eq *)

(* ── msg: wewnętrzne wiadomości ── *)
type msg =
  | TodosUpdate of todo list
  | Set_step of int
  | Click

(* ── emits: deklarowane wyjścia (kontrakt IDesign) ── *)
type emits =
  | TodoChanged of todo list
  | Renamed of string

(* ── Kontrakt wejść: deklaracyjne, typowane ── *)
let props : msg Props.t =
  let open Props in [
    list "todos" ~eq:equal_todo
      ~on:(fun (v : todo list) -> TodosUpdate v);
    int  "step"  ~default:1
      ~on:(fun v -> Set_step v);
  ]

type state = { items : todo list; step : int }

let init ~dispatch:_ = ({ items = []; step = 1 }, Cmd.none)

let update state : msg -> state * (msg, emits) Cmd.t = function
  | TodosUpdate t -> ({ state with items = t }, Cmd.none)
  | Set_step n    -> ({ state with step = n }, Cmd.none)
  | Click         -> (state, Cmd.emit (Renamed "Hello"))

let view state dispatch _children = <div></div>

component
  ~module_:(module TodoList)
  ~tag_name:"well-todo-list"
  ()
;;
```

Dokumentacja kontraktu na górze pliku (doc comment) — architekt pisze:

```mlx
(** TodoList — lista zadań z konfigurowalnym krokiem.

    @input  todos : todo list — pełna lista zadań (vdom property)
    @input  step  : int (default 1) — krok paginacji
    @output TodoChanged : todo list — emit gdy użytkownik zmieni zawartość
    @output Renamed     : string    — emit gdy zmieniono nazwę listy *)
```

AI-junior wypełnia kod wg kontraktu; architekt weryfikuje wejścia/wyjścia
z samej deklaracji `props` + `type emits`.

# SPIKE FAZY 0 — wyniki (sesja 2026-07-07)

Zbudowano `lib/well_web/` z czterema executables-ami `(modes js)` przez
js_of_ocaml 6.2.0 (dune pkg, pin `(= 6.2.0)` w dune-project). Artefakty:
`hello.ml` (czysty), `spike_mlx.mlx` (dialet MLX), `spike_stack.ml`
(sourcemap test), `spike.html` (test w przeglądarce). Wszystkie budują
się do `_build/default/lib/well_web/*.bc.js` (~21MB — jsoo runtime + stdlib).

## ✅ POTWIERDZONE (cele spajka osiągnięte)

### S1. js_of_ocaml kompiluje OCaml → JS w build graph well
- Dodano `(js_of_ocaml (= 6.2.0))` + compiler + ppx do `dune-project`.
- `dune pkg lock` synchronizuje lockfile (jsoo pkgs lądują w `dune.lock/`).
- `(executable (modes js))` produkuje `.bc.js`. Build całości (`dune build @all`)
  przechodzi po zmianie lockfile.

### S2. MLX współistnieje z jsoo bez modyfikacji (NAJWAŻNIEJSZE)
- `spike_mlx.mlx` → `spike_mlx.bc.js` buduje się bez błędów (tylko istniejące
  ostrzeżenia menhir w `well_mlx_pp`).
- **Potwierdzone w Chrome** (agent-browser): `<hello-mlx>` renderuje
  "Hello from MLX via jsoo!", zero błędów w konsoli.
- **D15 (js_of_ocaml zamiast Melange) jest pełnie uzasadnione** — MLX
  działa bez kompromisów, dokładnie jak przewidział D15.

### S3. Custom element round-tripuje w przeglądarce
- `hello.ml` rejestruje `<hello-world>` przez `Js.Unsafe.eval_string`
  (zwykły string, nie `{js|...|js}` — patrz S5).
- **Potwierdzone w Chrome**: `<hello-world>` renderuje
  "Hello from OCaml!", zero błędów.

### S4. Sourcemap jest generowany (inline, base64)
- Artefakt zawiera `//# sourceMappingURL=data:application/json;base64,...`.
- Mapuje pozycje JS na nazwy plików OCaml (stdlib, jslib, runtime jsoo).
- Wymaga `(env (byte (flags :standard -g)))` w dune (debug info w bytecodzie).

## ⚠ ODKRYTE OGRANICZENIA (na które musimy uważać w Fazie 1)

### S5. `{js|...|js}` quasiquotation NIE działa pod dune pkg

`js_of_ocaml-ppx` jest zainstalowane, ale quasiquotation `{js|...|js}` rzuca
`Error: String literal not terminated`. `dune describe pp` potwierdza — ppx
się nie aplikuje. **Obejście:** używać zwykłych stringów OCaml z `Js.Unsafe.eval_string`
(czyli to, co dziś działa w spajku). Typowane FFI (##, ppx) wymaga diagnozy
w Fazie 1. **Hipoteza:** dune pkg buduje ppx z `.pkg` źródeł, a build driver
nie rejestruje quasiq poprawnie; albo trzeba `js_of_ocaml.deriving` zamiast
`{js|...|js}`.

### S6. OCaml backtrace NIE jest dostępny w runtime (REALNY LIMIT)

**To jest najważniejsze odkrycie spajka.** jsoo domyślnie NIE zachowuje
OCaml backtrace:
- Wyjątek OCaml `Failure "boom"` jest rzucany jako JS tablica
  `[0, 248, "Failure", -3, "boom from spike_stack.ml"]` — nie jest to JS `Error`,
  nie ma `.stack`, `.message`.
- `Printexc.record_backtrace true` + `Printexc.get_backtrace()` zwraca pusty
  string — jsoo runtime nie implementuje `caml_record_backtrace`/`get_backtrace`
  (grep w artefakcie: zero trafień).
- Uncaught exception drukuje tylko `Fatal error: exception Failure("...")`
  — bez pliku, bez funkcji.

**Konsekwencja dla D15/D9:** Twoje wymaganie (wyjątek → nazwa funkcji → AI
debuguje) **NIE jest zaspokojone** domyślnie. Trzeba jedna z trzech dróg
w Fazie 1:

1. **Wrapować wszystkie Cmd w try/catch** z JS `Error.captureStackTrace`
   — w runtime TEA, każdy dispatch otaczamy `try ... with e -> Error.captureStackTrace(...)`.
   Stack będzie zawierał JS-owe ramki jsoo, które sourcemap remapuje na .ml.
   Koszt: narzut na każdy dispatch.
2. **`--enable-source-maps` + `--pretty` w jsoo** + wyłapywanie **uncaught**
   exception w runtime (nie per-dispatch). Stack z uncaught ma więcej info
   niż caught. Ale to nie rozwiązuje per-funkcji debug.
3. **Custom error reporting** — runtime TEA ma własny `failwith`-wrapper,
   który łapie OCaml exn, ekstraktuje wiadomość (z tablicy `[0,248,"Failure",...,msg]`)
   i wrapuje w JS Error z message. Stack nadal bez OCaml nazw, ale przynajmniej
   wiadomość wyjątku dociera czytelnie.

**Moja rekomendacja:** opcja 3 na start (wiadomość + sourcemap dla lokalizacji
plików), opcja 1 jeśli AI-junior potrzebuje nazwy funkcji. Do rozstrzygnięcia
w Fazie 1.

### S6-resolved. Decyzja Solution Architekta: msg log + sourcemap bet

**Rozstrzygnięto (2026-07-08):** akceptujemy brak OCaml backtrace jako
limit jsoo na dziś. Strategia debug:
- **Pełny log msg** w runtime TEA — każdy dispatch loguje msg. Mając
  sekwencję msg, łatwo dojść co się dzieje (to nasza kontrola).
- **Sourcemap** dla lokalizacji plików (zachowane, S4).
- **Bet:** jsoo w końcu doda backtrace (standardowy feature, aktywnie
  rozwijany projekt — 6.4.1 czerwiec 2026).

**S6 nie blokuje już D9/Cmd.** Idziemy dalej bez per-dispatch wrapper.
Runtime TEA (Faza 2) ma po prostu logować msg — to wystarczy AI-juniorowi.

### S7. FFI typowane (##) jeszcze nie testowane

`Js.Unsafe.eval_string` działa, ale to omija sprawdzenie typowanego FFI jsoo
(`Js.t < ... >`, operator `##`, `%js` ppx). To jest istotne dla runtime'u Vdom
(handler zdarzeń, requestAnimationFrame, CustomEvent). **Spike nie potwierdza,
że typowane FFI działa** — wymaga osobnego testu w Fazie 1. Hipoteza: działa,
bo jsoo jest standardowo kompilowany i typowane FFI to core feature, ale
ppx (S5) może stwarzać problemy.

### S7-resolved. Typowane FFI działa — S5 był węższy niż myślane

Spike S7 (`lib/well_web/spike_ffi.ml`) **potwierdza, że typowane FFI
działa pełnie** pod dune pkg. Zbudowano i przetestowano w Chrome:
`<ffi-test>` renderuje "FFI typed works!" przez `el##.textContent :=`,
emituje `ffi-ready` CustomEvent z yojson payloadem, `requestAnimationFrame`
round-tripuje.

**Co działa (klucz dla runtime'u TEA Fazy 2):**
- `Js.t < ... >` typed interfaces (object types z `Js.prop`, `Js.meth`,
  `Js.readonly_prop`).
- `##` (method call), `##.` (property read), `##.x := v` (property write —
  uwaga: `:=` NIE `<-`; to był mój wczesny błąd).
- `Js.wrap_callback : ('a -> 'b) -> ('c, 'a -> 'b) meth_callback` —
  do przekazywania OCaml closures jako JS callbacks (np. rAF handler).
- `Js.Unsafe.inject` (do top), `Js.Unsafe.coerce`, `Js.Unsafe.meth_call`,
  `Js.Unsafe.new_obj`, `Js.Unsafe.obj` — dla JS constructs bez typowanego
  interface (CustomEvent constructor, dispatchEvent na Unsafe.top).
- `Js.Opt.to_option` dla nullable returns (`querySelector`).

**Korekta S5:** S5 nie jest „ppx jsoo nie działa pod dune pkg". Dokładniej:
- `{js|...|js}` quasiquotation **nadal nie działa** (S5 prawdziwe dla tego
  konkretnego constructu).
- Ale `##`/`##.`/`Js.t` **działają**, **pod warunkiem** że `(preprocess
  (pps js_of_ocaml-ppx))` jest w **executable** stanza — nie dziedziczy
  się automatycznie z library. To był mój błąd konfiguracji dune.

**Konsekwencje dla Faz 1+2:**
1. **Runtime TEA może używać typowanego FFI** (`##`, `Js.t`) zamiast
   `Js.Unsafe.eval_string`. To czystsze i type-safe.
2. **Każdy executable musi mieć `(preprocess (pps js_of_ocaml-ppx))`** —
   to stipulate w dune template dla komponentów aplikacji.
3. **CustomEvent constructor:** przez `Js.Unsafe.new_obj` z
   `Js.Unsafe.obj [| "detail", inject v |]` jako options. Nie da się
   czysto typować (JS `new` z options object).
4. **Yojson w jsoo** reprezentuje `` `Assoc [...] `` jako wewnętrzną tablicę
   `[0, hash, [...]]`, nie JS object. **Payload CustomEvent.detail przez
   yojson nie będzie czytelnym JS obiektem** — do rozstrzygnięcia w Fazie 1
   czy emit używa yojson (OCaml-side) czy konwersji do JS object (JS-side).

## KONSEKWENCJE DLA FAZY 1 (zaktualizowane)

- **D15 potwierdzone** — js_of_ocaml + MLX działa. Idziemy tym kierunkiem.
- **D16 (vdom) wymaga S6-resolve'** — bez backtrace debug vdom-u będzie trudny.
- **S5 (ppx quasiq)** — na start używamy `Js.Unsafe.eval_string` z stringami;
  typowane FFI to osobny mini-spike w Fazie 1.
- **S6 (backtrace)** — do rozstrzygnięcia z Solution Architektem: opcja 1 vs 3
  zanim zbudujemy runtime. **To blokuje D9 (Cmd) — bo Cmd.then_ używa Promise,
  który musi mieć czytelne stack trace przy reject.**

## STATUS DECYZJI (sesja 2026-07-07)

**Rozstrzygnięte:**
- (a) Melange vs js_of_ocaml → **js_of_ocaml (D15)**.
- (c) vdom vs html-string → **vdom Elm-style (D16)**.
- Props/attribute_change → **deklaratywne `Props.t` (D18)** — unieważnia D7, D9, D10, D11.
- Event-w-górę → **`Cmd.emit : emits -> cmd` type-safe (D18)** — unieważnia D9.

**W toku (czeka na Fazę 0):**
- (b) First-class module vs functor — **D1 przyjmuje first-class**, odwrócić
  tylko jeśli spike pokaże problem z interopem.
- (d) SSR/hydratacja — Counter jest client-only, ale API nie blokuje SSR
  (`view` da się wołać po stronie serwera przez to samo Html/Vdom).
- (e) Expressiveness properties — D18 rezerwuje `Props.list`/`of_eq` dla
  złożonych typów (eq-based). Pełna moc OCaml (rekordy, funkcje jako props)
  — do oceny gdy realny komponent zgłosi potrzebę.

## D15 — js_of_ocaml (NIE Melange)

Decyzja z sesji 2026-07-07, po badaniu OSS.

**Wybór: js_of_ocaml** (najnowszy: `6.4.1`, czerwiec 2026).

**Dealbreaker dla Melange:** Melange kompiluje OCaml własnym frontendem,
nie ma gwarancji, że dialekt **MLX** (który well już ma, `(dialect (name mlx))`
w `dune-project`, preprocessowany przez `well-mlx-pp`) przejdzie przez
Melange. Skoro konwencja to `web/*.mlx` (D — ustalone ustnie), Melange
wymagałby osobnego udowodnienia interoperacyjności MLX. js_of_ocaml
kompiluje standardowy bytecode → **MLX działa bez modyfikacji** (dialekt to
preprocesor AST, upstream od jsoo).

**Powody ZA js_of_ocaml:**
1. **MLX działa bez kompromisów** — najważniejsze.
2. **OCaml 5.4 wspierany** w 6.4.x — brak tarcia wersyjnego (well na 5.4).
3. **Sourcemap** (poprawiony w 5.9.0/6.x) zaspokaja wymaganie AI-debug:
   wyjątek → stack trace → nazwa funkcji OCaml przez sourcemap → AI widzi
   plik OCaml, nie JS. Czytelność outputu per se nie ma znaczenia dla
   AI-juniora.
4. **Cała libgraph OCaml dostępna** — `eio`, `yojson` mogą być współdzielone
   między serwerem a klientem (gdyby zaszła potrzeba SSR/hydratacji).
5. **Współistnieje z JS-owym silnikiem Channels** bez przepisywania
   (`--extern-js`), co pozwala inkrementalną migrację.

**Powód ODRZUCONY (Melange):** „czytelny JS output" traci znaczenie, bo AI
nie musi czytać JS-a — tylko dostać stack trace z nazwą funkcji, a sourcemap
js_of_ocaml to daje.

## ROZSTRZYGNIĘTE W SESJI 2026-07-07 (D8–D11, dopięte po lekturze state-mgr.ts)

- **D8.** `Cmd.t` = moduł z konstruktorami (`none`/`msg`/`emit`/`focus`/
  `batch`/`then_`), wariant prywatny. Port `Cmd<Msg>` z `state-mgr.ts:11-17`.
- **D9.** Event-w-górę przez `Cmd.emit` — komponent jawnie decyduje,
  runtime nie emituje automatycznie.
- **D10.** `prop_type` = `[ `String | `Int | `Float | `Bool ]`
  (przycięte z TS, które miało `Object`/`Array` bez sensu w light-DOM).
- **D11.** Trzy różnice względem TS: pominięto `cmp` w `update` i
  `onRefChange` w `init`; `view` dostała `dispatch` i zachowała
  projected `children` jako trzeci arg.
