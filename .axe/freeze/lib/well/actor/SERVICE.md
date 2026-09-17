# SERVICE.md — Well.Actor

## Rola

Well.Actor wykonuje trwałe, asynchroniczne obiegi złożone z niezależnie
kompilowanych typów aktorów; instancje posiadają prywatny stan i mailbox,
a każda wiadomość niesie pełną definicję swojego obiegu i pozycję wykonania.

## Granica abstrakcji

Aktor definiuje lokalne zachowanie, wejścia i emitowane wiadomości. Nie zna
odbiorców ani diagramu. Runtime interpretuje obieg, adresuje instancje,
serializuje ich aktywacje i zatwierdza stan wraz z komunikacją.

Jednostką tożsamości jest para `(actor_type, actor_id)`. `Room/5` i `Room/8`
są różnymi instancjami; `EmailSender/default` jest zwykłą instancją ze stałym ID.
Nazwa węzła obiegu nie jest ID aktora. Kilka węzłów i wykonań może używać tej
samej instancji; wszystkie jej wejścia trafiają do wspólnego mailboxa.

## Kontrakt

- [API.md](API.md) — typy publiczne, rejestracja, uruchamianie obiegów,
  obserwacja, administracja oraz kontrakt zachowania aktora.
- [CONTRACT.md](CONTRACT.md) — TOML, typowanie, kodowanie wiadomości,
  metadane i generowane moduły.
- [WORKFLOW.md](WORKFLOW.md) — format obiegu i koperty, routing, wybór,
  rozdzielenie oraz zagnieżdżone scalenia.
- [DURABILITY.md](DURABILITY.md) — zatwierdzanie zmian, retry, odtwarzanie,
  błędy, limity i utrzymanie stanu.
- [ARCH.md](ARCH.md) — granice komponentów i zasoby podsystemu.
- [STP.md](STP.md) — plan weryfikacji zachowania.
- [examples/README.md](examples/README.md) — kompletne przykłady.

Wymagania z tych plików obowiązują łącznie. API i formaty mają wersję 1.

## Założenia

1. Jedna uruchomiona instancja runtime'u jest wyłącznym właścicielem magazynu.
   Runtime działa na jednym komputerze. Restart procesu jest obsługiwany;
   replikacja, sieciowe aktory i przenoszenie między maszynami nie są objęte API.
2. Stan aktora jest serializowalny. Instancja nie wymaga stale żywego fibera
   ani otwartego zasobu. Każda aktywacja obsługuje dokładnie jedno wejście.
3. Dla jednej pary `(actor_type, actor_id)` trwa najwyżej jedna aktywacja,
   od pobrania stanu do rozstrzygnięcia transakcji albo odrzucenia próby.
4. Różne instancje mogą postępować współbieżnie. Brak gwarancji kolejności
   między różnymi mailboxami lub równoległymi producentami.
5. Aktor emituje zero, jedną albo wiele typowanych wiadomości. Emisja jest
   wynikiem obsługi; wiadomości stają się widoczne dopiero po zatwierdzeniu.
6. Runtime przechowuje zatwierdzony stan, przyjęte wejścia, outbox, wyniki,
   zegary i stan agregacji trwale. RAM może być cache'em, nie źródłem prawdy.
7. Obieg w kopercie jest niezmienny przez całe wykonanie. Zmiana pliku
   definicji nie zmienia wiadomości już przyjętych ani kolejnych ich potomków.
8. Asynchroniczność oznacza brak oczekiwania na wykonanie odbiorcy podczas
   emisji. Zapis do trwałego magazynu i oczekiwanie klienta na wynik są
   osobnymi operacjami. Żaden agregator nie blokuje fibera między wejściami.
9. Zarejestrowane moduły są zaufanym kodem aplikacji. Runtime nie jest
   sandboxem: błąd FFI, zakończenie procesu lub nieskończona pętla mogą
   przekroczyć granicę izolacji zwykłych wyjątków OCaml.

## Granica zmiany

Nowa semantyka dotyczy wyłącznie Well.Actor. Well.Service, MessageBus,
HTTP, RPC, LiveView, well.web, SQL aplikacji, sesje i format istniejących
kontraktów usług zachowują swoje API i zachowanie. Aplikacja niewłączająca
nowego Actor nie otrzymuje magazynu, nowych tras ani dodatkowych workerów.

Nie zmienia się ogólna wizja Well w ROADMAP. Niniejszy kontrakt określa
Well.Actor; opisy Well.Service pozostają kontraktem Well.Service.
Nie dodaje się automatycznych endpointów HTTP ani integracji z MessageBus.
Aplikacja może jawnie wywołać Actor z istniejącego handlera HTTP.

## Scenariusze

- Dwa wejścia do Room/5 wykonują się kolejno, a wejście do Room/8 może
  postępować w tym czasie. Ponowienie nie przepuszcza nowszego wejścia tego ID.
- Room emituje Accepted albo Rejected; obieg wybiera trasę na podstawie
  rodzaju wyemitowanej wiadomości, bez wiedzy aktora o odbiorcy.
- Aktor emituje trzy Requests albo węzeł fork kopiuje jeden Request do
  trzech odbiorców. Scalenie zbiera dokładnie wyniki utworzonych gałęzi.
- Dwa wykonania tego samego obiegu nie współdzielą agregatora, choć mogą
  współdzielić domenową instancję Room/5.
- Po awarii między zatwierdzeniem Room i dostarczeniem emisji router
  dostarcza zachowany outbox bez ponownego zatwierdzania Room.
- Nowa wersja obiegu jest używana przez nowe wykonania; istniejące kończą
  się według kopii niesionej w kopertach.

## Weryfikacja

[STP.md](STP.md) jest źródłem scenariuszy testowych. Akceptacja wymaga
zgodności API, walidatora, generatora oraz trwałych przejść po awarii.
