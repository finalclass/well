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
W pliku `lib/well_html/html.ml` zmieniamy definicję `node`:

```ocaml
type vdom = {
  tag : string;
  attrs : (string * string) list;
  handlers : (Obj.t -> Obj.t option) list; (* egzystencjalne, dla backendu ignorowane *)
  children : vdom list;
  text : string option;
}

type node = [ `Html of vdom ]
```

*(Uwaga: nazwa typu to `vdom`, a pole `handlers` na backendzie będzie po prostu ignorowane przy serializacji. Typ handlera musi być egzystencjalny / `Obj.t`, aby backend mógł istnieć bez znajomości typów msg TEA).*

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
Funkcja `Html.tag` przestaje używać `Printf.sprintf`. Buduje rekord `vdom`:
```ocaml
let tag name ~attrs ~bool_attrs ~handlers ~children () =
  `Html { tag = name; attrs = attrs; handlers = handlers; children = children; text = None }
```
*(Musimy obsłużyć `text` np. z `Html.txt`, żeby stawało się `text = Some "..."` bez zagnieżdżonych dzieci)*.

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
