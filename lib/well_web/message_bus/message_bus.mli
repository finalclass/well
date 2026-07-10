(** MessageBus — infrastruktura komunikacji asynchronicznej (Pub/Sub) między
    warstwami (Client, Manager). Wiadomości są kolejkowane na wejściu i
    wyjściu. Subskrybenci otrzymują je asynchronicznie, rozróżniane po topic.

    Reguły (z ARCH.md):
    - Tylko Client i Manager mogą publikować i odbierać wiadomości.
    - Zapytania są kolejkowane (na wejściu do Bus i na wyjściu).

    Topic rozróżnia rodzaj komunikatu (msg, cmd, vdom). Subskrybent
    dostaje tylko wiadomości z topic'u, na który się zapisał.

    Definiuje typ transportowy ['a envelope] — koperta niesie identyfikator
    instancji (string) oraz payload dowolnego typu. Typ jest importowany
    przez inne usługi (Client, Manager), ale one nie powinny go zwracać
    w swoich sygnaturach (zasada separacji typów — każda warstwa ma własne). *)

type 'a envelope
(** Koperta transportowa: (instance_id, payload). Ukrywa strukturę;
    konstruowana przez [create], odczytywana przez [instance_id]/[payload]. *)

val create : instance_id:string -> 'a -> 'a envelope
(** Stwórz kopertę z identyfikatorem instancji i payloadem. *)

val instance_id : 'a envelope -> string
(** Identyfikator instancji z koperty. *)

val payload : 'a envelope -> 'a
(** Payload z koperty. *)

(** Publish — opublikuj wiadomość asynchronicznie na topic.

    ```use-case
    (START)
    [Odbierz topic i kopertę (instance_id, payload)]
    [Zakolejkuj wiadomość na wejściu]
    [Dostarcz asynchronicznie do subskrybentów topic'u]
    (STOP)
    ```
*)
val publish : topic:string -> 'a envelope -> unit

(** Subscribe — zapisz się na wiadomości z topic'u.
    Zwraca identyfikator subskrypcji (string, do późniejszego odpisu).

    ```use-case
    (START)
    [Odbierz topic i callback]
    [Zarejestruj subskrypcję]
    [Zwróć subscription_id]
    (STOP)
    ```
*)
val subscribe : topic:string -> ('a envelope -> unit) -> string

(** Unsubscribe — odpisz się z topic'u.

    ```use-case
    (START)
    [Odszukaj subskrypcję po subscription_id]
    [Usuń subskrypcję]
    (STOP)
    ```
*)
val unsubscribe : subscription_id:string -> unit
