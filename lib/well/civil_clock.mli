type zone = private Timedesc.Time_zone.t

type date = Timedesc.Date.t

type date_time = Timedesc.t

type error =
  | Invalid_zone of string
  | Invalid_date of string
  | Invalid_instant of string

(** Rozwiąż strefę IANA. Kontrakt: [civil_clock/SERVICE.md].

    ```use-case
    Rozwiąż strefę IANA

    [Usuń otaczające białe znaki z nazwy]
    <nazwa to UTC albo nazwa strefy lub alias IANA w dostępnej bazie>
      (END Ok zone)
    <_>
      (END Error (Invalid_zone oryginalny_argument))
    ``` *)
val resolve : string -> (zone, error) result

(** Odczytaj jedną bieżącą chwilę w jawnej strefie.

    ```use-case
    Odczytaj lokalny czas

    [Odczytaj bieżącą chwilę raz]
    [Przedstaw chwilę w przekazanej strefie]
    (END date_time określający jedną chwilę)
    ``` *)
val now : zone:zone -> unit -> date_time

(** Wyznacz datę z jednego bieżącego odczytu w jawnej strefie.

    ```use-case
    Wyznacz dzisiejszą datę

    [Odczytaj lokalny czas przez now]
    [Wybierz datę odczytanej chwili]
    (END date)
    ``` *)
val today : zone:zone -> unit -> date

(** Wyznacz lokalną datę chwili z jawnym offsetem.

    ```use-case
    Wyznacz lokalną datę chwili

    [Usuń otaczające białe znaki z wejścia]
    <wejście nie spełnia profilu chwili z SERVICE.md>
      (END Error (Invalid_instant oryginalny_argument))
    [Zinterpretuj jedną chwilę określoną przez datę, godzinę i offset]
    [Wyznacz lokalną datę w przekazanej strefie]
    <lokalna data wykracza poza zakres reprezentacji>
      (END Error (Invalid_instant oryginalny_argument))
    <_>
      (END Ok date)
    ``` *)
val date_of_instant : zone:zone -> string -> (date, error) result

(** Odczytaj kompletną datę cywilną YYYY-MM-DD bez przypisywania strefy.

    ```use-case
    Odczytaj datę cywilną

    [Usuń otaczające białe znaki z wejścia]
    <wejście nie jest kompletną istniejącą datą YYYY-MM-DD>
      (END Error (Invalid_date oryginalny_argument))
    <_>
      (END Ok date bez strefy)
    ``` *)
val date_of_ymd : string -> (date, error) result
