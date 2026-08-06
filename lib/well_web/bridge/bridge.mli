(** Bridge — most między runtime'em OCaml a światem zewnętrznym JS-runtime/DOM.

    Tłumaczy żądania runtime (tworzenie elementów DOM, dispatch eventów,
    requestAnimationFrame, dostęp do globali) na wywołania JS przez FFI jsoo.

    Definiuje abstrakcyjne typy reprezentujące byty JS-runtime: [element]
    (węzeł DOM), [value] (dowolna JS-value), [event] (CustomEvent/Event),
    [callback] (OCaml function dla JS), [promise] (JS Promise).

    Lista operacji rozrasta się wraz z potrzebami runtime — poniższy zestaw
    to atomic verbs udowodnione w spajku S7. *)

type element
(** Węzeł DOM (custom element lub dziecko). *)

type value
(** Dowolna wartość JS (obiekt, tablica, primitive). Służy m.in. do
    persystencji stanu jako JS-value (V-state). *)

type event
(** CustomEvent/Event (dla dispatch w górę). *)

type 'a fn
(** OCaml function opakowana dla JS. *)

type 'a promise
(** JS Promise (dla Cmd.then_ i operacji async). *)

(** Konwersja wartości OCaml/JS do [value]. Klienci nie mogą konstruować
    [value] bezpośrednio — muszą użyć tego konstruktora. *)
val inject : 'a -> value

(** Opakuj funkcję unarną (przyjmującą jedną wartość JS) jako [fn]. *)
val fn1 : ('a -> 'b) -> ('a -> 'b) fn

(** GetNested — czytaj zagnieżdżone pole JS-value po ścieżce (kropki jako
    separatory). Np. get_string event "detail.value" czyta
    event.detail.value jako string.

    ```use-case
    (START)
    [Odbierz źródło (value) i ścieżkę]
    [Podziel ścieżkę po '.']
    [Przejdź zagnieżdżone obiekty przez FFI]
    [Zwróć finalną JS-value skonwertowaną na typ OCaml]
    (STOP)
    ```
*)
val get_string : value -> string -> string

val get_int : value -> string -> int

val get_float : value -> string -> float

val get_bool : value -> string -> bool

val get_value : value -> string -> value

(** RegisterElement — zarejestruj custom element w JS.

    ```use-case
    (START)
    [Odbierz tag_name i lifecycle callback]
    [Wywołaj customElements.define przez FFI]
    (STOP)
    ```
*)
val register_element :
  tag_name:string ->
  on_connect:(element -> unit) ->
  on_disconnect:(element -> unit) ->
  ?observed_attributes:string list ->
  ?on_attribute_change:
    (element ->
     name:string ->
     old_value:string option ->
     new_value:string option ->
     unit) ->
  ?property_names:string list ->
  ?on_property_set:(element -> name:string -> value:value -> unit) ->
  unit -> unit
(** Register a custom element. Optional [observed_attributes] wire
    [attributeChangedCallback]; [property_names] install prototype
    getters/setters that notify [on_property_set]. *)

(** FindElement — znajdź element w dokumencie.

    ```use-case
    (START)
    [Odbierz selector]
    [Wywołaj querySelector przez FFI]
    (STOP)
    ```
*)
val find_element : selector:string -> element option

(** SetText — ustaw textContent elementu.

    ```use-case
    (START)
    [Odbierz element i tekst]
    [Ustaw textContent przez FFI]
    (STOP)
    ```
*)
val set_text : element -> string -> unit

(** DispatchEvent — wyślij CustomEvent z elementu w górę.

    ```use-case
    (START)
    [Odbierz element, nazwę zdarzenia i payload]
    [Skonstruuj CustomEvent przez FFI]
    [Wywołaj dispatchEvent na elemencie]
    (STOP)
    ```
*)
val dispatch_event : element -> name:string -> payload:value -> unit

(** RequestAnimationFrame — zaplanuj callback w następnej klatce.

    ```use-case
    (START)
    [Odbierz callback]
    [Wywołaj requestAnimationFrame przez FFI]
    (STOP)
    ```
*)
val request_animation_frame : (float -> unit) fn -> unit

