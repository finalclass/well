# SERVICE.md — LoopManager

## Role

Koordynuje pętlę TEA (The Elm Architecture): odbiera asynchroniczne wiadomości
z MessageBus, wczytuje obecny stan, zleca ComponentAccess wykonanie `update`
oraz `view`, zapisuje nowy stan w StateAccess, publikuje wyniki (nowy vdom,
komendy) z powrotem asynchronicznie przez MessageBus.

## Abstraction boundary

Enkapsuluje mechanikę pętli TEA (V-engine): scheduling (kiedy odpalić update),
batching (czy grupować wiele wiadomości), re-entrancję (dispatch wewnątrz
update nie wchodzi rekursywnie), decyzja kiedy re-renderować. To, co ukrywa
przed klientami: **jak** pętla jest zaplanowana w czasie. Klienci widzą tylko
„publikujesz wiadomość, pętla kiedyś zareaguje”.

## Assumptions

- `Msg_envelope.t` jest skonstruowany poprawnie (ID instancji wskazuje na
  zarejestrowany komponent).
- StateAccess zwraca stan poprawnego typu dla danej instancji.
- ComponentAccess potrafi wykonać `update`/`view` bez błędu (komponent jest
  poprawny).
- `update` jest czystą funkcją (nie mutuje stanu poza return value).
- Publikacja na MessageBus nie rzuca (Bus jest zawsze gotowy).

## Scenarios

- [HandleInteraction](loop_manager.mli) — jedyny publiczny use case; reakcja
  na asynchroniczną wiadomość z MessageBus.

## Verification strategy

Manager to warstwa integracji — weryfikujemy kompletny przepływ, **bez mocków**.
Testujemy na jednym konkretnym przykładzie komponentu (np. `Counter` z
`DESIGN-COMPONENT.md`), wszystko na żywo:

- Krytyczne: czy po opublikowaniu wiadomości na MessageBus nowy stan zostaje
  zapisany w StateAccess, a publikacje vdom/cmd faktycznie trafiają z powrotem
  na Bus i trafiają do Rendering/EffectsManager.
- Krytyczne: czy re-entrancja jest poprawna (dispatch wewnątrz update wrzuca
  na kolejkę, nie wchodzi rekursywnie).
- Krytyczne: czy batchowanie wiadomości nie gubi msg.
