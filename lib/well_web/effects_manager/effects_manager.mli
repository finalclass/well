(** EffectsManager — wykonanie asynchronicznych efektów wychodzących.

    Manager odpowiedzialny za interpretację komend (Cmd) odbieranych
    asynchronicznie z [MessageBus]. Tłumaczy komendy na efekty w świecie
    zewnętrznym (emit, Promise, focus, DOM-ops) używając [Bridge],
    a następnie publikuje wynik (msg lub null) z powrotem na [MessageBus]. *)

(* Envelope lokalny EffectsManagera (zasada separacji typów — każda usługa ma
   własny; MessageBus ma swój, ComponentAccess swój). *)
type 'a envelope

(** RunEffect — wykonanie komendy i publikacja rezultatu.

    ```use-case
    (START)
    [Odbierz komendę (envelope) z MessageBus]
    [Zinterpretuj komendę (Cmd) używając Bridge]
    <Komenda powoduje wysłanie wiadomości>
      [Wyślij wiadomość asynchronicznie na MessageBus]
    <_>
      (STOP)
    (STOP)
    ```
*)
val handle_cmd : instance_id:string -> 'a envelope -> unit
