(** StateAccess — dostęp do zasobu ComponentState (per-instancja).

    Centralne miejsce do zapisu stanu wszystkich instancji komponentów.
    Generyczny key-value store: kluczem jest referencja do instancji,
    wartością dowolny stan. Nie jest instancjonowany per typ komponentu
    — jedno współdzielone miejsce do zapisu. *)

(** LoadState — wczytaj stan instancji komponentu.

    ```use-case
    (START)
    [Odszukaj instancję]
    [Wczytaj stan z zasobu (RAM)]
    (STOP)
    ```
*)
val load : 'ref -> 'state

(** PersistState — zapisz nowy stan instancji komponentu.

    ```use-case
    (START)
    [Odszukaj instancję]
    [Zapisz stan w zasobie (RAM)]
    (STOP)
    ```
*)
val persist : 'ref -> 'state -> unit

(** DestroyState — zwolnij stan instancji przy unmount.

    ```use-case
    (START)
    [Odszukaj instancję]
    [Usuń stan z zasobu]
    (STOP)
    ```
*)
val destroy : 'ref -> unit
