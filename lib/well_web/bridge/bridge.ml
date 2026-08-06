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

let js_escape_single_quoted (s : string) : string =
  let buf = Buffer.create (String.length s + 8) in
  String.iter
    (fun c ->
      match c with
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\'' -> Buffer.add_string buf "\\'"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let register_element
    ~(tag_name : string)
    ~(on_connect : element -> unit)
    ~(on_disconnect : element -> unit)
    ?(observed_attributes : string list = [])
    ?on_attribute_change
    ?(property_names : string list = [])
    ?on_property_set
    (() : unit)
    : unit =
  let connect_name = "__bridge_on_connect_" ^ tag_name in
  let disconnect_name = "__bridge_on_disconnect_" ^ tag_name in
  let attr_change_name = "__bridge_on_attr_" ^ tag_name in
  let prop_set_name = "__bridge_on_prop_" ^ tag_name in
  Js.Unsafe.set window (Js.string connect_name)
    (Js.Unsafe.inject (Js.wrap_callback on_connect));
  Js.Unsafe.set window (Js.string disconnect_name)
    (Js.Unsafe.inject (Js.wrap_callback on_disconnect));
  (match on_attribute_change with
   | None -> ()
   | Some f ->
     let cb
         (el : element)
         (name : Js.js_string Js.t)
         (old_v : Js.js_string Js.t Js.opt)
         (new_v : Js.js_string Js.t Js.opt)
         : unit =
       let old_value =
         match Js.Opt.to_option old_v with
         | None -> None
         | Some s -> Some (Js.to_string s)
       in
       let new_value =
         match Js.Opt.to_option new_v with
         | None -> None
         | Some s -> Some (Js.to_string s)
       in
       f el ~name:(Js.to_string name) ~old_value ~new_value
     in
     Js.Unsafe.set window (Js.string attr_change_name)
       (Js.Unsafe.inject (Js.wrap_callback cb)));
  (match on_property_set with
   | None -> ()
   | Some f ->
     let cb (el : element) (name : Js.js_string Js.t) (value : value) : unit =
       f el ~name:(Js.to_string name) ~value
     in
     Js.Unsafe.set window (Js.string prop_set_name)
       (Js.Unsafe.inject (Js.wrap_callback cb)));
  let observed_js =
    observed_attributes
    |> List.map (fun n -> "'" ^ js_escape_single_quoted n ^ "'")
    |> String.concat ","
  in
  let attr_cb_body =
    match on_attribute_change with
    | None -> ""
    | Some _ ->
      " attributeChangedCallback(name, oldValue, newValue) {" ^
      " window['" ^ attr_change_name ^ "'](this, name, oldValue, newValue);" ^
      " }"
  in
  let observed_static =
    match observed_attributes, on_attribute_change with
    | [], _ | _, None -> ""
    | _, Some _ ->
      " static get observedAttributes() { return [" ^ observed_js ^ "]; }"
  in
  let prop_install =
    match property_names, on_property_set with
    | [], _ | _, None -> ""
    | names, Some _ ->
      names
      |> List.map (fun name ->
          let n = js_escape_single_quoted name in
          " Object.defineProperty(C.prototype, '" ^ n ^ "', {" ^
          " configurable: true, enumerable: true," ^
          " get: function() { return this['__well_prop_" ^ n ^ "']; }," ^
          " set: function(v) {" ^
          "  this['__well_prop_" ^ n ^ "'] = v;" ^
          "  window['" ^ prop_set_name ^ "'](this, '" ^ n ^ "', v);" ^
          " }" ^
          " });")
      |> String.concat ""
  in
  let code =
    "(() => {" ^
    " const C = class extends HTMLElement {" ^
    observed_static ^
    " connectedCallback() { window['" ^ connect_name ^ "'](this); }" ^
    " disconnectedCallback() { window['" ^ disconnect_name ^ "'](this); }" ^
    attr_cb_body ^
    " };" ^
    prop_install ^
    " customElements.define('" ^ js_escape_single_quoted tag_name ^ "', C);" ^
    "})();"
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

let get_attribute (el : element) ~(name : string) : string option =
  let raw =
    Js.Unsafe.meth_call el "getAttribute"
      [| Js.Unsafe.inject (Js.string name) |]
  in
  match Js.Opt.to_option (Obj.magic raw : Js.js_string Js.t Js.opt) with
  | None -> None
  | Some s -> Some (Js.to_string s)

let has_attribute (el : element) ~(name : string) : bool =
  Js.to_bool
    (Js.Unsafe.meth_call el "hasAttribute"
       [| Js.Unsafe.inject (Js.string name) |])

let bool_idl_name (attr : string) : string option =
  match attr with
  | "disabled" -> Some "disabled"
  | "checked" -> Some "checked"
  | "selected" -> Some "selected"
  | "hidden" -> Some "hidden"
  | "readonly" -> Some "readOnly"
  | "required" -> Some "required"
  | "multiple" -> Some "multiple"
  | "autofocus" -> Some "autofocus"
  | "autoplay" -> Some "autoplay"
  | "controls" -> Some "controls"
  | "loop" -> Some "loop"
  | "muted" -> Some "muted"
  | "default" -> Some "default"
  | "open" -> Some "open"
  | "reversed" -> Some "reversed"
  | "ismap" -> Some "isMap"
  | "novalidate" -> Some "noValidate"
  | "formnovalidate" -> Some "formNoValidate"
  | "allowfullscreen" -> Some "allowFullscreen"
  | "async" -> Some "async"
  | "defer" -> Some "defer"
  | "draggable" -> Some "draggable"
  | "spellcheck" -> Some "spellcheck"
  | _ -> None

let set_bool_attribute (el : element) ~(name : string) ~(enabled : bool) : unit =
  if enabled then begin
    let _ : Js.Unsafe.any =
      Js.Unsafe.meth_call el "setAttribute"
        [| Js.Unsafe.inject (Js.string name); Js.Unsafe.inject (Js.string "") |]
    in
    ()
  end else
    remove_attribute el ~name;
  match bool_idl_name name with
  | None -> ()
  | Some idl ->
    try
      Js.Unsafe.set el (Js.string idl) (Js.bool enabled)
    with _ -> ()

let get_js_property (el : element) ~(name : string) : value option =
  let v = Js.Unsafe.get el (Js.string name) in
  if Js.typeof v = Js.string "undefined" then None else Some v

let set_js_property (el : element) ~(name : string) ~(value : value) : unit =
  Js.Unsafe.set el (Js.string name) value

let assign_js_property (el : element) ~(name : string) ~(value : value) : unit =
  let _ : Js.Unsafe.any =
    Js.Unsafe.fun_call
      (Js.Unsafe.js_expr
         "function (el, name, value) { el[name] = value; }")
      [| Js.Unsafe.inject el;
         Js.Unsafe.inject (Js.string name);
         Js.Unsafe.inject value |]
  in
  ()

let take_own_js_property (el : element) ~(name : string) : value option =
  let raw : Js.Unsafe.any =
    Js.Unsafe.fun_call
      (Js.Unsafe.js_expr
         {|function (el, name) {
            if (!Object.prototype.hasOwnProperty.call(el, name)) return undefined;
            var desc = Object.getOwnPropertyDescriptor(el, name);
            if (!desc || !('value' in desc)) return undefined;
            var v = desc.value;
            try { delete el[name]; } catch (e) {}
            return v;
          }|})
      [| Js.Unsafe.inject el; Js.Unsafe.inject (Js.string name) |]
  in
  if Js.typeof raw = Js.string "undefined" then None else Some raw

let set_well_prop_storage (el : element) ~(name : string) ~(value : value) : unit =
  let key = "__well_prop_" ^ name in
  Js.Unsafe.set el (Js.string key) value

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

let event_prevent_default (ev : event) : unit =
  let _ : Js.Unsafe.any =
    Js.Unsafe.meth_call ev "preventDefault" [||]
  in
  ()

let event_form_data (ev : event) : (string * string) list =
  try
    let raw : Js.Unsafe.any =
      Js.Unsafe.fun_call
        (Js.Unsafe.js_expr
           {|function (ev) {
              var t = ev && ev.target;
              if (!t || typeof FormData === "undefined") return [];
              var fd;
              try { fd = new FormData(t); } catch (e) { return []; }
              var out = [];
              fd.forEach(function (v, k) {
                if (typeof v === "string") out.push([k, v]);
              });
              return out;
            }|})
        [| Js.Unsafe.inject ev |]
    in
    let len =
      int_of_float
        (Js.to_float (Js.Unsafe.coerce (Js.Unsafe.get raw "length") : Js.number Js.t))
    in
    let rec go i acc =
      if i < 0 then acc
      else
        let pair = Js.Unsafe.get raw i in
        let k =
          Js.to_string (Js.Unsafe.coerce (Js.Unsafe.get pair 0) : Js.js_string Js.t)
        in
        let v =
          Js.to_string (Js.Unsafe.coerce (Js.Unsafe.get pair 1) : Js.js_string Js.t)
        in
        go (i - 1) ((k, v) :: acc)
    in
    go (len - 1) []
  with _ -> []

let query_selector_in (el : element) (selector : string) : element option =
  let result =
    Js.Unsafe.meth_call el "querySelector"
      [| Js.Unsafe.inject (Js.string selector) |]
  in
  Js.Opt.to_option (Obj.magic result : element Js.opt)

let focus (el : element) : unit =
  let _ : Js.Unsafe.any =
    Js.Unsafe.meth_call el "focus" [||]
  in
  ()

