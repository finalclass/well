# STP — migracja Well i CAP na MPA oraz Well.Web

## Framework

- `make check` i `make build` przechodzą bez zależności od LiveView.
- Publiczne API, runtime i generowany scaffold nie zawierają LiveView.
- Nowy scaffold buduje się z lokalnym Well; strona SSR oraz komponent
  TEA działają w przeglądarce.
- Istniejące testy niezależnych mechanizmów HTTP, HTML/VDOM, WebSocket,
  Channel, MessageBus, kontraktów i Actor zachowują działanie.

## HTTP i operacje

Testy integracyjne używają izolowanej aplikacji i testowej bazy.

- Strony z tabeli w SERVICE.md zwracają HTML; wejście bez uprawnień
  oraz dostęp do endpointów komponentów nie omijają autoryzacji.
- Każda trasa CAP poza logowaniem, również `/_cap/app.js`,
  odrzuca anonimowego klienta i zalogowanego użytkownika bez `cap`.
  POST używa poprawnego CSRF, żeby sprawdzić odmowę autoryzacji.
- Odebranie `cap` blokuje kolejne żądanie bez wylogowania.
- Nowa testowa trasa CAP bez kontroli w handlerze pozostaje chroniona;
  odmowa nie wykonuje handlera. GET i POST logowania pozostają dostępne.
- Diagnostyka HTTP realizuje kontrakt z `lib/well/SERVICE.md`:
  anonimowy klient, użytkownik bez grantu oraz posiadacz `cap`;
  GET i HEAD, panel włączony i wyłączony, odebranie grantu w sesji.
  Odmowy nie ujawniają danych diagnostycznych, a uprawniony klient
  zachowuje dotychczasowe odpowiedzi, także 503 przy braku gotowości.
- Karta użytkownika działa bez wcześniejszego otwarcia listy;
  nieistniejący użytkownik daje 404.
- Operacje użytkowników realizują SERVICE.md, odrzucają brak CSRF
  i chronią ostatniego administratora.
- Filtry i stronicowanie odtwarzają wynik z URL.
- SQL, edycja komórki, RPC i REPL pokazują wynik albo błąd;
  samo wejście GET nie wykonuje tych operacji.

## Wiadomości CAP

- Anonimowy klient i użytkownik bez `cap` nie dołączają do kanału
  CAP, nie wykonują jego poleceń i nie otrzymują jego danych.
- Subskrypcja `*` i wildcard kanału aplikacji nie ujawniają danych CAP.
- Posiadacz grantu otrzymuje stan początkowy, odpowiedzi i zdarzenia CAP.
- Odebranie grantu przy otwartym połączeniu blokuje następne polecenie
  oraz dostarczenie danych CAP, również oczekujących w kolejce.
- Na tym samym połączeniu kanał aplikacji nadal działa według swojej
  autoryzacji, także gdy klient nie ma grantu CAP.

## Retencja logów

Testy bufora działają w izolowanym procesie z rzeczywistym modułem
CAP oraz, dla napływu logów, z podłączonym hookiem loggera.
Nie podmieniają bufora jego modelem. Korzystają z limitów
z sekcji „Retencja logów” w SERVICE.md.

- Po wielokrotnym przekroczeniu limitu liczby wpisów zostają najnowsze
  wpisy; limit sumy bajtów działa także dla mniejszej liczby dłuższych
  komunikatów. Do budżetu wliczany jest kontekst.
- Bardzo długi komunikat i poziom, długi klucz i wartość oraz wiele par kontekstu
  respektują limit pojedynczego wpisu, pierwszeństwo komunikatu
  i znaczniki skrócenia. Skrócenie polskiego tekstu nie rozcina UTF-8.
  Plik i stdout otrzymują pełne dane.
- Import pliku wielokrotnie większego od budżetu, również z pojedynczym
  bardzo długim wierszem, zachowuje dozwolony wycinek. Po dopisaniu
  kolejnych wpisów obowiązują te same limity. Niepoprawny wiersz
  nie blokuje odczytu następnych poprawnych wpisów.
- Po usuwaniu najstarszych wpisów `recent`, wyszukiwanie z filtrami,
  `before` i `around` nie zwracają usuniętych wpisów ani duplikatów.
  Pokryć pusty bufor, granice zachowanego zakresu, skok poza zakres
  oraz monotoniczność identyfikatorów. Kilka rund równoległego dopisywania
  i odczytów zachowuje te własności oraz kończy się bez zakleszczenia.
- Próba pamięci obejmuje rozgrzewkę do nasycenia retencji oraz
  dziesięć kolejnych partii po 100 000 unikalnych logów z kontekstem.
  Po każdej partii pełne GC i pomiar liczby zachowanych wpisów,
  bajtów treści, żywych bajtów sterty i RSS procesu. Dopuszczalny
  wzrost żywej sterty względem pomiaru po rozgrzewce wynosi 1 MiB,
  a RSS 16 MiB; żaden limit retencji nie może być przekroczony.
  Osobne próby obejmują powtarzany import oraz generowanie dużych
  komunikatów i kontekstów, każda z własną rozgrzewką przy tym samym
  rozkładzie rozmiarów wpisów co próba. Dane wejściowe są tworzone partiami
  i po emisji zwalniane, żeby generator nie przechowywał historii.
  Raport podaje każdy pomiar i całkowitą liczbę wyemitowanych wpisów,
  nie tylko wynik końcowy. Wynik dotyczy pamięci logowania CAP,
  a nie wszystkich możliwych alokacji aplikacji.
- Regresja obejmuje istniejące testy CAP MPA i CAP access.
  W przeglądarce sprawdzić napływ, filtry, stronicowanie i skok
  do czasu po wyparciu starych wpisów oraz informację o ograniczonym
  wycinku historii. Brak grantu `cap` nadal blokuje dane logów.

## Odbiór przeglądarkowy

- Przeklikać każdą stronę, formularz i akcję na danych testowych,
  również błędne dane, puste wyniki, wylogowanie i ponowne logowanie.
- Sprawdzić bezpośrednie adresy, odświeżenie i Wstecz/Dalej.
- Sprawdzić napływ logów i wiadomości, aktualizację telemetrii,
  podpowiedzi i historię REPL oraz cleanup po opuszczeniu strony.
- Metryki: dwa wejścia na `/users/1` i `/users/2` dają jeden wiersz
  szablonu; JSON nie tworzy przejścia obiegu; plik statyczny i strona
  CAP nie wchodzą do klasy aplikacji; wyciszenie metody zatrzymuje jej
  licznik do podanego terminu, a po terminie licznik znów rośnie;
  restart procesu zachowuje liczby z okna; wyłączenie usługi bez terminu
  zostawia jej licznik bez wzrostu po restarcie i po czasie dłuższym niż
  doba, a ponowne włączenie pozwala licznikowi rosnąć.
- Porównać wygląd przed i po migracji przy identycznym viewport.
- Potwierdzić brak połączeń LiveView i błędów konsoli.
