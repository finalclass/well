# SERVICE.md — MessageBus

## Role

Infrastruktura komunikacji asynchronicznej (Pub/Sub) między warstwami (Client,
Manager). Wiadomości są kolejkowane na wejściu i wyjściu, a subskrybenci
otrzymują je asynchronicznie, rozróżniane po topic.

## Abstraction boundary

Enkapsuluje mechanizm pub/sub — jak wiadomości są kolejkowane, jak
dispatchowane do subskrybentów, jak obsługa wielu subskrybentów (fan-out).
Ukrywa przed klientami: implementację kolejki, dispatch loop, kolejność
dostarczania.

Definiuje typ transportowy `'a envelope` — koperta niesie `instance_id`
(string) oraz payload dowolnego typu. Typ jest importowany przez inne usługi
(Client, Manager), ale one nie powinny go zwracać w swoich sygnaturach (zasada
separacji typów — każda warstwa ma własne).

## Assumptions

- `publish` jest wołane wyłącznie przez Client lub Manager (reguła z ARCH.md).
- `subscribe`/`unsubscribe` są wołane wyłącznie przez Client lub Manager.
- `callback` w `subscribe` nie rzuca (lub wyjątek jest łapany i logowany, nie
  przerywa dispatch loop).
- Topic jest stringiem; subskrybent dostaje tylko wiadomości z topic'u, na
  który się zapisał.
- Komentarz „MessageBus jest gotowy" — `publish` nie rzuca, zawsze zakolejkuje.
- `unsubscribe` jest idempotentny — wołanie z nieistniejącym `subscription_id`
  jest no-op, nie błąd.

## Scenarios

- [Publish](message_bus.mli) — opublikuj wiadomość na topic.
- [Subscribe](message_bus.mli) — zapisz się na topic.
- [Unsubscribe](message_bus.mli) — odpisz się z topic'u.

## Verification strategy

Utility — prosty Pub/Sub. Weryfikujemy bez mocków, w izolacji (Bus sam w sobie
nie ma współpracowników). Krytyczne:

- Czy `publish` po `subscribe` faktycznie wywołuje callback (asynchronicznie).
- Czy wiele subskrybentów tego samego topic'u wszystkich dostaje wiadomość
  (fan-out).
- Czy subskrybent topic'u „msg" nie dostaje wiadomości z topic'u „cmd".
- Czy `unsubscribe` przerywa dostarczanie kolejnych wiadomości.
- Czy kolejność wiadomości jest zachowana w ramach topic'u.
