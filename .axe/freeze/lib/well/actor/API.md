# API — Well.Actor

## Publiczne typy

Poniższa sygnatura określa publiczną powierzchnię nowego runtime'u. Typy
abstrakcyjne otrzymują konstruktor lub pochodzą z generatora. Implementacja
projektuje ją na actor.mli; Markdown pozostaje miejscem definicji zachowania.

```ocaml
type actor_id = { actor_type : string; id : string }
type execution_id = string

type error = {
  code : string;
  message : string;
  path : string option;
}

type failure = Retry of string | Fail of string

type context = {
  self : actor_id;
  execution_id : execution_id;
  message_id : string;
  attempt : int;
  deadline_ms : int64;
}

type limits = {
  max_active : int;
  domains : int;
  workflow_bytes : int;
  payload_bytes : int;
  state_bytes : int;
  nodes : int;
  group_depth : int;
  emissions : int;
  deliveries_per_execution : int;
  active_executions : int;
  pending_deliveries : int;
}

type retry_policy = { max_attempts : int; delays_ms : int list }
type config = {
  store_path : string;
  limits : limits;
  retry_policy : retry_policy;
}

val default_limits : limits
val default_retry_policy : retry_policy
val configure : config -> (unit, error) result

type descriptor
type definition
type 'a message_type

type packed_message =
  | Message : 'a message_type * 'a -> packed_message

val message_type_name : 'a message_type -> string
val encode : 'a message_type -> 'a -> Yojson.Safe.t
val decode : 'a message_type -> Yojson.Safe.t -> ('a, error) result
val register_type : definition -> (unit, error) result
val catalog : unit -> Yojson.Safe.t

module Workflow : sig
  type t
  val validate : Yojson.Safe.t -> (t, error list) result
  val to_json : t -> Yojson.Safe.t
end

val send :
  request_id:string ->
  timeout_ms:int ->
  Workflow.t -> packed_message -> (execution_id, error) result

type location = {
  node_id : string;
  message_id : string;
  actor : actor_id option;
  attempt : int;
  at_ms : int64;
}

type diagnostic = {
  error : error;
  location : location option;
  missing_branches : string list;
}

type output = {
  path : int list;
  payload_type : string;
  schema_hash : string;
  payload : Yojson.Safe.t;
}

type execution_status =
  | Running
  | Blocked of diagnostic list
  | Completed
  | Failed of diagnostic

type snapshot = {
  execution_id : execution_id;
  request_id : string;
  status : execution_status;
  outputs : output list;
  pending_messages : int;
  open_groups : int;
  deadline_ms : int64;
}

type await_result = Terminal of snapshot | Wait_timeout of snapshot

val inspect : execution_id -> (snapshot, error) result
val await : timeout_ms:int -> execution_id -> (await_result, error) result
val decode_output : 'a message_type -> output -> ('a, error) result
val errors : execution_id -> (diagnostic list, error) result
val resume : execution_id -> (unit, error list) result
val abandon : execution_id -> reason:string -> (unit, error) result
val metrics : unit -> Yojson.Safe.t
```

`packed_message` zachowuje powiązanie wartości z jej kodekiem OCaml.
JSON jest używany do ładowania obiegu i obserwacji administracyjnej,
nie zastępuje typowanego wejścia aplikacji. `decode_output` najpierw
sprawdza nazwę i hash typu, potem dekoduje payload.

Kody błędów admission: NotConfigured, NotRunning, AlreadyConfigured,
RegistryFrozen, DuplicateActorType, InvalidContract, InvalidWorkflow,
InvalidInput, InvalidConfiguration, IdempotencyConflict, Overloaded,
StorageUnavailable, UnknownExecution, InvalidOperation, SchemaMismatch.
Kody wykonania: ActorFailed, AttemptsExhausted, InvalidEmission,
InvalidAddress, DuplicateBranch, InvalidGroup, JoinTimeout, ExecutionTimeout,
LimitExceeded, SchemaMismatch, Abandoned. Szczegóły lokalizacji są danymi,
nie częścią tekstu, który klient musiałby parsować.

