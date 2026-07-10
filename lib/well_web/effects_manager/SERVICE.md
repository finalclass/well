# SERVICE.md — EffectsManager

## Role

Koordynuje wykonanie asynchronicznych efektów wychodzących: odbiera komendy
(Cmd) z MessageBus, interpretuje je (emit CustomEvent, Promise, focus, DOM-ops)
używając Bridge, i publikuje wynikową wiadomość (lub null) z powrotem na
MessageBus.

## Abstraction boundary

Enkapsuluje V-side-effects — słownik + interpretacja Cmd: jakie Cmd są
wspierane, jak się tłumaczy na efekty w świecie zewnętrznym (przez Bridge do
JS/DOM). To, co ukrywa: **jak** komenda jest wykonana; LoopManager wie tylko
„wyślij komendę, dostaniesz kiedyś msg-or-null".

## Assumptions

- `Cmd_envelope.t` jest skonstruowany poprawnie (ID instancji wskazuje na
  zarejestrowany komponent, Cmd jest typu zgodnego z `emits` tego komponentu).
- Bridge jest zawsze gotowy (FFI do JS-runtime/DOM nie rzuca przy wywołaniu).
- `Cmd.then_` (Promise) zawsze się rozwiązuje (resolve lub reject; reject jest
  konwertowany na null-msg, nie propaguje wyjątku).
- Publikacja wyniku na MessageBus nie rzuca (Bus zawsze gotowy).

## Scenarios

- [RunEffect](effects_manager.mli) — jedyny publiczny use case; wykonanie
  komendy i publikacja rezultatu.

## Verification strategy

Manager to warstwa integracji — weryfikujemy kompletny przepływ, **bez mocków**,
na jednym konkretnym przykładzie komponentu (np. `Counter` z
`DESIGN-COMPONENT.md`). Testy integracyjne na samym końcu, gdy cała
architektura jest zmontowana. Brak batchowania — jeden `Cmd_envelope.t` to
jeden efekt.
