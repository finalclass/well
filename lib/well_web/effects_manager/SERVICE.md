# SERVICE.md — EffectsManager

## Role

Koordynuje wykonanie efektów wychodzących: odbiera komendy (`Cmd`) z
MessageBus (topic `"cmd"`), interpretuje je przez Bridge / MessageBus i
publikuje wynikowe wiadomości na topic `"msg"` gdy komenda tego wymaga.

## Abstraction boundary

Enkapsuluje V-side-effects — słownik + interpretacja Cmd. LoopManager wie
tylko „opublikuj cmd”; EffectsManager wie **jak** ją wykonać, w tym
`Cmd.send` (lookup `addr` w ComponentAccess, nie `instance_id` koperty —
koperta to pętla rodzica).

## Wspierane Cmd

| Cmd | Działanie |
|-----|-----------|
| `none` | no-op |
| `msg m` | `MessageBus.publish ~topic:"msg"` dla tej instancji |
| `emit e` | `CustomEvent "well-emit"` na hoście, `detail = e` (typed emits) |
| `emit_dom ~name ?detail` | `CustomEvent name` na hoście (stringowa nazwa dla parent DOM) |
| `focus sel` | `requestAnimationFrame` → `querySelector` na hoście → `.focus()` |
| `batch cs` | sekwencyjnie, zachowana kolejność, zagnieżdżenia OK |
| `perform f` | `f ~dispatch` z żywym `dispatch` publikującym na `"msg"`; wyjątki z setupu są połykane |
| `send ~addr m` | lookup `addr` → `dispatch` pętli dziecka; brak wpisu = **no-op** |

## Assumptions

- Envelope `cmd` ma poprawne `instance_id` i payload typu `Cmd.t` komponentu.
  Dla `send` `instance_id` to pętla **nadawcy**; cel to `addr`.
- Host DOM istnieje dla `emit` / `focus` (brak hosta = no-op).
- `send` na brakujący `addr` = no-op (jak `focus` przy braku węzła).
- `perform` nie blokuje pętli TEA — app planuje async (XHR, timeout, Promise)
  i woła `dispatch` z callbacków.
- Subskrypcja topicu `"cmd"` jest rejestrowana raz przy starcie runtime
  (`Well_web.ensure_runtime`).

## Scenarios

- [RunEffect](effects_manager.mli) — jedyny publiczny use case.

## Verification strategy

- Unit: `test/cmd_effects_test` — `is_none`, `iter`/`batch` order, `perform` /
  `send` ctor.
- Integracja e2e: `test_e2e_counter` (emit path); `test_addr_send` (parent
  `Cmd.send` → child `dispatch`); perform/init — ręcznie / app.