## Kontrakt zachowania

Dla kontraktu wygenerowany moduł ActorContract zawiera typy `inbound`,
`outbound` i własny moduł typu implementacji:

```ocaml
module type IMPL = sig
  type state
  val state_version : int
  val init : actor_id -> state
  val state_to_wire : state -> Yojson.Safe.t
  val state_of_wire : Yojson.Safe.t -> (state, string) result
  val handle : context -> state -> inbound ->
    (state * outbound list, failure) result
end

val make : (module IMPL) -> definition
```

`inbound` i `outbound` pochodzą z kontraktu Cyrografu; wiadomości zewnętrzne
używają `to_drut`/`from_drut` na surowym tekście. Kodeki stanu są własnością
aktora; kodeki wiadomości są generowane. `state_version` jest dodatnią liczbą.
Zmiana wymagająca innego odczytu blobu wymaga zwiększenia wersji. Runtime
nie wywołuje state_of_wire przy niezgodnej wersji i nie zastępuje stanu init.

`handle` może zwrócić nowy stan i pustą listę. Nie ma uprzywilejowanego
rodzaju `reply`. Każda emisja podlega obiegowi. Aktor nie oczekuje na
zakończenie innego aktora i nie wywołuje API send/await/resume/abandon.

Runtime nie przekazuje HTTP request, sesji, globalnego klienta RPC ani
adresów odbiorców. Dane użytkownika wymagane do działania są typowanym
payloadem. context służy do tożsamości, diagnostyki i idempotencji.

Typ aktora buduje się w osobnej bibliotece dune zależnej tylko od kontraktów,
Well.Actor i jawnych interfejsów swoich zależności. Implementacje innych
typów i definicje obiegów nie są zależnościami kompilacji tej biblioteki.
Rejestracja składa definicje, nie tworzy instancji.

## Configure i register_type

`configure` może być wywołane raz przed startem; waliduje dodatnie limity,
ścieżkę magazynu i retry policy (`delays_ms` ma max_attempts−1 elementów).
Otwarcie magazynu i blokada właściciela następują przy starcie runtime'u.
`register_type` odrzuca powtórzoną nazwę typu i niezgodny deskryptor. Rejestr jest
zamrażany przy starcie, także gdy nie ma jeszcze żadnej instancji.

```use-case
Zarejestruj definicję

<runtime już uruchomiony>
  (END RegistryFrozen)
<nazwa już istnieje>
  (END DuplicateActorType)
<deskryptor niepoprawny>
  (END InvalidContract)
[Zapisz niezmienną definicję]
(END Ok)
```

`catalog` działa po rejestracji także przed startem. Zwraca opis z
CONTRACT.md, bez kodu, konfiguracji zależności i sekretów.
`Workflow.validate` działa po rejestracji wymaganych typów; nie wymaga
uruchomienia magazynu. `to_json` zwraca defensywną kopię.

## Send

```use-case
Przyjmij obieg

<runtime nie działa>
  (END NotRunning)
<typ lub wartość wejścia niezgodne z workflow>
  (END InvalidInput)
<timeout poza zakresem>
  (END InvalidInput)
<request_id istnieje z innymi danymi>
  (END IdempotencyConflict)
<request_id istnieje z tymi samymi danymi>
  (END Ok z istniejącym execution_id)
<przekroczony limit admission>
  (END Overloaded)
[AdmitExecution]
(END Ok z nowym execution_id)
```

`send` nie uruchamia handle przed commit admission i nie czeka na wynik
odbiorcy. Dopuszczalne jest zakończenie krótkiego obiegu zanim wywołujący
zdąży wykonać inspect, ale zwrot send nie obiecuje takiego zakończenia.
Wywołanie przed Well.run jest odrzucane: nie ma prowizorycznej kolejki RAM.

