# ARCH.md — podsystem Well.Actor

## Granica systemu

Well.Actor jest podsystemem istniejącego Well. Dekompozycja poniżej dotyczy
mechaniki aktorowej, nie wymusza ról IDesign na typach aktorów aplikacji.
Moduł aktora nie staje się Engine ani Access wyłącznie dlatego, że jest
aktorem. Obieg aplikacji enkapsuluje orkiestrację; kod aktora lokalną regułę.

## Komponenty i zmienność

| Komponent | Rola | Enkapsulowana zmienność |
|---|---|---|
| Actor facade | Client | wejście i obserwacja z kodu aplikacji |
| ActivationManager | Manager | przebieg jednej obsługi i jej zatwierdzenia |
| WorkflowEngine | Engine | interpretacja języka obiegów i kontrola emisji |
| ActorDefinitionAccess | Access | dostęp do metadanych i zarejestrowanego zachowania |
| ExecutionAccess | Access | atomowe operacje na trwałym wykonaniu i stanie |
| Scheduler | Utility | gotowość, przydział aktywacji, zegary i wybudzenia |
| Contract | narzędzie | projekcja kontraktu Cyrografu i metadanych `[actor]` na typy, kodeki i deskryptor |
| Join actor | zachowanie wbudowane | zbieranie wyników konkretnej grupy |

```static-architecture
Well.Actor

Who
- [Actor facade]

What
- [ActivationManager]

How
- [WorkflowEngine]

How-to-access -> Where
- [ActorDefinitionAccess]->(ActorDefinitions)
- [ExecutionAccess]->(ExecutionStore)

Cross-cutting
- [Scheduler]
```

Scheduler inicjuje obsługę gotowego elementu przez ActivationManager;
nie implementuje biznesowych rozgałęzień. Wbudowany Join używa tej samej
serializacji aktywacji i protokołu zatwierdzenia co aktor aplikacji.
Nie korzysta z osobnego współdzielonego bufora wyników w RAM.

## Resource map

| Zasób | Reprezentacja |
|---|---|
| ActorDefinitions | moduły OCaml i niezmienne metadane kontraktów |
| ActorState | wersjonowany blob per para type/ID |
| Inbox | trwałe koperty, sekwencja per odbiorca, próby i termin gotowości |
| Outbox | kompletne koperty z tożsamościami ustalonymi przy commit |
| Execution | status, niezakończone tokeny, wyniki i idempotencja startu |
| JoinState | stan wbudowanego aktora per wykonanie i grupa |
| Timers | trwałe terminy oraz identyfikatory dostarczeń zegarowych |
| DeadLetters | terminalne błędy i dane potrzebne do diagnostyki |
| ExecutionStore | jeden plik SQLite należący wyłącznie do Actor |

Wspólny ExecutionStore jest techniczną granicą transakcji runtime'u,
nie współdzielonym modelem domeny. Aktorzy nie odczytują tabel innych aktorów.
Oddzielenie magazynu mailboxa od magazynu stanu nie może rozbić atomowości.

## Operacje ExecutionAccess

Operacje Access są atomowymi czasownikami, nie niezależnymi load/save/dequeue:

- AdmitExecution: idempotentnie przyjmij start, wykonanie i pierwszą kopertę.
- ClaimTurn: zarezerwuj najstarsze gotowe wejście wolnej instancji.
- CommitTurn: zatwierdź stan, zakończenie wejścia, outbox, grupy i tokeny.
- RescheduleTurn: zwolnij nieudaną próbę i zapisz termin ponowienia.
- FailExecution: zapisz błąd terminalny i unieważnij dalszy routing wykonania.
- DeliverOutbox: dopisz do inboxa idempotentnie i zakończ dostarczenie.
- AdmitTimer: trwale przyjmij wiadomość zegarową dokładnie raz dla timer_id.
- ObserveExecution: zwróć spójny status i uporządkowane wyniki.

Każda operacja odrzuca nieaktualną rezerwację lub rewizję. Wyjście procesu
unieważnia jego rezerwacje; następny właściciel odtwarza gotowość z dysku.

## Przejście aktywacji

```use-case
Obsłuż gotową wiadomość

[ClaimTurn]
<wykonanie terminalne>
  [Zakończ wejście bez uruchamiania zachowania]
  (END Discarded)
[Odtwórz osobny stan roboczy]
[Wykonaj lokalną obsługę]
<próba nieudana>
  [RescheduleTurn albo FailExecution]
  (END NotCommitted)
[Sprawdź i rozwiń emisje przez WorkflowEngine]
<emisje niezgodne z kontraktem lub obiegiem>
  [FailExecution bez zmiany stanu domenowego]
  (END InvalidEmission)
[CommitTurn]
(END Committed)
```

## Alokacja procesu

Jedna blokada właściciela magazynu obowiązuje także między procesami;
próba drugiego otwarcia kończy się błędem. Blokada systemowa zostaje
zwolniona przy śmierci procesu; nie polega na zegarowej dzierżawie.

Jedna aktywacja = jeden fiber, bez fibera oczekującego na pusty mailbox.
Liczba aktywnych instancji ma limit. Zegar i router nie uruchamiają
nieograniczonej liczby fiberów. Praca CPU może być rozłożona na domeny OCaml;
fiber sam w sobie nie zapewnia równoległego wykonywania kodu CPU.

SQLite: WAL, synchronous=FULL, busy_timeout=5000. Połączenia są prywatne
dla wykonującego je workera i nie są używane jednocześnie ani przekazywane
między domenami. Transakcja trwa tylko podczas operacji ExecutionAccess,
a nie przez wykonywanie aktora lub zewnętrzne I/O. Blokujące SQLite nie może
zatrzymywać domen obsługujących HTTP; Actor izoluje tę pracę we własnych
workerach. To wymaganie implementacyjne podsystemu Actor, nie zmiana Well.Db.

## Materiały projektowe

- [Routing Slip](https://www.enterpriseintegrationpatterns.com/patterns/messaging/RoutingTable.html)
  — inspiracja dla obiegu dołączonego do wiadomości; opisany tu fork/join jest rozszerzeniem Well.
- [Aggregator](https://www.enterpriseintegrationpatterns.com/patterns/messaging/Aggregator.html)
  — korelacja wyników, warunek kompletu i sposób agregacji.
- [Transactional Client](https://www.enterpriseintegrationpatterns.com/patterns/messaging/TransactionalClient.html)
  — granica zatwierdzania przetwarzania i komunikacji.
- [Idempotent Receiver](https://www.enterpriseintegrationpatterns.com/patterns/messaging/IdempotentReceiver.html)
  — bezpieczne przyjmowanie ponowień.
- [Akka interaction patterns](https://doc.akka.io/libraries/akka-core/current/typed/interaction-patterns.html)
  — response aggregator jako zachowanie aktora.

Konkretny format, limity i API w tym pakiecie są decyzjami projektu Well,
a nie twierdzeniami o wymaganiach wszystkich systemów aktorowych.
