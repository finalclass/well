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
- Karta użytkownika działa bez wcześniejszego otwarcia listy;
  nieistniejący użytkownik daje 404.
- Operacje użytkowników realizują SERVICE.md, odrzucają brak CSRF
  i chronią ostatniego administratora.
- Filtry i stronicowanie odtwarzają wynik z URL.
- SQL, edycja komórki, RPC i REPL pokazują wynik albo błąd;
  samo wejście GET nie wykonuje tych operacji.

## Odbiór przeglądarkowy

- Przeklikać każdą stronę, formularz i akcję na danych testowych,
  również błędne dane, puste wyniki, wylogowanie i ponowne logowanie.
- Sprawdzić bezpośrednie adresy, odświeżenie i Wstecz/Dalej.
- Sprawdzić napływ logów i wiadomości, aktualizację telemetrii,
  podpowiedzi i historię REPL oraz cleanup po opuszczeniu strony.
- Porównać wygląd przed i po migracji przy identycznym viewport.
- Potwierdzić brak połączeń LiveView i błędów konsoli.