## Inspect, await i errors

`inspect` odczytuje spójny snapshot. UnknownExecution jest odróżnione od
Running. Completed/Failed są terminalne i nie zmieniają znaczenia.
Outputs przy Failed mogą zawierać już zatwierdzone wyniki innych gałęzi;
nie oznaczają sukcesu całego wykonania.

`await` sprawdza status przed zasubskrybowaniem i po nim, aby nie zgubić
zakończenia między odczytem a oczekiwaniem. Zwalnia subskrypcję przy timeout
lub anulowaniu wywołującego. Czeka tylko fiber klienta. Completed i Failed
zwracają Terminal; Blocked jest obserwowalne w inspect, ale nie terminalne.
Timeout klienta zwraca Wait_timeout i aktualny snapshot, bez zmiany obiegu.

```use-case
Oczekuj na zakończenie

<nieznane execution_id>
  (END UnknownExecution)
<status terminalny>
  (END Terminal)
[Oczekuj na zmianę albo termin klienta]
<status terminalny>
  (END Terminal)
<_>
  (END Wait_timeout)
```

`errors` zwraca trwałą diagnostykę w kolejności zapisu. Błędy administracyjne
admission bez execution_id są zwracane bez tworzenia pustego wykonania.

## Resume i abandon

`resume` dotyczy tylko Blocked. Sprawdza wszystkie utrwalone odciski i
wersje stanów potrzebnych wykonaniu; jeśli pasują, przywraca Running,
zachowując ID wejść, obieg, próby i pierwotne deadline. Przeterminowane
wykonanie kończy się timeout zamiast otrzymać nowy termin. Rejestr runtime'u
nie jest zmieniany przez resume: zgodny kod musi być załadowany przy starcie.
Running/Completed/Failed zwracają InvalidOperation.

`abandon` dotyczy Running i Blocked. Atomowo zapisuje Failed/Abandoned.
Powtórzenie dla już Abandoned zwraca Ok. Inne terminalne wykonanie daje
InvalidOperation. Nie cofa stanów ani zewnętrznych efektów; semantyka
aktywacji w toku jest taka jak dla innego terminalnego błędu.

```use-case
Wznów zablokowane wykonanie

<status inny niż Blocked>
  (END InvalidOperation)
<niezgodny kontrakt lub wersja stanu>
  (END SchemaMismatch)
[Przywróć gotowość zachowanych wejść]
(END Ok)
```

```use-case
Zakończ administracyjnie

<już Abandoned>
  (END Ok)
<Completed albo Failed z inną przyczyną>
  (END InvalidOperation)
[FailExecution z kodem Abandoned i powodem]
(END Ok)
```

## Metrics

Odczyt zwraca obiekt liczb całkowitych: active_activations, ready_actors,
pending_inbox, pending_outbox, open_joins, running_executions,
blocked_executions, dead_letters, storage_errors. Ostatnie dwa są
licznikami magazynu od jego utworzenia; reszta jest bieżącym stanem.
Brak samoczynnego eksportu do istniejących endpointów Well.

## Lifecycle wewnętrzny

Istniejące wywołanie `Actor.start_all ~sw` przez Well.run pozostaje punktem
startu; podsystem sam zarządza własnymi workerami i zwalnianiem zasobów.
Nie wymaga nowych parametrów Well.run. Testy uruchamiają ten sam lifecycle
na wydzielonym switchu Eio i prywatnym magazynie.

## Zależności i operacje zewnętrzne

Implementacja może wykonać I/O przez jawnie wstrzyknięte interfejsy,
np. funktor z modułem MailTransport lub funkcję konstruktora modułu.
Zależności powstają w kompozycji aplikacji; nie trafiają do state ani kopert.
Nie importuje się implementacji innych aktorów ani globalnego Service client.

