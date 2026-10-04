# SERVICE.md — Well (HTTP: CSRF, CORS)

## Role

Ochrona żądań HTTP zmieniających stan (CSRF) oraz opcjonalne, fail-closed
zezwolenie przeglądarki na cross-origin (CORS). Integracja jawnych tokenów API
ze zweryfikowaną tożsamością aplikacji i kontekstem RPC. Aplikacja well jest
same-origin; CORS nie jest częścią scaffoldu.

## Abstraction boundary

Enkapsuluje reguły, które żądanie może zmienić stan i które obce originy
dostają nagłówki CORS. Ukrywa magazyn tokenów CSRF, porównanie stałoczasowe
i sposób składania nagłówków odpowiedzi. Aplikacja widzi `Well.csrf`,
`Well.csrf_token` i `Well.cors`.

## Contract

### Diagnostyka HTTP

`GET /health`, `GET /ready` i `GET /metrics` wymagają bieżącego
grantu `cap`. Ochrona jest wbudowana, niezależna od middleware
aplikacji i obowiązuje również przy wyłączonym panelu CAP.
Brak uwierzytelnienia daje 401, a brak grantu daje 403,
bez wykonania handlera diagnostyki. HEAD podlega tej samej kontroli.
Uprawniony użytkownik otrzymuje dotychczasowy wynik diagnostyki.

### `Well.api_token_auth`

```ocaml
type api_token_identity = {
  user_id : string;
  session_data : (string * string) list;
}
val api_token_auth :
  ?applies_to:(request -> bool) ->
  verify:(string -> api_token_identity option) -> unit -> unit
val api_token_authenticated : request -> bool
```

Aplikacja konfiguruje weryfikator przed uruchomieniem serwera. Well przekazuje
mu sekret z jawnego `Authorization: Bearer`; aplikacja przy każdym wywołaniu
sprawdza ważność, odwołanie i status właściciela oraz zwraca bieżącą tożsamość.
Cykl życia i uprawnienia tokenu należą do aplikacji. Well nie zapisuje sekretu.

```use-case
Uwierzytelnij żądanie API

<weryfikator skonfigurowany i jawny nagłówek Bearer>
  <nagłówek niepoprawny albo wielokrotny>
    (END 401 bez wykonania handlera)
  [Zweryfikuj token przez aplikację]
  <weryfikacja niedostępna>
    (END 503 bez wykonania handlera)
  <token odrzucony albo pusty user_id>
    (END 401 bez wykonania handlera)
  [Udostępnij tożsamość tylko w bieżącym fiberze żądania]
  [Wywołaj handler bez uwierzytelniania cookie]
  (END odpowiedź bez tworzenia sesji przeglądarkowej)
<_>
  [Zastosuj dotychczasową obsługę sesji]
  (END odpowiedź)
```

Jawny Bearer ma pierwszeństwo przed cookie; odrzucenie nigdy nie uruchamia
uwierzytelniania cookie. Pozostałe schematy Authorization zachowują działanie.
Bez konfiguracji weryfikatora legacy bearer session ID zachowuje działanie.
Opcjonalny predykat `applies_to` jawnie ogranicza integrację do wybranych
żądań aplikacji; domyślnie obejmuje wszystkie. Żądania poza tym zakresem
zachowują wcześniejszą obsługę sesji i CSRF. Pozwala to aplikacji zachować
oddzielny istniejący protokół Bearer session ID w wyznaczonym API.
Wyjątki weryfikatora dają ogólny komunikat 503, bez treści wyjątku.

`Well.rpc_ctx` i `Well.Session.get/get_all` widzą tę samą tożsamość.
`user_id` w danych dodatkowych nie zastępuje zweryfikowanego właściciela.
Identyfikator kontekstu jest losowy, nie jest sekretem API ani trwałą sesją.
Tożsamość jest izolowana między współbieżnymi fiberami i domenami oraz znika
po zakończeniu lub wyjątku handlera. Zapis, usunięcie i wyczyszczenie takiej
tożsamości przez Session jest odrzucane; odwołanie tokenu należy do aplikacji.
Token API nie tworzy wpisu w magazynie sesji ani nagłówka Set-Cookie.

