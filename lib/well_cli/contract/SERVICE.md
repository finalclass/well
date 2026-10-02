# SERVICE.md — Integracja Well z Cyrografem (budowanie kontraktów)

## Rola

Well komponuje kompilator Cyrografu z własnymi adapterami usług, proxy i
aktorów. Jedno polecenie `well contract build` czyta źródła, wywołuje publiczne
API Cyrografu, generuje dane i integrację Well, a następnie publikuje jeden
kompletny wynik. Well nie posiada własnej gramatyki typów ani kodeków
wiadomości — te należą do Cyrografu.

Granica nie tworzy drugiego procesu, pluginu ani usługi. Cyrograf jest
zewnętrznym systemem udostępnionym jako biblioteka; Well wywołuje jego publiczne
funkcje i nie przenosi logiki kompilatora do siebie.

## Granica abstrakcji

Warstwa ukrywa przed resztą Well: wybór frontendu źródeł, analizę i walidację
Cyrografu, nazewnictwo symboli w językach docelowych, staging i bezpieczną
publikację. Na zewnątrz Well widzi:

- `well contract build [source_dir] [output_dir]` jako jedyne polecenie budowania;
- biblioteki danych z wygenerowanymi wiadomościami (OCaml natywny, OCaml
  przeglądarkowy, TS, Go, Dart) i fasady integracyjne (`contract`,
  `contract_browser`);
- wygenerowane `IMPL`, `make_spec`, `Proxy`, deskryptory i adaptery aktora;
- `to_drut`/`from_drut` jako jedyne publiczne konwersje wiadomości.

Nie zależy od `well.core`. Kierunek zależności to
`well.core -> narzędzie kontraktowe -> cyrograf.compiler`, nigdy odwrotnie.
Generator emituje odwołania do Well jako tekst i nie potrzebuje wykonania Well.
Biblioteki z samymi wiadomościami zależą wyłącznie od runtime'u Cyrografu.

## Kontrakt

### Granice odpowiedzialności

| Co może się zmieniać | Właściciel | Granica |
|---|---|---|
| Składnia kontraktów, typowanie, nazwy targetów, kodowanie danych | Cyrograf | Publiczne `Cyrograf_compiler`, `Cyrograf.Schema`, wygenerowane `to_drut`/`from_drut`. |
| Kolejność przygotowania kompletnego wyniku Well | `Contract_build` | Snapshot źródeł, analiza, generowanie danych, generowanie integracji, jedna publikacja. |
| Wiązanie deklaracji z wykonaniem | `Contract_adapters` | Strategie Service/RPC i Actor na gotowym schemacie; bez własnej gramatyki typów i kodeków. |
| Transport, kontekst, sesja, błędy wywołania | Runtime i adaptery Well | HTTP, socket, wywołanie lokalne, mailbox, przeglądarka. |
| Źródła, układ katalogów, własność wyników | Dostęp do źródeł i artefaktów | Mechanizmy Cyrograf tooling za adapterem integracyjnym; bez kopiowania bezpiecznej publikacji. |
| Pakowanie i szablon aplikacji | Scaffold i Dune Well | Przypięte zależności, ścieżki bibliotek, reguły odtwarzania. |

```call-chain
Budowanie kontraktów Well

[CLI Well]
  -> [Contract_build]
    -> [Dostęp do źródeł]
      -> (Pliki źródłowe)
    -> [Dostęp do Cyrografu]
      -> (Kompilator Cyrograf)
    -> [Contract_adapters]
    -> [Dostęp do artefaktów]
      -> (Kompletny wynik)
```

```call-chain
Budowanie kontraktów Actor

[Well.Actor.Contract.build]
  -> [Contract_build]
    -> [Dostęp do źródeł]
      -> (Wiadomości i deklaracje aktorów)
    -> [Dostęp do Cyrografu]
      -> (Kompilator Cyrograf)
    -> [Contract_adapters]
    -> [Dostęp do artefaktów]
      -> (Typy, adaptery i deskryptor Actor)
```

### Publiczna powierzchnia koordynacji

Kontrakt wiążący w W2. Dokładne typy abstrakcyjne i nazwy plików są detalem
implementacji, ale te operacje i ich znaczenie są wiążące:

