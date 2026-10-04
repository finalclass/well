# STP.md — Plan testów integracji Well z Cyrografem

## Zasady odbioru

Weryfikacja uruchamia wygenerowany kod. Dopasowanie fragmentu tekstu nie
zastępuje kompilacji, RPC przez HTTP ani wykonania browsera. Braki toolchainu
są oznaczonym blokującym brakiem weryfikacji, nie sukcesem ani cichym
pominięciem. Ten plan nie deklaruje istnienia CI ani wsparcia targetu bez
rzeczywistego dowodu.

Poziomy:

- automatyczny: cele make poniżej, uruchamiane w izolowanych katalogach;
- integracyjny: wygenerowany kod woła realny serwer Well;
- przeglądarkowy: jsoo w prawdziwej przeglądarce woła serwer W2;
- danych: porównanie ze starym generatorem i niezależnym korpusem Drutu.

## Cele make (wiążące dla W1–W7)

Nazwy celów są wiążące; implementacja może je dodać w W2 i rozszerzać w W3–W7.

| Cel | Co uruchamia |
|---|---|
| `make contract-check` | Buduje schemat przez publiczne API Cyrografu i `validate` targetów; bez linkowania Well. |
| `make contract-build` | `well contract build` do izolowanego katalogu; sprawdza manifest i układ artefaktów. |
| `make contract-native` | Kompiluje i wykonuje wygenerowany serwer OCaml; lokalne i HTTP RPC do realnego handlera. |
| `make contract-browser` | Kompiluje jsoo i uruchamia Proxy w prawdziwej przeglądarce przeciw serwerowi W2. |
| `make contract-clients` | Kompiluje i wykonuje klientów TS, Go i Dart przeciw serwerowi W2. |
| `make contract-socket` | Wywołania przez socket, REPL i Cap; list/describe/health. |
| `make contract-actor` | Porównanie deskryptorów/hashów oraz magazynu starego i nowego Actor. |
| `make contract-scaffold` | `well init` poza checkoutem → lock → generowanie → build → odtworzenie. |
| `make contract-publish` | Własność katalogu, kolizje nazw, bezpieczeństwo ścieżek, brak zapisu. |

`make test` pozostaje ogólnym testem produktu; odbiór tej migracji wymaga
celów `contract-*`. Etap kończy własny wymagany odbiór.

## Korpus porównawczy

- Referencję generuje stary generator na ustalonej rewizji Well
  `5c573753367f10d7226f5eaedf1adbeacab2c09d`; fixture'y są zapisane w testach.
- Niezależne wektory Drutu pochodzą z przypiętej rewizji Drutu
  `0d4b4e1e7ef3d7fffe095bfa9b2d88b564e9da8a` (korpus zgodności).
- Round-trip nowego kodeka sam ze sobą nie dowodzi zgodności. Oczekiwania nie
  są wyliczane przez testowany generator.
- Poprawne wartości spoza starego zakresu browsera mają osobne wektory
  referencyjne; stary browser nie jest wzorcem dużych liczb.
- Zaostrzenie przyjmowania wadliwych danych jest jawną zmianą, nie wymaganiem
  zachowania błędów starego dekodera.

## Kryteria M01–M13

