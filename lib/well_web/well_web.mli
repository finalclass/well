(** Well.Web — fasada dla aplikacji, jedyny publiczny entry-point do runtime.

    Wewnętrznie organizuje 3 role jako sub-moduły:
    - [Registration] — rejestruje typ komponentu, podpina lifecycle callbacki.
    - [Inputs] — nasłuch DOM eventów, atrybutów, lifecycle bridging
      (create/destroy instancji przy connect/disconnect), subscriptions.
    - [Rendering] — subscribe MessageBus, renderuje vdom → DOM przez Bridge.
    - [Channels] — push z WS silnika ([well.js], D14).

    Ukrywa przed aplikacją: LoopManager, EffectsManager, Accessy, MessageBus,
    Bridge — ich wzajemne powiązania i kolejkowanie.

    Re-eksportuje z ComponentAccess wszystko, czego aplikacja potrzebuje:
    [COMPONENT], [Html] (jako [Vdom], z [Html.node]/[Html.vdom]),
    [Props.t], [Cmd.t], [emits]. *)

module type COMPONENT = Component_access.COMPONENT
(** Kontrakt modułu komponentu (init/update/view/props/emits). *)

module Vdom = Html
(** Typ węzła virtual DOM (generyczny nad msg). Aliased to [Html]:
    ujednolicony typ vdom dla backendu i frontendu. *)

module Props = Component_access.Props
(** Deklaratywne, typowane wejścia komponentu.

    Skalary ([int]/[float]/[bool]/[string]) idą z atrybutu HTML albo JS
    property. [list]/[of_eq] — tylko property. [attr_or_prop] — atrybut
    string ([of_string]) albo JS value ([of_js], bez stringify); puste /
    błąd parse = no-op. *)

module Cmd = Component_access.Cmd
(** Komenda (efekt wychodzący z komponentu: emit, Promise, focus, DOM-ops). *)

type emits = Component_access.emits
(** Deklarowane wyjścia komponentu (wariant). *)

(** RegisterComponent — zarejestruj typ komponentu w runtime.
    To jest jedyny punkt wejścia aplikacji.

    ```use-case
    (START)
    [Odbierz moduł komponentu i konfigurację]
    [Zapisz definicję w ComponentAccess]
    [Zarejestruj custom element w Bridge z lifecycle callbackami]
    [Podłącz Inputs: nasłuch eventów, lifecycle bridging]
    (STOP)
    ```
*)
val component :
  module_:(module COMPONENT) ->
  tag_name:string ->
  ?shadow_dom:bool ->
  unit -> unit
