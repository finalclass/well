# Plan migracji Well do Cyrografu

Status: plan zaakceptowany przez użytkownika poleceniem „ok, zlecaj”
2026-09-29. Wykonawca: `well:mechanik`. W0 zapisuje kontrakty i STP
w granicach przyjętych decyzji przed implementacją W1–W7.

Zakres polecenia: najpierw framework Well, następnie osobna migracja DG.
Niniejszy plan obejmuje Well i konieczne warunki jego integracji z Cyrografem.
Nie uruchamia wdrożenia ani migracji aplikacji zależnych.

## 1. Cel i punkt odniesienia

Cyrograf jest jedynym właścicielem języka wiadomości, reguł typów i generatorów
konwersji Drutu. Well komponuje te artefakty z własnymi adapterami usług,
proxy i aktorów. Użytkownik nadal buduje integrację poleceniem
`well contract build`; nie musi ręcznie uruchamiać dwóch generatorów.

Przegląd wykonano 2026-09-29 na rewizjach:

- Well: `5c573753367f10d7226f5eaedf1adbeacab2c09d`, gałąź `master`.
- Cyrograf: `9eb580c9bc95e552a3d14136d0a009c71456b6f2`, gałąź `main`.
- Drut: rewizja przypięta przez Cyrograf
  `0d4b4e1e7ef3d7fffe095bfa9b2d88b564e9da8a`.

Ostatnia rewizja Cyrografu ma według raportu operatora zielony odbiór ośmiu
targetów. Nie przeprowadzono tu ponownie tego odbioru. Niezakończony smoke
JetBrains pozostaje ograniczeniem wydania Cyrografu; nie dowodzi wady kodeków
i nie wymaga zatrzymania prac nad integracją przypiętej rewizji.

## 2. Ustalenia z przeglądu

| Obszar | Stan obecny i znaczenie dla migracji |
|---|---|
| Kompilator usług | `lib/well_cli/contract_parser.ml`, `contract_types.ml` i `contract_codegen.ml` zawierają własny model, parser oraz generatory danych i integracji. Docelowo pozostaje tylko część integracyjna. |
| Powierzchnia RPC | Generator produkuje OCaml `IMPL`, `make_spec`, funkcje z `~ctx`, browser `Proxy`, TS `Proxy`, wywołania Go i klientów Darta. Sam Cyrograf ich nie zastępuje. |
| Runtime usług | `lib/well/service.ml` przenosi payload jako `Yojson.Safe.t`; HTTP parsuje ciało przed wywołaniem kodeka. Samo dopięcie `from_drut` po ponownym stringify utraciłoby część ścisłej walidacji liczb. |
| Starsi aktorzy RPC | `lib/well/actor.ml` używa `Service.spec` i tej samej reprezentacji payloadu. Zmiana granicy dispatch obejmuje również tę ścieżkę, z zachowaniem kolejności mailboxa i supervision. |
| Przeglądarka | Well wymaga OCaml browser Proxy przez `js_of_ocaml` 6.2.0. `Cyrograf/docs/api.md` deklaruje dziś OCaml natywne 64-bitowe, a jsoo jako osobne rozszerzenie. |
| Walidacja | Stary generator RPC podstawia m.in. `0`, `false`, `""` i `[]`, toleruje część brakujących/nadmiarowych pozycji. Cyrograf takie wejście odrzuca. Nie są to równoważne dekodery. |
| Kontekst | `ctx` jako typ źródłowy jest odrzucany przez Cyrograf, ale `Well.rpc_ctx` jest także osobnym argumentem każdego serwerowego handlera. Te dwa zastosowania trzeba rozróżnić. |
| Nowy Well.Actor | `lib/well/actor_contract.ml` ma drugi parser/generator oraz deskryptory i hashe używane przy odtwarzaniu. Cyrograf nie interpretuje `[actor]`; to rozszerzenie należy do Well. |
| Publikacja | Domyślny output Well to `lib/contract/build` wewnątrz źródeł. Cyrograf ArtifactAccess odrzuca nakładanie się katalogów. Stare wyniki Well nie mają też manifestu Cyrografu. |
| Scaffold | `lib/well_cli/template.ml` zawiera TOML, kopie wygenerowanych modułów, reguły Dune i instrukcje. Zmiana samego CLI pozostawiłaby nowo tworzone aplikacje na starym generatorze. |
| Konsumenci pomocniczy | REPL, panel Cap i introspekcja usług używają metadanych i `dispatch_by_name`; także wymagają testów integracji. |
| Specyfikacja | Główny opis RPC jest w `ROADMAP.md` §9 i skillach, osobny kontrakt Actor w `lib/well/actor/`. Brak `docs/main.md`, `docs/arch.md` i `axe.toml`; wskazany w AGENTS symlink `.agents/skills/axe` nie jest dostępny. |

