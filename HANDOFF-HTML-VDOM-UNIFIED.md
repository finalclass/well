# Handoff: Unifikacja Html.node i Vdom (Jeden typ dla Backendu i Frontendu)

> **Kontekst:** Ten dokument jest instrukcją startową dla dużej zmiany architektonicznej w frameworku `well`.
> Cel: ujednolicenie reprezentacji DOM. Zamiast stringów (backend) i osobnego rekordu (frontend), wprowadzamy jeden typ `vdom`, który nosi strukturę oraz handlery.
> **Najważniejsza zasada (KRYTYCZNE):** Po tej zmianie istniejące projekty użytkownika (generowane przez `well init`) **muszą kompilować się i działać bez zmian w ich kodzie**.

## 1. Stan obecny (Co mamy dzisiaj)

- **Frontend (`lib/well_web/`)** posiada runtime TEA (The Elm Architecture) produkujący Web Components.
- W `lib/well_web/component_access/` zdefiniowany jest typ `Vdom.t` jako rekord:
  ```ocaml
  type 'msg Vdom.t = {
    tag : string;
    attrs : (string * string) list;
    handlers : (string * 'msg handler) list;
    children : 'msg Vdom.t list;
    text : string option;
  }
  ```
- **Backend (`lib/well_html/html.ml`)** posiada `type node = [ `Html of string ]`.
- **MLX (Preprocesor w `lib/well_mlx_pp/jsx_helper.ml`)** generuje wywołania `Html.tag "div" ~attrs:... ~bool_attrs:... ~children:... ()`, które formatują stringi.
- Frontend dla TEA nie używa MLX, budując `Vdom.t` ręcznie w plikach `.ml`.

## 2. Stan docelowy (Co chcemy osiągnąć)

Wprowadzamy jeden wspólny typ o nazwie `vdom`.
W pliku `lib/well_html/html.ml` wprowadzamy nowy typ `vdom`.

**KRYTYCZNE: Typ `vdom` musi być generyczny nad `'msg`, aby zachować type-safety w komponentach TEA.** Komponenty frontendu piszą `<button on_click=(fun _ -> Increment)/>` i kompilator musi wiedzieć, że `Increment` to poprawny `msg`. Bez parametru `'msg` tracimy type-safety.

```ocaml
type 'msg vdom = {
  tag : string;
  attrs : (string * string) list;
  handlers : (string * 'msg handler) list;  (* type-safe! *)
  children : 'msg vdom list;
  text : string option;
}
```

- **Frontend (komponenty TEA):** `view` zwraca `msg vdom` (konkretny msg, type-safe).
- **Backend (strony serwerowe):** `<div>(txt "Hello")</div>` nie ma msg, więc MLX produkuje `'a vdom` (polimorficzny, `'a` nieużywane bo `handlers=[]`).
- **Transport runtime:** gdy vdom przepływa przez MessageBus do Rendering, i tak jest `Obj.magic` (egzystencjalne). Type-safety żyje tylko w ciele komponentu (przy pisaniu `view`), w transporcie jest egzystencjalne — i to jest OK.

### Problem do rozwiązania przez agenta: `Html.node` i automatyczna coercion

Typ `Html.node` (który jest subtype `Well.response` i musi coercion'ować automatycznie z MLX `<div/>`) musi zostać **konkretny** (nie polimorficzny), żeby coercion działało. Ale `'msg vdom` jest polimorficzny.

Agent musi wybrać jedno z rozwiązań:
1. **Polimorficzny wariant OCaml:** `type node = [ \`Html of 'a. 'a vdom ]` — pozwala na automatyczną coercion z dowolnego `'msg vdom`.
2. **Egzystencjalny wrapper:** `type node = Node : 'msg vdom -> node` albo podobnie — wymaga explicite opakowania (może być chowane w MLX preprocesorze albo w `Html.tag`).
3. **Konkretny `'a vdom` na backendzie:** backend MLX produkuje konkretny (np. `unit vdom`), frontend ma `msg vdom`, konwersja na granicy.

Najważniejsze: **API komponentu dla użytkownika to `msg vdom` (type-safe)**. Implementacja `Html.node` / coercion to szczegół wewnętrzny, który agent musi dopracować.

