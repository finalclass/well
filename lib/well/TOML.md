# Well.Toml — kontrakt serializacji

## Rola i granica

`Well.Toml` jest infrastrukturą odczytu i zapisu dokumentów TOML udostępnianą
aplikacjom przez `well.core`. Ukrywa reprezentację potrzebną do poprawnego,
czytelnego zapisu zagnieżdżonych tabel i kolekcji. Schematy danych aplikacji,
identyfikatory, wersjonowanie i zasady trwałości pozostają u ich właścicieli.

## Kontrakt

```ocaml
type t = Otoml.t
val from_string : string -> t
val from_file : string -> t
val to_string : t -> string
val to_file : string -> t -> unit
```

`to_string` zwraca dokument TOML zachowujący wartości i przynależność pól do
tabel. Zwykłe pola danej tabeli występują przed jej podtabelami i tablicami
tabel, niezależnie od kolejności wejściowych par. Kolejność wewnątrz obu grup
oraz kolejność elementów tablic pozostają zachowane.

Niepusta tablica złożona wyłącznie ze zwykłych tabel jest zapisywana jako
tablica tabel (`[[…]]`). Normalizacja obejmuje wszystkie poziomy dokumentu.
Puste tablice pozostają zwykłymi pustymi tablicami. Tablice wartości,
tablice mieszane oraz jawne tabele inline zachowują swoją reprezentację;
tablica tabel inline nie jest automatycznie zamieniana na sekcje `[[…]]`.

Formatowanie używa dwóch spacji wcięcia i pustego wiersza przed sekcją tabeli.
Operacja nie modyfikuje wejściowej wartości i nie wprowadza reguł domenowych.
`to_file` zapisuje ten sam tekst co `to_string` i zamyka plik także po wyjątku;
nie gwarantuje atomowego zapisu. Błędy drukarki, parsera i plików pozostają
wyjątkami dotychczasowego API.

Poprawne dokumenty wejściowe mają unikalne klucze i wartości obsługiwane przez
Otoml. Zachowanie komentarzy, oryginalnych białych znaków i identyczności
bajtowej wejściowego tekstu nie jest częścią kontraktu. Zmiana ujednolica
serializację używaną dotychczas przez lokalny `Toml_print` w aplikacji DG;
publiczne sygnatury Well pozostają bez zmian.

## Weryfikacja

Rzeczywisty parser i drukarka Otoml, bez mocków:

- Pole skalarne po podtabeli na wejściu zachowuje właściciela po zapisie
  i odczycie; obejmuje także zagnieżdżone podtabele.
- Niepuste tablice tabel na kilku poziomach zachowują wartości i kolejność
  rekordów po odczycie; wynik zawiera sekcje `[[…]]`.
- Jawne tablice tabel, puste kolekcje, zwykłe i mieszane tablice oraz tabele
  inline zachowują znaczenie, w tym znaki wymagające escaping.
- Powtórna serializacja odczytanego dokumentu daje identyczny tekst.
- `to_file` zapisuje tekst identyczny z `to_string` i daje się odczytać przez
  `from_file`.

Uruchomienie: `make toml-test`. Regresja sąsiedniego konsumenta TOML:
`make registry-test`. Kompilacja frameworka: `make build`.