```ocaml
module Contract_build : sig
  type error = { code : string; message : string; path : string option }
  type summary = { modules : string list; artifacts : string list }

  val build :
    source_dir:string ->
    output_dir:string ->
    ?targets:Cyrograf_compiler.target list ->
    ?ocaml_profiles:Ocaml_profile.t list ->
    unit ->
    (summary, error list) result
end
```

- Domyślne `targets` to zestaw zgodności Well: OCaml (oba profile), TS, Go, Dart.
- Domyślne `ocaml_profiles` to `[Native; Js]`. `Native` mapuje `Int` na `int`;
  `Js` (js_of_ocaml) mapuje `Int` na `int64`.
- `build` przygotowuje cały zestaw w stagingu i publikuje go raz; błąd dowolnego
  wymaganego targetu pozostawia poprzedni wynik.
- `Well.Actor.Contract.build` pozostaje bibliotecznym wejściem aktora i używa
  tej samej koordynacji.

### Decyzje wiążące (D-INT)

**D-INT-1 — Źródła.** Docelowe źródła to `.cyrograf`. Zwykły TOML pozostaje
wejściem zgodności obsługiwanym przez Cyrograf. W jednym katalogu nie mogą
współistnieć dwie definicje tego samego modułu. Migracja formatu nie zmienia
kolejności pól. Well nie posiada drugiego parsera typów.

**D-INT-2 — Kompilator.** Well używa biblioteki kompilatora; `well contract
build` nie wymaga binarki `cyrograf` w `PATH`. Formatter i LSP pozostają
narzędziami Cyrografu, bez drugiej implementacji w Well.

**D-INT-3 — Artefakty danych.** Typy i kodeki wygenerowane przez Cyrograf są
odrębnymi artefaktami. Well dodaje pliki adapterów i fasady z aliasami, np.
`module Request = Contract_messages.Orders.Request`. Well nie przepisuje
wygenerowanych typów, nie dopisuje transportu do ich plików i nie usuwa ich
`.mli`, aby dostać się do ukrytych funkcji.

**D-INT-4 — Konwersje.** Publiczne konwersje wiadomości to wyłącznie
`to_drut`/`from_drut` w konwencji targetu. Adaptery Well korzystają tylko z nich.
`IMPL`, `make_spec`, `Proxy`, witness aktora i konstruktory należą do innych
aspektów API. Well nie dodaje ogólnej warstwy aliasów starego API.

**D-INT-5 — Zmiany nazw.** Przewidziane są zmiany po escapowaniu (`type'` wobec
`type_`), camelCase w TS/Darcie oraz nowe reprezentacje wariantów. Migracja
konsumentów jest jawna; brak automatycznej warstwy zgodności.

**D-INT-6 — Stary PPX.** `show`, `equal`, `to_yojson`, `of_yojson` ze starego
PPX nie są automatycznie zamienne na pozycyjny Drut. Porównywanie i prezentacja
należą do potrzeb konsumenta; te wywołania migruje się świadomie, nie mechanicznie.

**D-INT-7 — Wyjście i własność.** Domyślny `output_dir` to
`lib/contract_generated`, obok `lib/contract`. Zachowana jest forma
`well contract build [source_dir] [output_dir]`. Jawny output wewnątrz źródeł
zgłasza błąd z instrukcją zmiany ścieżki. Katalogu bez manifestu nie przejmuje
się automatycznie; stary wynik usuwa się dopiero po przepięciu odwołań.

**D-INT-8 — Nazwy bibliotek.** Native i browser OCaml dostają odrębne biblioteki
danych (`contract_data`, `contract_data_browser`) oraz fasady (`contract`,
`contract_browser`). W workspace nie powstają dwie biblioteki Dune o nazwie
`generated_contracts`. Cyrograf przyjmuje nazwę biblioteki danych OCaml
(domyślnie `generated_contracts`); Well jawnie ją ustawia.

**D-INT-9 — Jeden manifest i jedna publikacja.** Pełny zestaw (dane wszystkich
targetów + adaptery Well + deskryptory) jest budowany w pamięci/stagingu i
publikowany raz wspólnym manifestem. Błąd dowolnego wymaganego targetu
pozostawia poprzedni wynik. Ciche pomijanie błędów TS/Go/Dart jest usunięte.

**D-INT-10 — jsoo.** Profil `Js` Cyrografu odwzorowuje `Int` na `int64` i
sprawdza pełny zakres Drutu `[-9007199254740991, 9007199254740991]`. Profil
`Native` zachowuje `int`. Format danych jest identyczny. Well nie utrzymuje
własnej kopii poprawionego kodeka; warunki profilu są zapisane w specyfikacji
Cyrografu (W0) i realizowane w W1.

