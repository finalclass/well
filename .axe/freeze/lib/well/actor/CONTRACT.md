# Kontrakty aktorów, typy i generowanie

## TOML

Kontrakt typu aktora używa istniejącego języka `[msg.*]` i osobnej tabeli
`[actor]`. Definicje wiadomości nie są endpointami RPC.

```toml
[actor]
name = "Reporter"
version = 1

[actor.accepts]
Generate = "Reports.Request"

[actor.emits]
Produced = "Reports.Report"
```

`name`: `[A-Z][A-Za-z0-9_]{0,63}`, zastrzeżony prefiks `__well.` nie jest
dostępny aplikacji. `version`: dodatni integer. accepts jest niepuste,
emits może być puste. Klucze accepts/emits są nazwami konstruktorów OCaml:
`[A-Z][A-Za-z0-9_]{0,63}`. Nazwy w obu zbiorach mogą się powtarzać, ponieważ
są generowane w osobnych modułach Inbound i Outbound.

Wartość każdego wpisu jest kwalifikowaną albo lokalną nazwą wiadomości
z `[msg]`, nie anonimowym JSON-em. Rodzaj wiadomości i typ jej payloadu są
różnymi pojęciami: Produced i Corrected mogą mieć ten sam Reports.Report.

Plik może zawierać `[actor]` wraz z `[msg]`, albo tylko `[msg]` jako wspólny
katalog. Mieszanie `[actor]` i `[service.rpc]` w jednym pliku jest błędem
kontraktu aktorowego. Obecny język i generowanie kontraktów usług nie są
przy tej okazji zmieniane.

Nazwa modułu kontraktu wynika z nazwy pliku, np. `Reports.toml` → Reports.
Nazwy pól rekordów: `[a-z][A-Za-z0-9_]{0,63}`; słowa kluczowe OCaml są
escapowane wyłącznie w wygenerowanym kodzie, nigdy w metadanych i ścieżkach.
Duplikaty, nieznane klucze, nieznane referencje, kolizje nazw po normalizacji,
cykliczne definicje typów i jednoczesne struct+variant są odrzucane.

## Współdzielone typy

```toml
[msg.Request.struct]
reporter_id = "string"
subject = "string"

[msg.RequestList.struct]
requests = { type = "list", of = "Request" }

[msg.Report.struct]
source = "string"
text = "string"

[msg.ReportBatch.struct]
items = { type = "list", of = "Report" }

[msg.Summary.struct]
text = "string"
```

Każdy kwalifikowany typ jest zdefiniowany dokładnie raz. Aktorzy zależą od
biblioteki wspólnych kontraktów, nie od implementacji pozostałych aktorów.
Definicje wiadomości używanych w przykładach są kompletne w examples.

## Typy i wire

Obsługiwane typy: string, int, float, bool, void, date, record; kwalifikowane
referencje do struct/variant; list of i optional w istniejącej składni TOML.
`ctx` nie jest typem wiadomości Actor: dane kontekstu aplikacji deklaruje się
jawnie jako rekord. Brak automatycznego wstrzykiwania rpc_ctx.

- struct → tablica wartości w kolejności deklaracji pól TOML;
- variant → `["Constructor", payload]`;
- optional → null dla braku, wartość dla obecności; pozycja nie znika;
- list → tablica elementów; void → null;
- record → obiekt JSON; string/date → string, bool → boolean;
- float → skończona liczba; int → integer w przedziale bezpiecznym JSON,
  `[-9007199254740991, 9007199254740991]`.

Actor odrzuca NaN, Infinity, duplikaty kluczy, niezgodne długości tablic,
nieznane tagi wariantów i wartości poza zakresem. `record` nie umożliwia
statycznego adresowania input_path ani nie zastępuje typowanego wejścia.
Date ma postać string jak w kontraktach Well; brak dodatkowego parsowania
kalendarzowego w wersji 1. Reguła int dotyczy Actor, nie zmienia RPC.

## Metadane

Generator zapisuje descriptor.json:

- format=1;
- modules: nazwy kontraktów;
- messages: kwalifikowana nazwa → rodzaj, uporządkowane pola/konstruktory,
  referencje do typów, optional i wire-index dla pola;
- actors: nazwa typu → version, accepts, emits;
- schema_hash per typ oraz actor_contract_hash per typ aktora.

Listy pól zachowują kolejność TOML, nawet jeśli słowniki mają sortowane
klucze. Hash typu uwzględnia jego kwalifikowaną nazwę, uporządkowany schemat
oraz pełne, topologicznie rozwinięte referencje. Hash kontraktu aktora
uwzględnia nazwę, version i typy accepts/emits wraz z hashami.