(* ── Channels / WS silnik (well.js, D14) ── *)

(** SubscribeChannel — zapisz się na wiadomości z kanału WS.
    [channels.ml] (Client) używa tego do odbioru push z silnika [well.js].
    Zwraca subscription_id (string).

    ```use-case
    (START)
    [Odbierz nazwę kanału i callback]
    [Zarejestruj subskrypcję w silniku WS przez FFI]
    [Zwróć subscription_id]
    (STOP)
    ```
*)
val subscribe_channel : channel:string -> (value -> unit) fn -> string

(** PushChannel — wyślij wiadomość na kanał WS.

    ```use-case
    (START)
    [Odbierz nazwę kanału i payload]
    [Wyślij przez silnik WS (FFI)]
    (STOP)
    ```
*)
val push_channel : channel:string -> payload:value -> unit

(** UnsubscribeChannel — odpisz się z kanału WS.

    ```use-case
    (START)
    [Odszukaj subskrypcję po subscription_id]
    [Usuń subskrypcję w silniku WS (FFI)]
    (STOP)
    ```
*)
val unsubscribe_channel : subscription_id:string -> unit

(* ── Imperatywne operacje DOM (diff/patch vdom, Rendering Client) ── *)

(** CreateElement — stwórz element DOM o danym tagu.

    ```use-case
    (START)
    [Odbierz tag_name]
    [Wywołaj document.createElement przez FFI]
    [Zwróć nowy element]
    (STOP)
    ```
*)
val create_element : string -> element

(** CreateTextNode — stwórz węzeł tekstowy.

    ```use-case
    (START)
    [Odbierz tekst]
    [Wywołaj document.createTextNode przez FFI]
    [Zwróć węzeł tekstowy]
    (STOP)
    ```
*)
val create_text_node : string -> element

(** AppendChild — dołącz dziecko do rodzica.

    ```use-case
    (START)
    [Odbierz parent i child]
    [Wywołaj parent.appendChild przez FFI]
    (STOP)
    ```
*)
val append_child : parent:element -> child:element -> unit

(** InsertBefore — wstaw dziecko przed referencyjnym (None = na końcu).

    ```use-case
    (START)
    [Odbierz parent, child i ref_]
    [Jeśli ref_ = None, użyj null]
    [Wywołaj parent.insertBefore przez FFI]
    (STOP)
    ```
*)
val insert_before : parent:element -> child:element -> ref_:element option -> unit

(** RemoveChild — usuń dziecko z rodzica.

    ```use-case
    (START)
    [Odbierz parent i child]
    [Wywołaj parent.removeChild przez FFI]
    (STOP)
    ```
*)
val remove_child : parent:element -> child:element -> unit

(** ReplaceChild — zastąp stare dziecko nowym.

    ```use-case
    (START)
    [Odbierz parent, old i new_]
    [Wywołaj parent.replaceChild przez FFI]
    (STOP)
    ```
*)
val replace_child : parent:element -> old:element -> new_:element -> unit

(** SetAttribute — ustaw atrybut HTML na elemencie.

    ```use-case
    (START)
    [Odbierz element, name i value]
    [Wywołaj element.setAttribute przez FFI]
    (STOP)
    ```
*)
val set_attribute : element -> name:string -> value:string -> unit

(** GetAttribute — read an HTML attribute; [None] if missing. *)
val get_attribute : element -> name:string -> string option

(** HasAttribute — whether the named attribute is present. *)
val has_attribute : element -> name:string -> bool

(** SetBoolAttribute — reflect a boolean HTML attribute and common
    IDL boolean properties ([disabled], [selected], [checked], …).
    When [enabled] is false the attribute is removed and the property
    cleared when present. *)
val set_bool_attribute : element -> name:string -> enabled:bool -> unit

(** GetJsProperty — read a JS data property from an element (own or proto).
    [None] when the value is [undefined]. *)
val get_js_property : element -> name:string -> value option

