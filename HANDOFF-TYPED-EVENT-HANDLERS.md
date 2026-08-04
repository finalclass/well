# Handoff: Typed Event Handlers dla unified vdom (Elm-style convenience)

> **Kontekst:** Ten dokument jest instrukcją startową dla zmiany w warstwie
> event handlerów unifikacji vdom (już zmergowanej na `master`).
> Cel: wprowadzić **typowane, wygodne handlery** (jak Elm) zamiast obecnego
> generycznego `'msg handler = Obj.t -> 'msg option`, który wymaga `Some Msg`
> boilerplate nawet dla najprostszego `on_click`.
> **Najważniejsza zasada:** po tej zmianie `on_click=Increment` (msg value,
> bez `Some`) musi działać w MLX, a istniejący kod zmergowany na `master`
> (counter.mlx, counter_test.ml, rendering.ml) musi zostać zmigrowany.

## 0. Stan obecny (po unifikacji vdom na masterze)

Zunifikowany vdom jest już na `master` (commits `fb9c40c`, `2948d01`, `108d237`).
Typ handlera dziś:

```ocaml
(* lib/well_html/html.ml *)
type 'msg handler = Obj.t -> 'msg option
```

To zmusza każdy handler (nawet `on_click`) do:
```ocaml
let dec _ = Some Decrement in
<button on_click=dec>(Html.txt "-")</button>
```

To jest boilerplate. Elm tego nie robi — `onClick : msg -> Attribute msg`.
Ten handoff wprowadza Elm-style typed handlers.

## 1. Stan docelowy

### Typ handlera (wariant)

W `lib/well_html/html.ml` zmień `type 'msg handler` z funkcji na wariant:

```ocaml
type 'msg handler =
  | Msg of 'msg                        (* dispatch msg, ignore event — on_click *)
  | On_key of (string -> 'msg)         (* wyciągnij event.key — on_keydown/keyup/press *)
  | On_value of (string -> 'msg)       (* wyciągnij event.target.value — on_input/change *)
  | On_event of (Obj.t -> 'msg option) (* cały event, optional — generic on / unknown events *)
  | None                               (* nigdy nie dispatch *)
```

**Kluczowa zasada:** ZNANE eventy są specjalizowane (wyciągają odpowiedni
kawałek z eventu). Generyczne/nieznane eventy idą przez `On_event` z całym
eventem.

### MLX desugaring (ZNANE → specjalne, reszta → generic)

`jsx_helper.ml` musi mapować atrybuty `on_*` na odpowiedni wariant handlera:

| MLX atrybut | Desugar do | Typ expr w MLX |
|---|---|---|
| `on_click=EXPR` | `("click", Msg EXPR)` | `'msg` (msg value) |
| `on_keydown=EXPR` | `("keydown", On_key EXPR)` | `string -> 'msg` |
| `on_keyup=EXPR` | `("keyup", On_key EXPR)` | `string -> 'msg` |
| `on_keypress=EXPR` | `("keypress", On_key EXPR)` | `string -> 'msg` |
| `on_input=EXPR` | `("input", On_value EXPR)` | `string -> 'msg` |
| `on_change=EXPR` | `("change", On_value EXPR)` | `string -> 'msg` |
| `on_submit=EXPR` | `("submit", Msg EXPR)` | `'msg` (submit nie ma value/key) |
| `on_blur=EXPR` | `("blur", Msg EXPR)` | `'msg` |
| `on_focus=EXPR` | `("focus", Msg EXPR)` | `'msg` |
| `on_<inne>=EXPR` | `("<inne>", On_event EXPR)` | `Obj.t -> 'msg option` |

**Klasyfikacja:**
- **Msg-only** (ignore event): `on_click`, `on_submit`, `on_blur`, `on_focus`,
  i wszystkie inne "akcyjne" eventy bez value/key.
- **On_key**: `on_keydown`, `on_keyup`, `on_keypress`.
- **On_value**: `on_input`, `on_change`.
- **On_event (fallback)**: wszystko inne (`on_wheel`, `on_scroll`,
  `on_custom_thing`, ...).

Lista ZNANYCH eventów jest jawnie zakodowana w `jsx_helper.ml` (asocjacja
`attr_name → wariant`). Nieznane eventy → `On_event`.

### Programmatic API (`.ml` bez MLX)

Programowe budowanie handlerów (dla kodu bez MLX) potrzebuje konstruktorów:

```ocaml
(* well.html — convenience constructors *)
val on_click : 'msg -> 'msg handler                 (* = Msg *)
val on_key : string -> 'msg -> 'msg handler         (* specific key match, helper)
                                                          albo zostaw Msg + helper w kodzie *)
val on_value : (string -> 'msg) -> 'msg handler     (* = On_value *)
val on_event : string -> (Obj.t -> 'msg option) -> 'msg handler
```

(Precyzyjny kształt convenience API do ustalenia — ważne że programowy kod też
jest wygodny, nie tylko MLX.)

## 2. Mechanizm działania

### A. rendering.ml (frontend) — interpretacja wariantu

`attach_listener` musi rozpakować wariant i wyciągnąć odpowiedni kawałek z
eventu:

```ocaml
let attach_listener dispatch node (name, handler) =
  let cb ev =
    let msg_opt =
      match handler with
      | Msg msg -> Some msg
      | On_key f -> Some (f (Bridge.event_key ev))
      | On_value f -> Some (f (Bridge.event_value ev))
      | On_event f -> f (Obj.repr ev)
      | None -> None
    in
    (match msg_opt with
     | Some msg -> dispatch (Obj.repr msg)
     | None -> ())
  in
  Bridge.add_event_listener node ~event_name:name (Bridge.fn1 cb)
```

**Wymaga nowych FFI w Bridge:**
- `Bridge.event_key : event -> string` — czyta `event.key` (np. "Enter").
- `Bridge.event_value : event -> string` — czyta `event.target.value`.

Zaimplementować w `lib/well_web/bridge/bridge.ml`/`.mli` (jsoo FFI do JS event).
Sprawdzić czy `Bridge.event` ma już dostęp do target/key — jeśli nie, dodać.

### B. jsx_helper.ml — desugaring

Obecny desugaring (po unifikacji vdom) traktuje wszystkie `on_*` tak samo:
routuje do `~handlers:[("click", expr)]` gdzie expr to funkcja. Trzeba zmienić:
dla każdego ZNANEGO event owrapować expr w odpowiedni konstruktor wariantu
(`Msg`, `On_key`, `On_value`), a dla nieznanych zostawić jako `On_event`.

**Implementacja:** jawnie zakodowana tabela `known_handlers : (string, variant_kind) list`
w `jsx_helper.ml`. `attr_name` (po strip `on_` prefix) lookup w tabeli.
Domyślnie `On_event`.

### C. well.html — typ + konstruktory

Typ `handler` z funkcji → wariant. `on_click`/`on_event`/etc. konstruktory.
`element`/`void_element` podpis bez zmian (`handlers : (string * 'msg handler) list`).

### D. Migracja istniejącego kodu

Po zmianie typu handlera, wszystkie miejsca używające handlera jako funkcji
(`Obj.t -> 'msg option`) przestaną się kompilować. Zmigrować:
- `lib/well_web/test_e2e_counter/counter_test.ml` — `on_click Decrement` (Msg).
- `lib/well_cli/template.ml` → `web/counter.mlx` — `on_click=Decrement` (Msg, MLX).
- `lib/well_web/rendering.ml` — `attach_listener` (powyżej).
- `test/mlx_syntax_test/mlx_syntax_test.mlx` — test handlerów.
- `lib/well_web/component_access/component_access.ml` — re-export handlera.

## 3. Ograniczenie MLX (KRYTYCZNE — sprawdź empirycznie)

Wartość atrybutu MLX **nie akceptuje inline `fun`**. Już zweryfikowane
(`./_build/default/lib/well_mlx_pp/pp.exe`):

```
OK   | <div on_click=Increment />
OK   | <div on_click=(Increment) />
OK   | <div on_keydown=handler />          (named handler)
OK   | <div on_change=handler />           (named handler)
OK   | <div on_change=(fun ev -> ...) />   (parenthesized inline fun)
FAIL | <div on_change=fun ev -> ... />     (bare fun — needs parens)
```

Zatem w MLX:
- `on_click=Msg` — działa (msg value).
- `on_keydown=handle_key` — działa (named function `string -> 'msg`).
- `on_keydown=(fun k -> ...)` — działa (nawiasowany `expr` w atrybucie).

**Zalecenie dla agenta:** po zmianie `jsx_helper.ml`, PRZED migracją scaffolda,
przetestuj empirycznie przez `pp.exe` że docelowe formy MLX faktycznie
parse'ują. Nie ufaj teoretyzowaniu — gramatyka MLX ma ograniczenia.

Przykład testu:
```bash
printf 'let v = <div on_click=Increment on_keydown=h on_input=v_h />' > /tmp/t.mlx
./_build/default/lib/well_mlx_pp/pp.exe /tmp/t.mlx  # exit 0?
```