Kanonizacja: [RFC 8785 (JCS)](https://www.rfc-editor.org/rfc/rfc8785), UTF-8, SHA-256, zapis małymi literami hex.
Dotyczy deskryptorów, workflow i porównywania admission. Wartości wejścia
muszą spełniać ograniczenia JSON/JCS; kodowanie −0 jest kanonicznym 0.
Hash nie jest podpisem ani mechanizmem autoryzacji.

Niezgodność nazwy lub hasha wyklucza automatyczne połączenie. Dwa schematy
identyczne strukturalnie, lecz o różnych nazwach, wymagają jawnej konwersji.
Zmiana kolejności pól zmienia wire i hash. Runtime nie ignoruje tego przy
odtwarzaniu starych wiadomości.

## Wynik generowania

Dla każdego modułu kontraktu:

- OCaml: typy wiadomości, make, to_wire, of_wire oraz witness message_type;
- dla typu aktora: Inbound.t, Outbound.t, IMPL i make : (module IMPL) → definition;
- osobna biblioteka typów i metadanych bez implementacji aktorów;
- descriptor.json do walidacji obiegu i przyszłego edytora.

Przykładowe API Reporter:

```ocaml
module Inbound : sig
  type t = Generate of Reports.Request.t
end

module Outbound : sig
  type t = Produced of Reports.Report.t
end

type inbound = Inbound.t
type outbound = Outbound.t

module type IMPL = sig
  type state
  val state_version : int
  val init : Well.Actor.actor_id -> state
  val state_to_wire : state -> Yojson.Safe.t
  val state_of_wire : Yojson.Safe.t -> (state, string) result
  val handle : Well.Actor.context -> state -> inbound ->
    (state * outbound list, Well.Actor.failure) result
end

val make : (module IMPL) -> Well.Actor.definition
```

Moduł `Reports.Request` udostępnia `message_type : t Well.Actor.message_type`.
To umożliwia `Message (Reports.Request.message_type, request)` przy send.
Źródłowa biblioteka Reporter nie musi znać nazwy kolejnego węzła.

State ma własny codec i state_version: TOML opisuje zewnętrzne wiadomości,
nie narzuca modelu prywatnego stanu. Nie ma funkcji Proxy wykonujących RPC
pod rodzajami wiadomości aktora. Pierwsza wersja wymaga generatora OCaml
oraz JSON metadata; dodatkowe języki nie są wymagane do uruchomienia Actor.
Nie zmienia się outputu istniejącego generatora TS/Go/Dart/browser dla RPC.

## Wiązanie generowanego modułu z runtime'em

Podmoduł `Well.Actor.Generated` jest publiczną, wersjonowaną powierzchnią
dla wygenerowanego kodu, nie alternatywnym sposobem routingu:

```ocaml
module type RAW_ACTOR = sig
  type state
  type inbound
  type outbound
  val state_version : int
  val init : actor_id -> state
  val state_to_wire : state -> Yojson.Safe.t
  val state_of_wire : Yojson.Safe.t -> (state, string) result
  val inbound_of_wire : kind:string -> Yojson.Safe.t -> (inbound, string) result
  val outbound_to_wire : outbound -> string * Yojson.Safe.t
  val handle : context -> state -> inbound ->
    (state * outbound list, failure) result
end

val descriptor : Yojson.Safe.t -> (descriptor, error list) result
val define : descriptor -> actor_type:string ->
  (module RAW_ACTOR) -> (definition, error list) result
val message_type : descriptor -> name:string ->
  encode:('a -> Yojson.Safe.t) ->
  decode:(Yojson.Safe.t -> ('a, string) result) ->
  ('a message_type, error) result
```

Generator opakowuje IMPL w RAW_ACTOR, dołącza wygenerowane kodeki i
zweryfikowany descriptor. Niepoprawne metadane w ręcznie zmienionym kodzie
zwracają błąd; wygenerowane make może zgłosić Invalid_argument przy błędzie
własnego artefaktu, przed register_type. Runtime dodatkowo waliduje każdy wire
względem deskryptora, niezależnie od kodeka modułu.

## Powtarzalność i błędy generatora

Te same pliki wejściowe dają bajtowo identyczne artefakty; brak czasu,
losowych identyfikatorów i zależności od kolejności katalogu. Generator
najpierw parsuje oraz waliduje cały katalog. Błąd kontraktu nie pozostawia
częściowo podmienionego zestawu wyników. Błędy zawierają plik, ścieżkę tabeli
i powód. Brak cichego zastępowania nieznanego typu stringiem.

Generator nie kompiluje implementacji ani nie otwiera magazynu Actor.
Przykłady TOML podlegają temu samemu parserowi i walidatorowi co aplikacja.

## Narzędzie w granicy Actor

Generowanie jest oddzielne od istniejącego well contract build:

```ocaml
module Contract : sig
  val build : source_dir:string -> output_dir:string ->
    (unit, error list) result
end
```

Pełna nazwa: Well.Actor.Contract.build. Jest wywoływalne z krótkiego
programu OCaml aplikacji lub narzędzia build, przed uruchomieniem runtime'u.
Nie wymaga configure/register_type. Katalog source_dir zawiera wyłącznie
kontrakty aktorów i ich wspólne typy. Podanie kontraktu service.rpc jest
błędem tego narzędzia, nie zmianą obsługi RPC w Well.

Output: ocaml/<snake_case_module>.ml, ocaml/<snake_case_module>.mli,
ocaml/dune oraz descriptor.json. Biblioteka w ocaml/dune nazywa się
actor_contracts i zależy od well.core oraz yojson. Nie łączy implementacji
aktorów. Output_dir musi być odrębnym katalogiem dedykowanym temu narzędziu;
nie nadpisuje się katalogu dotychczasowego generatora RPC.

Build tworzy wynik w katalogu tymczasowym obok output_dir. Jeśli output_dir
istnieje i zawiera inne pliki niż poprzedni manifest Actor, zwraca błąd.
Podmiana jest wykonywana dopiero po pełnym wygenerowaniu i sprawdzeniu
zestawu; poprzedni poprawny katalog można odtworzyć po błędzie podmiany.
Nie deklaruje się atomowego publish wielu plików przy awarii systemu;
manifest zawiera odciski plików, a kolejny build wykrywa niepełny zestaw
i odtwarza go. Nie uruchamia się kompilatora na niekompletnym manifeście.

Parser/generator aktorów należy do Well.Actor.Contract. Nie zmienia się
lib/well_cli/contract_parser.ml, contract_codegen.ml ani cmd_contract.ml.
Wspólna składnia wiadomości jest testowana względem przykładów Well,
bez refaktoryzowania istniejącej ścieżki codegenu.

## Struktura JSON deskryptora

Pola opisowe schematu mają następującą jednoznaczną postać:

- typ prymitywny: {"kind":"primitive","name":"string"} (analogicznie inne);
- referencja: {"kind":"reference","name":"Reports.Report"};
- lista: {"kind":"list","element":TYPE};
- optional: {"kind":"optional","element":TYPE};
- rekord: {"kind":"struct","fields":[{"name":"source","type":TYPE,"index":0},...]};
- wariant: {"kind":"variant","constructors":[{"name":"Accepted","type":TYPE},...]}.

Top-level descriptor to dokładnie {format, modules, messages, actors}.
Modules jest uporządkowaną listą nazw. Messages to słownik kwalifikowana
nazwa → {schema, schema_hash}. Actors to słownik nazwa → {version, accepts,
emits, actor_contract_hash}; accepts/emits mapują rodzaj na kwalifikowany typ.
Index pól zaczyna się od zera i pokrywa się z pozycją w fields. Optional
jest węzłem typu, nie niezależnym sprzecznym znacznikiem obok niego.

Hash typu jest SHA-256 JCS obiektu {name, schema}, w którym każda referencja
została zastąpiona {kind:"resolved", name, schema} rekurencyjnie. Hash aktora
jest SHA-256 JCS obiektu {name, version, accepts, emits}, gdzie wartości
accepts/emits są obiektami {name, schema_hash}. Hash nie obejmuje samego siebie.
Hash workflow jest SHA-256 JCS pełnego JSON-a definicji. Idempotencja admission
porównuje JCS obiektu {workflow, payload_type, schema_hash, payload, timeout_ms}.

Catalog używa tego formatu, ale actors zawiera wyłącznie typy faktycznie
zarejestrowane przez register_type. Rejestracja kilku definicji z identycznym
opisem wspólnego typu jest dozwolona; ta sama kwalifikowana nazwa z innym
schematem jest InvalidContract. Workflow.validate wymaga, aby wszystkie jego
typy wiadomości były obecne w katalogu zarejestrowanych definicji. Przykład
obliczeniowy z samym end również wymaga załadowanego katalogu przez rejestrację
definicji, choć nie aktywuje tego aktora.

## Przebieg budowania

```use-case
Wygeneruj kontrakty Actor

[Odczytaj katalog źródłowy]
[Parsuj wszystkie TOML i rozwiąż typy]
<zebrane błędy>
  (END Error list)
[Sprawdź własność katalogu wynikowego]
<obce pliki>
  (END Error list)
[Wygeneruj pełny zestaw w katalogu tymczasowym]
[Sprawdź metadane i zapisz manifest]
[Podmień poprzedni zestaw]
(END Ok)
```

Generated.descriptor parsuje i sprawdza powyższy format, referencje i hashe;
Generated.define sprawdza istnienie actor_type i dodatnią state_version;
Generated.message_type sprawdza istnienie kwalifikowanego typu. Błędy są
zwracane bez rejestracji ani tworzenia instancji. Funkcje te nie wywołują
init/handle; pełne sprawdzanie kodeków następuje na wartościach w runtime.
