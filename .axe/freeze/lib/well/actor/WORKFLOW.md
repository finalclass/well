# Obieg i koperta — wersja 1

## Definicja obiegu

Definicja jest zwykłym JSON-em. Każda przyjęta i emitowana koperta zawiera
cały dokument `workflow`, nie tylko referencję do globalnego diagramu.
Runtime może współdzielić niezmienne obiekty w RAM, ale odtworzenie koperty
nie wymaga obecności pierwotnego pliku definicji.

Główne pola, wszystkie wymagane:

| Pole | Typ | Znaczenie |
|---|---|---|
| format | integer, dokładnie 1 | wersja języka |
| name | string | nazwa obiegu |
| version | string | wersja ustalona przez aplikację |
| entry | string | ID węzła wejściowego |
| input_type | string | kwalifikowana nazwa kontraktu payloadu wejścia |
| bindings | object string→string | niezmienne parametry adresowania |
| nodes | object ID→node | wszystkie węzły |

Nieznane klucze, duplikaty kluczy JSON, brakujące pola i złe typy są błędem.
Nazwy obiegu, wersji, węzłów, bindingów i rodzaju wiadomości nie są kodem.
Brak `eval`, skryptów, wyrażeń OCaml i dostępu do środowiska procesu.
ID węzła i bindingu: `[A-Za-z][A-Za-z0-9_]{0,63}`. Nazwa/wersja: niepusty
UTF-8, do 128 bajtów. ID aktora: niepusty UTF-8, do 256 bajtów, traktowany
jako wartość, nigdy ścieżka pliku. Nazwa typu jest określona w CONTRACT.md.

Typy payloadów są kwalifikowanymi nazwami z katalogu kontraktów. Zgodność
wymaga tego samego typu i odcisku schematu. Podobieństwo pól nie jest
niejawną konwersją. Transformacje wykonuje jawny aktor.

## Węzeł actor

Wymagane pola:

```json
{
  "kind": "actor",
  "actor": "Reporter",
  "id": {"binding": "reporter_id"},
  "accept": "Generate",
  "emission_mode": "many",
  "outputs": {"Produced": "collect"},
  "join": "collect"
}
```

- `actor`: zarejestrowany typ; `accept`: nazwa przyjmowanej wiadomości.
- `id`: dokładnie jedna postać `{"fixed":"default"}`, `{"binding":"name"}`
  albo `{"input_path":["room_id"]}`. `input_path` to niepusta lista nazw pól
  rekordów, prowadzona przez metadane kontraktu do wymaganego pola string.
  Listy, warianty i optional na ścieżce nie są dozwolone. Runtime odczytuje
  pozycyjny JSON zgodnie z kontraktem; nie indeksuje obiektu po nazwie pola.
- `emission_mode`: `one` = dokładnie jedna emisja; `optional` = zero lub jedna;
  `many` = dowolna liczba do limitu. Wynik sprzeczny z deklaracją unieważnia
  próbę przed commit. Zero emisji kończy token, z zastrzeżeniem otwartego join.
- `outputs`: każda zadeklarowana przez typ wiadomość emitowana ma dokładnie
  jednego odbiorcę-węzeł. Brak trasy nie jest cichym pominięciem. Cel `end`
  lub `drop` musi być jawnym węzłem. Niedeklarowane nazwy są błędem.
- `join`: ID węzła join albo `null`. Wartość różna od null otwiera grupę
  dla całej listy emisji tej konkretnej aktywacji. Jedna emisja tworzy jedną
  gałąź, również gdy kilka emisji ma ten sam rodzaj i trafia do tego samego
  węzła. Kolejność listy wyznacza ordynały gałęzi.

Wybór gałęzi wyraża `emission_mode=one` i różne rodzaje emitowanych wiadomości.
Nie wymaga osobnego silnika predykatów: aktor podejmuje lokalną decyzję,
a obieg przyporządkowuje rodzajowi wiadomości dalszą trasę.

Gdy `join=null`, wiele emisji tworzy niezależne tokeny. Wewnątrz otwartej
gałęzi scalenia węzeł bez własnego join musi mieć `emission_mode=one`:
gałąź ma dostarczyć dokładnie jeden wynik swojemu join. Rozdzielenie
wewnątrz niej wymaga własnej, zagnieżdżonej grupy z jednym wynikiem.

Aktor nie może modyfikować definicji ani pozycji obiegu. W API zachowania
nie otrzymuje `workflow`, tablicy odbiorców ani funkcji send/ask.

## Węzeł fork

Kopiuje jeden payload do kilku gałęzi bez uruchamiania kodu aplikacji:

