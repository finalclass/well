# SERVICE.md — StateAccess

## Role

Centralne miejsce do zapisu stanu wszystkich instancji komponentów w runtime.
Generyczny key-value store: kluczem jest referencja do instancji komponentu,
wartością dowolny stan. Nie jest instancjonowany per typ komponentu — jedno
współdzielone miejsce do zapisu dla całego runtime'u.

## Abstraction boundary

Enkapsuluje V-state — lokalizację stanu: gdzie żyje (RAM), jak jest
persystowany, jak się go wczytuje. To, co ukrywa przed LoopManagerem: **gdzie**
stan fizycznie siedzi; LoopManager wie tylko „podaj mi stan / zapisz stan".

Persystencja w przyszłości (localStorage, baza, SSR) oraz historia stanu
(time-travel) są opcjonalne i odłożone na później.

## Assumptions

- Instancja istnieje w zasobie przy wywołaniu `load`/`persist` (LoopManager
  rejestruje instancję przez ComponentAccess przed pierwszym użyciem stanu).
- Stan jest niezmienialny poza `persist` (LoopManager nie mutuje stanu
  otrzymanego przez `load`).
- `destroy` jest wywoływane raz per instancja, przy `disconnectedCallback`
  (unmount z DOM).

## Scenarios

- [LoadState](state_access.mli) — wczytaj stan instancji.
- [PersistState](state_access.mli) — zapisz nowy stan instancji.
- [DestroyState](state_access.mli) — zwolnij stan instancji przy unmount.

## Verification strategy

Access to prosty key-value store — weryfikujemy integracyjnie z LoopManagerem
na konkretnym komponencie (`Counter` z `DESIGN-COMPONENT.md`), bez mocków.
Krytyczne: czy `persist` po `load` zwraca ten sam stan; czy `destroy` czyści
stan (kolejne `load` po `destroy` nie zwraca starego stanu).
