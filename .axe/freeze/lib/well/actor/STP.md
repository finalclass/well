# STP — Well.Actor

## Strategia

Weryfikacja wyłącznie nowego Actor oraz zachowania jego starej ścieżki.
Testy wyprowadzane z tego planu powstają podczas zatwierdzonego axe sync,
nie podczas przygotowania specyfikacji. Nie dopisuje się nowych scenariuszy
biznesowych na podstawie szczegółów implementacji.

Fixtures: oddzielny tymczasowy magazyn na test, jawny rejestr aktorów,
kontrolowany zegar, bariery aktywacji zamiast sleep, wstrzykiwany transport
zewnętrzny liczący efekty po kluczu. Testy odtwarzania uruchamiają osobne
procesy na tym samym pliku i wymuszają zakończenie w wskazanym punkcie.
Nie zastępuje się rzeczywistego restartu ponownym utworzeniem Hashtbl.

## Kontrakty i generator

| ID | Scenariusz i obserwowalny wynik |
|---|---|
| C01 | Wszystkie TOML w examples parsują się i generują typy, witness, Inbound/Outbound, IMPL, make i descriptor. |
| C02 | Wygenerowane .ml/.mli i przykład implementacji budują się z well.core. Osobne biblioteki Reporter i SummaryBuilder nie zależą od siebie. |
| C03 | Błędny rodzaj inbound/outbound odrzuca kompilator; Message wiąże wartość z właściwym witness. |
| C04 | Struct, variant, optional, list i referencje między plikami zachowują pozycyjny wire. Metadane pola zgadzają się z jego indeksem. |
| C05 | Błędy TOML: nieznana nazwa, cykl typów, duplikat, zła składnia typu, kolizja nazw, actor+service, reserved name: brak częściowej podmiany output. |
| C06 | Dwukrotna generacja i zmiana kolejności katalogu dają identyczne pliki. Zmiana kolejności pól zmienia wire/hash. |
| C07 | Ręczny RAW_ACTOR zwracający niezgodny wire nie obchodzi walidacji. |
| C08 | Kodeki odrzucają brak/nadmiar pozycji, nieznany wariant, NaN/Infinity i int poza zakresem. |
| C09 | Kanonizacja JCS: kolejność kluczy obiektu nie zmienia hasha, kolejność tablicy zmienia; oficjalne wektory liczb i znaków. |
| C10 | Obcy output_dir i niepełny manifest są wykrywane; wejściowe błędy zachowują poprzedni poprawny wynik. |

## Admission i API

| ID | Scenariusz i obserwowalny wynik |
|---|---|
| A01 | Configure raz; złe limity/retry odrzucone; register_type po starcie i drugi raz tej samej nazwy odrzucone. |
| A02 | Validate oraz register_type nie uruchamiają init, handle ani zewnętrznego transportu. |
| A03 | Send przed startem daje NotRunning, nie tworzy kolejki RAM. |
| A04 | Send po commit admission zwraca ID, nawet gdy odbiorca wciąż nie ruszył; inspect daje Running. |
| A05 | Ten sam request_id i identyczne dane przed/po Completed/Failed/restart zwracają jedno wykonanie. Inne dane dają IdempotencyConflict. |
| A06 | Zła wiadomość wejściowa, limit admission albo brak zapisu nie tworzy częściowej instancji/wykonania. |
| A07 | Await przed i po zakończeniu działa; wyścig odczyt/subskrypcja nie gubi zakończenia; anulowanie usuwa waiter. |
| A08 | Timeout await nie przerywa obiegu; późniejszy inspect widzi ukończony wynik. |
| A09 | Decode_output sprawdza nazwę i hash, odrzuca podobny strukturalnie inny typ. |
| A10 | Resume tylko Blocked, zachowuje deadline/ID; abandon ma opisaną idempotencję i nie cofa stanów. |

## Walidacja i routing

