# SERVICE.md — Well.Civil_clock

## Rola i granica abstrakcji

`Well.Civil_clock`, dostępny przez `well.core`, udostępnia daty cywilne
i lokalny czas w jawnie wybranej strefie IANA. Jest narzędziem infrastruktury
wspólnym dla warstw aplikacji. Enkapsuluje rozwiązanie nazwy strefy,
interpretację chwili i wybór daty zgodnie z regułami tej strefy, w tym DST.

Konfiguracja strefy, jej wartość domyślna, reakcja na błędną konfigurację,
urlopy, dni robocze i dostępność należą do aplikacji. Moduł nie czyta
`Well.Config`, nie wybiera strefy systemowej i nie przechowuje globalnej
strefy. Dwie aplikacje lub dwa wywołania mogą używać różnych stref
niezależnie, bez zmiany konfiguracji procesu.

## Kontrakt

Poniższa sygnatura jest źródłem publicznego interfejsu
`lib/well/civil_clock.mli`, udostępnionego jako `Well.Civil_clock`.

```ocaml
type zone = private Timedesc.Time_zone.t
type date = Timedesc.Date.t
type date_time = Timedesc.t

type error =
  | Invalid_zone of string
  | Invalid_date of string
  | Invalid_instant of string

val resolve : string -> (zone, error) result
val now : zone:zone -> unit -> date_time
val today : zone:zone -> unit -> date
val date_of_instant : zone:zone -> string -> (date, error) result
val date_of_ymd : string -> (date, error) result
```

`zone` powstaje wyłącznie przez `resolve`. Prywatny alias umożliwia jawną
koercję `(zone :> Timedesc.Time_zone.t)` do dalszych operacji biblioteki,
bez dopuszczenia konstrukcji strefy o dowolnym stałym offsecie jako `zone`.
`date` jest dniem kalendarza gregoriańskiego bez godziny, offsetu i strefy.
`date_time` zawiera lokalną datę, godzinę i strefę; wynik `now` określa
jedną chwilę także podczas jesiennego powtórzenia lokalnej godziny.

Typy dat pozostają zgodne z Timedesc: formatowanie daty przez
`Timedesc.Date.Ymd.to_iso8601`, rok/miesiąc/dzień przez `Timedesc.Date`,
a lokalna godzina i formatowanie chwili przez `Timedesc`. Well nie
wprowadza drugiego modelu kalendarza ani wrapperów tych operacji.

Wejścia tekstowe są normalizowane przez `String.trim`. Wariant błędu
zawiera oryginalny argument, przed normalizacją. Odrzucenie danych wejściowych
zwraca `Error`, bez wyjątku parsera i bez fallbacku. Nieoczekiwane awarie
środowiska wykonania nie są zamieniane na błąd danych wejściowych.

### `resolve`

```use-case
Rozwiąż strefę IANA

[Usuń otaczające białe znaki z nazwy]
<nazwa to UTC albo nazwa strefy lub alias IANA w dostępnej bazie>
  (END Ok zone)
<_>
  (END Error (Invalid_zone oryginalny_argument))
```

Nazwy są rozróżniane co do wielkości liter. Pusta nazwa, nieznana nazwa
i zapis samego offsetu, np. `+02:00` lub `UTC+2`, są odrzucane. Nazwy IANA
takie jak `Etc/GMT-2` pozostają poprawne; ich znaczenie określa baza stref.
Aplikacja może po błędzie ponownie wywołać `resolve` z własną jawną strefą
domyślną albo przerwać operację.

### `now` i `today`

`now ~zone ()` odczytuje bieżącą chwilę raz i zwraca jej lokalną datę
i godzinę w przekazanej strefie. `today ~zone ()` zwraca datę tego samego
rodzaju odczytu; wewnątrz jednego wywołania nie pobiera czasu ponownie.
Osobne wywołania mogą leżeć po dwóch stronach północy. Konsument wymagający
wspólnego odczytu używa `Timedesc.date (now ~zone ())`.

### `date_of_instant`