W drzewie zastano niezarejestrowane pliki `.axe/freeze/` dotyczące innych
obszarów. Nie są częścią tej migracji i nie należy ich usuwać ani zaliczać
jako nowego, zweryfikowanego baseline.

## 3. Podział odpowiedzialności według zmienności

| Co może się zmieniać | Właściciel | Granica |
|---|---|---|
| Składnia kontraktów, typowanie, nazwy targetów i kodowanie danych | Cyrograf | Publiczne `Cyrograf_compiler`, `Cyrograf.Schema` i wygenerowane `to_drut`/`from_drut`; bez importowania prywatnego runtime'u. |
| Kolejność przygotowania kompletnego wyniku Well | Koordynacja budowania kontraktów w Well | Odczyt snapshotu, analiza, generowanie danych, generowanie integracji, jedna publikacja. |
| Sposób wiązania deklaracji z wykonaniem | Generator integracji Well | Strategie dla Service/RPC oraz Actor, otrzymujące gotowy schemat; bez własnej gramatyki typów i kodeków wiadomości. |
| Transport, kontekst, sesja i błędy wywołania | Runtime i adaptery Well | HTTP, socket, wywołanie lokalne, mailbox, przeglądarka; te elementy nie wchodzą do Cyrografu. |
| Źródła, układ katalogów i własność wyników | Dostęp do źródeł i artefaktów | Wykorzystanie mechanizmów Cyrograf tooling za adapterem integracyjnym; bez kopiowania bezpiecznej publikacji do każdego generatora. |
| Pakowanie i szablon aplikacji | Scaffold i konfiguracja Dune Well | Przypięte zależności, ścieżki bibliotek i reguły odtwarzania wygenerowanych plików. |

To granice modułów w jednym programie. Nie powstaje proces kompilatora
uruchamiany z shella, system pluginów ani osobna usługa na każdy target.
Warstwa dostępu do kompilatora traktuje Cyrograf jako zewnętrzny system
udostępniony przez bibliotekę; nie przenosi jego logiki do Well.

```call-chain
Budowanie kontraktów Well

[CLI Well]
  -> [Koordynacja budowania kontraktów]
    -> [Dostęp do źródeł]
      -> (Pliki źródłowe)
    -> [Dostęp do Cyrografu]
      -> (Kompilator Cyrograf)
    -> [Generator integracji]
    -> [Dostęp do artefaktów]
      -> (Kompletny wynik)
```

```call-chain
Budowanie kontraktów Actor

[Well.Actor.Contract.build]
  -> [Koordynacja budowania kontraktów]
    -> [Dostęp do źródeł]
      -> (Wiadomości i deklaracje aktorów)
    -> [Dostęp do Cyrografu]
      -> (Kompilator Cyrograf)
    -> [Generator integracji]
    -> [Dostęp do artefaktów]
      -> (Typy, adaptery i deskryptor Actor)
```

Biblioteka narzędziowa nie zależy od `well.core`. Ewentualne zachowanie
`Well.Actor.Contract.build` jako bibliotecznego wejścia wymaga kierunku
`well.core -> narzędzie kontraktowe -> cyrograf.compiler`, nigdy odwrotnego.
Generator emituje odwołania do Well jako tekst; nie potrzebuje wykonania Well.
Biblioteki z samymi wiadomościami zależą wyłącznie od runtime'u Cyrografu.

## 4. Zalecane decyzje do zapisania w specyfikacji

### Dane i generowany kod

1. Docelowe źródła to `.cyrograf`; zwykły TOML pozostaje wejściem zgodności
   obsługiwanym przez Cyrograf. W katalogu nie mogą współistnieć dwie
   definicje tego samego modułu. Migracja formatu nie zmienia kolejności pól.