(** SetJsProperty — write a JS data property on an element. *)
val set_js_property : element -> name:string -> value:value -> unit

(** AssignJsProperty — [el[name] = value] through the prototype setter
    when present (unlike [set_js_property], which may create an own data
    property and shadow accessors). *)
val assign_js_property : element -> name:string -> value:value -> unit

(** TakeOwnJsProperty — if [el] has an own data property [name], return its
    value and delete the own property so prototype accessors are visible.
    [None] when missing or accessor-only. Used on connect to unshadow CE
    property accessors after pre-upgrade assignment. *)
val take_own_js_property : element -> name:string -> value option

(** SetWellPropStorage — write the internal [__well_prop_<name>] slot used
    by CE prototype getters/setters (without invoking the setter notify). *)
val set_well_prop_storage : element -> name:string -> value:value -> unit

(** RemoveAttribute — usuń atrybut HTML z elementu.

    ```use-case
    (START)
    [Odbierz element i name]
    [Wywołaj element.removeAttribute przez FFI]
    (STOP)
    ```
*)
val remove_attribute : element -> name:string -> unit

(** AddEventListener — dodaj listener zdarzenia, zwraca funkcję do odpięcia.

    ```use-case
    (START)
    [Odbierz element, event_name i callback]
    [Zapisz opakowany callback w ref]
    [Wywołaj element.addEventListener przez FFI]
    [Zwróć closure wołające removeEventListener]
    (STOP)
    ```
*)
val add_event_listener :
  element -> event_name:string -> (event -> unit) fn -> (unit -> unit)

(** GetParent — zwróć rodzica elementu (None jeśli bez rodzica).

    ```use-case
    (START)
    [Odbierz element]
    [Czytaj element.parentNode przez FFI]
    [Jeśli null, zwróć None; inaczej Some]
    (STOP)
    ```
*)
val get_parent : element -> element option

(** GetInputValue — czytaj value elementu formularza (input/select).
    Nazwa unika kolizji z istniejącym [get_value] (GetNested).

    ```use-case
    (START)
    [Odbierz element]
    [Czytaj element.value przez FFI]
    [Zwróć jako string]
    (STOP)
    ```
*)
val get_input_value : element -> string

(** SetValue — ustaw value elementu formularza.

    ```use-case
    (START)
    [Odbierz element i value]
    [Ustaw element.value przez FFI]
    (STOP)
    ```
*)
val set_value : element -> string -> unit

(** EventKey — czytaj [event.key] (np. "Enter", "Escape").
    Używane przez Rendering przy interpretacji handlera [On_key].

    ```use-case
    (START)
    [Odbierz zdarzenie DOM]
    [Czytaj event.key przez FFI]
    [Zwróć jako string]
    (STOP)
    ```
*)
val event_key : event -> string

(** EventValue — czytaj [event.target.value] (aktualna wartość elementu
    formularza, który wyemitował zdarzenie). Używane przez Rendering przy
    interpretacji handlera [On_value] ([on_input], [on_change]).

    ```use-case
    (START)
    [Odbierz zdarzenie DOM]
    [Czytaj event.target.value przez FFI (ścieżka zagnieżdżona)]
    [Zwróć jako string]
    (STOP)
    ```
*)
val event_value : event -> string

(** EventPreventDefault — [event.preventDefault()]. *)
val event_prevent_default : event -> unit

(** EventFormData — named string fields from the submit target via
    [FormData(event.target)]. File values omitted. Empty list if target
    is not a form or FormData construction fails.

    ```use-case
    (START)
    [Odbierz zdarzenie DOM (submit)]
    [preventDefault jest osobno — tu tylko odczyt]
    [new FormData(event.target)]
    [Zbierz pary (name, value) dla wpisów string]
    [Zwróć listę (string * string)]
    (STOP)
    ```
*)
val event_form_data : event -> (string * string) list

(** QuerySelectorIn — querySelector scoped to an element (host). *)
val query_selector_in : element -> string -> element option

(** Focus — call element.focus(); missing / non-focusable = no-op at call site. *)
val focus : element -> unit