**D-INT-11 — Zestaw targetów.** Zgodność Well to OCaml native, OCaml browser,
TS, Go, Dart. Pozostałe targety Cyrografu mogą generować same wiadomości przez
jawny wybór. Nowe proxy Python/Java/C#/Rust są oddzielnym rozszerzeniem, nie
częścią tej migracji.

**D-INT-12 — Przypięcie.** Wersja Cyrografu jest przypięta pełną, osiągalną
rewizją w Well i w rozwiązywaniu zależności nowego scaffoldu. Nie zostawia się
ścieżki domowej, placeholdera SHA ani nieistniejącej rewizji jako finalnej
zależności. Przepisanie jedynego root commita Cyrografu nie jest trwałą strategią.

### Układ artefaktów

```text
lib/contract_generated/
  manifest.json          # wspólny: dane, adaptery, deskryptory
  schema.json            # model Cyrografu (format 1)
  ocaml/                 # profil native;  library contract_data
  ocaml_js/              # profil js;      library contract_data_browser
  typescript/
  go/
  dart/
  adapters/              # fasady contract / contract_browser, IMPL, make_spec, Proxy
```

Manifest jest tablicą względnych ścieżek, unikalnych, bez `..`, absolutów i
symlinków. Wejście, wynik i ich podkatalogi nie nakładają się.

### Dispatch tekstowy

**HTTP.** `POST /rpc/<Service>/<method>` zachowuje `application/json`. Ciało
żądania to sam tekst Drutu, bez dodatkowego JSON stringa. Adapter przekazuje
tekst do wygenerowanego `from_drut` przed materializacją payloadu w JSON AST.
Odpowiedź to wynik `to_drut` jako tekst.

**Proxy.** OCaml browser, TS, Go i Dart wywołują `to_drut` i wysyłają tekst,
a czytają tekst odpowiedzi. Nie wykonują `JSON.stringify(text)` na tekście Drutu.

**Socket.** Zachowana jest ramka `{service, rpc, payload}` i odpowiedź
`{result}` albo `{error}`. Adapter ramki musi przekazać oryginalny tekst
payloadu do `from_drut`. Parsowanie ramki nie może wcześniej zaokrąglić liczby
w payloadzie; jeżeli użyte narzędzie tego nie zapewnia, adapter wyodrębnia
surowy fragment tekstu, a brak tej możliwości zgłasza jako konkretny brak
kontraktu — nie zastępuje walidacji przez `stringify` po parsowaniu.

**Wywołanie lokalne.** Wygenerowane funkcje `~ctx` i `IMPL`/`make_spec`
używają typowanych wartości. Starszy Actor i Service zachowują uzgodnioną
reprezentację i kolejność mailboxa; współbieżność się nie zmienia.

**Introspekcja.** Format wejścia REPL/Cap pozostaje. Zachowane wejście
`dispatch_by_name` przyjmujące JSON AST jest adapterem wartości, bez obietnicy
odtworzenia pierwotnych leksemów. Surowe wejścia sieciowe przechodzą pełną
walidację tekstu.

### Kontekst (`ctx`)

Kontekst wykonania jest własnością Well i osobnym argumentem handlera. HTTP
wyznacza go z żądania/sesji; socket i wywołanie lokalne przekazują ustaloną
wartość. Kontrakt wiadomości nie może pozwolić klientowi zastąpić nim tożsamości
wyznaczonej przez serwer.

Legacy pole `ctx` w TOML jest osobnym przypadkiem migracji i wymaga diagnozy
z lokalizacją:

- dane domenowe → zwykła struktura w kontrakcie;
- kontekst wykonania → argument handlera.

Pola nie usuwa się po cichu, bo zmieniłoby to pozycje w Drucie. Stara ścieżka
`Actor.register`/`dispatch` zachowuje `ctx` bez zmian.

### Błędy

Rozróżniane są cztery warstwy. Błąd konwersji nie uruchamia handlera dla
wadliwego requestu. Domenowy wariant odmowy jest zwykłą odpowiedzią domenową.