## 3. Mechanizm działania (Krok po kroku)

### A. Kod użytkownika (BEZ ZMIAN)
Strony użytkownika wyglądają (i działają) identycznie:
```mlx
Well.get "/" (fun _ ->
  <div>(txt "Hello World")</div>
)
```

### B. Preprocesor MLX (`jsx_helper.ml`)
Dla zwykłych tagów generuje wywołanie `Html.tag` tak jak wcześniej. Różnica polega na tym, jak `on_*` są traktowane:
- Jeśli MLX napotyka atrybut `on_click=(wyrażenie)`, **NIE** dodaje go do `~attrs`.
- Musi dodać go do nowej listy `~handlers` w wywołaniu `Html.tag`.

### C. Moduł `Html` (`html.ml`)
Funkcja `Html.tag` przestaje używać `Printf.sprintf`. Buduje rekord `'msg vdom`:
```ocaml
let tag name ~attrs ~bool_attrs ~handlers ~children () : 'msg vdom =
  { tag = name; attrs = attrs; handlers = handlers; children = children; text = None }
```
*(Musimy obsłużyć `text` np. z `Html.txt`, żeby stawało się `text = Some "..."` bez zagnieżdżonych dzieci).*

`Html.tag` zwraca `'msg vdom`. Na backendzie (gdy nie ma handlerów) jest polimorficzny `'a vdom`. Agent musi rozwiązać jak ten `'msg vdom` coercion'uje się do `Html.node`/`response` (patrz problem "Html.node i automatyczna coercion" wyżej).

### D. Serwer HTTP (`lib/well/well.ml` lub `router.ml`)
W miejscu, gdzie response jest wysyłany do przeglądarki, musimy sprowadzić `vdom` z powrotem do Stringa:
```ocaml
let send_response resp =
  match resp with
  | `Html vdom_node ->
      let html_string = Html.element_to_string vdom_node in
      (* wysyłamy html_string *)
```
`Html.element_to_string` to nowa funkcja rekursywnie zamieniająca rekord na string (dziedziczy logikę obecnego `Printf.sprintf`).

### E. Frontend (`lib/well_web/`)
Znika duplikacja. Typ `Vdom.t` staje się po prostu `Html.vdom`. Rendering w `lib/well_web/rendering.ml` przyjmuje `Html.vdom` i buduje z niego żywy DOM, podpinając `handlers` zamiast je ignorować.

## 4. Co musisz zrobić (Zakres prac)

1. **`lib/well_html/html.ml`**: Zmień `type node` na `` `Html of vdom ``. Zaktualizuj `Html.tag`, `Html.txt` aby budowały rekord. Napisz `Html.element_to_string : vdom -> string`.
2. **`lib/well/well.ml` (lub warstwa wysyłająca HTTP)**: Wymuś konwersję `` `Html vdom `` -> string przed wysłaniem ciała odpowiedzi.
3. **`lib/well_mlx_pp/jsx_helper.ml`**: Zmodyfikuj desugaring. Jeśli atrybut zaczyna się od `on_`, trafia do `~handlers:[("click", expr)]`, a nie do `~attrs`.
4. **`lib/well/types.ml`**: Zaktualizuj definicję `response`, aby używała nowego `Html.node` (z rekordem).
5. **`lib/well_web/`**: Usuń `Vdom.t` z `component_access`, używaj `Html.vdom`. Zaktualizuj fasadę i moduł `rendering`.
6. **Scaffold (`lib/well_cli/template.ml`)**: Zmień `web/counter.ml` na `web/counter.mlx`. Funkcja `view` powinna używać składni MLX: `<button on_click=(fun _ -> Increment)/>`.

## 5. Kryteria Akceptacji (Definition of Done)

1. Polecenie `well init testproj && cd testproj && dune build` kończy się sukcesem.
2. Strona napisana jako `<div/>` działa i renderuje się poprawnie w przeglądarce (jako string HTML).
3. Komponent `Counter` napisany w `counter.mlx` używa `<button on_click=...>` i reaguje na kliknięcia w przeglądarce (jako Web Component).
4. Kod z istniejących projektów (np. `Well.get "/" (fun _ -> <div/>)`) kompiluje się bez ingerencji użytkownika.
