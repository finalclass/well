(** EffectsManager — interpretacja komend (Cmd) z MessageBus.

    Subskrybent topicu ["cmd"]. Tłumaczy komendy na efekty zewnętrzne
    (emit CustomEvent, focus, perform/async dispatch) przez Bridge /
    MessageBus. Wynikowe msg wracają na topic ["msg"]. *)

type 'a envelope

(** RunEffect — wykonanie komendy.

    ```use-case
    (START)
    [Odbierz komendę (envelope) z MessageBus]
    [Zinterpretuj Cmd (none/msg/emit/emit_dom/focus/batch/perform)]
    <msg lub perform→dispatch>
      [Opublikuj na topic "msg"]
    <emit / emit_dom>
      [CustomEvent na hoście DOM]
    <focus>
      [rAF → querySelector → focus]
    (STOP)
    ```
*)
val handle_cmd : instance_id:string -> 'a envelope -> unit