| Warstwa | Warunek | Wynik |
|---|---|---|
| transport | brak połączenia, timeout, zerwanie | błąd transportu; handler nie uruchomiony |
| framing | niepoprawna ramka socketa, brak `service`/`rpc` | błąd ramki |
| Drut żądania | `from_drut` odrzuca tekst | błąd wywołania; handler nie uruchomiony |
| dispatch | nieznana usługa albo metoda | błąd dispatchu |
| handler | wyjątek w implementacji | błąd wykonania; kolejne wywołania działają |
| Drut odpowiedzi | `to_drut`/`from_drut` odpowiedzi niepoprawne | błąd wykonania |
| domena | wariant odmowy w typie response | odpowiedź domenowa (Drut) |

Mapowanie na HTTP jest wiążące:

- błędny Drut żądania → 400 z ciałem `{"error":"..."}`;
- nieznana usługa/metoda → 404 z ciałem `{"error":"..."}`;
- wyjątek handlera → 500 z ciałem `{"error":"..."}`;
- odpowiedź domenowa → 200 z ciałem Drutu;
- dotychczasowa odpowiedź `{"error":"..."}` na 2xx pozostaje interpretowana
  jako błąd przez Proxy (kompatybilność).

Domyślny Proxy zachowuje kontrakt przeglądarkowy CSRF, cookies i XHR.
TypeScript dodatkowo eksportuje `createProxy(options)` oraz współdzielony
`well_transport.ts`. Opcje to `baseUrl`, `bearerToken` (sekret lub dostawca
synchroniczny/asynchroniczny), `fetch` oraz dodatni `timeoutMs`.
Instancje mają niezależną konfigurację. Bearer używa jawnego Authorization,
`credentials: omit`, nie wysyła CSRF/XHR i odrzuca przekierowania.
Błędy HTTP zachowują `status` w nieudanym ProxyResult; diagnostyka transportu
nie zawiera sekretu ani treści wyjątku. Callback otrzymuje wynik raz.
Domyślne `Proxy` pozostaje zgodne z istniejącymi wywołaniami.
Serwer może włączyć [uwierzytelnianie API tokenów](../../well/SERVICE.md).

### Rozszerzenie Actor

Migracja kontraktów nie przebudowuje aktorów w Cell, nie zmienia schedulera,
magazynu ani semantyki obiegów. Well zachowuje `accepts/emits`, witness,
`Inbound`/`Outbound`, prywatny codec stanu, walidację runtime względem
deskryptora i hashe kontraktów.

- Wiadomości są w `.cyrograf`; metadane aktora w osobnym pliku Well, np.
  `Reporter.actor.toml`. `[actor]` nie jest interpretowane przez Cyrograf.
- Dla obecnych mieszanych plików TOML adapter Well odczytuje wyłącznie
  rozszerzenie `[actor]`, zachowuje kolejność reszty i przekazuje deklaracje
  wiadomości do Cyrografu. Nie utrzymuje drugiego parsera typów; nieznanych
  kluczy nie wolno zgubić podczas projekcji.
- `descriptor.json` Actor pozostaje formatem 1. Plik `schema.json` Cyrografu jest
  odrębnym artefaktem i nie zastępuje deskryptora. Powstaje jawne odwzorowanie
  schematu na dotychczasowy format Actor, porównywane JCS/SHA-256 ze starym
  wynikiem. Zachowane są kwalifikowane nazwy, kolejność pól, hashe typów i
  `actor_contract_hash`. Nowe typy natywne bez starego odpowiednika nie
  otrzymują pozornej gwarancji zgodności.
- Codec prywatnego stanu nie jest automatycznie konwertowany; `state_version`
  pozostaje kontraktem aktora.

### Zależność od Cyrografu

Warunki integracji realizowane w W1 po stronie Cyrografu:

- profil OCaml `Js`: `Int → int64`, pełny zakres Drutu, natywny `Int → int`;
- minimalna publiczna informacja kompilatora dla adapterów: projekcja nazw
  symboli i ścieżek artefaktów dla schematu (bez importowania prywatnego
  `Naming` i bez kopiowania jego logiki do Well);
- opcja nazwy biblioteki danych OCaml (`contract_data`/`contract_data_browser`);
- brak zmian publicznego API konwersji wiadomości poza `to_drut`/`from_drut`.

## Założenia

1. Well i Cyrograf dzielą jeden format Drutu w przypiętej rewizji. Różnica
   profilu OCaml dotyczy reprezentacji `Int`, nie formatu danych.
