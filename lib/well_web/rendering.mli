(** Rendering — rola Clienta: renderuje vdom → DOM przez Bridge.

    Subskrybuje topic "vdom" na [MessageBus]. Dla każdej koperty: buduje
    (przy pierwszym vdom instancji) lub aktualizuje mirror-tree ([ctrl]),
    który trzyma węzeł DOM, źródłowy vdom oraz dzieci. Vdom na Busie jest
    egzystencjalny (TransportAny); Rendering traktuje go jako
    [Html.node] przez konwersję [Obj] (jak LoopManager/ComponentAccess).

    Algorytm diff jest pozycyjny (children matchowane po indeksie, bez
    keying) — zapożyczony, uproszczony wariant LexiFi/ocaml-vdom.
    Keyed-diff pojawi się, gdy [Html.vdom] dostanie pole [key]. *)

(** Mirror-tree: korekspodobny węzeł DOM + jego źródłowy vdom + dzieci
    ctrl + funkcje odpięcia listenerów. Wewnętrzny; Rendering trzyma
    [Hashtbl] instance_id → root ctrl. *)
type ctrl

(** Blit — początkowe przełożenie vdom → DOM przez Bridge. Tworzy węzeł,
    ustawia attrs, wiesza listenery, blit'uje dzieci rekursywnie.

    Listenery interpretują wariant [Html.handler]: [Msg] dispatchuje msg
    ignorując event; [On_key]/[On_value] wyciągają [event.key]/
    [event.target.value] przez Bridge i dispatchują wynik; [On_form]
    woła [preventDefault], zbiera [FormData] z targetu submit i
    dispatchuje [f form_data]; [On_event] dostaje cały event jako [Obj.t];
    [Ignore] nie wiesza nic.

    ```use-case
    (START)
    [Odbierz vdom]
    <Węzeł tekstowy>
      [Utwórz text-node przez Bridge]
    <Węzeł elementu>
      [Utwórz element przez Bridge]
      [Ustaw attrs]
      [Dodaj listenery (interpretacja wariantu handlera)]
      [Blit dzieci rekursywnie]
    [Zwróć ctrl]
    (STOP)
    ```
*)
val blit : 'msg Html.node -> ctrl

(** Sync — załatcz istniejący ctrl nowym vdom (pozycyjny diff attrs,
    handlers, text, children). Reaguje na kolejny vdom z MessageBus.

    ```use-case
    (START)
    [Odbierz ctrl i nowy vdom]
    <Zmiana text>
      [Ustaw textContent tylko gdy liść (brak children);
       nigdy nie czyść textContent przy elementach z dziećmi]
    <Zmiana attrs>
      [Posortowane-merge: dodaj/zmień/usuń attrs]
    <Zmiana handlers>
      [Odpiecz stare, przepiecz nowe listenery]
    <Dzieci>
      [Pozycyjny diff: sync wspólnych w miejscu gdy ten sam tag
       (bez re-insert — zachowuje focus/selection), replace przy
       zmianie tagu, usuń nadmiarowe, blit+append nowe]
    (STOP)
    ```
*)
val sync : ctrl -> 'msg Html.vdom -> unit

(** Init — zapisz się na topic "vdom" na MessageBus (raz, lazy). Dla każdej
    koperty: znajdz root ctrl w wewnętrznej tabeli (lub blit nowy pod host
    z ComponentAccess) i wywołaj [sync]. Idempotentna. *)
val init : unit -> unit
