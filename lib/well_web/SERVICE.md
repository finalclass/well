# SERVICE.md — Well.Web (Client)

## Role

Fasada dla aplikacji — jedyny publiczny entry-point do runtime. Implementacja:

- `well_web.ml` — `val component` (rejestruje typ, `ensure_runtime`, lifecycle
  `on_connect`/`on_disconnect` wołane przez Bridge: create → init_state →
  Client `StateAccess.persist` → vdom → Instance_table → publish_cmd).
- `rendering.ml` — subscribe `"vdom"`, blit vdom → DOM przez Bridge; handlery
  DOM (`attach_listener`) → publish `"msg"` (ścieżka interakcji).

Planowane / **niezaimplementowane**: osobne `inputs.ml` / `registration.ml` /
`channels.ml`. `Props.t` w kontrakcie — **brak** odczytu atrybutów przy connect.

## Abstraction boundary

Enkapsuluje rejestrację, mount lifecycle i rendering (handlery DOM → msg).
Ukrywa przed aplikacją: wewnętrzne serwisy (LoopManager, EffectsManager,
Accessy, MessageBus, Bridge), ich wzajemne powiązania, kolejkowanie.
Aplikacja widzi tylko `module type COMPONENT`, `val component` oraz
re-eksportowane typy (`Html.node`/`Html.vdom` przez alias `Vdom`, `Props.t`,
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
- Runtime globalny (`ensure_runtime` + `Rendering.init`) startuje raz przy
  pierwszym `component` i jest współdzielony przez wszystkie typy komponentów.

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
  (DOM event → Rendering handler → MessageBus `"msg"` → LoopManager →
  ComponentAccess.update → StateAccess.persist → MessageBus `"vdom"` →
  Rendering → DOM; opcjonalnie `"cmd"` → EffectsManager).
- Czy `dispatch_event` (emit) z `update` dociera do parenta w HTML (event-w-górę).
- Czy usunięcie elementu z DOM wywołuje cleanup (destroy_instance,
  unsubscribe, destroy_state).

## Cmd bus + init flush

Przy pierwszym `component` runtime:

1. Subskrybuje topic `"msg"` → `LoopManager.handle_msg` (raz, globalnie).
2. Subskrybuje topic `"cmd"` → `EffectsManager.handle_cmd` (raz, globalnie).
3. Przy `connectedCallback` (sync construct, Bus flush async `setTimeout(0)`):
   `init_state ~dispatch` (Access tylko woła `init`; publish `"msg"` tylko gdy
   `init` sam wywoła `dispatch`; zwrócony cmd **nie** run), Client persist,
   publish `"vdom"`, rejestracja Instance_table, publish init cmd na `"cmd"`
   jeśli ≠ none (jeden envelope; batch nie jest rozbijany przez Loop/Client).

`Cmd.perform` / `batch` / `focus` / `emit` są interpretowane wyłącznie w
EffectsManager — nie w `update`.

