(** Rendering — rola Clienta: renderuje vdom → DOM przez Bridge.

    Subskrybuje topic "vdom" na [MessageBus]. Dla każdej koperty: buduje
    (przy pierwszym vdom instancji) lub aktualizuje mirror-tree ([ctrl]),
    który trzyma węzeł DOM, źródłowy vdom oraz dzieci. Vdom na Busie jest
    egzystencjalny (TransportAny); Rendering traktuje go jako
    [Vdom.t] przez konwersję [Obj] (jak LoopManager/ComponentAccess).

    Algorytm diff jest pozycyjny (children matchowane po indeksie, bez
    keying) — zapożyczony, uproszczony wariant LexiFi/ocaml-vdom.
    Keyed-diff pojawi się, gdy [Vdom.t] dostanie pole [key]. *)

(** Mirror-tree: korekspodobny węzeł DOM + jego źródłowy vdom + dzieci
    ctrl + funkcje odpięcia listenerów. Wewnętrzny; Rendering trzyma
    [Hashtbl] instance_id → root ctrl. *)
type ctrl

(** Blit — początkowe przełożenie vdom → DOM przez Bridge. Tworzy węzeł,
    ustawia attrs, wiesza listenery, blit'uje dzieci rekursywnie.

    ```use-case
    (START)
    [Odbierz vdom]
    <Węzeł tekstowy>
      [Utwórz text-node przez Bridge]
    <Węzeł elementu>
      [Utwórz element przez Bridge]
      [Ustaw attrs]
      [Dodaj listenery]
      [Blit dzieci rekursywnie]
    [Zwróć ctrl]
    (STOP)
    ```
*)
val blit : 'msg Component_access.Vdom.t -> ctrl

(** Sync — załatcz istniejący ctrl nowym vdom (pozycyjny diff attrs,
    handlers, text, children). Reaguje na kolejny vdom z MessageBus.

    ```use-case
    (START)
    [Odbierz ctrl i nowy vdom]
    <Zmiana text>
      [Ustaw nowy text przez Bridge]
    <Zmiana attrs>
      [Posortowane-merge: dodaj/zmień/usuń attrs]
    <Zmiana handlers>
      [Odpiecz stare, przepiecz nowe listenery]
    <Dzieci>
      [Pozycyjny diff: sync wspólnych, usuń nadmiarowe, blit nowe,
       dołącz w odpowiedniej kolejności]
    (STOP)
    ```
*)
val sync : ctrl -> 'msg Component_access.Vdom.t -> unit

(** Init — zapisz się na topic "vdom" na MessageBus (raz, lazy). Dla każdej
    koperty: znajdz root ctrl w wewnętrznej tabeli (lub blit nowy pod host
    z ComponentAccess) i wywołaj [sync]. Idempotentna. *)
val init : unit -> unit