2. Cyrograf jest wołany wyłącznie przez publiczne API; Well nie importuje
   prywatnych modułów kompilatora.
3. Adaptery Well nie zawierają gramatyki typów ani drugiego kodeka wiadomości.
4. Publikacja jest jednorazowa i całościowa; poprzedni poprawny wynik jest
   odtwarzalny po błędzie.
5. Stara ścieżka `well contract build` oparta na `Contract_parser`/
   `Contract_codegen` jest usuwana dopiero w W7, po przepięciu odwołań.
6. Aplikacja niewłączająca zmigrowanych kontraktów działa na starej ścieżce do
   czasu zakończenia W7.

## Scenariusze

```use-case
Zbuduj kontrakty Well

[Odczytaj katalog źródłowy]
[Wywołaj analizę Cyrografu]
<zebrane błędy>
  (END Error list)
[Wygeneruj dane wybranych targetów i profili]
[Wygeneruj adaptery Well]
<brak wymaganego targetu>
  (END Error list, poprzedni wynik zachowany)
[Sprawdź własność katalogu wynikowego]
<obce pliki albo output w źródłach>
  (END Error list)
[Zapisz wspólny manifest]
[Opublikuj kompletny wynik raz]
(END Ok)
```

```use-case
Wywołaj usługę przez HTTP

[Odbierz POST /rpc/<Service>/<method>]
[Wyznacz ctx z żądania albo sesji]
[Przekaż surowy tekst do from_drut]
<Drut niepoprawny>
  (END 400, handler nie uruchomiony)
[Wywołaj handler z typowanym requestem]
<wyjątek handlera>
  (END 500)
[Zakoduj odpowiedź przez to_drut]
(END 200 z tekstem Drutu)
```

```use-case
Wygeneruj deskryptor Actor

[Odczytaj [actor] z metadanych Well]
[Przekaż deklaracje wiadomości do Cyrografu]
[Odwzoruj schemat na format deskryptora 1]
[Policz JCS/SHA-256]
<niezgodność ze starym wynikiem>
  (END Error list dla niezmienionego znaczenia)
(END descriptor.json)
```

## Granica zmiany

Nowa integracja dotyczy `lib/well_cli/contract*`, kompozycji budowania, adapterów
usług i aktorów oraz publikacji wyników. Nie zmienia: routingu HTTP, LiveView,
well.web, SQL aplikacji, sesji, CSRF/CORS ani starej ścieżki
`Well.Service`/`Actor.register` do czasu W7. Nie uruchamia Cell, deployu ani
migracji DG.

## Śledzenie zatwierdzonej delty

Well nie ma katalogu `docs/` ani `axe.toml`, więc mechaniczny `delta.py`
operujący na `docs/` nie opisuje rzeczywistego układu specyfikacji i nie może
zaliczyć baseline. Obowiązuje jawna konwencja:

- Rzeczywisty układ specyfikacji Well jest wyliczony w
  `.axe/source-manifest.json` (autorowane artefakty: `ROADMAP.md`, `AGENTS.md`,
  `DESIGN-COMPONENT.md`, `lib/**/SERVICE.md`, dokumenty `lib/well/actor/*.md`,
  `skills/**/SKILL.md` oraz `lib/well_cli/contract/*`).
- Zatwierdzoną deltę tej migracji stanowią zmiany wskazane w raporcie W0 i
  odzwierciedlone w manifeście (odciski plików). Delta jest zatwierdzona przez
  przyjęty plan i polecenie jego wykonania, nie przez fikcyjny „verified freeze".
- `.axe/freeze` pozostaje ostatnim zautomatyzowanym zweryfikowanym obrazem
  specyfikacji (dotychczas: Actor, 2026-09-17). Nie wolno go rozszerzać o
  niezweryfikowane zmiany W0 ani o cudzą zaległą deltę.
- Każdy etap W1–W7 przesuwa freeze wyłącznie dla tych specyfikacji, które sam
  zaimplementował i zweryfikował przez własny wymagany odbiór z STP. Etap nie
  ogłasza pełnego baseline ani wsparcia targetu JetBrains.
- Brak obowiązkowego testu jest odbiorem częściowym; nie chowa się go pod „done"
  i nie przenosi automatycznie na następny etap.

## Weryfikacja

Źródłem scenariuszy testowych jest [STP.md](STP.md), który wiąże kryteria
M01–M13 z celami make i realnym wykonaniem wygenerowanego kodu.
