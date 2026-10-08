# STP.md — Well.Civil_clock

## Strategia

Testy publicznego API `Well.Civil_clock` używają rzeczywistej biblioteki
Timedesc i dołączonej pełnej bazy IANA, bez mockowania reguł stref.
Oczekiwane daty są literalnymi wartościami poniżej, a nie wynikiem drugiego
wywołania tej samej konwersji bibliotecznej. Zachowanie określa
[SERVICE.md](SERVICE.md); ten plan wyznacza zakres testów po jego akceptacji.

## C01 — rozwiązanie strefy

`Europe/Warsaw`, `America/New_York`, `Asia/Kathmandu`, `UTC` i
`Etc/GMT-2` dają `Ok zone`. Białe znaki wokół poprawnej nazwy są pomijane.
Nieznana nazwa, puste wejście, same białe znaki, `europe/warsaw`, `+02:00`
i `UTC+2` dają `Invalid_zone` z dokładnym oryginalnym argumentem.
Jawne drugie wywołanie `resolve "UTC"` po błędzie daje poprawną strefę;
pierwsze wywołanie nie wykonuje fallbacku.

## C02 — granica daty i offset wejścia

Każdy wiersz to oddzielna konwersja przez `date_of_instant`. Strefa
przekazana do operacji pochodzi z `resolve`.

| Strefa | Chwila | Oczekiwana data |
|---|---|---|
| `UTC` | `2026-01-15T23:30:00Z` | `2026-01-15` |
| `Europe/Warsaw` | `2026-01-15T23:30:00Z` | `2026-01-16` |
| `Europe/Warsaw` | `2025-12-31T23:30:00Z` | `2026-01-01` |
| `America/New_York` | `2026-01-16T00:30:00Z` | `2026-01-15` |
| `Asia/Kathmandu` | `2026-01-15T18:30:00Z` | `2026-01-16` |
| `UTC` | `2026-01-16T00:30:00+02:00` | `2026-01-15` |
| `Europe/Warsaw` | `2026-01-16T00:30:00+01:00` | `2026-01-16` |
| `Europe/Warsaw` | `2026-01-15T23:30:00.123456789Z` | `2026-01-16` |

Przeplatanie wywołań dla UTC, Warszawy i Nowego Jorku zachowuje te wyniki,
również przy równoległym użyciu w dwóch domenach OCaml.

## C03 — zima, lato i przejścia DST

| Strefa | Chwila | Oczekiwana data |
|---|---|---|
| `Europe/Warsaw` | `2026-01-15T22:30:00Z` | `2026-01-15` |
| `Europe/Warsaw` | `2026-07-15T22:30:00Z` | `2026-07-16` |
| `Europe/Warsaw` | `2026-03-28T22:30:00Z` | `2026-03-28` |
| `Europe/Warsaw` | `2026-03-29T22:30:00Z` | `2026-03-30` |
| `Europe/Warsaw` | `2026-03-29T00:59:59Z` | `2026-03-29` |
| `Europe/Warsaw` | `2026-03-29T01:00:00Z` | `2026-03-29` |
| `Europe/Warsaw` | `2026-10-24T22:30:00Z` | `2026-10-25` |
| `Europe/Warsaw` | `2026-10-25T22:30:00Z` | `2026-10-25` |
| `Europe/Warsaw` | `2026-10-25T00:59:59Z` | `2026-10-25` |
| `Europe/Warsaw` | `2026-10-25T01:00:00Z` | `2026-10-25` |
| `Europe/Warsaw` | `2026-03-29T02:30:00+01:00` | `2026-03-29` |
| `Europe/Warsaw` | `2026-10-25T02:30:00+02:00` | `2026-10-25` |
| `Europe/Warsaw` | `2026-10-25T02:30:00+01:00` | `2026-10-25` |

## C04 — data cywilna

`2024-02-29`, `2026-01-16`, `0000-01-01` i `9999-12-31` dają daty
formatowane z powrotem do tego samego tekstu; otaczające białe znaki są
pomijane. Wynik nie wymaga rozwiązania strefy.

Puste wejście, `2026-02-29`, `2026-02-30`, miesiące `00`/`13`, dzień `00`,
`2026-1-16`, `20260116`, cyfry spoza ASCII, `2026-01-16extra` i
`2026-01-16T00:00:00Z` dają `Invalid_date` z oryginalnym argumentem.

## C05 — odrzucanie niepoprawnych chwil

Puste wejście, nieistniejąca data, sama data, godzina bez offsetu,
offset `+0100`, `+24:00`, `+01:60` albo `-00:00`, godzina `24`, minuta `60`,
sekunda `60`, małe `t`/`z`, nazwa strefy w nawiasach, cyfry spoza ASCII,
pusty ułamek, dziesięć cyfr ułamka i dodatkowy tekst dają `Invalid_instant`
z oryginalnym argumentem. Poprawna chwila otoczona białymi znakami daje
taki sam wynik jak bez nich. `+00:00` pozostaje poprawne.

`9999-12-31T23:30:00Z` w `Europe/Warsaw` i
`0000-01-01T00:30:00+01:00` w `UTC` dają `Invalid_instant`, ponieważ
wynikowa data wykracza poza reprezentację. Żaden przypadek błędnego wejścia
nie rzuca wyjątku parsera ani nie zwraca daty w zastępczej strefie.

## C06 — bieżący czas i publiczna integracja

Bez uruchomienia Well i Eio, w osobnym procesie konsumenta `well.core`:

- `now ~zone ()` dla Warszawy zwraca jej strefę i dokładnie jedną chwilę;
  mieści się między odczytem zegara systemowego przed i po wywołaniu.
- `today ~zone ()` daje datę jednego z ograniczających go wywołań `now`,
  co dopuszcza przejście północy między osobnymi odczytami.
- Procesy uruchomione z `TZ=UTC` oraz `TZ=America/New_York` zachowują
  identyczne wyniki deterministycznych konwersji C02–C03 dla jawnej strefy.
- Prywatny alias `zone` daje się koercjować do `Timedesc.Time_zone.t`;
  publiczne aliasy dat obsługują formatowanie i odczyt pól z kontraktu.
- Próba przekazania dowolnego `Timedesc.Time_zone.t` jako `zone` nie
  kompiluje się; `date` i `date_time` również pozostają różnymi typami.

## Uruchomienie i zakres

Cel odbioru implementacji: `make civil-clock-test`, obejmujący C01–C06,
izolowanego konsumenta i negatywne próby kompilacji. Cel dodaje się wraz
z implementacją. Kontrola typów frameworka: `make check`; kompilacja
frameworka: `make build`. Sukces obejmuje wszystkie te kontrole.

Plan nie obejmuje migracji DG, konfiguracji `app.timezone`, domyślnej strefy
aplikacji, reguł urlopów i dostępności, harmonogramowania zdarzeń ani UI.
