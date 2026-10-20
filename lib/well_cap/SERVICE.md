# SERVICE.md — CAP

## Rola i granica

Wbudowany panel administracyjny Well prezentuje stan aplikacji i umożliwia
wykonywanie operacji administracyjnych. Enkapsuluje prezentację i transport
panelu; korzysta z istniejących mechanizmów Auth, Db, Service, MessageBus
i Telemetry bez zmiany ich odpowiedzialności.

## Kontrakt stron

Każdy GET zwraca kompletną stronę HTML renderowaną na serwerze.
Nawigacja używa zwykłych odnośników i pełnych żądań dokumentu.

| Adres | Strona |
|---|---|
| `/_cap/login` | Logowanie |
| `/_cap/` | Przegląd |
| `/_cap/routes` | Trasy |
| `/_cap/connections` | Połączenia |
| `/_cap/db` | Baza danych |
| `/_cap/services` | Usługi i wywoływanie RPC |
| `/_cap/messages` | Wiadomości MessageBus |
| `/_cap/logs` | Logi |
| `/_cap/telemetry` | Telemetria |
| `/_cap/metrics` | Metryki tras, obiegu i metod usług |
| `/_cap/repl` | REPL |
| `/_cap/users` | Lista użytkowników |
| `/_cap/users/new` | Tworzenie użytkownika |
| `/_cap/users/:id` | Karta użytkownika i formularze administracyjne |

Filtry, wyszukiwanie, stronicowanie, wybór bazy i tabeli, wybór
usługi i metody RPC oraz okno i klasa metryk mają reprezentację w URL.
Bezpośrednie wejście, odświeżenie oraz Wstecz/Dalej odtwarzają wskazany widok.
Nieistniejący użytkownik otrzymuje odpowiedź 404.

Formularze administracyjne korzystają z POST i ochrony CSRF.
Udana zmiana użytkownika kończy się przekierowaniem do właściwej strony;
błąd wraca do formularza z komunikatem. Hasła nie trafiają do URL ani
ponownie do HTML. Wylogowanie jest operacją POST.

Zachowane operacje: tworzenie i usuwanie użytkownika, zmiana emaila
i hasła, nadawanie i odbieranie grantów, przeglądanie baz i tabel,
edycja komórek, wykonywanie SQL, wywoływanie RPC, wykonywanie REPL
oraz włączanie i wyłączanie pomiaru metod usług.

## Retencja logów

Podgląd logów CAP przechowuje najnowszy wycinek historii procesu.
Pamięć zachowanych wpisów jest ograniczona niezależnie od czasu działania,
liczby wygenerowanych logów, otwarcia panelu i rotacji plików.
Jednocześnie obowiązują limity 4096 wpisów i 4 MiB treści.
Treść oznacza sumę długości w bajtach poziomu, komunikatu oraz kluczy
i wartości kontekstu; liczba wpisów ogranicza narzut struktur danych.
Przekroczenie któregokolwiek limitu usuwa najstarsze wpisy i zwalnia
odwołania do ich komunikatów oraz kontekstu.

Jeden zachowany wpis zawiera najwyżej 16 KiB treści. Poziom zajmuje
najwyżej 64 bajty tego budżetu. Komunikat ma pierwszeństwo przed
kontekstem. Zbyt długi poziom lub komunikat jest skracany
na granicy znaku UTF-8, z widocznym znacznikiem `[truncated]` wliczanym
do limitu; kontekst zachowuje tylko pierwsze kompletne pary mieszczące
się w pozostałym budżecie. Pominięcie kontekstu również jest oznaczone
tym znacznikiem. Panel zachowuje własną ograniczoną kopię, bez
utrzymywania odwołań do pierwotnych dużych komunikatów i kontekstów.
Ograniczenie podglądu nie zmienia treści kierowanej do pliku i stdout.

Import istniejącego `well.log` przy uruchomieniu stosuje tę samą
retencję i ograniczenie pojedynczego wpisu. Odczyt jest strumieniowy:
rozmiar pliku ani pojedynczego wiersza nie wyznacza rozmiaru bufora
odczytu. Po imporcie nowe wpisy wypierają najstarsze na tych samych
zasadach.

Identyfikatory wpisów rosną przez czas życia procesu i nie są używane
ponownie po usunięciu wpisu. Wyszukiwanie, filtry, stronicowanie
według identyfikatora i skok do czasu dotyczą wyłącznie zachowanej
historii. Starsze usunięte wpisy nie wracają przy odświeżeniu ani
stronicowaniu; strona poprzedzająca najstarszy zachowany wpis jest
pusta. Skok do czasu poza zachowanym zakresem wskazuje najbliższy
zachowany wpis. Odczyty pozostają chronologiczne i bez duplikatów
również podczas równoległego dopisywania i usuwania najstarszych wpisów.
Strona logów wyraźnie informuje, że pokazuje tylko ostatni wycinek
historii. Dotychczasowe reguły dostępu CAP obowiązują bez zmian.

