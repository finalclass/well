(** ComponentAccess — dostęp do zasobu ComponentDefinition.

    Ukrywa definicje zarejestrowanych typów komponentów oraz mapowania
    instancji (instance_id ↔ DOM element ↔ definicja). Pozwala LoopManagerowi
    zlecać wykonanie [init]/[update]/[view] na module komponentu bez
    znajomości jego typów. [instance] jest typem wewnętrznym — publiczne API
    operuje wyłącznie na stringowym identyfikatorze instancji (instance_id).

    Stan instancji żyje w StateAccess (ComponentAccess nie przechowuje stanu).

    Definiuje współdzielone typy: [COMPONENT] (kontrakt modułu komponentu),
    [Html] (jako [Vdom], z [Html.node]/[Html.vdom]), [Props.t], [Cmd.t],
    [emits], re-eksportowane przez Clienta. *)

(* ── Współdzielone typy (re-eksportowane w Client) ── *)

(** Typ węzła virtual DOM. Aliased to [Html]: jeden typ vdom dla backendu
    (serializacja do stringa) i frontendu (renderowanie do live DOM).
    Generyczny nad ['msg] — handlery niosą msg komponentu; na backendzie
    zawsze [unit]. D16. *)
module Vdom = Html

(** Deklaratywne, typowane wejścia komponentu (D18). *)
module Props : sig
  type 'msg decl
  type 'msg t = 'msg decl list
  val int    : string -> on:(int    -> 'msg) -> ?default:int    -> unit -> 'msg decl
  val float  : string -> on:(float  -> 'msg) -> ?default:float  -> unit -> 'msg decl
  val bool   : string -> on:(bool   -> 'msg) -> ?default:bool   -> unit -> 'msg decl
  val string : string -> on:(string -> 'msg) -> ?default:string -> unit -> 'msg decl
  val list   : string -> eq:('a -> 'a -> bool) -> on:('a list -> 'msg) -> 'msg decl
  val of_eq  : string -> eq:('a -> 'a -> bool) -> on:('a      -> 'msg) -> 'msg decl
end

(** Komenda — efekt wychodzący z komponentu (D18). *)
module Cmd : sig
  type ('msg, 'emits) t
  val none   : ('msg, 'emits) t
  val msg    : 'msg -> ('msg, 'emits) t
  val emit   : 'emits -> ('msg, 'emits) t
  val focus  : string -> ('msg, 'emits) t
  val is_none : ('msg, 'emits) t -> bool
end

(** Deklarowane wyjścia komponentu (typowany wariant, D18). *)
type emits

(** Typy transportowe koperty — abstrakcyjne. Strukturę stanu/wiadomości/
    komendy komponentu zna tylko jego moduł; LoopManager operuje na nich
    polimorficznie przez kopertę. *)
type state
type msg
type cmd

val is_cmd_none : cmd -> bool
(** Sprawdź czy komenda jest none (LoopManager używa do decyzji o publikacji). *)

(** Kontrakt modułu komponentu (D18). Moduł first-class, re-eksportowany
    przez Client jako [Well_web.COMPONENT]. *)
module type COMPONENT = sig
  type state
  (** Stan komponentu. Musi być OCaml-record z [@@deriving js] — runtime
      konwertuje do JS-value za darmo (dla persystencji/historii, gdy
      włączone). *)

  type msg
  (** Wewnętrzne wiadomości komponentu. *)

  type emits
  (** Deklarowane wyjścia (typowany wariant). *)

  val props  : msg Props.t
  (** Deklaratywne, typowane wejścia. *)

  val init   : dispatch:(msg -> unit) -> state * (msg, emits) Cmd.t
  (** Inicjalizacja stanu początkowego + ewentualna komenda. *)

  val update : state -> msg -> state * (msg, emits) Cmd.t
  (** Czysta funkcja: (stan, wiadomość) → (nowy stan, komenda). *)

  val view   : state -> (msg -> unit) -> 'a Html.node -> msg Html.node
  (** Renderowanie stanu do vdom. Trzeci argument = projected children
      (pochodzące z komponentu-rodzica, mające własny typ msg — polimorficzne).
      Zwracany vdom niesie msg tego komponentu (handlery wołają dispatch). *)
end

(* ── Envelope (typ lokalny ComponentAccess, zgodnie z separacją typów) ── *)

type 'a envelope
(** Koperta niesie payload (state/msg/cmd/vdom) dla konkretnej instancji.
    Konstrukcja wewnętrzna — klienci dostają koperty z metod Accessa. *)

(* ── Rejestracja typu i lifecycle instancji ── *)

(** RegisterType — zarejestruj definicję typu komponentu.

    ```use-case
    (START)
    [Odbierz moduł komponentu i konfigurację]
    [Zapisz definicję w zasobie]
    (STOP)
    ```
*)
val register_type :
  module_:(module COMPONENT) ->
  tag_name:string ->
  ?shadow_dom:bool ->
  unit -> unit

(** CreateInstance — stwórz instancję zarejestrowanego typu.
    Zwraca instance_id (string).

    ```use-case
    (START)
    [Odszukaj definicję typu po tag_name]
    [Wygeneruj nowy identyfikator instancji]
    [Powiąż element DOM z instancją]
    [Zwróć instance_id]
    (STOP)
    ```
*)
val create_instance : tag_name:string -> dom_element:Bridge.element -> string

(** DestroyInstance — usuń instancję przy unmount.

    ```use-case
    (START)
    [Odszukaj instancję po instance_id]
    [Usuń powiązanie z zasobu]
    (STOP)
    ```
*)
val destroy_instance : instance_id:string -> unit

(** DomElement — zwróć element DOM powiązany z instancją (host renderowania).

    ```use-case
    (START)
    [Odszukaj instancję po instance_id]
    [Zwróć powiązany element DOM]
    (STOP)
    ```
*)
val dom_element : instance_id:string -> Bridge.element

(** State_key — zwróć klucz stanu instancji (do StateAccess). *)
val state_key : instance_id:string -> unit ref

(* ── Wykonanie operacji na module komponentu ── *)

(** InitState — wykonaj init na module komponentu, zwróć stan początkowy.
    Stan początkowy jest przekazywany do StateAccess przez LoopManagera
    (ComponentAccess nie przechowuje stanu).

    ```use-case
    (START)
    [Odszukaj instancję po instance_id]
    [Zleć init na module komponentu]
    [Zwróć instance_id ze stanem początkowym]
    (STOP)
    ```
*)
val init_state : instance_id:string -> state envelope

(** UpdateState — wykonaj update na module komponentu.
    State jest pobierany z StateAccess przez LoopManagera i przekazywany
    w kopercie. ComponentAccess zwraca nowy stan (LoopManager woła
    StateAccess.persist) oraz komendę.

    ```use-case
    (START)
    [Odszukaj instancję po instance_id]
    [Zleć update(state, msg) na module komponentu]
    [Zwróć instance_id z nowym stanem i komendą]
    (STOP)
    ```
*)
val update_state :
  instance_id:string -> state envelope -> msg envelope -> (state * cmd) envelope

(** RenderView — wykonaj view na module komponentu, zwróć vdom.

    ```use-case
    (START)
    [Odszukaj instancję po instance_id]
    [Zleć view(state) na module komponentu]
    [Zwróć instance_id z vdom]
    (STOP)
    ```
*)
val render_view : instance_id:string -> state envelope -> 'msg Html.node envelope