| ID | Scenariusz i obserwowalny wynik |
|---|---|
| W01 | Przykłady choice, three-reports, nested i dynamic-reports przechodzą walidację i wykonanie. |
| W02 | Nieznany cel, nieosiągalny węzeł, cykl, pusty fork, duplikat branch name, brak entry: InvalidWorkflow z lokalizacją. |
| W03 | Niezgodność payloadu między węzłami jest odrzucona przed admission. |
| W04 | Fixed/binding/input_path adresują prawidłowo; input_path czyta string przez metadane pozycyjnego wire. Optional/list/variant na ścieżce odrzucone. |
| W05 | One + Accepted uruchamia tylko ścieżkę Accepted; Rejected tylko Rejected. Zero/dwie emisje przy one dają InvalidEmission bez zmiany stanu. |
| W06 | Many zachowuje wszystkie emisje, także wielokrotne tego samego rodzaju; kolejność listy ustala branch_path. |
| W07 | Brak outputs dla zadeklarowanej emisji jest błędem; jawny drop kończy bez wyniku; zero emisji optional kończy token. |
| W08 | Defensywne kopiowanie: zmiana JSON-a klienta po validate/send nie zmienia obiegu. |
| W09 | Każdy inbox/outbox po restarcie zawiera pełny workflow i stałe kontrakty; zmiana pliku definicji nie zmienia kontynuacji. |
| W10 | Dwa węzły z tym samym actor_type mają odrębne pozycje w obiegu i mogą współdzielić actor_id. |

## Scheduler i stan

| ID | Scenariusz i obserwowalny wynik |
|---|---|
| S01 | Bariera w Room/5: drugie wejście do Room/5 nie rozpoczyna handle; Room/8 może postępować. |
| S02 | Jednoczesne pierwsze wejścia do tego samego ID zatwierdzają jeden stan początkowy; init po rollback może być powtórzone. |
| S03 | Mutacja stanu roboczego i wyjątek: kolejna próba widzi dokładnie poprzedni zatwierdzony blob. |
| S04 | Nowsze wejście nie wyprzedza starszego podczas backoff; inne adresy nie są wstrzymywane. |
| S05 | Brak fibera per nieaktywny aktor; limit aktywacji i brak głodzenia przy wielu gotowych ID. |
| S06 | Zewnętrzny blokujący fake transport nie pozwala na drugą aktywację tego samego ID po timeout. |
| S07 | Kooperatywne anulowanie zamyka zasoby i zwalnia claim bez zużycia próby. |
| S08 | Niezgodny state_version daje Blocked, nie init ani reset blobu. |

## Agregacja

| ID | Scenariusz i obserwowalny wynik |
|---|---|
| J01 | Trzy odpowiedzi w każdej permutacji kolejności dają jeden batch w kolejności gałęzi. Po pierwszej/drugiej brak kontynuacji i brak czekającego fibera agregatora. |
| J02 | Ten sam message_id dostarczony dwa razy liczy się raz; drugi różny wynik tego samego branch_id daje DuplicateBranch. |
| J03 | Dwa wykonania i dwie grupy tego samego węzła nie mieszają danych. |
| J04 | Wewnętrzny join kończy się przed zewnętrznym; wynik wraca do właściwej ramki. |
| J05 | Statycznie odrzucone: end/drop przed join, obca grupa, dwa źródła dla jednego join, pominięcie zagnieżdżenia i fan-out bez wewnętrznego join w otwartej gałęzi. |
| J06 | Dynamiczne zero emisji daje jeden pusty batch; jedna daje jednoelementowy; wiele identycznych rodzajów tworzy osobne branch_id. |
| J07 | Restart po 1/3 i 2/3 zachowuje wyniki, expected set i deadline. |
| J08 | Wynik przed deadline kończy grupę; przy commit w deadline lub później wygrywa JoinTimeout. Redelivery timera nie daje drugiego zakończenia. |
| J09 | Brak raportu daje JoinTimeout z listą brakujących gałęzi; nie emituje częściowego batcha. |
| J10 | Utworzenie grupy i szybki wynik nie prowadzą do utraty wyniku przed inicjalizacją agregatora. |

## Crash i atomowość

