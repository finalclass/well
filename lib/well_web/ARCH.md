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

**Well.Web** jest pojedynczym Clientem — fasadą dla aplikacji. Implementacja dziś:

- `well_web.ml` — `val component` (entry-point), lifecycle `on_connect` / `on_disconnect`, rejestracja custom elementu przez Bridge, mount path (create → init → persist → vdom → cmd).
- `rendering.ml` — subscribe `"vdom"`, blit vdom → DOM przez Bridge; **attach_listener** na handlerach DOM → `dispatch` → publish `"msg"` (ścieżka interakcji użytkownika).

Planowane / **niezaimplementowane** (brak plików): osobne `inputs.ml` / `registration.ml` / `channels.ml`. `Props.t` jest w kontrakcie ComponentAccess, ale **nie jest odczytywane przy connect** — brak wire atrybutów → msg.

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
| Client | Well.Web | Rejestracja + lifecycle mount (`well_web.ml`) + renderowanie i handlery DOM (`rendering.ml` → `"msg"`). Atrybuty/`Props` i push z WS — kontrakt/plan, **nie wired** w Client lifecycle |
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

[Rendering]                     (* attach_listener → dispatch *)
  ~> [MessageBus]               (* topic "msg" *)
       ~> [LoopManager]
            -> [StateAccess]
                 -> (ComponentState)
            -> [ComponentAccess]
                 -> (ComponentDefinition)
            ~> [MessageBus]     (* topic "vdom" — zawsze *)
                 ~> [Rendering]
                      -> [Bridge]
            ~> [MessageBus]     (* topic "cmd" — 0|1 envelope, skip none *)
                 ~> [EffectsManager]
                      -> [Bridge]
                      ~> [MessageBus]  (* perform/msg → "msg" → LoopManager *)
```

Komunikacja Client↔Manager i Manager↔Manager jest **wyłącznie asynchroniczna** przez MessageBus (decyzja architektoniczna — spójność od góry do dołu, ponieważ część komunikacji i tak musi być async). `MessageBus.publish` = enqueue + `setTimeout(flush, 0)` — po powrocie z `on_connect` / handlera ani vdom, ani EffectsManager jeszcze nie zbiegły. Sync `->` tylko Manager→Access, Access→Resource, Manager/Effects→Bridge; oraz **mount-only** Client→Access w `on_connect` (nie kopiować na inne UC).

Po jednym cyklu `handle_msg` LoopManager publikuje (bez porównywania old/new state):
- **zawsze** 1× `"vdom"` (render po każdym update — brak skip-vdom),
- **0 lub 1** envelope na `"cmd"`: skip gdy `Cmd.none`; w przeciwnym razie **cały** `cmd` (w tym `batch`) jako **jeden** payload. Rozwijanie batch / `Cmd.iter` robi EffectsManager, nie LoopManager.

## Globalne subskrypcje runtime (raz)

Przy pierwszym `Well_web.component` Client woła `ensure_runtime` i rejestruje
**globalnie, raz na proces** (nie per-instancja):

| Topic MessageBus | Subskrybent | Rola |
|---|---|---|
| `"msg"` | LoopManager (`handle_msg`) | pętla TEA: update → persist → vdom/cmd |
| `"cmd"` | EffectsManager (`handle_cmd`) | interpretacja Cmd (emit/focus/perform/batch/msg) |
| `"vdom"` | Rendering (`init` → subscribe) | sync vdom → live DOM przez Bridge |

Publikują na te topiki (żywe moduły):
- `"msg"` — Rendering (handlery DOM), EffectsManager (`Cmd.msg` / `perform`→dispatch), Client mount gdy `init` woła żywy `dispatch`
- `"vdom"` / `"cmd"` — LoopManager (po update) oraz Client mount (`on_connect`)

Access **nie** subskrybuje Bus.

## Call chain — MountInstance (init przy connect)

Drugi główny use case: **pierwsze podpięcie custom elementu do DOM**
(`connectedCallback` → `on_connect`). To nie idzie przez LoopManager —
Client orkiestruje init synchronicznie, a efekty init flushuje na Bus.

```call-chain
MountInstance

[Well.Web / on_connect]
  -> [ComponentAccess]          (* create_instance *)
       -> (ComponentDefinition)
  -> [ComponentAccess]          (* init_state ~dispatch live; init may dispatch *)
       -> (ComponentDefinition)
  -> [StateAccess]              (* Client persist — nie LoopManager *)
       -> (ComponentState)
  -> [ComponentAccess]          (* render_view *)
       -> (ComponentDefinition)
  ~> [MessageBus]               (* topic "vdom"; flush async setTimeout(0) *)
       ~> [Rendering]
            -> [Bridge]
  ~> [MessageBus]               (* topic "cmd" — 0|1 envelope jeśli ≠ none *)
       ~> [EffectsManager]
            -> [Bridge]
            ~> [MessageBus]     (* perform/msg → "msg" *)
                 ~> [LoopManager]
```

Kolejność w `on_connect` (wiążąca):

1. `create_instance` — mapowanie instance_id ↔ host DOM ↔ definicja.
2. `init_state ~dispatch` — Access tylko woła `M.init ~dispatch` i zwraca
   `(state * cmd)`; **nie** publikuje na Bus. Client-supplied `dispatch` może
   enqueue `"msg"` **tylko jeśli** `init` sam woła `dispatch`. Zwrócony `cmd`
   **nie** jest tu uruchamiany.
3. `StateAccess.persist` — Client zapisuje stan początkowy (LoopManager
   **nie** woła `init_state`).
4. `render_view` + publish `"vdom"` — enqueue pierwszego painta (flush Bus async).
5. rejestracja w Client `Instance_table` (lokalna tabela host→instance).
6. `publish_cmd` init cmd na `"cmd"` (skip gdy `Cmd.none`) — jeden envelope;
   EffectsManager interpretuje po flushu Bus.

Sync Client→Access w tym łańcuchu jest **wyłącznie mount lifecycle** — nie
kopiować na HandleInteraction ani inne UC.

`Cmd.perform` z init/update wykonuje wyłącznie EffectsManager; w `perform`
wolno async I/O + `dispatch`, nie nawigacja parent/DOM (→ `emit` / `emit_dom`
/ `focus`).
