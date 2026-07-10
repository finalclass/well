open Js_of_ocaml

type element = Js.Unsafe.any

type value = Js.Unsafe.any

type event = Js.Unsafe.any

type 'a fn = Obj.t

type 'a promise = Js.Unsafe.any

let inject (x : 'a) : value = Js.Unsafe.inject x

let fn1 (f : 'a -> 'b) : ('a -> 'b) fn = Obj.repr (Js.wrap_callback f)

let get_path (src : Js.Unsafe.any) (path : string) : Js.Unsafe.any =
  List.fold_left
    (fun acc seg -> Js.Unsafe.get acc (Js.string seg))
    src
    (String.split_on_char '.' path)

let get_string (src : value) (path : string) : string =
  Js.to_string (Js.Unsafe.coerce (get_path src path) : Js.js_string Js.t)

let get_int (src : value) (path : string) : int =
  int_of_float (Js.to_float (Js.Unsafe.coerce (get_path src path) : Js.number Js.t))

let get_float (src : value) (path : string) : float =
  Js.to_float (Js.Unsafe.coerce (get_path src path) : Js.number Js.t)

let get_bool (src : value) (path : string) : bool =
  Js.to_bool (Js.Unsafe.coerce (get_path src path) : bool Js.t)

let get_value (src : value) (path : string) : value =
  get_path src path

let window : < .. > Js.t = Js.Unsafe.(global)

class type document_t = object
  method querySelector : Js.js_string Js.t -> element Js.opt Js.meth
end

let document : document_t Js.t =
  Js.Unsafe.coerce (Js.Unsafe.get window (Js.string "document"))

let register_element
    ~(tag_name : string)
    ~(on_connect : element -> unit)
    ~(on_disconnect : element -> unit)
    (() : unit)
    : unit =
  let on_connect_cb = on_connect in
  let on_disconnect_cb = on_disconnect in
  let connect_name = "__bridge_on_connect_" ^ tag_name in
  let disconnect_name = "__bridge_on_disconnect_" ^ tag_name in
  Js.Unsafe.set window (Js.string connect_name)
    (Js.Unsafe.inject (Js.wrap_callback on_connect_cb));
  Js.Unsafe.set window (Js.string disconnect_name)
    (Js.Unsafe.inject (Js.wrap_callback on_disconnect_cb));
  let code =
    "customElements.define('" ^ tag_name ^
    "', class extends HTMLElement {" ^
    " connectedCallback() { window['" ^ connect_name ^ "'](this); }" ^
    " disconnectedCallback() { window['" ^ disconnect_name ^ "'](this); }" ^
    " });"
  in
  Js.Unsafe.eval_string code

let find_element ~(selector : string) : element option =
  Js.Opt.to_option (document##querySelector (Js.string selector))

let set_text (el : element) (text : string) : unit =
  let node : < textContent : Js.js_string Js.t Js.prop > Js.t =
    Js.Unsafe.coerce el
  in
  node##.textContent := Js.string text

let dispatch_event
    (el : element)
    ~(name : string)
    ~(payload : value)
    : unit =
  let opts =
    Js.Unsafe.obj [| "detail", payload |]
  in
  let ctor = Js.Unsafe.(get window (Js.string "CustomEvent")) in
  let ev =
    Js.Unsafe.new_obj ctor
      [| Js.Unsafe.inject (Js.string name); Js.Unsafe.inject opts |]
  in
  let _ : bool =
    Js.Unsafe.meth_call el "dispatchEvent" [| Js.Unsafe.inject ev |]
  in
  ()

let request_animation_frame (cb : (float -> unit) fn) : unit =
  let win : < requestAnimationFrame : (float -> unit) Js.callback -> int Js.meth > Js.t =
    Js.Unsafe.coerce window
  in
  let _ : int = win##requestAnimationFrame (Obj.obj cb : (float -> unit) Js.callback) in
  ()

let ws_engine () : Js.Unsafe.any =
  Js.Unsafe.get window (Js.string "__well_ws")

let subscribe_channel
    ~(channel : string)
    (cb : (value -> unit) fn)
    : string =
  let id =
    Js.Unsafe.meth_call (ws_engine ()) "subscribe"
      [| Js.Unsafe.inject (Js.string channel);
         Js.Unsafe.inject (Obj.obj cb : (_, Js.Unsafe.any -> unit) Js.meth_callback) |]
  in
  let s : Js.js_string Js.t = Js.Unsafe.coerce id in
  Js.to_string s

let push_channel ~(channel : string) ~(payload : value) : unit =
  let _ : Js.Unsafe.any =
    Js.Unsafe.meth_call (ws_engine ()) "push"
      [| Js.Unsafe.inject (Js.string channel); payload |]
  in
  ()

let unsubscribe_channel ~(subscription_id : string) : unit =
  let _ : Js.Unsafe.any =
    Js.Unsafe.meth_call (ws_engine ()) "unsubscribe"
      [| Js.Unsafe.inject (Js.string subscription_id) |]
  in
  ()

let create_element (tag_name : string) : element =
  Js.Unsafe.meth_call document "createElement"
    [| Js.Unsafe.inject (Js.string tag_name) |]

let create_text_node (text : string) : element =
  Js.Unsafe.meth_call document "createTextNode"
    [| Js.Unsafe.inject (Js.string text) |]

let append_child ~(parent : element) ~(child : element) : unit =
  let _ : Js.Unsafe.any =
    Js.Unsafe.meth_call parent "appendChild" [| Js.Unsafe.inject child |]
  in
  ()

let insert_before
    ~(parent : element)
    ~(child : element)
    ~(ref_ : element option)
    : unit =
  let ref_node : Js.Unsafe.any =
    match ref_ with
    | Some r -> Js.Unsafe.inject r
    | None -> Js.Unsafe.inject (Js.null : element Js.opt)
  in
  let _ : Js.Unsafe.any =
    Js.Unsafe.meth_call parent "insertBefore"
      [| Js.Unsafe.inject child; ref_node |]
  in
  ()

let remove_child ~(parent : element) ~(child : element) : unit =
  let _ : Js.Unsafe.any =
    Js.Unsafe.meth_call parent "removeChild" [| Js.Unsafe.inject child |]
  in
  ()

let replace_child ~(parent : element) ~(old : element) ~(new_ : element) : unit =
  let _ : Js.Unsafe.any =
    Js.Unsafe.meth_call parent "replaceChild"
      [| Js.Unsafe.inject new_; Js.Unsafe.inject old |]
  in
  ()

let set_attribute (el : element) ~(name : string) ~(value : string) : unit =
  let _ : Js.Unsafe.any =
    Js.Unsafe.meth_call el "setAttribute"
      [| Js.Unsafe.inject (Js.string name); Js.Unsafe.inject (Js.string value) |]
  in
  ()

let remove_attribute (el : element) ~(name : string) : unit =
  let _ : Js.Unsafe.any =
    Js.Unsafe.meth_call el "removeAttribute"
      [| Js.Unsafe.inject (Js.string name) |]
  in
  ()

let add_event_listener
    (el : element)
    ~(event_name : string)
    (cb : (event -> unit) fn)
    : (unit -> unit) =
  let wrapped : (< >, event -> unit) Js.meth_callback = Obj.obj cb in
  let cb_ref = ref wrapped in
  let _ : Js.Unsafe.any =
    Js.Unsafe.meth_call el "addEventListener"
      [| Js.Unsafe.inject (Js.string event_name); Js.Unsafe.inject !cb_ref |]
  in
  let unsubscribe () : unit =
    let _ : Js.Unsafe.any =
      Js.Unsafe.meth_call el "removeEventListener"
        [| Js.Unsafe.inject (Js.string event_name); Js.Unsafe.inject !cb_ref |]
    in
    ()
  in
  unsubscribe

let get_parent (el : element) : element option =
  let node = Js.Unsafe.get el (Js.string "parentNode") in
  Js.Opt.to_option (Obj.magic node : element Js.opt)

let get_input_value (el : element) : string =
  let v = Js.Unsafe.get el (Js.string "value") in
  Js.to_string (Js.Unsafe.coerce v : Js.js_string Js.t)

let set_value (el : element) (value : string) : unit =
  Js.Unsafe.set el (Js.string "value") (Js.Unsafe.inject (Js.string value))

let event_key (ev : event) : string =
  get_string ev "key"

let event_value (ev : event) : string =
  get_string ev "target.value"
