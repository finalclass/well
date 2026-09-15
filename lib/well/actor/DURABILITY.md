# Trwałość, awarie i eksploatacja

## Co oznacza sukces

Sukces `send` oznacza trwałe przyjęcie wykonania i pierwszego wejścia,
nie wykonanie aktora ani całego obiegu. Zakończenie `handle` jest wynikiem
próby, nie potwierdzeniem commit. Odpowiedź Completed z `inspect`/`await`
oznacza, że wszystkie kroki i ich wyniki są zatwierdzone.

Zakres gwarancji obejmuje restart procesu, systemu oraz utratę zasilania
przy poprawnie działającym dysku i respektowaniu fsync. Uszkodzenie nośnika,
ręczna modyfikacja magazynu i utrata jego plików wymagają przywrócenia kopii.

## Admission i tożsamość startu

Klient nadaje niepusty `request_id`, do 128 bajtów UTF-8. Klucz obowiązuje
w całym magazynie Actor. Pierwsze przyjęcie zapisuje niezmienną definicję,
wejście, limity wykonania, odciski kontraktów i execution_id.

Ponowienie tego request_id z identycznym obiegiem, payloadem i limitem czasu
zwraca ten sam execution_id niezależnie od obecnego statusu. Inna zawartość
daje IdempotencyConflict i niczego nie uruchamia. Semantyczną identyczność
określa kanonizacja z CONTRACT.md. Utworzenie admission i pierwszej koperty
jest jedną transakcją. Niejednoznaczny wynik po awarii połączenia klient
rozstrzyga przez ponowienie tego samego request_id.

## Aktywacja i stan

Inbox porządkuje wejścia per adres według kolejności trwałego admission do
tego inboxa. Tylko jego najstarsze niezakończone wejście może zostać podjęte.
Claim obejmuje również ładowanie, init, obsługę, walidację emisji i commit.
Retry najstarszego wejścia blokuje nowsze wejścia tego adresu, ale nie inne
adresy. Gotowość wielu adresów obsługiwana jest round-robin, bez głodzenia.

Stan roboczy jest za każdym razem dekodowany z zatwierdzonego blobu do
nowego obiektu. Nie wolno współdzielić jego referencji z cache'em ani inną
aktywacją. Nieudana próba wyrzuca stan roboczy, także jeśli był mutowany.
Runtime nie zakłada, że abstrakcyjny `type state` jest niemutowalny.

Gdy stan jeszcze nie istnieje, `init` tworzy go w ramach pierwszej próby.
Zostaje trwale zapisany dopiero z jej poprawnym commit. Init może być
powtórzone po nieudanej próbie: musi być deterministyczne względem ID i
konfiguracji oraz pozbawione zewnętrznych efektów. Gwarancja to jedno
zatwierdzone utworzenie, a nie dokładnie jedno wywołanie funkcji init.
Nie tworzy się instancji podczas samej rejestracji ani validate.

## Atomowy CommitTurn

W jednej transakcji magazynu:

1. Sprawdź aktualność claim, rewizji stanu i statusu wykonania.
2. Zapisz nowy stan wraz z wersją schematu.
3. Oznacz wejście jako zakończone i zapisz jego identyfikator deduplikacji.
4. Zapisz wszystkie koperty outboxa z finalnymi tożsamościami i obiegiem.
5. Zapisz powstanie/zamknięcie grup, timery, wyniki i zmianę zbioru tokenów.
6. Jeśli nic nie pozostało, oznacz wykonanie Completed.

Brak miejsca, błąd zapisu lub przerwanie przed commit nie może pozostawić
częściowego stanu. Zapis stanu i kasowanie wejścia osobnymi transakcjami
narusza kontrakt. Nie ma otwartej transakcji SQLite podczas `handle`.

Po commit router dostarcza outbox do inboxa w transakcji z deduplikacją
message_id i oznaczeniem pozycji outboxa jako dostarczonej. Każdy adres
widzi kolejność emisji jednego rodzica; przeplot różnych rodziców jest
kolejnością rzeczywistych dostarczeń. Nie ma globalnego FIFO.

Źródłowe `handle` może wykonać się ponownie przed commit. Zatwierdzone
wejście nie powoduje drugiego zatwierdzenia stanu przy redelivery.
Nie deklaruje się exactly-once dla dowolnego zewnętrznego efektu.

## Błędy