### `Well.csrf : middleware`

W scaffoldzie jest włączony. Nie przyjmuje allowlisty originów.

```use-case
CSRF — żądanie

<Well.api_token_authenticated jest true>
  (END przepuść)
<metoda GET, HEAD lub OPTIONS>
  (END przepuść)
<_>
  <Sec-Fetch-Site to cross-site lub same-site>
    (END 403 cross-origin)
  <Origin jest "null" albo authority Origin ≠ Host>
    (END 403 cross-origin)
  <X-Requested-With to XMLHttpRequest>
    (END przepuść)
  <_csrf_token w formularzu albo X-CSRF-Token zgadza się z tokenem sesji>
    (END przepuść)
  <_>
    (END 403 invalid CSRF token)
```

Odpowiedź 403:

- cross-origin: ciało `Forbidden — cross-origin request`
- zły lub brak tokenu: ciało `Forbidden — invalid CSRF token`

### `Well.csrf_token : request -> string`

Token sesji, do ukrytego pola formularza albo nagłówka `X-CSRF-Token`.

### `Well.cors`

```ocaml
val cors :
  origins:string list ->
  ?methods:string list ->
  ?headers:string list ->
  ?max_age:int ->
  unit -> middleware
```

Nie jest w scaffoldzie. `origins` jest obowiązkowe. Pusta lista → wyjątek
przy konstrukcji. `"*"` tylko gdy jawnie na liście.

Domyślne `methods`: `GET`, `POST`, `PUT`, `DELETE`, `OPTIONS`.
Domyślne `headers`: `Content-Type`, `Authorization` — bez `X-Requested-With`.

Middleware nigdy nie ustawia `Access-Control-Allow-Credentials`.

```use-case
CORS — odpowiedź

<Origin dozwolony albo lista zawiera "*">
  [ACA-Origin: echo Origin albo "*"]
  [Allow-Methods, Allow-Headers]
  <lista nie zawiera "*">
    [Vary: Origin]
  <metoda OPTIONS>
    (END 204)
  <_>
    [next]
    (END odpowiedź z nagłówkami CORS)
<_>
  <metoda OPTIONS>
    (END 204 bez CORS)
  <_>
    [next]
    (END odpowiedź bez CORS)
```

Lista CORS nie osłabia CSRF: POST z dozwolonej obcej origin i tak dostaje
403 cross-origin.

## Assumptions

- Aplikacja well serwuje HTML, RPC i cookie z jednego originu.
- Cookie sesji jest host-only, `HttpOnly`, `SameSite=Lax`.
- Nagłówek `Host` to authority żądania (host[:port] jak w HTTP).
- `Origin` to `http://` lub `https://` plus authority, bez ścieżki.
  Porównanie z `Host` jest case-insensitive, bez normalizacji portów
  domyślnych.
- Brak `Origin` i brak `Sec-Fetch-Site` (klient nie-przeglądarkowy,
  stara przeglądarka) nie jest sam w sobie powodem 403; dalej obowiązuje
  token albo `X-Requested-With`.
- `Sec-Fetch-Site: none` (nawigacja użytkownika) i `same-origin` przepuszczają
  warstwę origin; token / XHR nadal obowiązuje.
- `X-Requested-With: XMLHttpRequest` (bez rozróżniania wielkości liter)
  zwalnia z tokenu tylko po przejściu warstwy origin.
- Formularz HTML nie ustawia `X-Requested-With` ani `Sec-Fetch-Site:
  same-origin` przy ataku z obcej strony.
- CORS jest zezwoleniem dla przeglądarki, nie tarczą serwera. Brak
  middleware CORS = brak nagłówków CORS = przeglądarka blokuje obcy origin.