```json
{
  "kind": "fork",
  "input_type": "Reports.Request",
  "branches": [
    {"name": "finance", "next": "finance"},
    {"name": "sales", "next": "sales"},
    {"name": "stock", "next": "stock"}
  ],
  "join": "collect"
}
```

`branches` to niepusta lista, nazwy są unikalne. Kolejność listy jest
porządkiem wyniku, nie kolejnością wykonania. `join` jest ID albo null.
Wszystkie gałęzie zostają trwale zaplanowane atomowo. Payload i pełny obieg
są kopiowane do każdej koperty. Każde dostarczenie ma osobne message_id.
Fork z join=null wewnątrz otwartej grupy jest niedozwolony.

## Węzeł join

```json
{
  "kind": "join",
  "item_type": "Reports.Report",
  "batch_type": "Reports.ReportBatch",
  "timeout_ms": 30000,
  "next": "summary"
}
```

`batch_type` jest rekordem z dokładnie jednym wymaganym polem `items`,
będącym listą `item_type`. Następny węzeł przyjmuje `batch_type`. Każde
wejście do join ma `item_type`. Różne rodzaje raportów można zawrzeć we
wspólnym typowanym wariancie, np. Finance/Sales/Stock, i agregować listę
tego wariantu. Brak konwersji heterogenicznych JSON-ów do dowolnego rekordu.

Join jest obsługiwany przez wbudowanego aktora `__well.join`. Instancja ma
ID wyznaczone przez `(execution_id, group_id)`. Jego stan i mailbox podlegają
zwykłym gwarancjom Actor. Kod aplikacji nie rejestruje typów `__well.*`.

### Powstanie grupy

Przy commit źródłowego actor/fork runtime ustala group_id, zbiór branch_id,
ordynały, typ wyniku, join_node i absolutny deadline. Ten sam commit
zapisuje początkowy stan agregatora, trwały timer i wszystkie koperty
wychodzące. Nie istnieje wyścig „wynik przyszedł przed utworzeniem grupy”.

Dla actor liczba gałęzi jest liczbą faktycznych emisji. Dla fork wynika
z listy branches. Zero emisji aktora z join tworzy natychmiast pusty batch
bez oczekiwania; dalszy węzeł dostaje `items=[]`. Powstaje jedna kontynuacja.

### Przyjęcie wyniku

Koperta niesie stos otwartych grup. Join musi odpowiadać grupie na szczycie.
Tożsamość wyniku to `(group_id, branch_id)`, nie liczba odebranych kopert.
Duplikat tego samego message_id nie liczy się ponownie. Drugie różne
zatwierdzone wejście dla tej samej gałęzi jest błędem `DuplicateBranch`.

Agregator zapisuje wynik i kończy aktywację. Po skompletowaniu dokładnie
oczekiwanego zbioru emituje jeden batch, zamyka grupę i usuwa jej ramkę
ze stosu. `items` są uporządkowane według ordynałów gałęzi. Kontynuacja
wraca do kontekstu rodzica; dwie grupy i dwa wykonania nie mieszają wyników.

### Zagnieżdżenia

Wewnętrzny fork/actor otwiera nową grupę na stosie. Jego join produkuje
jeden wynik dla dalszej części zewnętrznej gałęzi. Nie może dostarczać
wyników bezpośrednio do zewnętrznego join z pominięciem wewnętrznego.

Dla każdego źródła z join walidator sprawdza wszystkie możliwe trasy do
wskazanego join: żadna gałąź nie może zakończyć się wcześniej ani ominąć
scalenia; zagnieżdżone grupy muszą się zamknąć. Każdy join ma dokładnie
jedno źródło strukturalne, ale dowolnie wiele grup podczas wykonań.
Poza odpowiadającą grupą wejście do join jest błędem.

### Timeout

`timeout_ms` jest wymagane, dodatnie i nie większe od limitu wykonania.
Termin liczony jest od atomowego utworzenia grupy, nie od pierwszego wyniku.
Nie przedłuża się po częściowych odpowiedziach, retry ani restarcie.

Przy każdej próbie zatwierdzenia wyniku agregator sprawdza deadline.
Jeśli czas >= deadline, wynik nie zamyka grupy sukcesem: grupa i wykonanie
kończą się `JoinTimeout`, z listą brakujących branch_id. To samo rozstrzygnięcie
wywołuje trwały timer. Zakończenie jest pojedyncze i atomowe.
Nie emituje się częściowego batcha. Polityka ta jest stała dla wersji 1.

## Węzły końcowe

- `{"kind":"end","input_type":"Reports.Summary"}`: trwale zapisuje
  typowany wynik tokenu i kończy go.
- `{"kind":"drop","input_type":"Reports.Report"}`: jawnie kończy token
  bez wyniku. Nie oznacza błędu.