| Zdarzenie | Rozstrzygnięcie |
|---|---|
| Niepoprawny workflow/wejście | odrzucenie przed admission, brak instancji |
| Domenowa odmowa | zwykła typowana emisja aktora, routing według obiegu |
| Zwrócone Retry lub zwykły wyjątek handle | ponowienie, bez commit stanu/emisji |
| Zwrócone Fail | Failed wykonania, stan tej próby bez zmian |
| Zła emisja, stan niekodowalny, dynamiczny adres pusty | Failed/InvalidEmission, bez commit tej próby |
| Wyczerpanie retry | Failed/AttemptsExhausted i dead-letter |
| Timeout join | Failed/JoinTimeout, brak częściowego batcha |
| Deadline wykonania | Failed/ExecutionTimeout |
| Niezgodność schematu stanu lub kontraktu po restarcie | Blocked, dane zachowane |
| Błąd magazynu, brak miejsca, SQLITE_BUSY po timeout | wstrzymanie prac zapisu, bez kasowania wejść |
| Anulowanie fibera przy zamykaniu | oddanie claim, bez zaliczania do błędów aktora |

Wersja 1 używa 5 prób łącznie: pierwsza + 4 retry. Odstępy po nieudanych
próbach: 1, 2, 4, 8 sekund, zapisywane jako absolutne available_at. Polityka
konfigurowalna przed startem, przechowywana w admission, nie zmienia się po
restarcie dla istniejącego wykonania. Retry nie resetuje deadline.
Błąd magazynu nie zużywa budżetu retry aktora. Nieznany skutek commit
rozstrzygany jest przez odczyt trwałego message_id przed ponownym handle.

Wszystkie błędy mają kod, execution_id, node_id, message_id, adres aktora
jeśli istnieje, numer próby i czas. Diagnostyka nie wymaga serializacji
stosów OCaml. Payload nie jest automatycznie wypisywany do logu.
Dead-letter zachowuje kopertę i błąd w magazynie Actor.

## Terminalny błąd i równoległe gałęzie

Pierwszy terminalny błąd kończy wykonanie jako Failed. Nierozpoczęte
wejścia i niedostarczone emisje tego wykonania są zakończone bez uruchamiania
zachowania. Nie usuwa się wcześniej zatwierdzonych stanów innych aktorów.

Już działająca próba może dokończyć zewnętrzną operację. Jej CommitTurn
sprawdza terminalność: stan i nowe emisje tej próby nie zostają zatwierdzone.
Nie ma automatycznej kompensacji ani gwarancji cofnięcia zewnętrznego efektu.
Taka sytuacja pozostaje widoczna w diagnostyce jako DiscardedAfterFailure.

Brak „kill fibera i uruchom drugą próbę tego samego ID”. Claim zostaje
zwolniony dopiero po faktycznym zakończeniu kodu. Błąd lub timeout jednego
wykonania nie pozwala na równoczesny dostęp do stanu tej samej instancji.

## Zegary

Timery join oraz całego wykonania są zapisane na dysku razem z obiektem,
którego dotyczą. Po restarcie przeterminowany timer jest gotowy od razu.
Każdy ma trwały timer_id; redelivery i wyścig timer/wynik są idempotentne.

Czas to UTC epoch ms. Zegar systemowy powinien być synchronizowany; duży
skok w przód może wywołać timeout, cofnięcie może opóźnić dostarczenie timera.
Runtime porównuje deadline również podczas commit, nie polega wyłącznie
na punktualnym wybudzeniu. W testach zegar jest kontrolowany.

Deadline wykonania jest wymaganym dodatnim parametrem `send`, najwyżej
30 dni od admission. `await` ma osobny timeout klienta i nie zmienia tego
terminu ani stanu wykonania. Timeout klienta nie jest anulowaniem obiegu.

## Limity i przeciążenie

Domyślne limity konfigurowane przed startem:

| Limit | Domyślna wartość |
|---|---:|
| aktywne instancje równocześnie | 64 |
| worker domains Actor | 1 |
| nieskompresowana definicja workflow | 256 KiB |
| nieskompresowany payload / stan | 1 MiB każde |
| węzły definicji | 256 |
| głębokość zagnieżdżeń grup | 16 |
| emisje jednej aktywacji | 256 |
| utworzone dostarczenia jednego wykonania | 100000 |
| aktywne wykonania w magazynie | 10000 |
| suma oczekujących inbox + outbox | 100000 |

Pominięcie konfiguracji nie oznacza nieograniczonego zasobu. Próba admission
powyżej limitu zwraca Overloaded bez częściowego zapisu. Dla aktywnego
wykonania przekroczenie limitu emisji/stanu/dostarczeń kończy je
LimitExceeded przed commit domenowego stanu danej próby.

Chwilowe zapełnienie globalnej kolejki zatrzymuje admission nowych
wykonań. Wewnętrzne przeniesienie outbox→inbox jest operacją neutralną
licznikowo. Commit zwiększający kolejkę powyżej limitu kończy dane wykonanie
LimitExceeded, zamiast bez końca blokować wszystkie aktywacje. Błędy
terminalne i usuwanie już niepotrzebnych tokenów muszą działać także przy
pełnym limicie. Liczniki obejmują trwałe rezerwacje w jednej transakcji.

