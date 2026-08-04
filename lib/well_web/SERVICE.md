# SERVICE.md — Well.Web (Client)

## Role

Fasada dla aplikacji — jedyny publiczny entry-point do runtime. Wewnętrznie
organizuje 3 role jako sub-moduły:

- `registration.ml` — `val component` (rejestruje typ komponentu, stwarza
  instancje serwisów, koordynuje rejestrację przez ComponentAccess + Bridge,
  podpina lifecycle callbacki).
- `inputs.ml` — nasłuch DOM eventów, atrybutów (`Props.t`), lifecycle
  bridging (create/destroy instancji przy connect/disconnect), `subscriptions`.
  Implementuje `on_connect`/`on_disconnect`, które Bridge woła.
- `rendering.ml` — subscribe MessageBus, renderuje vdom → DOM przez Bridge.
- `channels.ml` — push z WS silnika (`well.js`, D14) → publish msg na
  MessageBus.

## Abstraction boundary

Enkapsuluje 3 wolatylności (V-inputs, V-rendering, V-channels) oraz
rejestrację. Ukrywa przed aplikacją: wewnętrzne serwisy (LoopManager,
EffectsManager, Accessy, MessageBus, Bridge), ich wzajemne powiązania,
kolejkowanie. Aplikacja widzi tylko `module type COMPONENT`, `val component`
oraz re-eksportowane typy (`Html.node`/`Html.vdom` przez alias `Vdom`, `Props.t`,
`Cmd.t`, `emits`).

## Assumptions

- `component` jest wołane raz per typ komponentu, przy ładowaniu aplikacji,
  zanim jakikolwiek element tego typu pojawi się w DOM.
- `module_` wskazuje na moduł zgodny z `COMPONENT` (poprawne `init`/`update`/
  `view`/`props`/`emits`, `state` z `[@@deriving js]`).
- `tag_name` jest unikalny w obrębie aplikacji (dwie rejestracje tego samego
  `tag_name` są błędem — `Bridge.register_element` ma no-op w tym przypadku,
  zgodnie ze specyfikacją `customElements.define`).
- Lifecycle callbacki (`on_connect`/`on_disconnect`) są wywoływane przez
  Bridge za każdym razem, gdy element tego typu jest wstawiany/usuwany z DOM.
- Sub-moduły (Inputs, Rendering, Channels) są tworzone raz (przy pierwszym
  `component`) i współdzielone przez wszystkie typy komponentów.

## Scenarios

- [RegisterComponent](well_web.mli) — jedyny publiczny use case; rejestracja
  typu komponentu i podpięcie całego lifecycle.

## Verification strategy

Client to fasada — weryfikujemy integracyjnie na konkretnym komponencie
(`Counter` z `DESIGN-COMPONENT.md`), bez mocków. To jest test ostateczny,
który spiná całą architekturę. Krytyczne:

- Czy po `Well_web.component (module Counter) ~tag_name:"well-counter"`
  element `<well-counter>` w HTML faktycznie się renderuje (init → view → DOM).
- Czy kliknięcie przycisku w komponencie przepływa przez całą pętlę
  (DOM event → Inputs → MessageBus → LoopManager → ComponentAccess.update →
  StateAccess.persist → MessageBus → Rendering → DOM).
- Czy `dispatch_event` (emit) z `update` dociera do parenta w HTML (event-w-górę).
- Czy usunięcie elementu z DOM wywołuje cleanup (destroy_instance,
  unsubscribe, destroy_state).

## Cmd bus + init flush

Przy pierwszym `component` runtime:

1. Subskrybuje topic `"msg"` → `LoopManager.handle_msg` (raz, globalnie).
2. Subskrybuje topic `"cmd"` → `EffectsManager.handle_cmd` (raz, globalnie).
3. Przy `connectedCallback`: `init ~dispatch` z żywym dispatchem (publish `"msg"`),
   persist state, publish initial vdom, **flush init cmd** na `"cmd"` jeśli nie-none.

`Cmd.perform` / `batch` / `focus` / `emit` są interpretowane wyłącznie w
EffectsManager — nie w `update`.