| ID | Obserwowalny warunek | Gdzie |
|---|---|---|
| M01 | Ten sam kontrakt w TOML i `.cyrograf` daje te same typy wiadomości i ten sam układ poprawnego Drutu; kolejność pól i tagi stałe. | `contract-check`, `contract-build`, korpus porównawczy |
| M02 | Biblioteka samych wiadomości kompiluje się bez Well; adaptery używają tylko publicznych konwersji. | `contract-check`, negatywne testy importów |
| M03 | Usługi o różnych modułach, referencje kwalifikowane, puste struktury, warianty i wszystkie rodzaje optional działają przez realny handler. | `contract-native` |
| M04 | Wadliwe liczby, duplikaty kluczy Record, brak/nadmiar pozycji i nieznane tagi są odrzucane na surowym wejściu; brak podstawiania wartości domyślnych. | `contract-native`, korpus Drutu |
| M05 | Browser zachowuje pełny uzgodniony zakres liczb i Unicode; nie linkuje `well.core`, Eio, SQLite ani kompilatora Cyrografu. | `contract-browser`, kontrola zależności |
| M06 | HTTP i socket nie niszczą ścisłości Drutu wcześniejszym parsowaniem; błędy nie są mylone z domenowymi wariantami. | `contract-native`, `contract-socket` |
| M07 | Kontekst z sesji nie może zostać zastąpiony polem klienta; CSRF i cookies zachowują kontrakt Well. | `contract-native`, testy CSRF |
| M08 | Błąd generowania, obcy plik, niebezpieczna ścieżka lub brak zapisu nie niszczą poprzedniego wyniku; usuwane są tylko poprzednie własne artefakty. | `contract-publish` |
| M09 | Wygenerowane proxy OCaml/TS/Go/Dart kompilują się i wykonują RPC; opcjonalne targety danych są publikowane bez deklarowania nieistniejącego proxy. | `contract-browser`, `contract-clients` |
| M10 | Actor zachowuje deskryptory, hashe, witness i odtwarzanie magazynu; zmiana generatora nie jest migracją danych SQLite. | `contract-actor` |
| M11 | REPL, Cap i starszy Actor zachowują działanie, a metadane używają kanonicznych nazw schematu. | `contract-socket` |
| M12 | Nowy scaffold buduje się z przypiętych źródeł i odtwarza artefakty po ich usunięciu; żaden stary generator nie jest wymagany do bootstrapu. | `contract-scaffold` |
| M13 | Nazwy po normalizacji i nazwy adapterów Well nie kolidują; generator zgłasza błąd przed publikacją. | `contract-build`, `contract-publish` |

## Odbiór etapów

**M01–M02 (W1–W2).** `contract-check` na przykładzie native i TOML równoważnym;
generowanie bez Well; porównanie tekstów Drutu z korpusem starego generatora.
Biblioteka wiadomości kompiluje się jako izolowany konsument bez `well.core`.

**M03–M04 (W2).** Realny serwer OCaml: różne moduły, referencje kwalifikowane,
puste struktury, warianty, `optional` obecne/brakujące, listy. Surowy tekst z
`1.0000000000000001` w polu Int jest odrzucany; zero, false, pusty string i pusta
lista nie są podstawiane za brak. Duplikaty kluczy Record i nadmiar pozycji
odrzucane; błąd requestu nie uruchamia implementacji.

**M05 (W3).** jsoo 6.2.0 w prawdziwej przeglądarce uruchamia Proxy i woła serwer
W2. Sprawdzane: granice 32-bitowe oraz `±9007199254740991`, ułamki dla Int,
Unicode, Record, optional, listy, warianty. Test porównuje wynik z natywnym
OCaml i TS. Kontrola zależności: brak `well.core`, Eio, SQLite, kompilatora.

**M06 (W4).** Socket: ramka `{service, rpc, payload}` z surowym tekstem payloadu;
`1.0000000000000001` w polu Int odrzucone, nie zamienione na `1`. HTTP: błąd
Drutu → 400 i handler nieuruchomiony; domena → 200; wyjątek → 500. Awaria
handlera nie wyłącza kolejnych wywołań; kolejność mailboxa starszego Actor i
współbieżność Service zachowane.

**M07 (W4).** Kontekst pochodzi z żądania/sesji; pole klienta nie zastępuje
tożsamości. CSRF, cookies i nagłówki XHR bez zmian. 2xx z `{"error":"..."}`
pozostaje błędem dla Proxy.

**M08 (W2/W6).** `contract-publish`: obcy plik bez manifestu blokuje; output
w źródłach odrzucony; błąd jednego targetu zostawia poprzedni wynik; usuwane są
tylko poprzednie własne artefakty; kolizje nazw zgłaszane przed publikacją.