Wyczerpanie dysku jest osobnym zdarzeniem storage failure. Nie wolno wtedy
zwrócić pozornego sukcesu Failed, jeśli nie udało się go trwale zapisać.

## Startup, shutdown i restart

Rejestracja i konfiguracja przed Well.run. Istniejący hook Actor.start_all
uruchamia podsystem, jeśli skonfigurowano jego magazyn. Bez konfiguracji
nowego runtime'u hook nie tworzy plików ani workerów nowego modelu.

Start uzyskuje wyłączną blokadę magazynu, otwiera schemat, sprawdza wersję,
odtwarza claimy po poprzednim procesie, timery i outbox. Nie aktywuje wszystkich
logicznych instancji. Uszkodzony schemat magazynu daje błąd startu Actor.

Zmiana schematu technicznego magazynu odbywa się przed admission w transakcji.
Nowsza nieobsługiwana wersja magazynu jest odrzucana bez modyfikacji.
Nie ma automatycznej migracji domenowego `state` między wersjami aktora.

Zamykanie zaprzestaje admission i nowych claimów. Anulowanie aktywacji przez
istniejący switch Well pozostawia niezatwierdzone wejścia do odtworzenia.
Kod aktora musi respektować kooperatywne anulowanie i zwalniać własne zasoby.
Nie zmienia się mechaniki shutdown HTTP ani publicznych parametrów Well.run.

## Retencja i diagnostyka

Brak automatycznego usuwania admission keys, deduplikacji, stanów domenowych,
wyników i dead-letter w wersji 1. Ukończone payloady technicznych inboxów
mogą być usunięte po trwałym zapisaniu deduplikacji i potrzebnych wyników;
nie wolno usuwać danych potrzebnych aktywnym/Blocked wykonaniom.

API udostępnia status wykonania, wyniki, listę błędów i metryki Actor.
Nie dodaje tras, endpointów zdrowia ani zmian do Service.full_health.
Backup i retencję całego pliku wykonuje operator poza aktywnym zapisem lub
narzędziem obsługującym spójny backup SQLite. Nie kopiuje samego pliku .db
w trakcie działania z pominięciem WAL.

## Blocked i aktywacje rozpoczęte wcześniej

Blocked wstrzymuje nowe claimy i dalsze dostarczanie do aktorów danego
wykonania. Zachowane timery nadal obowiązują. Próba uzyskana wcześniej
w stanie Running może zatwierdzić zgodny stan i odłożyć emisje do outboxa,
jeśli wykonanie nie stało się terminalne; outbox czeka na resume.
Wykonanie Blocked nie przechodzi samoczynnie do Completed. Resume sprawdza
zgodność, po czym normalnie rozstrzyga też brak pozostałych tokenów.
Failed/Completed nigdy nie wracają do Running.

## Budżet kroków i pamiętanie zakończenia

Token oznacza jedną logiczną kontynuację. Claim nie tworzy nowego tokenu.
Retry zachowuje token i message_id; zakończenie zastępuje token zbiorem
potomków albo wynikiem. Otwarta grupa jest osobnym zobowiązaniem, więc
chwilowa pustka mailboxów podczas zbierania raportów nie kończy wykonania.
Ruch outbox→inbox zachowuje tożsamość i licznik tokenu. Wbudowany join
zamienia komplet gałęzi oraz grupę na jedną kontynuację w tym samym commit.

Limit deliveries_per_execution obejmuje początkowe wejście, wszystkie
zaplanowane potomne dostarczenia i komunikaty techniczne, w tym timery;
redelivery tego samego ID nie zwiększa licznika. Zakończenie terminalne jest
operacją magazynu i nie wymaga utworzenia kolejnego tokenu. Branch_path
kontynuacji po join wraca do ścieżki sprzed otwarcia jego grupy.

## Zakończenie i anulowanie zegarów

Zegary są zobowiązaniami technicznymi, nie tokenami przepływu. Zamknięcie
grupy atomowo unieważnia jej timer; przejście wykonania do Completed/Failed
atomowo unieważnia jego pozostałe timery. Nie oczekuje się na pierwotny
termin timera, aby uznać kompletne wykonanie za zakończone. Już dostarczona
wiadomość unieważnionego timera jest idempotentnym no-op bez zmiany statusu.

Każdy CommitTurn sprawdza również absolutny deadline wykonania. Próba
kończąca się w tym terminie lub później nie zatwierdza stanu domenowego;
wykonanie zostaje atomowo Failed/ExecutionTimeout. Nie wystarczy sprawdzić
termin przed uruchomieniem handle. Wykonanie zakończone przed terminem nie
może zostać później zmienione na Failed przez spóźniony timer.
