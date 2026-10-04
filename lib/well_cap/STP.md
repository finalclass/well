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
