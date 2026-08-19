# SERVICE.md — Well.Web (Client)

## Role

Fasada dla aplikacji — jedyny publiczny entry-point do runtime. Implementacja:

- `well_web.ml` — `val component` (rejestruje typ, `ensure_runtime`, lifecycle
  `on_connect`/`on_disconnect` wołane przez Bridge: create → init_state →
  Client `bind_addr` → `StateAccess.persist` → **Inputs.hydrate** → vdom →
  Instance_table → publish_cmd). Rejestruje CE z `observedAttributes` (w tym
  `data-well-addr`) + property setters.
- `rendering.ml` — subscribe `"vdom"`, blit/sync vdom → DOM przez Bridge
  (string `attrs` + `bool_attrs`); handlery DOM → publish `"msg"`.
- `inputs.ml` — host attributes / JS properties / `Props.t` → msg (hydrate
  sync przy connect; po mount publish `"msg"` jak eventy DOM).

Planowane / **niezaimplementowane**: osobne `registration.ml` / `channels.ml`.

## Abstraction boundary

Enkapsuluje rejestrację, mount lifecycle, Inputs (Props z hosta) i rendering
(handlery DOM → msg). Ukrywa przed aplikacją: wewnętrzne serwisy
(LoopManager, EffectsManager, Accessy, MessageBus, Bridge), ich wzajemne
powiązania, kolejkowanie. Aplikacja widzi tylko `module type COMPONENT`,
`val component` oraz re-eksportowane typy (`Html.node`/`Html.vdom` przez
alias `Vdom`, `Props.t`, `Cmd.t` w tym `Cmd.send`, `emits`). Tożsamość
pętli dziecka: `Html.element ~addr` / MLX `addr=` (wire `data-well-addr`).

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
- `addr` jest opcjonalny. Host bez `data-well-addr` nie jest adresowalny.
- Dwa hosty z tym samym `addr`: last writer wins (błąd aplikacji).
- `Cmd.send` na brakujący `addr` jest no-op (pętla może nie być zamontowana).
- `data-well-addr` jest always-observed; Client wiąże/odwiązuje pętlę.
  To nie jest Prop — Inputs go nie parsuje.

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
- Czy `Cmd.send ~addr` z `update` rodzica trafia w `dispatch` / `update`
  dziecka o tym `addr` (`lib/well_web/test_addr_send`).
- Czy send na brakujący `addr` jest no-op; czy dwa `addr` nie mieszają pętli;
  czy disconnect zdejmuje wpis.
- Czy usunięcie elementu z DOM wywołuje cleanup (destroy_instance,
  unsubscribe, destroy_state, `unbind_addr`).

## Cmd bus + init flush

Przy pierwszym `component` runtime:

1. Subskrybuje topic `"msg"` → `LoopManager.handle_msg` (raz, globalnie).
2. Subskrybuje topic `"cmd"` → `EffectsManager.handle_cmd` (raz, globalnie).
3. Przy `connectedCallback` (sync construct, Bus flush async `setTimeout(0)`):
   `init_state ~dispatch` (Access tylko woła `init`; publish `"msg"` tylko gdy
   `init` sam wywoła `dispatch`; zwrócony cmd **nie** run), `bind_addr` z
   `data-well-addr` (brak = bez addr), Client persist,
   **Inputs.hydrate** (attrs parseable + JS properties → `update` sync),
   publish `"vdom"` ze stanu po hydrate, rejestracja Instance_table, publish
   init cmd na `"cmd"` jeśli ≠ none (jeden envelope; batch nie jest rozbijany
   przez Loop/Client).
4. Po mount: `attributeChangedCallback` / property setter → Inputs → `"msg"`
   → LoopManager (skip gdy `equal` last-seen). `data-well-addr` → Client
   `bind_host_addr` (nie Inputs).

`Cmd.perform` / `batch` / `focus` / `emit` / `send` są interpretowane wyłącznie w
EffectsManager — nie w `update`.

## Addr / Cmd.send (parent → child)

Host dziecka może mieć `data-well-addr` (API: `Html.element ~addr`, MLX
`addr="…"`). Przy connect Client wiąże `addr` z `dispatch` pętli; przy
disconnect Access zdejmuje wpis. `Cmd.send ~addr child_msg` kładzie
wartość na `dispatch` tej pętli. Brak `addr` w rejestrze = no-op.
Dwa hosty z tym samym `addr`: last writer wins. Rodzic nie trzyma hosta
ani nie woła metod DOM.

## Props / host inputs

- Skalary (`string`/`bool`/`int`/`float`): HTML attribute **oraz** JS property.
- `attr_or_prop`: HTML attribute (`of_string`) **oraz** JS property (`of_js`
  gdy wartość nie jest stringiem; JS string też idzie przez `of_string`).
  Pusty string i błąd parse → no-op (komponent się mountuje).
- `list` / `of_eq`: **tylko** JS property (`parse_string = None`).
- Observed attributes = nazwy props skalarnych i `attr_or_prop` **oraz**
  `data-well-addr` (Client, nie Inputs).
- Property accessors na prototypie CE dla wszystkich props.
- Komponenty z `props = []` bez zmian zachowania.
- **Hydrate priority:** JS property (jeśli ustawione) wygrywa nad atrybutem HTML.
- **Usunięcie atrybutu** (`removeAttribute` / `attributeChangedCallback` z
  `newValue = null`): dla skalarów dispatch `on default` (wartość z
  `?default` w deklaracji Props; wbudowane defaulty: `""` / `false` / `0` /
  `0.0`).
- **`Props.list`:** akceptuje JS `Array` (elementy string/number/boolean) lub
  listę OCaml z heapu jsoo; inne wartości → reject (fail closed). Brak
  JSON-w-atrybucie.
- **Pre-upgrade own property:** przypisanie `el.prop = v` przed
  `customElements.define` / przed upgrade tworzy own data property, które
  shadowuje akcesory prototypu. Przy `connectedCallback` Inputs przenosi
  own value do `__well_prop_*` i usuwa own prop — hydrate i późniejsze settery
  działają. Live path po connect: `el.prop = v` trafia w setter prototypu.
- **Kolejność upgrade:** `attributeChangedCallback` przed `connectedCallback`
  jest no-op (brak `instance_id`); hydrate i tak odczyta attrs przy connect.
- **bool_attrs / IDL:** renderer ustawia atrybut HTML po nazwie HTML i
  synchronizuje camelCase IDL (`readonly`→`readOnly`, `novalidate`→`noValidate`,
  …) gdy znane.

