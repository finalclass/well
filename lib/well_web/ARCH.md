# ARCH.md — Well.Web

> Statyczna architektura podsystemu `well.web` — runtime'u TEA produkującego
> Web Components. Osobny `ARCH.md` dla podsystemu (poziom 2); `well.web` jest
> częścią większego systemu `well`, ale tu opisujemy tylko jego wewnętrzną
> architekturę. Pełne decyzje projektowe API w `DESIGN-COMPONENT.md`.

## Resource map

| Resource | Technologia |
|---|---|
| ComponentState | RAM (per-instancja). Persystencja konfigurowalna w przyszłości (localStorage, serwer). Historia stanu (time-travel) — możliwa. |
| ComponentDefinition | First-class module (init/update/view/props/emits) + konfiguracja (tag_name, shadow_dom). |

## Components table

| Service | Layer | Folder | Contract | External doc |
|---|---|---|---|---|
| Well.Web | Client | `lib/well_web/` | `well_web.mli` | `SERVICE.md` |
| LoopManager | Manager | `lib/well_web/loop_manager/` | `loop_manager.mli` | `SERVICE.md` |
| EffectsManager | Manager | `lib/well_web/effects_manager/` | `effects_manager.mli` | `SERVICE.md` |
| StateAccess | Access | `lib/well_web/state_access/` | `state_access.mli` | `SERVICE.md` |
| ComponentAccess | Access | `lib/well_web/component_access/` | `component_access.mli` | `SERVICE.md` |
| MessageBus | Cross-cutting (Utility) | `lib/well_web/message_bus/` | `message_bus.mli` | `SERVICE.md` |
| Bridge | Cross-cutting (Utility) | `lib/well_web/bridge/` | `bridge.mli` | `SERVICE.md` |

**Well.Web** jest pojedynczym Clientem — fasadą dla aplikacji. Wewnętrznie organizuje 3 role jako osobne pliki (sub-moduły):

- `registration.ml` — `val component` (entry-point), `module type COMPONENT`, tworzy instancje serwisów, rejestruje custom element.
- `inputs.ml` — DOM event, atrybuty (`Props.t`), lifecycle bridging, `subscriptions` → publish msg na MessageBus.
- `rendering.ml` — subscribe MessageBus, renderuje vdom → DOM przez Bridge.
- `channels.ml` — push z WS silnika (`well.js`, D14) → publish msg na MessageBus.

Trzy wolatylności (V-inputs, V-rendering, V-channels) są enkapsulowane wewnątrz sub-modułów Clienta. Client jako całość jest fasadą dla aplikacji.

Brak Engine — V-side-effects okazał się Managerem (EffectsManager). Wszystkie efekty asynchroniczne wymagają koordynacji w czasie (Promise, rAF), co jest profilem Managera, nie stateless Engine.

**Kontrakty:** pliki `.mli` są wiążące (compiler egzekwuje w compile-time). Diagramy przypadków użycia żyją w doc-comment `(** *)` nad każdym publicznym `val`. Brak TOML — Well.Web jest czysto OCaml, brak codegenu kontraktów (analogia do `axe` frontend: COLLAPSE do `.mli` zamiast COMPONENT.md).

## Static architecture

```static-architecture
Well.Web

Who
- [Well.Web]

What
- [LoopManager] [EffectsManager]

How

How-to-access -> Where
- [StateAccess]->(ComponentState)  [ComponentAccess]->(ComponentDefinition)

Cross-cutting
- [MessageBus] [Bridge]
```

Wolatylności enkapsulowane per warstwa:

| Warstwa | Serwis | Wolatylność |
|---|---|---|
| Client | Well.Web | Rejestracja + źródła msg (DOM event, atrybuty, lifecycle, subscriptions, sandboxing, push z WS) + renderowanie (jak `view` trafia do HTML/DOM; vdom jest implementacją) — 3 role wewnętrzne jako sub-moduły |
| Manager | LoopManager | Mechanika pętli TEA (scheduling, batching, re-entrancja) |
| Manager | EffectsManager | Słownik + interpretacja efektów wychodzących (Cmd, DOM-ops) |
| Access | StateAccess | Lokalizacja stanu (pure-client, localStorage, baza, SSR) |
| Access | ComponentAccess | Interfejs/kontrakt modułu komponentu (init/update/view/props/emits) |
| Cross-cutting | MessageBus | Komunikacja async między warstwami (Pub/Sub, kolejkowane in/out) |
| Cross-cutting | Bridge | Translacja żądań runtime do świata zewnętrznego (JS-runtime, FFI jsoo) |

Reguły MessageBus (dodatkowe):
- Tylko Client i Manager mogą publikować i odbierać wiadomości.
- Zapytania są kolejkowane (zarówno na wejściu do Bus, jak i na wyjściu).

## Call chain — główny use case

Główny use case Well.Web: **zmiana DOM z uwagi na interakcję użytkownika**.

```call-chain
HandleInteraction

[Inputs]
  ~> [MessageBus]
       ~> [LoopManager]
            -> [StateAccess]
                 -> (ComponentState)
            -> [ComponentAccess]
                 -> (ComponentDefinition)
            ~> [MessageBus]
                 ~> [EffectsManager]
                      -> [Bridge]
            ~> [MessageBus]
       ~> [Rendering]
```

Komunikacja Client↔Manager i Manager↔Manager jest **wyłącznie asynchroniczna** przez MessageBus (decyzja architektoniczna — spójność od góry do dołu, ponieważ część komunikacji i tak musi być async). Sync `->` tylko Manager→Access, Access→Resource, Manager/Effects→Bridge.

Po jednym cyklu update LoopManager może opublikować 0..N msg na Bus:
- 0 — gdy update zwraca `Cmd.none` i stan się nie zmienia (lub gdy state się nie zmienia → brak publikacji do Rendering).
- 1 — gdy są efekty ale brak zmiany widoku (lub odwrotnie).
- 2+ — gdy Cmd jest batch (wiele efektów) + zmiana widoku.