2. Well używa biblioteki kompilatora, nie wymaga osobnej binarki `cyrograf`
   w PATH do `well contract build`. Formatter i LSP pozostają narzędziami
   Cyrografu, bez drugiej implementacji w Well.
3. Typy i kodeki generowane przez Cyrograf są odrębnymi artefaktami.
   Well dodaje pliki adapterów i fasady z aliasami, np.
   `module Request = Contract_messages.Orders.Request`. Nie przepisuje
   wygenerowanych typów, nie dopisuje transportu do ich plików i nie usuwa
   ich `.mli`, aby dostać się do ukrytych funkcji.
4. Publiczne konwersje wiadomości pozostają wyłącznie
   `to_drut`/`from_drut` według konwencji targetu. `IMPL`, `make_spec`,
   `Proxy`, witness aktora i konstruktory należą do innych aspektów API.
5. Przewidzieć zmiany nazw po escapowaniu (`type'` wobec `type_`), camelCase
   w TS/Darcie oraz nowe reprezentacje wariantów. Nie dodawać ogólnej
   warstwy aliasów starego API. Migracja konsumentów ma być jawna.
6. Zinwentaryzować `show`, `equal`, `to_yojson` i `of_yojson` pochodzące ze
   starego PPX. Porównywanie i prezentacja należą do potrzeb konsumenta;
   konwersja nazwanego JSON-a nie jest automatycznie zamienna na pozycyjny
   Drut. Nie zastępować tych wywołań mechanicznie.

### Liczby i przeglądarka — warunek wstępny

