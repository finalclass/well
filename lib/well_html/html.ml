(** HTML generation library with full HTML5 tag coverage and XSS protection.

    The core type is ['msg vdom]: a single DOM representation shared by the
    server (renders to an HTML string) and the frontend TEA runtime (renders
    to live DOM via {!rendering}). The ['msg] parameter carries the component
    message type through [handlers]; on the server it is always [unit] since
    server-rendered nodes never carry handlers. *)

(** Named form fields collected on submit: [(name, value), ...].
    Built from [FormData(event.target)]; file values are omitted (v1).
    Duplicate names appear as separate pairs in DOM order. *)
type form_data = (string * string) list

(** A DOM event handler. Specialized per known event shape so the common case
    ([on_click=Msg] — a bare message value) carries no [Some]/[None]
    boilerplate; only the generic fallback ([On_event]) and the explicit
    no-op ([Ignore]) deal in optionality.

    - [Msg m]: dispatch [m], ignore the event — [on_click], [on_blur],
      [on_focus], [on_dblclick].
    - [On_key f]: read [event.key], dispatch [f key] — [on_keydown],
      [on_keyup], [on_keypress]. Always dispatches.
    - [On_value f]: read [event.target.value], dispatch [f value] —
      [on_input], [on_change]. Always dispatches.
    - [On_form f]: [preventDefault], read named fields from the submit
      target via [FormData], dispatch [f form_data] — [on_submit].
      Always dispatches (empty list when the target is not a form).
    - [On_event f]: the whole event as [Obj.t], optional — generic fallback
      for unknown events ([on_wheel], [on_scroll], ...).
    - [Ignore]: never dispatch.

    Covariant in ['msg]: a handler that carries no message widens to
    [unit handler] on the server, where handlers are never serialized. *)
type +'msg handler =
  | Msg of 'msg
  | On_key of (string -> 'msg)
  | On_value of (string -> 'msg)
  | On_form of (form_data -> 'msg)
  | On_event of (Obj.t -> 'msg option)
  | Ignore

(** A virtual DOM node. Covariant in ['msg]: a ['msg vdom] widens to
    [unit vdom] (the server/response instantiation) wherever handlers are
    absent, which is what lets MLX-produced nodes coerce into {!Well.response}. *)
type +'msg vdom = {
  tag : string;
  attrs : (string * string) list;
  bool_attrs : string list;
  handlers : (string * 'msg handler) list;
  children : 'msg node list;
  text : string option;
  void : bool;
}

(** A wrapped vdom — the value MLX emits and [Well.response] carries. *)
and 'msg node = [ `Html of 'msg vdom ]

(** Escape HTML special characters (ampersand, angle brackets, double quotes). *)
let escape_html s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | '&' -> Buffer.add_string buf "&amp;"
      | '<' -> Buffer.add_string buf "&lt;"
      | '>' -> Buffer.add_string buf "&gt;"
      | '"' -> Buffer.add_string buf "&quot;"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let attrs_to_string attrs =
  let parts =
    List.filter_map
      (fun (k, v) ->
        if v = "" then None
        else Some (Printf.sprintf " %s=\"%s\"" k (escape_html v)))
      attrs
  in
  String.concat "" parts

let bool_attrs_to_string bools =
  if bools = [] then "" else " " ^ String.concat " " bools

(* ── Shared element constructor ───────────────────────────────────── *)

let element (tag : string) ?(attrs : (string * string) list = [])
    ?(bool_attrs : string list = []) ?(handlers : (string * _ handler) list = [])
    ?(children : _ node list = []) ?(text : string = "") () : 'msg node =
  `Html { tag; attrs; bool_attrs; handlers; children; text = Some text; void = false }

let void_element (tag : string) ?(attrs : (string * string) list = [])
    ?(bool_attrs : string list = []) ?(handlers : (string * _ handler) list = [])
    ?(children : _ node list = []) ?(text : string = "") () : 'msg node =
  `Html { tag; attrs; bool_attrs; handlers; children; text = Some text; void = true }

(** Build a normal (closing-tag) element. MLX desugars [<tag ...>] to this. *)
let tag name ?attrs ?bool_attrs ?handlers ?children ?text () =
  element name ?attrs ?bool_attrs ?handlers ?children ?text ()

(** Build a void/self-closing element (e.g. [<input />]). *)
let void_tag name ?attrs ?bool_attrs ?handlers ?children ?text () =
  void_element name ?attrs ?bool_attrs ?handlers ?children ?text ()

(** Wrap a vdom into a node. *)
let node (v : 'msg vdom) : 'msg node = `Html v

(* ── Document ────────────────────────────────────────────────────── *)

let html ?(attrs = []) ?(bool_attrs = []) ?(children = []) () : 'msg node =
  `Html { tag = "html"; attrs; bool_attrs; handlers = []; children;
    text = None; void = false }

(* Each tag helper is an explicit [fun] so its type generalizes —
   [let head = tag "head"] alone would be a monomorphic value (value
   restriction: the optionals carry a free type variable). *)
let head ?attrs ?bool_attrs ?handlers ?children ?text () = tag "head" ?attrs ?bool_attrs ?handlers ?children ?text ()
let title ?attrs ?bool_attrs ?handlers ?children ?text () = tag "title" ?attrs ?bool_attrs ?handlers ?children ?text ()
let body ?attrs ?bool_attrs ?handlers ?children ?text () = tag "body" ?attrs ?bool_attrs ?handlers ?children ?text ()
let base ?attrs ?bool_attrs ?handlers ?children ?text () = void_tag "base" ?attrs ?bool_attrs ?handlers ?children ?text ()

(* ── Sections ────────────────────────────────────────────────────── *)

let main ?attrs ?bool_attrs ?handlers ?children ?text () = tag "main" ?attrs ?bool_attrs ?handlers ?children ?text ()
let header ?attrs ?bool_attrs ?handlers ?children ?text () = tag "header" ?attrs ?bool_attrs ?handlers ?children ?text ()
let footer ?attrs ?bool_attrs ?handlers ?children ?text () = tag "footer" ?attrs ?bool_attrs ?handlers ?children ?text ()
let nav ?attrs ?bool_attrs ?handlers ?children ?text () = tag "nav" ?attrs ?bool_attrs ?handlers ?children ?text ()
let section ?attrs ?bool_attrs ?handlers ?children ?text () = tag "section" ?attrs ?bool_attrs ?handlers ?children ?text ()
let article ?attrs ?bool_attrs ?handlers ?children ?text () = tag "article" ?attrs ?bool_attrs ?handlers ?children ?text ()
let aside ?attrs ?bool_attrs ?handlers ?children ?text () = tag "aside" ?attrs ?bool_attrs ?handlers ?children ?text ()
let address ?attrs ?bool_attrs ?handlers ?children ?text () = tag "address" ?attrs ?bool_attrs ?handlers ?children ?text ()

(* ── Headings ────────────────────────────────────────────────────── *)

let h1 ?attrs ?bool_attrs ?handlers ?children ?text () = tag "h1" ?attrs ?bool_attrs ?handlers ?children ?text ()
let h2 ?attrs ?bool_attrs ?handlers ?children ?text () = tag "h2" ?attrs ?bool_attrs ?handlers ?children ?text ()
let h3 ?attrs ?bool_attrs ?handlers ?children ?text () = tag "h3" ?attrs ?bool_attrs ?handlers ?children ?text ()
let h4 ?attrs ?bool_attrs ?handlers ?children ?text () = tag "h4" ?attrs ?bool_attrs ?handlers ?children ?text ()
let h5 ?attrs ?bool_attrs ?handlers ?children ?text () = tag "h5" ?attrs ?bool_attrs ?handlers ?children ?text ()
let h6 ?attrs ?bool_attrs ?handlers ?children ?text () = tag "h6" ?attrs ?bool_attrs ?handlers ?children ?text ()

(* ── Grouping / block ────────────────────────────────────────────── *)

let div ?attrs ?bool_attrs ?handlers ?children ?text () = tag "div" ?attrs ?bool_attrs ?handlers ?children ?text ()
let p ?attrs ?bool_attrs ?handlers ?children ?text () = tag "p" ?attrs ?bool_attrs ?handlers ?children ?text ()
let pre ?attrs ?bool_attrs ?handlers ?children ?text () = tag "pre" ?attrs ?bool_attrs ?handlers ?children ?text ()
let blockquote ?attrs ?bool_attrs ?handlers ?children ?text () = tag "blockquote" ?attrs ?bool_attrs ?handlers ?children ?text ()
let figure ?attrs ?bool_attrs ?handlers ?children ?text () = tag "figure" ?attrs ?bool_attrs ?handlers ?children ?text ()
let figcaption ?attrs ?bool_attrs ?handlers ?children ?text () = tag "figcaption" ?attrs ?bool_attrs ?handlers ?children ?text ()
let hr ?attrs ?bool_attrs ?handlers ?children ?text () = void_tag "hr" ?attrs ?bool_attrs ?handlers ?children ?text ()
let br ?attrs ?bool_attrs ?handlers ?children ?text () = void_tag "br" ?attrs ?bool_attrs ?handlers ?children ?text ()
let wbr ?attrs ?bool_attrs ?handlers ?children ?text () = void_tag "wbr" ?attrs ?bool_attrs ?handlers ?children ?text ()

(* ── Lists ───────────────────────────────────────────────────────── *)

let ul ?attrs ?bool_attrs ?handlers ?children ?text () = tag "ul" ?attrs ?bool_attrs ?handlers ?children ?text ()
let ol ?attrs ?bool_attrs ?handlers ?children ?text () = tag "ol" ?attrs ?bool_attrs ?handlers ?children ?text ()
let li ?attrs ?bool_attrs ?handlers ?children ?text () = tag "li" ?attrs ?bool_attrs ?handlers ?children ?text ()
let dl ?attrs ?bool_attrs ?handlers ?children ?text () = tag "dl" ?attrs ?bool_attrs ?handlers ?children ?text ()
let dt ?attrs ?bool_attrs ?handlers ?children ?text () = tag "dt" ?attrs ?bool_attrs ?handlers ?children ?text ()
let dd ?attrs ?bool_attrs ?handlers ?children ?text () = tag "dd" ?attrs ?bool_attrs ?handlers ?children ?text ()

(* ── Inline text semantics ───────────────────────────────────────── *)

let span ?attrs ?bool_attrs ?handlers ?children ?text () = tag "span" ?attrs ?bool_attrs ?handlers ?children ?text ()
let a ?attrs ?bool_attrs ?handlers ?children ?text () = tag "a" ?attrs ?bool_attrs ?handlers ?children ?text ()
let strong ?attrs ?bool_attrs ?handlers ?children ?text () = tag "strong" ?attrs ?bool_attrs ?handlers ?children ?text ()
let em ?attrs ?bool_attrs ?handlers ?children ?text () = tag "em" ?attrs ?bool_attrs ?handlers ?children ?text ()
let b ?attrs ?bool_attrs ?handlers ?children ?text () = tag "b" ?attrs ?bool_attrs ?handlers ?children ?text ()
let i ?attrs ?bool_attrs ?handlers ?children ?text () = tag "i" ?attrs ?bool_attrs ?handlers ?children ?text ()
let u ?attrs ?bool_attrs ?handlers ?children ?text () = tag "u" ?attrs ?bool_attrs ?handlers ?children ?text ()
let s ?attrs ?bool_attrs ?handlers ?children ?text () = tag "s" ?attrs ?bool_attrs ?handlers ?children ?text ()
let small ?attrs ?bool_attrs ?handlers ?children ?text () = tag "small" ?attrs ?bool_attrs ?handlers ?children ?text ()
let mark ?attrs ?bool_attrs ?handlers ?children ?text () = tag "mark" ?attrs ?bool_attrs ?handlers ?children ?text ()
let del ?attrs ?bool_attrs ?handlers ?children ?text () = tag "del" ?attrs ?bool_attrs ?handlers ?children ?text ()
let ins ?attrs ?bool_attrs ?handlers ?children ?text () = tag "ins" ?attrs ?bool_attrs ?handlers ?children ?text ()
let sub ?attrs ?bool_attrs ?handlers ?children ?text () = tag "sub" ?attrs ?bool_attrs ?handlers ?children ?text ()
let sup ?attrs ?bool_attrs ?handlers ?children ?text () = tag "sup" ?attrs ?bool_attrs ?handlers ?children ?text ()
let abbr ?attrs ?bool_attrs ?handlers ?children ?text () = tag "abbr" ?attrs ?bool_attrs ?handlers ?children ?text ()
let time ?attrs ?bool_attrs ?handlers ?children ?text () = tag "time" ?attrs ?bool_attrs ?handlers ?children ?text ()
let cite ?attrs ?bool_attrs ?handlers ?children ?text () = tag "cite" ?attrs ?bool_attrs ?handlers ?children ?text ()
let q ?attrs ?bool_attrs ?handlers ?children ?text () = tag "q" ?attrs ?bool_attrs ?handlers ?children ?text ()
let dfn ?attrs ?bool_attrs ?handlers ?children ?text () = tag "dfn" ?attrs ?bool_attrs ?handlers ?children ?text ()
let var ?attrs ?bool_attrs ?handlers ?children ?text () = tag "var" ?attrs ?bool_attrs ?handlers ?children ?text ()
let samp ?attrs ?bool_attrs ?handlers ?children ?text () = tag "samp" ?attrs ?bool_attrs ?handlers ?children ?text ()
let kbd ?attrs ?bool_attrs ?handlers ?children ?text () = tag "kbd" ?attrs ?bool_attrs ?handlers ?children ?text ()
let code ?attrs ?bool_attrs ?handlers ?children ?text () = tag "code" ?attrs ?bool_attrs ?handlers ?children ?text ()
let data ?attrs ?bool_attrs ?handlers ?children ?text () = tag "data" ?attrs ?bool_attrs ?handlers ?children ?text ()
let ruby ?attrs ?bool_attrs ?handlers ?children ?text () = tag "ruby" ?attrs ?bool_attrs ?handlers ?children ?text ()
let rt ?attrs ?bool_attrs ?handlers ?children ?text () = tag "rt" ?attrs ?bool_attrs ?handlers ?children ?text ()
let rp ?attrs ?bool_attrs ?handlers ?children ?text () = tag "rp" ?attrs ?bool_attrs ?handlers ?children ?text ()
let bdi ?attrs ?bool_attrs ?handlers ?children ?text () = tag "bdi" ?attrs ?bool_attrs ?handlers ?children ?text ()
let bdo ?attrs ?bool_attrs ?handlers ?children ?text () = tag "bdo" ?attrs ?bool_attrs ?handlers ?children ?text ()

(* ── Tables ──────────────────────────────────────────────────────── *)

let table ?attrs ?bool_attrs ?handlers ?children ?text () = tag "table" ?attrs ?bool_attrs ?handlers ?children ?text ()
let thead ?attrs ?bool_attrs ?handlers ?children ?text () = tag "thead" ?attrs ?bool_attrs ?handlers ?children ?text ()
let tbody ?attrs ?bool_attrs ?handlers ?children ?text () = tag "tbody" ?attrs ?bool_attrs ?handlers ?children ?text ()
let tfoot ?attrs ?bool_attrs ?handlers ?children ?text () = tag "tfoot" ?attrs ?bool_attrs ?handlers ?children ?text ()
let tr ?attrs ?bool_attrs ?handlers ?children ?text () = tag "tr" ?attrs ?bool_attrs ?handlers ?children ?text ()
let th ?attrs ?bool_attrs ?handlers ?children ?text () = tag "th" ?attrs ?bool_attrs ?handlers ?children ?text ()
let td ?attrs ?bool_attrs ?handlers ?children ?text () = tag "td" ?attrs ?bool_attrs ?handlers ?children ?text ()
let caption ?attrs ?bool_attrs ?handlers ?children ?text () = tag "caption" ?attrs ?bool_attrs ?handlers ?children ?text ()
let colgroup ?attrs ?bool_attrs ?handlers ?children ?text () = tag "colgroup" ?attrs ?bool_attrs ?handlers ?children ?text ()
let col ?attrs ?bool_attrs ?handlers ?children ?text () = void_tag "col" ?attrs ?bool_attrs ?handlers ?children ?text ()

(* ── Forms ───────────────────────────────────────────────────────── *)

let form ?attrs ?bool_attrs ?handlers ?children ?text () = tag "form" ?attrs ?bool_attrs ?handlers ?children ?text ()
let button ?attrs ?bool_attrs ?handlers ?children ?text () = tag "button" ?attrs ?bool_attrs ?handlers ?children ?text ()
let input ?attrs ?bool_attrs ?handlers ?children ?text () = void_tag "input" ?attrs ?bool_attrs ?handlers ?children ?text ()
let label ?attrs ?bool_attrs ?handlers ?children ?text () = tag "label" ?attrs ?bool_attrs ?handlers ?children ?text ()
let textarea ?attrs ?bool_attrs ?handlers ?children ?text () = tag "textarea" ?attrs ?bool_attrs ?handlers ?children ?text ()
let select ?attrs ?bool_attrs ?handlers ?children ?text () = tag "select" ?attrs ?bool_attrs ?handlers ?children ?text ()
let option ?attrs ?bool_attrs ?handlers ?children ?text () = tag "option" ?attrs ?bool_attrs ?handlers ?children ?text ()
let optgroup ?attrs ?bool_attrs ?handlers ?children ?text () = tag "optgroup" ?attrs ?bool_attrs ?handlers ?children ?text ()
let fieldset ?attrs ?bool_attrs ?handlers ?children ?text () = tag "fieldset" ?attrs ?bool_attrs ?handlers ?children ?text ()
let legend ?attrs ?bool_attrs ?handlers ?children ?text () = tag "legend" ?attrs ?bool_attrs ?handlers ?children ?text ()
let datalist ?attrs ?bool_attrs ?handlers ?children ?text () = tag "datalist" ?attrs ?bool_attrs ?handlers ?children ?text ()
let output ?attrs ?bool_attrs ?handlers ?children ?text () = tag "output" ?attrs ?bool_attrs ?handlers ?children ?text ()
let progress ?attrs ?bool_attrs ?handlers ?children ?text () = tag "progress" ?attrs ?bool_attrs ?handlers ?children ?text ()
let meter ?attrs ?bool_attrs ?handlers ?children ?text () = tag "meter" ?attrs ?bool_attrs ?handlers ?children ?text ()

(* ── Interactive ─────────────────────────────────────────────────── *)

let details ?attrs ?bool_attrs ?handlers ?children ?text () = tag "details" ?attrs ?bool_attrs ?handlers ?children ?text ()
let summary ?attrs ?bool_attrs ?handlers ?children ?text () = tag "summary" ?attrs ?bool_attrs ?handlers ?children ?text ()
let dialog ?attrs ?bool_attrs ?handlers ?children ?text () = tag "dialog" ?attrs ?bool_attrs ?handlers ?children ?text ()

(* ── Media / embedded ────────────────────────────────────────────── *)

let img ?attrs ?bool_attrs ?handlers ?children ?text () = void_tag "img" ?attrs ?bool_attrs ?handlers ?children ?text ()
let video ?attrs ?bool_attrs ?handlers ?children ?text () = tag "video" ?attrs ?bool_attrs ?handlers ?children ?text ()
let audio ?attrs ?bool_attrs ?handlers ?children ?text () = tag "audio" ?attrs ?bool_attrs ?handlers ?children ?text ()
let source ?attrs ?bool_attrs ?handlers ?children ?text () = void_tag "source" ?attrs ?bool_attrs ?handlers ?children ?text ()
let track ?attrs ?bool_attrs ?handlers ?children ?text () = void_tag "track" ?attrs ?bool_attrs ?handlers ?children ?text ()
let canvas ?attrs ?bool_attrs ?handlers ?children ?text () = tag "canvas" ?attrs ?bool_attrs ?handlers ?children ?text ()
let picture ?attrs ?bool_attrs ?handlers ?children ?text () = tag "picture" ?attrs ?bool_attrs ?handlers ?children ?text ()
let iframe ?attrs ?bool_attrs ?handlers ?children ?text () = tag "iframe" ?attrs ?bool_attrs ?handlers ?children ?text ()
let embed ?attrs ?bool_attrs ?handlers ?children ?text () = void_tag "embed" ?attrs ?bool_attrs ?handlers ?children ?text ()
let object_ ?attrs ?bool_attrs ?handlers ?children ?text () = tag "object" ?attrs ?bool_attrs ?handlers ?children ?text ()
let map ?attrs ?bool_attrs ?handlers ?children ?text () = tag "map" ?attrs ?bool_attrs ?handlers ?children ?text ()
let area ?attrs ?bool_attrs ?handlers ?children ?text () = void_tag "area" ?attrs ?bool_attrs ?handlers ?children ?text ()

(* ── Metadata / scripting ────────────────────────────────────────── *)

let meta ?attrs ?bool_attrs ?handlers ?children ?text () = void_tag "meta" ?attrs ?bool_attrs ?handlers ?children ?text ()
let link ?attrs ?bool_attrs ?handlers ?children ?text () = void_tag "link" ?attrs ?bool_attrs ?handlers ?children ?text ()
let script ?attrs ?bool_attrs ?handlers ?children ?text () = tag "script" ?attrs ?bool_attrs ?handlers ?children ?text ()
let noscript ?attrs ?bool_attrs ?handlers ?children ?text () = tag "noscript" ?attrs ?bool_attrs ?handlers ?children ?text ()
let template ?attrs ?bool_attrs ?handlers ?children ?text () = tag "template" ?attrs ?bool_attrs ?handlers ?children ?text ()
let slot ?attrs ?bool_attrs ?handlers ?children ?text () = tag "slot" ?attrs ?bool_attrs ?handlers ?children ?text ()

(* ── Text / raw nodes ────────────────────────────────────────────── *)

(** An escaped text node (XSS-safe). MLX bare-string children desugar to this. *)
let txt (s : string) : 'a node =
  `Html { tag = ""; attrs = []; bool_attrs = []; handlers = []; children = [];
    text = Some (escape_html s); void = false }

(** A raw/unescaped HTML node. The string is emitted verbatim. Use with caution. *)
let raw (s : string) : 'a node =
  `Html { tag = "#raw"; attrs = []; bool_attrs = []; handlers = []; children = [];
    text = Some s; void = false }

(** Concatenate nodes into a fragment node. {!element_to_string} flattens
    fragments; convenient for MLX [(children |> cat |> raw)]. *)
let cat (children : 'msg node list) : 'msg node =
  `Html { tag = "#frag"; attrs = []; bool_attrs = []; handlers = []; children;
    text = None; void = false }

(** Render a hidden CSRF token input field. *)
let csrf_input token : 'a node =
  void_element "input" ~attrs:
    [ ("type", "hidden"); ("name", "_csrf_token"); ("value", token) ] ()

(** Render a field error message span, or empty if no error for the field. *)
let field_error errors field_name : 'a node =
  match List.assoc_opt field_name errors with
  | Some msg -> span ~attrs:[ ("class", "field-error") ] ~text:msg ()
  | None -> raw ""

(* ── Handler helpers (frontend) ──────────────────────────────────── *)

(** A handler that always dispatches the given [msg], ignoring the event.
    Convenience for the [Msg] constructor; use directly as an attribute value
    ([on_click=Increment]) or programmatically
    ([~handlers:[("click", on_click Increment)]]). *)
let on_click (msg : 'msg) : 'msg handler = Msg msg

let on_form (f : form_data -> 'msg) : 'msg handler = On_form f

(** Attach a named event handler to a node. *)
let on_event (name : string) (handler : 'msg handler) (node : 'msg vdom) : 'msg vdom =
  { node with handlers = (name, handler) :: node.handlers }

(* ── Serialization ────────────────────────────────────────────────── *)

(** Recursively render a node to an HTML string. The server uses this to turn
    a vdom response into the HTTP body. [tag = ""] and ["#raw"] emit their
    text verbatim; ["#frag"] flattens to its children's serialization. *)
let rec element_to_string (`Html v : _ node) : string =
  match v.tag with
  | "" | "#raw" -> (match v.text with Some s -> s | None -> "")
  | "#frag" ->
    String.concat "" (List.map element_to_string v.children)
  | _ ->
    let attr_str = attrs_to_string v.attrs ^ bool_attrs_to_string v.bool_attrs in
    if v.void then Printf.sprintf "<%s%s />" v.tag attr_str
    else
      let inner =
        match v.text with
        | Some s when v.children = [] -> s
        | _ -> String.concat "" (List.map element_to_string v.children)
      in
      Printf.sprintf "<%s%s>%s</%s>" v.tag attr_str inner v.tag