| ID | Punkt przerwania / obserwacja po restarcie |
|---|---|
| D01 | Po admission przed handle: to samo wejście jest wykonane, klient retry dostaje ten sam execution_id. |
| D02 | Po handle przed CommitTurn: stan bez zmian, brak widocznych emisji, wejście gotowe do ponowienia. |
| D03 | W każdej części zapisu CommitTurn przed COMMIT: zero częściowego stanu/grup/wyników/outboxa. |
| D04 | Po CommitTurn przed routingiem: nowy stan pozostaje, wszystkie emisje zostają dostarczone bez ponownego commit rodzica. |
| D05 | Przy dostarczeniu outboxa: odbiorca ma dokładnie jedno zatwierdzone przetworzenie także po ponowieniu delivery. |
| D06 | Po ostatnim wyniku join przed dostarczeniem batcha: jeden batch, grupa pozostaje zamknięta. |
| D07 | Błąd SQLite/pełny dysk: brak sukcesu admission/commit bez trwałego zapisu; po naprawie brak utraty przyjętych wejść. |
| D08 | Niejasny wynik COMMIT: runtime sprawdza message_id zamiast bezwarunkowo uruchomić handle ponownie. |
| D09 | Osobny proces próbuje otworzyć ten sam magazyn: odrzucony; po zakończeniu pierwszego blokada dostępna. |
| D10 | Odtworzenie z niezgodnym deskryptorem: Blocked i zachowane koperty, potem resume ze zgodnym kodem. |
| D11 | Stary/wcześniejszy deadline po restarcie wywołuje terminalny timeout, nie nowe pełne okno. |

## Efekty, błędy i limity

| ID | Scenariusz i obserwowalny wynik |
|---|---|
| E01 | Zewnętrzny efekt + awaria przed commit: fake idempotent receiver przy retry widzi ten sam klucz i jeden skutek. |
| E02 | Fake bez deduplikacji dokumentuje możliwość dwóch skutków; runtime nie raportuje gwarancji exactly-once. |
| E03 | Retry pięć prób, odstępy 1/2/4/8, po piątej dead-letter; późniejsze wejścia innego wykonania tego aktora mogą postępować. |
| E04 | Domenowa odmowa emituje typowany wynik, nie zwiększa licznika błędów i nie uruchamia retry. |
| E05 | Terminalny błąd jednej gałęzi zatrzymuje nierozpoczęte rodzeństwo; wcześniej zatwierdzony stan pozostaje. |
| E06 | In-flight próba kończy po Failed: jej stan/outbox nie commitują, diagnostyka zachowuje DiscardedAfterFailure. |
| E07 | Limity rozmiaru/stanu/emisji/głębokości/tokenów: brak częściowego commit. Zapełnienie globalnej kolejki nie blokuje terminalnego zamykania. |
| E08 | Napływ nowych wykonań powyżej limitu daje Overloaded; runtime nadal opróżnia istniejący outbox. |
| E09 | Metrics odpowiadają rzeczywistym kolejkom, grupom i aktywacjom; brak automatycznego logowania payloadów. |

## Granica regresji

- R01: istniejące Actor.register/dispatch/health działają jak przed zmianą.
- R02: bez configure/register_type nie powstaje magazyn, timer ani worker
  nowego Actor; stary hook startup zachowuje dotychczasową ścieżkę.
- R03: nowy register_type nie zmienia Service.list_services,
  Service.describe_services, Service.full_health ani tras RPC.
- R04: mieszana aplikacja obsługuje stary Service, stary Actor i nowy Actor
  równocześnie, bez kolizji rejestrów przy tej samej nazwie.
- R05: istniejące testy codegenu RPC i transportu przechodzą bez zmian
  swoich oczekiwanych wyników. Nie rozszerza się przy tym ich funkcjonalności.

## Polecenia i kryterium akceptacji

Podczas implementacji: `make check`, testy Actor i generatora z tego planu,
`make test`, `make build`. Istniejący niezależny failure oauth_provider_test
może być oznaczony jako znany wyłącznie po rozpoznaniu tej samej przyczyny.
Inne regresje są błędem zmiany. Zestaw C02 zawiera budowę przykładu jako
oddzielnych bibliotek; samo porównanie wygenerowanego tekstu nie wystarcza.

Nie jest testem produktu: edytor graficzny, sieciowa dystrybucja, migracja
aplikacji zależnych, nowe endpointy HTTP, zmiany well.web ani własności
zewnętrznego dostawcy maili. Używa się substytutu transportu do granicy Actor.

Uzupełnienie J08/A07: po szybkim Completed await nie czeka do timeout;
pozostałe timery są unieważnione i ich redelivery nie zmienia Completed.
Uzupełnienie D11: handle rozpoczęty przed deadline, ale kończący po nim,
nie zatwierdza swojego stanu i kończy wykonanie ExecutionTimeout.