Zasób otwarty na czas próby musi zostać zamknięty także przy wyjątku i
anulowaniu. Połączenie SQLite aktora nie jest połączeniem ExecutionStore;
jego zapis nie należy do transakcji runtime'u. Dla operacji zewnętrznej
aktor używa stabilnego klucza idempotencji, np. message_id + lokalna nazwa
operacji; attempt nigdy nie jest częścią tego klucza. Jeśli odbiorca nie
obsługuje deduplikacji, możliwe powtórzenie efektu jest właściwością danego
kontraktu aktora i musi być jawnie opisane przez autora aplikacji.

Wbudowany runtime nie obiecuje rollbacku maila, pliku ani osobnej bazy.
Powrót Retry lub wyjątek po takim efekcie może doprowadzić do jego ponowienia.
Utrwalenie outboxa gwarantuje dostarczenie zamiaru, nie jednokrotny skutek
w dowolnym zewnętrznym systemie.

## Zgodność z dotychczasowym Well.Actor

Istniejące register : ?restart:restart → Service.spec → unit, dispatch,
start_all oraz health zachowują swoje dotychczasowe zachowanie. Rejestrują
stary wariant sekwencyjnego RPC. Nie są automatycznie zamieniane na trwałe
instancje. Nowe typy rejestruje register_type; nowy runtime wymaga configure.

Obie ścieżki pozostają wewnątrz Well.Actor. Nie dodaje się modułu
Well.Legacy_actor, nie zmienia Service.spec, tablicy dispatch usług ani
Service.full_health. Nowe typy nie rejestrują się jako usługi RPC.
Zbieżna nazwa typu nowego aktora i starej usługi nie tworzy połączenia:
API oraz rejestry są rozdzielone. health zachowuje dotychczasowy format
i zakres starych aktorów; nowy model obserwuje się przez inspect/metrics.

Gwarancje trwałości i obiegów z tego pakietu dotyczą register_type/send,
a nie starego register/dispatch. Dokumentacja obu ścieżek oznacza to jawnie.
Nowa aplikacja wybiera register_type. Usunięcie starej ścieżki nie jest
częścią tej zmiany.

## Pozostałe operacje — przebieg

```use-case
Skonfiguruj nowy runtime

<runtime uruchomiony albo konfiguracja już ustalona>
  (END AlreadyConfigured)
<niepoprawna ścieżka, limity lub retry policy>
  (END InvalidConfiguration)
[Zapisz niezmienną konfigurację startową]
(END Ok)
```

```use-case
Zweryfikuj definicję obiegu

[Sprawdź strukturę JSON]
[Sprawdź katalog, typy, adresowanie i reguły grafu]
<zebrane błędy>
  (END Error list)
[Zachowaj niezmienną kopię definicji i wymaganych deskryptorów]
(END Workflow.t)
```

```use-case
Odczytaj wykonanie lub jego błędy

<runtime nie działa>
  (END NotRunning)
<nieznane execution_id>
  (END UnknownExecution)
[Odczytaj spójny snapshot albo uporządkowane błędy]
(END Ok)
```

```use-case
Zdekoduj wartość lub wynik

<output ma inną nazwę typu lub hash niż witness>
  (END SchemaMismatch)
[Sprawdź wire względem schematu]
<niezgodny payload>
  (END InvalidInput)
[Zastosuj kodek przypisany do witness]
(END Ok)
```

Dla decode nie ma porównania output name/hash, bo otrzymuje sam payload;
obowiązuje weryfikacja schematu witness. Encode sprawdza wynik kodeka i przy
niezgodności zgłasza Invalid_argument (to błąd własnego kodeka). Send zamienia
taki błąd na InvalidInput, bez admission. message_type_name odczytuje nazwę
witness; to_json odczytuje kopię dokumentu; catalog odczytuje kopię metadanych.
Są to czyste odczyty, bez aktywacji. Metrics wymaga działającego runtime'u;
przed startem zgłasza Invalid_argument. API z result zwraca NotRunning
zamiast odczytywać zamknięty magazyn.