- Świadome `~origins:["*"]` oznacza publiczny odczyt bez credentials.
  Cookie i CSRF nadal wiążą same-origin.
- Kto potrzebuje cookie + obcej origin, nie używa `Well.csrf` w tej postaci
  (brak allowlisty). Nie składa się CORS credentials z CSRF.

## Scenarios

- Formularz POST z `_csrf_token` z tej samej strony — 200.
- Ajax same-origin z `X-Requested-With: XMLHttpRequest` bez tokenu — 200.
- POST bez tokenu i bez Ajax — 403 invalid CSRF token.
- POST z obcej strony (przeglądarka stawia `Sec-Fetch-Site: cross-site`
  albo `Origin` ≠ `Host`), nawet z `X-Requested-With` — 403 cross-origin.
- `Well.cors ~origins:["https://app.example.com"] ()` — GET z tego Origin
  dostaje ACAO; POST z tego Origin przy włączonym CSRF i tak 403.
- Nowy projekt: `Well.use Well.csrf`; brak `Well.use Well.cors`.

## Verification strategy

Krytyczne (testy HTTP / unit middleware):

API token (`make api-token-test`):

- Poprawny Bearer bez cookie i bez CSRF: handler widzi tego samego właściciela
  przez RPC i Session; brak Set-Cookie i trwałego wpisu sesji.
- Poprawny Bearer razem z cookie: właścicielem pozostaje właściciel tokenu.
- Niepoprawny, pusty lub wielokrotny Bearer razem z prawidłowym cookie:
  401, WWW-Authenticate Bearer i handler nieuruchomiony.
- Odwołanie/wygaśnięcie/nieaktywny właściciel symulowane przez weryfikator:
  kolejne żądanie dostaje 401; każdorazowa weryfikacja.
- Wyjątek weryfikatora: 503 bez treści wyjątku; brak fallbacku.
- Równoległe żądania różnych właścicieli z yieldem oraz wyjątek handlera:
  tożsamości nie przenikają do siebie ani do następnego żądania.
- Próby zmiany danych tożsamości: odrzucone, właściciel niezmieniony.
- Sam cookie bez CSRF nadal 403; Basic Authorization i legacy tryb bez
  skonfigurowanego weryfikatora zachowują dotychczasowe działanie.

CSRF:

- GET bez tokenu — nie 403 CSRF.
- POST bez tokenu, bez XHR, bez Origin — 403, ciało z `invalid CSRF token`.
- POST z poprawnym `_csrf_token` — 200.
- POST z poprawnym `X-CSRF-Token` — 200.
- POST z `X-Requested-With: XMLHttpRequest`, bez tokenu, bez Origin — 200.
- POST z XHR i `Sec-Fetch-Site: cross-site` — 403, ciało z `cross-origin`.
- POST z `Sec-Fetch-Site: same-site` — 403 cross-origin.
- POST z `Origin: https://evil.example` i `Host: example.com` — 403
  cross-origin, niezależnie od XHR i tokenu.
- POST z `Origin: null` — 403 cross-origin.
- POST z Origin, którego authority = `Host`, plus XHR bez tokenu — 200.
- POST z `Sec-Fetch-Site: same-origin` bez tokenu i bez XHR — 403 token.
- POST z `Sec-Fetch-Site: none` i poprawnym tokenem — 200.

CORS:

- `Well.cors ~origins:[] ()` rzuca przy konstrukcji.
- Dozwolony Origin na GET — `Access-Control-Allow-Origin` równe temu Origin,
  jest `Vary: Origin`, brak `Access-Control-Allow-Credentials`.
- Niedozwolony Origin — brak `Access-Control-Allow-Origin`.
- `~origins:["*"]` — ACAO `*`, brak Allow-Credentials, brak wymogu Vary.
- Domyślne Allow-Headers nie zawierają `X-Requested-With`.
- OPTIONS dozwolonego Origin — 204 i nagłówki CORS.

Scaffold: `Well.use Well.csrf` jest; `Well.use Well.cors` nie ma.
