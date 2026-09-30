# Kontrakty aktorów, typy i generowanie

## Źródła i metadane

Wiadomości aktora definiuje się w źródłach `.cyrograf`; Cyrograf jest jedynym
właścicielem gramatyki typów i generowania kodeków. Well utrzymuje wyłącznie
metadane typu aktora — tabelę `[actor]` w osobnym pliku Well, np.
`Reporter.actor.toml`. `[actor]` nie jest interpretowane przez Cyrograf.
Definicje wiadomości nie są endpointami RPC.

```toml
# Reporter.actor.toml
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
z `.cyrograf`, nie anonimowym JSON-em. Rodzaj wiadomości i typ jej payloadu są
różnymi pojęciami: Produced i Corrected mogą mieć ten sam Reports.Report.

Adapter Well obsługuje też zastane, mieszane pliki TOML. Wtedy odczytuje
wyłącznie rozszerzenie `[actor]`, zachowuje kolejność reszty i przekazuje
deklaracje wiadomości do Cyrografu; nie utrzymuje drugiego parsera typów.
Nieznanych kluczy nie wolno zgubić podczas projekcji — są błędem, nie cichym
pominięciem. Mieszanie `[actor]` i `[service.rpc]` w jednym pliku pozostaje
błędem kontraktu aktorowego.

Nazwa modułu kontraktu wynika z nazwy pliku, np. `Reports.cyrograf` → Reports.
Nazwy pól rekordów są walidowane przez Cyrograf według jego języka. Duplikaty,
nieznane klucze, nieznane referencje, kolizje nazw po normalizacji, cykliczne
definicje typów i jednoczesne struct+variant odrzuca Cyrograf.

## Współdzielone typy

```cyrograf
struct Request {
  reporter_id: String
  subject: String
}

struct RequestList {
  requests: List<Request>
}

struct Report {
  source: String
  text: String
}

struct ReportBatch {
  items: List<Report>
}

struct Summary {
  text: String
}
```

Każdy kwalifikowany typ jest zdefiniowany dokładnie raz. Aktorzy zależą od
biblioteki wspólnych kontraktów, nie od implementacji pozostałych aktorów.
Definicje wiadomości używanych w przykładach są kompletne w examples.

## Typy i Drut

Obsługiwane typy i reguły języka należą do Cyrografu: string, int, float, bool,
void, date, record; kwalifikowane referencje do struct/variant; list i optional
w składni `.cyrograf`. `ctx` nie jest typem wiadomości Actor: dane kontekstu
aplikacji deklaruje się jawnie jako rekord. Brak automatycznego wstrzykiwania
rpc_ctx; Cyrograf odrzuca źródłowy `Ctx` jako `UnsupportedFrameworkType`.

- struct → tablica wartości w kolejności deklaracji pól;
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
Wiadomości zewnętrzne przechodzą przez Drut tekstowy, a nie przez pośredni
JSON AST, który mógłby zaokrąglić liczbę.

## Metadane

Adapter Well odwzorowuje schemat Cyrografu na dotychczasowy `descriptor.json`:

- format=1;
- modules: nazwy kontraktów;
- messages: kwalifikowana nazwa → rodzaj, uporządkowane pola/konstruktory,
  referencje do typów, optional i wire-index dla pola;
- actors: nazwa typu → version, accepts, emits;
- schema_hash per typ oraz actor_contract_hash per typ aktora.

Listy pól zachowują kolejność źródła, nawet jeśli słowniki mają sortowane
klucze. Hash typu uwzględnia jego kwalifikowaną nazwę, uporządkowany schemat
oraz pełne, topologicznie rozwinięte referencje. Hash kontraktu aktora
uwzględnia nazwę, version i typy accepts/emits wraz z hashami. Plik
`schema.json` Cyrografu jest odrębnym artefaktem i nie zastępuje deskryptora;
odwzorowanie jest jawne i porównywane JCS/SHA-256 ze starym wynikiem dla
niezmienionego znaczenia. Nowe typy natywne bez starego odpowiednika nie
otrzymują pozornej gwarancji zgodności.

Kanonizacja: [RFC 8785 (JCS)](https://www.rfc-editor.org/rfc/rfc8785), UTF-8, SHA-256, zapis małymi literami hex.
Dotyczy deskryptorów, workflow i porównywania admission. Wartości wejścia
muszą spełniać ograniczenia JSON/JCS; kodowanie −0 jest kanonicznym 0.
Hash nie jest podpisem ani mechanizmem autoryzacji.

Niezgodność nazwy lub hasha wyklucza automatyczne połączenie. Dwa schematy
identyczne strukturalnie, lecz o różnych nazwach, wymagają jawnej konwersji.
Zmiana kolejności pól zmienia wire i hash. Runtime nie ignoruje tego przy
odtwarzaniu starych wiadomości.

## Wynik generowania

Cyrograf generuje typy wiadomości oraz `to_drut`/`from_drut`; Well dokłada
adaptery typu aktora. Dla każdego modułu kontraktu:

- Cyrograf (OCaml): typy wiadomości, `make` oraz `to_drut`, `from_drut`;
- Well (adapter aktora): witness `message_type`, Inbound.t, Outbound.t, IMPL
  i `make : (module IMPL) → definition`;
- osobna biblioteka typów i metadanych bez implementacji aktorów;
- `descriptor.json` do walidacji obiegu i przyszłego edytora.

Well używa wyłącznie publicznych konwersji Cyrografu (`to_drut`/`from_drut`)
i nie utrzymuje własnej kopii kodeka ani drugiego parsera typów.

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

State ma własny codec i state_version: Cyrograf opisuje zewnętrzne wiadomości,
nie narzuca modelu prywatnego stanu. Wiadomości zewnętrzne są konwertowane przez
`to_drut`/`from_drut`; runtime otrzymuje surowy tekst payloadu przed jakimkolwiek
krokiem, który mógłby zaokrąglić liczbę. Nie ma funkcji Proxy wykonujących RPC
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

Generator (Cyrograf plus adapter Well) opakowuje IMPL w RAW_ACTOR, dołącza
wygenerowane kodeki i zweryfikowany descriptor. Niepoprawne metadane w ręcznie
zmienionym kodzie zwracają błąd; wygenerowane make może zgłosić Invalid_argument
przy błędzie własnego artefaktu, przed register_type. Runtime dodatkowo waliduje
każdy wire względem deskryptora, niezależnie od kodeka modułu.

## Powtarzalność i błędy generatora

Te same pliki wejściowe dają bajtowo identyczne artefakty; brak czasu,
losowych identyfikatorów i zależności od kolejności katalogu. Generator
najpierw parsuje oraz waliduje cały katalog. Błąd kontraktu nie pozostawia
częściowo podmienionego zestawu wyników. Błędy zawierają plik, ścieżkę
deklaracji i powód. Brak cichego zastępowania nieznanego typu stringiem.

Generator nie kompiluje implementacji ani nie otwiera magazynu Actor.
Przykłady `.cyrograf` podlegają temu samemu parserowi i walidatorowi co aplikacja.

## Narzędzie w granicy Actor

Generowanie kontraktów aktora jest wejściem bibliotecznym:

```ocaml
module Contract : sig
  val build : source_dir:string -> output_dir:string ->
    (unit, error list) result