```use-case
Wyznacz lokalną datę chwili

[Usuń otaczające białe znaki z wejścia]
<wejście nie spełnia profilu chwili określonego poniżej>
  (END Error (Invalid_instant oryginalny_argument))
[Zinterpretuj jedną chwilę określoną przez datę, godzinę i offset]
[Wyznacz lokalną datę w przekazanej strefie]
<lokalna data wykracza poza zakres reprezentacji>
  (END Error (Invalid_instant oryginalny_argument))
<_>
  (END Ok date)
```

Akceptowany profil ISO 8601 to
`YYYY-MM-DDTHH:MM:SS[.fraction](Z|+HH:MM|-HH:MM)`: wielkie `T` i `Z`,
cyfry ASCII, sekundy `00`–`59`, opcjonalnie od jednej do dziewięciu cyfr
ułamka sekundy, godzina `00`–`23`, minuta `00`–`59` i offset o wartości
bezwzględnej mniejszej niż 24 godziny, z minutą `00`–`59`. Data musi istnieć
w kalendarzu. `-00:00`, oznaczające nieznany offset, jest odrzucane.

Sama data, godzina bez offsetu, offset bez dwukropka, nazwa strefy dopisana
do chwili, sekunda przestępna i dodatkowy tekst są odrzucane. Offset wejścia
określa chwilę; reguły przekazanej strefy określają wynikową datę. Moduł nie
sprawdza, czy wejściowa godzina z offsetem jest lokalną godziną tej strefy.
Wiosenna luka ani jesienne powtórzenie godziny nie zmieniają znaczenia
poprawnego wejścia z jawnym offsetem.

Wynik zależy wyłącznie od wejścia i przekazanej strefy, bez odczytu zegara
lub konfiguracji. Operacja umożliwia deterministyczny odbiór granic daty
i przejść DST.

### `date_of_ymd`

Po normalizacji akceptuje wyłącznie kompletny zapis `YYYY-MM-DD` z cyframi
ASCII i istniejącą datą gregoriańską. Zakres roku wynosi `0000`–`9999`,
zgodnie z reprezentacją Timedesc. Krótszy zapis, dodatkowe znaki, godzina,
offset i nieistniejąca data dają `Error (Invalid_date oryginalny_argument)`.
Operacja nie obcina wejścia do pierwszych dziesięciu znaków.

Nie przyjmuje strefy: parsowanie daty cywilnej nie tworzy północy ani chwili
i nie przesuwa dnia. Interpretacja pola przechowującego różne formaty
pozostaje decyzją aplikacji; nie ma operacji zgadującej format wejścia.

## Założenia

Reguły IANA i DST pochodzą z Timedesc z pełną bazą stref
`timedesc.tzdb.full`, dołączoną do programu. Moduł nie używa ręcznych
przesunięć godzin, zmiennej `TZ` ani systemowego katalogu zoneinfo.
Wersja bazy pochodzi z zależności wydania; jej aktualizacja może zmienić
wynik dla stref, których reguły uległy zmianie.

Zależność Timedesc należy do publicznej powierzchni `well.core` przez
aliasy typów. Dostęp do tego modułu nie wymaga uruchomienia serwera Well
ani środowiska Eio. Nie dodaje endpointu HTTP, RPC ani wiadomości CAP.

## Scenariusze i odbiór

Kryteria i konkretne przykłady wejść określa [STP.md](STP.md).
Konfiguracja DG `app.timezone`, domyślne `Europe/Warsaw` i reguły domenowe
pozostają w DG. Usunięcie jego `Zone` i reeksportu `Shared.Civil_clock`
wymaga osobnej migracji po publikacji tego API.

Referencje biblioteki: [Timedesc](https://daypack-dev.github.io/timere/timedesc/Timedesc/index.html),
[Time_zone](https://daypack-dev.github.io/timere/timedesc/Timedesc/Time_zone/index.html)
i [Date.Ymd](https://daypack-dev.github.io/timere/timedesc/Timedesc/Date/Ymd/index.html).