## 4. Kompletny przykład docelowy (MLX)

```mlx
type msg = Increment | SetName of string | Save
let handle_key k = if k = "Enter" then Save else (* no-op; None nie możliwe dla On_key... *)
  (* UWAGA: On_key to string -> 'msg, nie option. Jeśli "ignoruj" potrzebny,
     użyj On_event z msg option. Patrz sekcja 5. *)
  Increment  (* placeholder — patrz open question niżej *)
let handle_value v = SetName v

let view : msg Html.node =
  <div on_click=Increment>
    <input on_input=handle_value on_keydown=handle_key />
    <button on_click=Save>(Html.txt "save")</button>
  </div>
```

Counter — czysty, zero boilerplate:
```mlx
let view state _dispatch _children : msg Html.node =
  let count_txt = string_of_int state.count in
  <div style="display:flex; gap:8px; align-items:center;">
    <button on_click=Decrement>(Html.txt "-")</button>
    <span style="font-family:monospace; width:32px; text-align:center;" class'="count">(Html.txt count_txt)</span>
    <button on_click=Increment>(Html.txt "+")</button>
    <button on_click=Reset>(Html.txt "reset")</button>
  </div>
```

## 5. Open questions (DO ARCHITEKTA — przed implementacją)

### Q1: Jak "zignorować" w On_key / On_value?

`On_key : (string -> 'msg)` i `On_value : (string -> 'msg)` **zawsze** dispatch'ują
(po wyciągnięciu key/value). Nie ma ścieżki None. Jeśli użytkownik chce
"tylko Enter" w on_keydown, musi:
- (a) użyć `On_event` (`Obj.t -> 'msg option`) zamiast `On_key`, ALBO
- (b) wprowadzić msg `NoOp` i dispatchować go, ALBO
- (c) zmienić typ na `(string -> 'msg option)` (ale to psuje prostotę).

**Rekomendacja agenta do ustalenia z architektem.** Elm rozwiązuje to przez
`Json.Decode` (decoder fail = brak dispatch). well może dodać `On_key_match`:
`On_key of (string -> 'msg option)` — optional. Ale wtedy `on_click=Msg`
(simple) vs `on_keydown=(fun k -> Some ...)` (optional) — niespójne.
Pytanie: czy On_key/On_value powinny być `option` czy nie?

### Q2: Lista ZNANYCH eventów

Powyższa tabela to propozycja. Architekt potwierdź pełną listę:
- Msg-only: click, submit, blur, focus, ... (które jeszcze? dblclick?)
- On_key: keydown, keyup, keypress.
- On_value: input, change.

Czy są inne kategorie? (np. `on_scroll` z `number`? `on_mouse_move` z coords?)
Domyślnie wszystko poza wymienionymi → On_event.

### Q3: Programowe convenience API

Dla kodu `.ml` (bez MLX): czy `Html.on_click : 'msg -> 'msg handler` wystarcza,
czy trzeba pełnego zestawu (`on_keydown`, `on_input`, ...)? Zostawić
konstruktory wariantu (`Msg`, `On_key`...) jako publiczne, czy tylko
convenience wrappers?

## 6. Zakres prac (kolejność sugerowana)

1. **`lib/well_web/bridge/`** — dodaj `event_key`, `event_value` FFI (jsoo).
   Weryfikuj przez istniejące testy bridge'a / spike.
2. **`lib/well_html/html.ml`** — typ `handler` → wariant; konstruktory
   `on_click`/`on_value`/`on_event`.
3. **`lib/well_mlx_pp/jsx_helper.ml`** — tabela ZNANYCH eventów; desugaring
   `on_*` → odpowiedni wariant. **Testuj `pp.exe` empirycznie.**
4. **`lib/well_web/rendering.ml`** — `attach_listener` interpretuje wariant.
5. **Migracja:** `counter.mlx` (scaffold), `counter_test.ml`, `mlx_syntax_test.mlx`,
   `component_access` re-exports.
6. **SERVICE.md / dokumentacja** — typ handlera, tabela ZNANYCH eventów.

## 7. Kryteria Akceptacji (Definition of Done)

1. `make build` + `make test` zielone (poza pre-existing `oauth_provider_test`
   runtime failure — niezależny).
2. `counter.mlx` (scaffold) używa `on_click=Increment` (msg value, bez `Some`)
   i się kompiluje.
3. `well init <proj> && cd <proj> && dune build` (z lokalnym well, patrz
   sekcja 8) zielone.