end
```

Pełna nazwa: Well.Actor.Contract.build. Jest wywoływalne z krótkiego
programu OCaml aplikacji lub narzędzia build, przed uruchomieniem runtime'u.
Nie wymaga configure/register_type. Katalog source_dir zawiera wyłącznie
kontrakty aktorów, ich wspólne typy i metadane `[actor]`. Podanie kontraktu
service.rpc jest błędem tego narzędzia, nie zmianą obsługi RPC w Well.

Wiadomości pochodzą z Cyrografu; adaptery aktora są generowane w Well.
Kierunek zależności to `well.core -> narzędzie kontraktowe -> cyrograf.compiler`,
nigdy odwrotnie. Output: `ocaml/<snake_case_module>.ml`,
`ocaml/<snake_case_module>.mli`, `ocaml/dune` oraz `descriptor.json`.
Biblioteka danych w `ocaml/dune` zależy od publicznej biblioteki wiadomości
Cyrografu, `well.core` oraz yojson; nie łączy implementacji aktorów.
Output_dir musi być odrębnym katalogiem dedykowanym temu narzędziu; nie
nadpisuje się katalogu dotychczasowego generatora RPC.

Build tworzy wynik w katalogu tymczasowym obok output_dir. Jeśli output_dir
istnieje i zawiera inne pliki niż poprzedni manifest Actor, zwraca błąd.
Podmiana jest wykonywana dopiero po pełnym wygenerowaniu i sprawdzeniu
zestawu; poprzedni poprawny katalog można odtworzyć po błędzie podmiany.
Nie deklaruje się atomowego publish wielu plików przy awarii systemu;
manifest zawiera odciski plików, a kolejny build wykrywa niepełny zestaw
i odtwarza go. Nie uruchamia się kompilatora na niekompletnym manifeście.

Parser/generator typów wiadomości należy do Cyrografu. Well nie utrzymuje
drugiego parsera typów ani kopii kodeka. Stara ścieżka
`lib/well_cli/contract_parser.ml`, `contract_codegen.ml` i `cmd_contract.ml`
jest usuwana dopiero po przepięciu wszystkich odwołań (W7). Migrację
realizuje [integracja Well z Cyrografem](../well_cli/contract/SERVICE.md).

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
[Wywołaj analizę Cyrografu dla wiadomości]
[Odczytaj metadane [actor] i rozwiąż accepts/emits]
<zebrane błędy>
  (END Error list)
[Odwzoruj schemat na descriptor]
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