## Metryki

Strona `/_cap/metrics` czyta agregaty z bazy frameworka. Agregaty
przeżywają restart procesu i obejmują ostatnią godzinę albo ostatnią
dobę. Parametry `window=hour|day` i `class=app|static|cap` wybierają
widok.

Endpoint HTTP jest parą metody i szablonu trasy (`GET /users/:id`).
Nieznana ścieżka wpada do jednego wiersza `(unmatched)`, a pliki
statyczne do prefiksu montowania z `/*`. Dla każdego endpointu widać
liczbę wejść, średni czas, przybliżony p95 oraz liczby odpowiedzi
2xx, 4xx i 5xx. Ruch aplikacji, plików statycznych i CAP jest osobno.
Czas żądania obejmuje całą obsługę HTTP i nie zastępuje czasu metody.

Obieg liczy przejścia między dokumentami HTML aplikacji w jednej
sesji przeglądarki. Pierwsze wejście sesji zaczyna się od `(entry)`.
Żądania JSON, pliki statyczne, CAP i odpowiedzi inne niż 2xx nie
przesuwają obiegu.

Każda zarejestrowana metoda usługi i aktora jest mierzona, także gdy
usługa nie jest opublikowana przez `expose`. Wiersz pokazuje liczbę
wywołań, średni czas, przybliżony p95 oraz podział na sukces i błąd
wykonania. Odmowa zapisana jako zwykły wynik kontraktu jest sukcesem
wywołania. Operator wycisza całą usługę albo jedną metodę na 1, 6
albo 24 godziny. Po tym terminie pomiar wraca. Wybór przeżywa restart.
Operator wyłącza też całą zarejestrowaną usługę albo aktora bez terminu.
Wyłączenie przeżywa restart i trwa, aż operator włączy pomiar. W tym
czasie żadna metoda tej usługi nie jest mierzona: wywołanie nie
aktualizuje liczników i nie wykonuje zapisu agregatu. Dotychczasowe
liczby w oknie zostają. Czas żądania HTTP pozostaje osobnym pomiarem.
Wywołanie, które omija rejestr usług, nie ma wiersza.
Usunięcie ostatniego posiadacza grantu `cap` lub odebranie mu tego grantu
jest odrzucane.

## Fragmenty Well.Web

TEA obsługuje tylko aktualizacje logów, wiadomości i telemetrii oraz
lokalną interakcję REPL wymagającą podpowiedzi i historii poleceń.
Otaczająca strona pozostaje MPA. Komponenty nie przejmują routingu.
Wywołania objęte kontraktem korzystają z wygenerowanego Proxy.
Odłączenie komponentu zatrzymuje jego subskrypcje i cykliczne odczyty.

## Wiadomości CAP

Kanały `cap:*` są zarezerwowane dla komunikacji CAP.
Serwer wymaga bieżącego grantu `cap` przed dołączeniem do kanału,
wykonaniem polecenia oraz wysłaniem danych CAP do klienta,
włącznie ze stanem początkowym i odpowiedziami na polecenia.
Klasyfikacja wynika z kanału po stronie serwera, nie z deklaracji
pochodzenia wiadomości przez klienta. Ogólna subskrypcja `*`
ani wildcard rejestracji aplikacji nie omijają ochrony kanałów CAP.
Po odebraniu grantu istniejące połączenie nie wykonuje poleceń CAP
i nie otrzymuje kolejnych danych CAP, także już oczekujących w kolejce.
Odmowa nie zamyka wspólnego WebSocketu; kanały aplikacji zachowują
swoje reguły autoryzacji. Dane CAP nie są wysyłane kanałami aplikacji.

## Założenia

Wszystkie strony poza logowaniem oraz wszystkie endpointy danych
i operacji sprawdzają bieżące uprawnienie `cap`.
Ochrona obejmuje również zasoby panelu, w tym `/_cap/app.js`.
Każda nowo zarejestrowana trasa CAP automatycznie wymaga tego grantu;
pominięcie kontroli w handlerze nie pozwala ominąć autoryzacji.
Jedynymi publicznymi trasami CAP są GET i POST `/_cap/login`.
Odebranie grantu blokuje następne żądanie w istniejącej sesji.
Odmowa nie wykonuje handlera: strony przekierowują do logowania,
a endpointy danych, operacji i zasobów zwracają 401.

Zachowana jest istniejąca grafika: CSS, kolory, typografia, ikony
i układ panelu. Elementy odnoszące się wyłącznie do LiveView są usunięte.
