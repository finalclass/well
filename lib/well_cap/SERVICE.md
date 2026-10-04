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
| `/_cap/repl` | REPL |
| `/_cap/users` | Lista użytkowników |
| `/_cap/users/new` | Tworzenie użytkownika |
| `/_cap/users/:id` | Karta użytkownika i formularze administracyjne |

Filtry, wyszukiwanie, stronicowanie, wybór bazy i tabeli oraz wybór
usługi i metody RPC mają reprezentację w URL. Bezpośrednie wejście,
odświeżenie oraz Wstecz/Dalej odtwarzają wskazany widok.
Nieistniejący użytkownik otrzymuje odpowiedź 404.

Formularze administracyjne korzystają z POST i ochrony CSRF.
Udana zmiana użytkownika kończy się przekierowaniem do właściwej strony;
błąd wraca do formularza z komunikatem. Hasła nie trafiają do URL ani
ponownie do HTML. Wylogowanie jest operacją POST.

Zachowane operacje: tworzenie i usuwanie użytkownika, zmiana emaila
i hasła, nadawanie i odbieranie grantów, przeglądanie baz i tabel,
edycja komórek, wykonywanie SQL, wywoływanie RPC i wykonywanie REPL.
Usunięcie ostatniego posiadacza grantu `cap` lub odebranie mu tego grantu
jest odrzucane.

## Fragmenty Well.Web

TEA obsługuje tylko aktualizacje logów, wiadomości i telemetrii oraz
lokalną interakcję REPL wymagającą podpowiedzi i historii poleceń.
Otaczająca strona pozostaje MPA. Komponenty nie przejmują routingu.
Wywołania objęte kontraktem korzystają z wygenerowanego Proxy.
Odłączenie komponentu zatrzymuje jego subskrypcje i cykliczne odczyty.

## Założenia

Wszystkie strony poza logowaniem oraz wszystkie endpointy danych
i operacji sprawdzają bieżące uprawnienie `cap`.
Zachowana jest istniejąca grafika: CSS, kolory, typografia, ikony
i układ panelu. Elementy odnoszące się wyłącznie do LiveView są usunięte.