**M09 (W3).** Klienci TS, Go i Dart kompilują się i wykonują RPC do serwera W2.
Sprawdzane: CSRF/cookies, błąd sieci, status HTTP, 2xx z error, wadliwa
odpowiedź, odwołania między modułami, liczby poza zakresem 32-bitowym. Same
asercje na tekście wygenerowanych plików nie wystarczają.

**M10 (W5).** Porównanie starego i nowego: dla tych samych kontraktów
deskryptory i hashe JCS/SHA-256 identyczne (`format=1`, kwalifikowane nazwy,
kolejność pól, hashe typów, `actor_contract_hash`). Nowa binarka otwiera
magazyn utworzony przez starą; wznowienie niezmienionego obiegu zachowuje
payloady, stan, `message_id` i wynik; rzeczywista niezgodność daje Blocked.
Nowe typy bez starego odpowiednika nie mają pozornej gwarancji zgodności.
Codec prywatnego stanu nie jest automatycznie konwertowany; negatywne testy
typów implementacji aktorów zachowane.

**M11 (W4).** `contract-socket`: REPL `list/describe/health`; wywołanie z Cap;
starszy Actor zachowuje działanie. Metadane używają kanonicznych nazw schematu.

**M12 (W6).** `well init` poza checkoutem → `dune pkg lock` → generowanie →
`dune build`/`check` → realne RPC i browser Proxy. Skasowanie wyłącznie wyników
generowania i ponowne odtworzenie przez build; powtórny build bez zmian
deterministyczny. Build aplikacji nie zależy od plików dewelopera w
`/home/sel/ocaml-contract` ani od binarki Cyrografu.

**M13 (W2–W6).** Nazwy po normalizacji (`type'`/`type_`, camelCase) i nazwy
adapterów Well nie kolidują. Generator zgłasza błąd przed publikacją.

## API-token transport (`make api-token-test`)

Wygenerowany TypeScript Proxy uruchomiony przez Deno woła serwer Well.
Poprawny token daje tożsamość przez RPC i Session bez cookie/CSRF; zły token
daje status 401 bez handlera. Dwie instancje Proxy zachowują różne dane
uwierzytelnienia. Test obejmuje błąd HTTP, 2xx z error, wadliwą odpowiedź,
timeout, wyjątek fetch bez ujawnienia sekretu i zachowany tryb przeglądarkowy.
Testy rdzenia według [strategii HTTP](../../well/SERVICE.md) sprawdzają
przywrócenie kontekstu, współbieżność, niezmienność tożsamości i odwołanie.

## Odbiór przeglądarkowy

`make contract-browser` używa prawdziwej przeglądarki (nie wyłącznie jsdom),
serwuje zbudowany jsoo i wykonuje pełne wywołania do serwera W2. Wynik obejmuje
zrzut logu sieci i konsoli oraz porównanie wartości z natywnym OCaml i TS.

## Odbiór końcowy (W7)

- `make check`, `make test`, `make build` oraz cele `contract-*`.
- Znany `oauth_provider_test` wyodrębnia się wyłącznie po potwierdzeniu tej
  samej przyczyny na baseline; inne błędy nie są wyjątkiem.
- `oauth_provider_test` na baseline: potwierdzić przed wyodrębnieniem.
- Raport końcowy: wymaganie → test, dokładne polecenia/kody/logi, rewizje obu
  repozytoriów, zmiany API i ścieżek, wynik ponownego wygenerowania, lista
  zmian dla migracji DG.
- Brak wymaganej kontroli oznacza odbiór częściowy.

## Czego ten plan nie testuje

- Migracji DG ani wdrożenia innych aplikacji — to osobne zadanie po W7.
- Formatowania, LSP i edytorów Cyrografu — należą do jego własnego STP.
- Nowych proxy Python/Java/C#/Rust — oddzielne rozszerzenie.
- JetBrains Cyrografu — ograniczenie wydania Cyrografu, nie tej migracji.

## TypeScript Promise client

`make contract-clients` verifies generated `Service.method(ctx, request)` against
real HTTP, preserving browser CSRF, strict Drut and domain replies.
`make api-token-test` verifies independent bearer contexts, HTTP status errors,
credential-free diagnostics, timeouts and redirects with the Promise client.
