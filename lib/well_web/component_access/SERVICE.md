# SERVICE.md — ComponentAccess

## Role

Ukrywa definicje zarejestrowanych typów komponentów (moduły first-class z
`init`/`update`/`view`/`props`/`emits`) oraz mapowania instancji (instance_id ↔
DOM element ↔ definicja). Pozwala LoopManagerowi zlecać wykonanie
`init`/`update`/`view` na module komponentu bez znajomości jego typów.

## Abstraction boundary

Enkapsuluje V-component — interfejs/kontrakt modułu komponentu (init/update/
view/props/emits) oraz mapowanie instancji. To, co ukrywa przed LoopManagerem:
konkretną strukturę `state`/`msg`, faktyczny moduł komponentu, DOM element.

`instance` jest typem wewnętrznym (implementation detail) — publiczne API
operuje wyłącznie na stringowym `instance_id`. Stan instancji żyje w
StateAccess (ComponentAccess nie przechowuje stanu). Definiuje współdzielone
typy `Html.node`/`Html.vdom` (przez alias `Vdom`, generyczny nad `'msg`),
`Props.t`, `Cmd.t`, `emits`,
re-eksportowane przez Clienta.

### Cmd ADT — konstrukcja, nie wykonanie

ComponentAccess **eksponuje** ADT `Cmd.t` i fold `Cmd.iter` (shape komendy
dla EffectsManager). Access / `init` / `update` **tylko konstruują** wartości
`Cmd.t` — **nie** interpretują efektów (brak Bridge, brak CustomEvent, brak
XHR w tej warstwie).

| Konstruktor | Znaczenie (interpretuje EffectsManager) |
|---|---|
| `none` | brak efektu |
| `msg m` | re-entry update przez Bus (`"msg"`) |
| `emit e` | `CustomEvent "well-emit"`, `detail = emits` |
| `emit_dom ~name ?detail` | `CustomEvent` o podanej nazwie (parent DOM) |
| `focus sel` | rAF + `querySelector` na hoście + `.focus()` |
| `batch cs` | sekwencja dzieci (zagnieżdżenia OK) |
| `perform f` | `f ~dispatch` z żywym dispatch na `"msg"` |

`Cmd.iter ~none ~msg ~emit ~emit_dom ~focus ~perform` — jedyny punkt foldu
drzewa komend; woła go **EffectsManager**, nie Access.

### `init_state` i żywy `dispatch`

`init_state ~instance_id ~dispatch` woła `COMPONENT.init ~dispatch` i zwraca
kopertę `(state * cmd)`.

- `~dispatch` jest **żywy** w momencie init (Client podaje publish na topic
  `"msg"` dla tej instancji) — nie no-op.
- Zwrócone `cmd` **nie** jest tu uruchamiane; caller (Client przy mount /
  LoopManager przy update) publikuje je na topic `"cmd"` gdy ≠ `none`.
- Access nie subskrybuje MessageBus i nie woła `Cmd.iter` w ścieżce efektów.

## Assumptions

- `register_type` jest wołane raz per typ komponentu, przy ładowaniu aplikacji,
  zanim jakikolwiek element tego typu pojawi się w DOM.
- `create_instance` jest wołane z `tag_name`, który został wcześniej
  zarejestrowany przez `register_type`.
- `dom_element` przekazany do `create_instance` jest elementem DOM poprawnego
  typu (odpowiada `tag_name`).
- `instance_id` przekazany do `destroy_instance`/`init_state`/`update_state`/
  `render_view` wskazuje na istniejącą instancję (utworzoną przez
  `create_instance`, niezniszczoną przez `destroy_instance`).
- Stan komponentu (`state`) jest OCaml-record z `[@@deriving js]` — runtime
  może konwertować do JS-value za darmo (dla persystencji/historii, gdy
  włączone).
- `update` jest czystą funkcją (nie mutuje stanu poza return value).
- `init`/`update` zwracają tylko skonstruowane `Cmd.t`; wykonanie efektów
  należy do EffectsManager po publikacji na `"cmd"`.
- Projected children (light DOM hosta przy connect) to **lifecycle instancji**,
  nie TEA `state`: Access trzyma listę węzłów DOM i podaje je do `view` jako
  stabilny token vdom `tag="#slot"` (Rendering reparentuje prawdziwe węzły).
- `capture_projection` jest wołane raz na instancję **po** hydrate props i
  **przed** pierwszym `render_view` (Client MountInstance). Capture odłącza
  znaczące `childNodes` hosta (elementy + niepusty tekst; puste tekstowe i
  komentarze pomijane).
- Gdy `view` nie wstawi tokenu `#slot` w drzewie, projected nodes pozostają
  poza dokumentem (niewidoczne) do destroy instancji.
- `render_view` woła `view` z żywym `dispatch` (ten sam, co w `init_state`)
  oraz tokenem projected — nie stubem `unit`.

## Scenarios

- [RegisterType](component_access.mli) — zarejestruj definicję typu komponentu.
- [CreateInstance](component_access.mli) — stwórz instancję zarejestrowanego typu.
- [DestroyInstance](component_access.mli) — usuń instancję przy unmount.
- [InitState](component_access.mli) — wykonaj init (`~dispatch` live), zwróć
  `(state * cmd)` bez uruchamiania cmd.
- [UpdateState](component_access.mli) — wykonaj update, zwróć komendę
  (konstrukcja; bez efektów).
- [CaptureProjection](component_access.mli) — zrzut light-DOM hosta
  (projected children) na instancję; przed pierwszym `render_view`.
- [ProjectedNodes](component_access.mli) — odczyt zrzutu (dla Rendering `#slot`).
- [RenderView](component_access.mli) — wykonaj view z tokenem projected
  children (`#slot`) i żywym `dispatch`, zwróć vdom.
- `props_of_instance` / `props_of_tag` — runtime view deklaracji `Props.t`
  dla Inputs (nazwa, kind, parse_string, equal, to_msg, default_value).
  `kind` rozróżnia `List` (JS Array / OCaml list) od `Complex` (`of_eq`).
- `instance_id_of_element` — reverse lookup host → instance_id.

## Verification strategy

Access z mapowaniem instancji i egzystencjalnym stanem — weryfikujemy
integracyjnie z LoopManagerem na konkretnym komponencie (`Counter` z
`DESIGN-COMPONENT.md`), bez mocków. Krytyczne:

- Czy `create_instance` zwraca unikalne `instance_id` per instancja.
- Czy `update_state` faktycznie woła `update` modułu i zapisuje nowy stan
  w instancji (kolejne `render_view` widzi nowy stan).
- Czy `destroy_instance` czyści mapowanie (kolejne wołania na tym
  `instance_id` są błędem).
- Czy wiele instancji tego samego typu jest niezależnych (stan jednej nie
  wpływa na drugą).
