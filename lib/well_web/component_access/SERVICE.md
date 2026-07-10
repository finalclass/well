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
typy `Vdom.t` (generyczny nad `'msg`), `Props.t`, `Cmd.t`, `emits`,
re-eksportowane przez Clienta.

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

## Scenarios

- [RegisterType](component_access.mli) — zarejestruj definicję typu komponentu.
- [CreateInstance](component_access.mli) — stwórz instancję zarejestrowanego typu.
- [DestroyInstance](component_access.mli) — usuń instancję przy unmount.
- [InitState](component_access.mli) — wykonaj init na module komponentu.
- [UpdateState](component_access.mli) — wykonaj update, zwróć komendę.
- [RenderView](component_access.mli) — wykonaj view, zwróć vdom.

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
