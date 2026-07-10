(** LoopManager — pętla TEA (init/update/view) i orkiestracja stanu.

    Manager odpowiedzialny za koordynację cyklu TEA: odbiera asynchroniczne
    wiadomości z [MessageBus], wczytuje obecny stan, zleca [ComponentAccess]
    wykonanie update oraz wygenerowanie view, zapisuje nowy stan w
    [StateAccess], publikuje wyniki (vdom, komendy) z powrotem przez
    [MessageBus]. *)

(* Envelope lokalny LoopManagera (zasada separacji typów — każda usługa ma
   własny; MessageBus ma swój, ComponentAccess swój). *)
type 'a envelope

(** HandleInteraction — reakcja na asynchroniczną wiadomość.

    ```use-case
    (START)
    [Odbierz wiadomość (envelope) z MessageBus]
    [Wczytaj obecny stan z StateAccess]
    [Zleć ComponentAccess wykonanie update(state, msg)]
      | [Zapisz nowy stan w StateAccess]
        [Zleć ComponentAccess wygenerowanie view(state)]
        [Wyślij wiadomość z nowym vdom asynchronicznie]
      | <Jest komenda>
        [Wyślij wiadomość o komendzie asynchronicznie]
    (STOP)
    ```
*)
val handle_msg : instance_id:string -> 'a envelope -> unit