End/drop są niedozwolone w gałęzi przed jej join. Obieg jest Completed,
gdy nie ma już aktywnych tokenów, niedostarczonych kontynuacji, otwartych
grup ani prób w toku. Może mieć zero lub wiele wyników. Wyniki są
uporządkowane leksykograficznie według ścieżki ordynałów od początku obiegu.
Gdy powstaje błąd terminalny, status Failed ma pierwszeństwo przed Completed.

## Walidacja przed przyjęciem startu

Walidator zbiera błędy z lokalizacjami JSON Pointer, nie uruchamia aktorów
ani I/O aplikacji. Sprawdza strukturę, limity, istnienie entry i celów,
osiągalność wszystkich węzłów, typy, zgodność kontraktów, adresowanie,
kompletność outputs, strukturę grup i zakończenia. Definicja wymaga tylko
typów aktorów, nigdy istniejących instancji. Pierwszy send nie wywołuje init.

Błędy wartości dynamicznych (np. pusty actor_id z poprawnie typowanego
payloadu) mogą wystąpić dopiero podczas wykonywania. Runtime wykrywa je
przed commit źródłowej aktywacji. Walidacja statyczna nie jest gwarancją
poprawności biznesowej ani sukcesu zasobów zewnętrznych.

## Koperta wewnętrzna

Pola w trwałej kopercie:

| Pole | Znaczenie |
|---|---|
| format | 1 |
| execution_id | tożsamość jednego uruchomienia |
| message_id | unikalna tożsamość dostarczenia, stała we wszystkich retry |
| causation_id | message_id rodzica albo null dla wejścia |
| workflow | pełna niezmienna definicja JSON |
| workflow_hash | odcisk zawartości definicji |
| contracts | mapa kwalifikowanych typów i wersji aktorów na odciski schematów |
| node_id | węzeł do wykonania, nie poprzedni węzeł |
| actor_address | rozstrzygnięta para type/ID albo null dla kroku technicznego |
| message_kind | rodzaj wejścia danego aktora albo nazwa komunikatu technicznego |
| payload_type | kwalifikowany typ payloadu |
| payload | pozycjonalny JSON zgodny z kontraktem |
| branch_path | lista ordynałów używana do stabilnego porządkowania |
| groups | stos ramek: group_id, branch_id, ordinal, join_node |
| created_at_ms | UTC epoch ms zapisane przy powstaniu |
| execution_deadline_ms | stały deadline całego wykonania |

Licznik prób i available_at są metadanymi inboxa, nie modyfikacją obiegu.
Group membership i deadline mają autorytatywną kopię w stanie agregatora.
Runtime weryfikuje zgodność ramki z tą kopią; klient nie może podstawić koperty.
Publiczne API przyjmuje tylko definicję i payload pierwszego kroku.

message_id i group_id powstają przed commit, są utrwalone razem z planem
emisji i nie zmieniają się przy redelivery. Próba zakończona przed commit
nie ma widocznych potomków. Nie polega się na aktualnym indeksie w mailboxie.

## Niezmienność i wersjonowanie

Walidowany dokument jest defensywnie kopiowany. Mutacja JSON-a przekazanego
przez klienta po validate/send nie zmienia wykonania. Hash oblicza runtime
według reguł z CONTRACT.md. Identyczne name/version z różną treścią to różne
definicje; execution_id zawsze wskazuje konkretną treść.

Przy restarcie runtime sprawdza kontrakty z kopert przed uruchomieniem
zachowania. Niezgodny kontrakt zatrzymuje dane wykonanie jako Blocked,
bez retry i bez utraty wejść. Zmiana definicji obiegu nie naprawia starych
kopert. Operator przywraca zgodny kod albo jawnie kończy wykonanie.

## Zakres języka

Edytor graficzny jest konsumentem tego formatu, poza implementacją Actor.
Nie ma bezpośredniego dostępu użytkownika HTTP do ładowania obiegów.
Aplikacja sprawdza uprawnienia przed wywołaniem API Actor i wybiera katalog
udostępnianych zachowań. Sam zgodny typ wiadomości nie oznacza uprawnienia.

Wersja 1 dopuszcza wyłącznie acykliczne grafy. Walidator odrzuca cykle,
łącznie z pętlą do tego samego węzła. Powtórzenie typu aktora w różnych
węzłach jest dozwolone. Ponowienia transportowe nie są cyklami obiegu.

Strukturę dokumentu określa również [workflow.schema.json](workflow.schema.json).
JSON Schema sprawdza strukturę i nazwy; walidacja kontraktów, bajtowych
limitów UTF-8, osiągalności i stosu grup pozostaje obowiązkiem Workflow.validate.
Maksima zależne od config są sprawdzane przez runtime, nie zaszyte w schemacie.