4. Nowe testy MLX w `test/mlx_syntax_test/mlx_syntax_test.mlx` pokrywają:
   `on_click=msg`, `on_keydown=named_handler`, `on_input=named_handler`,
   fallback `on_<unknown>=handler`.
5. `rendering.ml` poprawnie interpretuje każdy wariant (test e2e w
   `lib/well_web/test_e2e_counter/` — jeśli feasible w jsoo).

## 8. Jak testować scaffold end-to-end

`well init` scaffold'uje projekt pin'ujący `well` z GitHub (stary kod). Aby
testować lokalne zmiany:

```bash
cd /tmp && rm -rf tt && /home/sel/Documents/well/_build/default/bin/main.exe init tt
cd /tmp/tt
# Pin do lokalnego checkoutu:
perl -0pi -e 's{git\+ssh://git\@github.com/finalclass/well\.git}{file:///home/sel/Documents/well}' dune-project
# Dune pkg scan wywala się na .agents/skills/axe (directory-as-source bug).
# Tymczasowo przenieś:
mv /home/sel/Documents/well/.agents /tmp/_agents_bak
rm -rf dune.lock _build && dune pkg lock && dune build
echo "exit=$?"
mv /tmp/_agents_bak /home/sel/Documents/well/.agents   # przywróć!
rm -rf /tmp/tt
```

(Run `./vendor/dune build bin/main.exe` w frameworku po zmianach w
`template.ml`, zanim scaffold'ujesz — żeby `well init` użył nowej wersji.)

## 9. Zmienne środowiskowe / stan repo

- Branch: `master` (wszystko zmergowane). Nie twórz branchy samodzielnie
  (architekt tego nie chce) — commituj na master po wyraźnej prośbie.
- `axe` skill: zmiana dotyka `lib/` — zastosuj 5-fazowy workflow
  (Diagnosis → Propose → Completeness → Coherence → Implement). Typ handlera
  to change to COMPONENT contract (re-export przez `Well_web.Vdom`/`Html`) —
  SERVICE.md / DESIGN-COMPONENT.md może wymagać aktualizacji.
- **Brak komentarzy w kodzie** (reguła axe). Spec w SERVICE.md / .mli docstrings.
- `well init` scaffold używa **natywnych atrybutów MLX**
  (`style="..."`, `class'="..."`, `on_click=Msg`), NIE `attrs=[(...)]` —
  zgodnie z AGENTS.md. `attrs=[...]` tylko dla dynamicznych list.

## 10. Checklist plików do zmiany

- [ ] `lib/well_web/bridge/bridge.ml` + `.mli` — `event_key`, `event_value`.
- [ ] `lib/well_html/html.ml` — typ `handler` → wariant; konstruktory.
- [ ] `lib/well_mlx_pp/jsx_helper.ml` — tabela ZNANYCH eventów, desugaring.
- [ ] `lib/well_web/rendering.ml` — `attach_listener` wariant-aware.
- [ ] `lib/well_web/rendering.mli` — zaktualizować docstring (handler).
- [ ] `lib/well_web/component_access/component_access.ml` + `.mli` — re-export.
- [ ] `lib/well_cli/template.ml` — `web/counter.mlx` (`on_click=Msg`), README block.
- [ ] `lib/well_web/test_e2e_counter/counter_test.ml` — `on_click Msg`.
- [ ] `test/mlx_syntax_test/mlx_syntax_test.mlx` — testy typed handlers.
- [ ] `test/html_test/html_test.ml` — jeśli testuje handler (pewnie nie).
- [ ] `lib/well_web/SERVICE.md` + `lib/well_web/component_access/SERVICE.md` — handler.

## 11. Kontekst: co już zrobiono (unifikacja vdom, na masterze)

- `Html.node = [`Html of 'msg vdom]`, kowariantny w `'msg`. Backend: `unit`.
  Frontend: `msg` komponentu.
- `Html.handler` = dziś `Obj.t -> 'msg option` (do zmiany w tym handoffie).
- MLX `<tag>` desugar'uje do `Html.tag` (zwraca `node`); `on_*` → `~handlers`.
- `rendering.ml` rozpakowuje `` `Html of vdom `` przy iteracji dzieci.
- `jsx_helper.ml` ma już logikę rozpoznawania `on_` prefix → handlers (sekcja
  `html_props`); trzeba ją rozszerzyć o warianty ZNANYCH eventów.
- `wrap_string_children` w `jsx_helper.ml` owija bare-string children w `Html.txt`.

(Pełen kontekst unifikacji: przeczytaj diff commitów `fb9c40c`, `108d237`.)