Nie wystarczy skompilować obecnego generatora OCaml przez jsoo. Jsoo 6.2.0
ma 32-bitowy `int`, a Drut dopuszcza całkowite wartości do
`9007199254740991`; obecny runtime Cyrografu używa m.in. takiej stałej typu
`int`. Źródło ograniczenia: [oficjalna dokumentacja jsoo 6.2.0](https://raw.githubusercontent.com/ocsigen/js_of_ocaml/6.2.0/manual/overview.wiki).

Rekomendacja: osobny profil generowania OCaml dla jsoo w Cyrografie,
z `Int` odwzorowanym na `int64` i sprawdzeniem zakresu Drutu. Profil natywny
zachowuje dotychczasowe `int`. Format danych pozostaje identyczny; kod
przeglądarkowy będzie wymagał jawnego dostosowania użyć liczb. Nie wolno
obcinać dużych wartości, zawężać całego Drutu do 32 bitów ani udawać pełnego
wsparcia przez testy tylko na małych liczbach.

Profil obejmuje też Unicode, `Record`, zagnieżdżone typy i ścisłość parsera.
Przyjęty wybór i mapowanie typów trzeba zapisać w specyfikacji Cyrografu
w W0 przed implementacją W1. Well nie utrzymuje własnej kopii poprawionego kodeka.

### Wywołania, kontekst i błędy

- Zachować serwerowe `IMPL`, `make_spec`, wygodne wywołania z `~ctx`,
  `Service.register/expose/cast` oraz callbackowy browser `Proxy`.
  Dane użyte przez te adaptery pochodzą z Cyrografu.
- Kontekst wykonania jest własnością Well, osobnym argumentem handlera.
  HTTP wyznacza go z żądania/sesji. Kontrakt wiadomości nie może pozwolić
  klientowi zastąpić nim tożsamości wyznaczonej przez serwer.
- Legacy pole `ctx` w TOML jest osobnym przypadkiem migracji: zdiagnozować
  z lokalizacją. Jeżeli chodzi o dane domenowe, trzeba zadeklarować zwykłą
  strukturę; jeżeli o kontekst wykonania — korzystać z argumentu handlera.
  Nie usuwać takiego pola po cichu, bo zmieniłoby to pozycje w Drucie.
- Docelowy dispatch transportowy przekazuje tekst Drutu do wygenerowanego
  `from_drut` przed materializacją payloadu w JSON AST. Dotyczy to requestu
  i odpowiedzi, HTTP oraz socketa. Lokalna ścieżka usług i starszy Actor
  muszą używać uzgodnionej reprezentacji bez zmiany współbieżności.
- HTTP zachowuje `POST /rpc/<Service>/<method>`, `application/json` i ciało
  zawierające sam Drut, bez dodatkowego JSON stringa. Proxy przesyła wynik
  `to_drut` i czyta tekst odpowiedzi; nie wykonuje `JSON.stringify(text)`.
- Socket zachowuje ramkę z `service`, `rpc`, `payload` i odpowiedzią
  `result`/`error`. Adapter ramki musi zachować oryginalny fragment tekstu
  payloadu do walidacji. Parsowanie ramki nie może wcześniej zaokrąglić
  liczby w jej payloadzie. Jeżeli użyte narzędzie tego nie zapewnia, zgłosić
  konkretny brak kontraktu; nie zastępować walidacji stringify po parsowaniu.
- Pozostawić format introspekcji potrzebny REPL/Cap. Jeżeli zachowane wejście
  `dispatch_by_name` przyjmuje już JSON AST, traktować je jako adapter
  wartości, bez obietnicy odtworzenia pierwotnych leksemów. Surowe wejścia
  sieciowe muszą przechodzić pełną walidację tekstu.
- Błąd konwersji ma być jawnym błędem wywołania, bez uruchomienia handlera
  dla wadliwego requestu. Dokładne statusy HTTP i mapowanie na błędy
  callbacków/wyjątki należy zapisać w kontrakcie integracji; domenowy
  wariant odmowy pozostaje zwykłą odpowiedzią domenową.
- Zachować CSRF, cookies, źródła tokenu i nagłówki XHR według kontraktu
  Well. Obsłużyć również dotychczasową odpowiedź `{"error":"..."}` na 2xx.

### Generowanie i publikacja

- Zalecany domyślny output: `lib/contract_generated`, obok `lib/contract`.
  Zachować formę `well contract build [source_dir] [output_dir]`.
  Jawny output wewnątrz źródeł zgłasza błąd z instrukcją zmiany ścieżki.
- Rozdzielić biblioteki z wiadomościami i adaptery Well. Dla OCaml przewidzieć
  osobne nazwy bibliotek danych natywnych i browserowych oraz fasady
  `contract`/`contract_browser`; uniknąć dwóch bibliotek Dune o nazwie
  `generated_contracts` w tym samym workspace.
- Budować pełny zestaw w pamięci/stagingu i publikować go raz wspólnym
  manifestem. Błąd dowolnego wymaganego targetu pozostawia poprzedni wynik.
  Usunąć obecne ciche pomijanie błędów TS/Go/Dart.
- Nie przejmować automatycznie katalogu bez manifestu i nie usuwać starych
  plików jako domyślnie własnych. Nowy katalog omija potrzebę takiego
  przejęcia; stary wynik usuwa się dopiero po przepięciu wszystkich odwołań.
- Zachować obsługiwane dziś integracje RPC: OCaml server/browser, TS, Go,
  Dart. Pozostałe targety Cyrografu mogą generować same wiadomości przez
  jawny wybór; nowe proxy Python/Java/C#/Rust są oddzielnym rozszerzeniem.
  Domyślny zestaw zgodności Well to dotychczasowe cztery języki i browser;
  nie narzucać istniejącym źródłom kolizji dodatkowych targetów bez ich wyboru.
- Przypiąć wersję Cyrografu pełną rewizją po zamknięciu niezbędnych poprawek,
  zarówno w Well, jak i w rozwiązywaniu zależności nowego scaffoldu.
  Sprawdzić czysty lock/build bez lokalnego checkoutu Cyrografu. Po utworzeniu
  zależności rewizja musi pozostać osiągalna; dotychczasowe przepisywanie
  jedynego commita Cyrografu nie jest trwałą strategią wersjonowania zależności.

### Well.Actor

Migracja kontraktów nie przebudowuje aktorów w Cell, nie zmienia schedulera,
magazynu ani semantyki obiegów. Wiadomości przechodzą przez Cyrograf;
Well zachowuje `accepts/emits`, witness, `Inbound/Outbound`, prywatny codec
stanu, walidację runtime względem deskryptora i hashe kontraktów.

Docelowo wiadomości są w `.cyrograf`, a metadane aktora w osobnym pliku
Well, np. `Reporter.actor.toml`. Dla obecnych mieszanych plików TOML adapter
Well odczytuje wyłącznie rozszerzenie `[actor]`, zachowuje kolejność reszty
i przekazuje deklaracje wiadomości do Cyrografu. Nie utrzymuje drugiego
parsera typów; nieznanych kluczy nie wolno zgubić podczas projekcji.

Nie zastępować `descriptor.json` Actor plikiem `schema.json` Cyrografu.
Zbudować jawne odwzorowanie schematu na dotychczasowy format Actor i porównać
JCS/SHA-256 ze starym wynikiem. Zachować kwalifikowane nazwy, kolejność pól,
hashe typów i actor_contract_hash dla niezmienionego znaczenia. Nowe typy
natywne bez starego odpowiednika nie otrzymują pozornej gwarancji zgodności.

## 5. Kolejne pakiety dla `well:mechanik`

Zadania wykonuje jeden operator kolejno. Każdy pakiet otrzymuje zatwierdzoną
specyfikację, zakres ścieżek i kryteria odbioru; zakończenie to działający
przekrój i dowody, nie sam plik generatora. Nie wolno zostawiać wymaganego
testu jako domyślnego zadania dla następnego etapu.

### W0 — zamknięcie specyfikacji integracji

Praca architektoniczna przed pakietami implementacyjnymi: przygotować
kontrakt integracji i STP przy `lib/well_cli/contract/`, odesłać do niego
z `ROADMAP.md` i AGENTS. Zaktualizować odpowiednie reguły w kontraktach Actor,
zamiast ignorować obecne gwarancje jego API. Opisać również decyzje z §4:
profil jsoo, dispatch tekstowy, błędy, układ artefaktów i rozszerzenia Well.

Ustalić źródła snapshotu axe dla rzeczywistego układu tego repo. Domyślny
skrypt operujący na nieistniejącym `docs/` nie jest dowodem objęcia zmian.
Nie tworzyć nowego baseline przez skopiowanie niezweryfikowanego stanu.

Wynik: spójne kontrakty i STP realizujące przyjęty plan, diff do przeglądu
i gotowe zakresy W1–W7. Akceptacja planu i polecenie zlecenia obejmują
zapis tej specyfikacji i jej implementację; nie obejmują dodatkowych zmian
reguł Cyrografu poza wymaganiami integracji opisanymi w planie.

### W1 — warunki integracji w Cyrografie

Zakres poza Well, opisany osobnym diffem specyfikacji Cyrografu w W0:
profil jsoo i minimalna publiczna informacja kompilatora potrzebna do
wiązania schematu z wygenerowanymi symbolami/artefaktami. Użyć istniejących
publicznych funkcji tam, gdzie wystarczają; brak mapowania nazw nie uzasadnia
importowania prywatnego `Naming` ani kopiowania całej jego logiki do Well.
Nie rozszerzać przy tym publicznego API konwersji wiadomości.

Odbiór: rzeczywista kompilacja jsoo 6.2.0 i wymiana z natywnym OCaml/TS,
w tym granice 32 bitów oraz ±9007199254740991, wadliwe ułamki dla Int,
Unicode, Record, optional, listy i warianty. Kod wiadomości nie zależy od
Well. Regresje dotychczasowych targetów Cyrografu przechodzą.

### W2 — kompilator i pierwszy działający serwer RPC

Ścieżki: zależności Dune/lock, `lib/well_cli/contract*`, kompozycja budowania,
integracja `lib/well/service.ml`, niezbędne fragmenty starszego Actor i ctx.
Powstaje jeden pełny przekrój: źródło TOML/native → Cyrograf → fasada OCaml →
rejestracja → rzeczywiste wywołanie lokalne i HTTP.

Odbiór: kompilacja poza repo, identyczne poprawne payloady referencyjne,
wywołanie handlera z właściwym ctx, rozróżnienie błędu Drutu i odpowiedzi
domenowej; błąd requestu nie uruchamia implementacji. Nowa ścieżka nie
uruchamia starszego parsera/kodeka jako fallbacku.

### W3 — przeglądarka i istniejący klienci sieciowi

Ścieżki: strategie integracji browser/TS/Go/Dart, pliki transportu oraz
testy wygenerowanych konsumentów. Browser korzysta z profilu W1 i zachowuje
`Proxy.method request ~on_done`. Pozostałe proxy używają dwóch publicznych
konwersji odpowiedniego targetu.

Odbiór: uruchomiony jsoo w prawdziwej przeglądarce wywołuje serwer W2;
TS, Go i Dart kompilują i wykonują wywołania do tego serwera. Sprawdzić
CSRF/cookies, błąd sieci, status HTTP, 2xx z error, wadliwą odpowiedź,
odwołania między modułami oraz liczby poza zakresem 32-bitowym.
Same asercje na tekście wygenerowanych plików nie wystarczają.

### W4 — socket, introspekcja, Cap i starszy Actor

Ścieżki: `lib/well/service.ml`, `lib/well/actor.ml`,
`lib/well_cli/cmd_repl.ml`, `lib/well_cap/{services_live,repl_live}.ml`
oraz powiązane testy. Domknąć transport surowego payloadu i adaptery AST.

Odbiór: wywołanie przez socket i REPL; list/describe/health; wywołanie z Cap;
zachowanie ctx; współbieżność Service i kolejność starszego Actor.
Wejście z `1.0000000000000001` w polu Int jest odrzucane także przez socket,
nie zamieniane po drodze na dopuszczalne `1`. Awaria handlera nie wyłącza
kolejnych wywołań, a kontrakty sesji i supervision pozostają zachowane.

### W5 — kontrakty trwałego Well.Actor

Ścieżki: narzędzie kontraktowe, `lib/well/actor_contract.ml`,
`lib/well/actor/examples`, testy generatora i istniejące testy trwałości.
Wiadomości pochodzą z Cyrografu, adaptery aktora są generowane w Well.

Odbiór: porównanie starych i nowych deskryptorów/hashów dla tych samych
kontraktów oraz uruchomienie nowej binarki na testowym magazynie utworzonym
przez starą. Wznowienie niezmienionego obiegu zachowuje payloady, stan,
message_id i wynik; rzeczywista niezgodność nadal daje Blocked.
Zachować niezależną kompilację implementacji aktorów i negatywne testy typów.
Codec prywatnego stanu nie jest automatycznie konwertowany.

### W6 — scaffold, źródła natywne i dokumentacja użytkownika

Ścieżki: `lib/well_cli/template.ml`, reguły Dune, README/ROADMAP oraz
`skills/well`, `skills/well-front`, `skills/well-axe` i ich dostarczane kopie.
Nowy projekt otrzymuje `.cyrograf`, nowy katalog wynikowy i właściwe piny.
Usunąć ręcznie utrzymywane kopie starych wygenerowanych modułów z szablonu;
źródłem wyników scaffoldu jest ten sam generator co `well contract build`.

Wskazówki dla kontraktów osadzonych w Markdown mają kierować na bloki
`cyrograf` i ich deterministyczną projekcję, zachowując jasno opisaną ścieżkę
legacy TOML. Dotyczy to dystrybuowanych instrukcji nowych aplikacji;
aktualizacja dokumentacji i projekcji w DG jest późniejszym zadaniem.

Odbiór: `well init` poza checkoutem → lock → generowanie → build/check →
rzeczywiste RPC i browser Proxy. Następnie skasowanie wyłącznie wyników
generowania i ponowne odtworzenie przez build. Powtórny build bez zmian jest
deterministyczny, a build aplikacji nie zależy od plików dewelopera w
`/home/sel/ocaml-contract` ani od osobno zainstalowanej binarki Cyrografu.

### W7 — usunięcie starej ścieżki i odbiór Well

Usunąć nieużywany parser, model kontraktów i generatory danych z Well,
zostawiając strategie integracji. Otoml może nadal być wymagany przez
konfigurację/Registry i rozszerzenia Actor; nie usuwać zależności globalnie
na podstawie samego usunięcia parsera RPC.

Odbiór: `make check`, `make test`, `make build` oraz cele integracyjne
z zatwierdzonego STP. Znany `oauth_provider_test` wyodrębnić wyłącznie po
potwierdzeniu tej samej przyczyny na baseline. Inne błędy nie są wyjątkiem.
CI wykonać na czystym checkoutcie, jeśli jest dostępne; w repo podczas
przeglądu nie znaleziono workflow GitHub, więc jego dodanie wymaga ujęcia
w zakresie STP, a raport nie może obiecywać istniejącego pipeline'u.

Raport końcowy: wymaganie → test, dokładne polecenia/kody/logi, rewizje obu
repozytoriów, zmiany API i ścieżek, wynik ponownego wygenerowania oraz lista
zmian dla migracji DG. Brak wymaganej kontroli oznacza odbiór częściowy.

Kolejność: W0 → W1 → W2 → W3 → W4 → W5 → W6 → W7.
Wstępne testy natywnego RPC mogą być opracowywane bez browsera, ale nie
pozwalają uznać migracji za zakończoną przed W1/W3.

## 6. Wspólne kryteria, które muszą wejść do STP

| ID | Obserwowalny warunek |
|---|---|
| M01 | Ten sam kontrakt w TOML i Cyrografie daje te same typy wiadomości i ten sam układ poprawnego Drutu; kolejność pól i tagi pozostają stałe. |
| M02 | Biblioteka samych wiadomości kompiluje się bez Well, a adaptery korzystają tylko z publicznych konwersji. |
| M03 | Usługi o różnych modułach, referencje kwalifikowane, puste struktury, warianty i wszystkie rodzaje optional działają przez rzeczywisty handler. |
| M04 | Wadliwe liczby, duplikaty kluczy Record, brak/nadmiar pozycji i nieznane tagi są odrzucane na surowym wejściu; nie ma podstawiania wartości domyślnych. |
| M05 | Browser zachowuje pełen uzgodniony zakres liczb i Unicode; nie linkuje `well.core`, Eio, SQLite ani kompilatora Cyrografu. |
| M06 | HTTP i socket nie niszczą ścisłości Drutu wcześniejszym parsowaniem; błędy nie są mylone z domenowymi wariantami. |
| M07 | Kontekst z sesji nie może zostać zastąpiony polem klienta; CSRF i obsługa cookies zachowują kontrakt Well. |
| M08 | Błąd generowania, obcy plik, niebezpieczna ścieżka lub brak zapisu nie niszczą poprzedniego wyniku; usuwane są tylko poprzednie własne artefakty. |
| M09 | Wygenerowane proxy OCaml/TS/Go/Dart kompilują się i wykonują RPC; opcjonalne targety danych Cyrografu są poprawnie publikowane bez deklarowania nieistniejącego proxy. |
| M10 | Actor zachowuje deskryptory, hashe, witness i odtwarzanie magazynu; zmiana generatora nie jest migracją danych SQLite. |
| M11 | REPL, Cap i starszy Actor zachowują działanie, a metadane używają kanonicznych nazw schematu. |
| M12 | Nowy scaffold buduje się z przypiętych źródeł i odtwarza artefakty po ich usunięciu; żaden stary generator nie jest wymagany do bootstrapu. |
| M13 | Nazwy po normalizacji i nazwy adapterów Well nie kolidują; generator zgłasza błąd przed publikacją. |

Korpus porównawczy powinien pochodzić ze starego generatora uruchomionego
na ustalonej rewizji i z niezależnych wektorów Drutu. Round-trip nowego kodeka
sam ze sobą nie dowodzi zgodności. Poprawne wartości spoza starego zakresu
browsera mają osobne wektory referencyjne; nie traktować starego browsera
jako wzorca dużych liczb. Zaostrzenie przyjmowania wadliwych danych jest
jawną zmianą, nie wymaganiem zachowania błędów starego dekodera.

## 7. Granica następnego etapu — DG

Well można uznać za gotowy do migracji DG po W7. Do tego czasu DG zachowuje
dotychczasową przypiętą rewizję frameworka; nie wykonuje się w nim locka,
regenerowania kontraktów ani wdrożenia jako skutku ubocznego pracy w Well.

Pakiet przekazania do DG zawiera:

- finalny pin Well/Cyrografu i wymagania toolchainu;
- mapę ścieżek Dune/importów oraz przykład serwera i browser Proxy;
- listę zmian nazw, optional i liczbowego profilu jsoo;
- procedurę TOML/Markdown → `.cyrograf`, z rozróżnieniem ctx i metadanych Actor;
- ostrzeżenie przed mechaniczną zamianą serializacji PPX na Drut;
- wyniki zgodności poprawnych payloadów oraz sposób odtworzenia starego builda.

Nie usuwa się historii Well i nie przejmuje reguły jednego root commita
z repozytorium Cyrografu. Plan nie obejmuje pushu, wydania ani restartu
działających aplikacji. Kodowanie jest zlecone wskazanemu operatorowi;
kontrakty migracji i STP powstają przed implementacją.
