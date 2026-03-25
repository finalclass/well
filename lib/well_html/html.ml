(** HTML generation library with full HTML5 tag coverage, XSS protection, and LiveView support. *)

(** An HTML node. Coerces to [Well.response] via [:>] in route handlers. *)
type node = [ `Html of string ]

(** Escape HTML special characters (ampersand, angle brackets, double quotes) for safe embedding. *)
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
  if bools = [] then ""
  else " " ^ String.concat " " bools

(** Concatenate a list of nodes into a single HTML string. *)
let cat (children : node list) =
  String.concat "" (List.map (fun (`Html s) -> s) children)

(* ── Shared element constructor ───────────────────────────────────── *)

let _el ~void name
    ?(attrs : (string * string) list = [])
    ?(bool_attrs : string list = [])
    ?(children : node list = []) () : node =
  let attr_str = attrs_to_string attrs ^ bool_attrs_to_string bool_attrs in
  if void then begin
    ignore children;
    `Html (Printf.sprintf "<%s%s />" name attr_str)
  end else
    `Html (Printf.sprintf "<%s%s>%s</%s>" name attr_str (cat children) name)

(** Create a normal HTML element (with closing tag). *)
let tag = _el ~void:false

(** Create a void/self-closing HTML element (e.g. [<input />]). *)
let void_tag = _el ~void:true

(* ── Document ────────────────────────────────────────────────────── *)

let html ?attrs ?bool_attrs ?children () =
  let (`Html inner) = tag "html" ?attrs ?bool_attrs ?children () in
  `Html ("<!DOCTYPE html>\n" ^ inner)
let head = tag "head"
let title = tag "title"
let body = tag "body"
let base = void_tag "base"

(* ── Sections ────────────────────────────────────────────────────── *)

let main = tag "main"
let header = tag "header"
let footer = tag "footer"
let nav = tag "nav"
let section = tag "section"
let article = tag "article"
let aside = tag "aside"
let address = tag "address"

(* ── Headings ────────────────────────────────────────────────────── *)

let h1 = tag "h1"
let h2 = tag "h2"
let h3 = tag "h3"
let h4 = tag "h4"
let h5 = tag "h5"
let h6 = tag "h6"

(* ── Grouping / block ────────────────────────────────────────────── *)

let div = tag "div"
let p = tag "p"
let pre = tag "pre"
let blockquote = tag "blockquote"
let figure = tag "figure"
let figcaption = tag "figcaption"
let hr = void_tag "hr"
let br = void_tag "br"
let wbr = void_tag "wbr"

(* ── Lists ───────────────────────────────────────────────────────── *)

let ul = tag "ul"
let ol = tag "ol"
let li = tag "li"
let dl = tag "dl"
let dt = tag "dt"
let dd = tag "dd"

(* ── Inline text semantics ───────────────────────────────────────── *)

let span = tag "span"
let a = tag "a"
let strong = tag "strong"
let em = tag "em"
let b = tag "b"
let i = tag "i"
let u = tag "u"
let s = tag "s"
let small = tag "small"
let mark = tag "mark"
let del = tag "del"
let ins = tag "ins"
let sub = tag "sub"
let sup = tag "sup"
let abbr = tag "abbr"
let time = tag "time"
let cite = tag "cite"
let q = tag "q"
let dfn = tag "dfn"
let var = tag "var"
let samp = tag "samp"
let kbd = tag "kbd"
let code = tag "code"
let data = tag "data"
let ruby = tag "ruby"
let rt = tag "rt"
let rp = tag "rp"
let bdi = tag "bdi"
let bdo = tag "bdo"

(* ── Tables ──────────────────────────────────────────────────────── *)

let table = tag "table"
let thead = tag "thead"
let tbody = tag "tbody"
let tfoot = tag "tfoot"
let tr = tag "tr"
let th = tag "th"
let td = tag "td"
let caption = tag "caption"
let colgroup = tag "colgroup"
let col = void_tag "col"

(* ── Forms ───────────────────────────────────────────────────────── *)

let form = tag "form"
let button = tag "button"
let input = void_tag "input"
let label = tag "label"
let textarea = tag "textarea"
let select = tag "select"
let option = tag "option"
let optgroup = tag "optgroup"
let fieldset = tag "fieldset"
let legend = tag "legend"
let datalist = tag "datalist"
let output = tag "output"
let progress = tag "progress"
let meter = tag "meter"

(* ── Interactive ─────────────────────────────────────────────────── *)

let details = tag "details"
let summary = tag "summary"
let dialog = tag "dialog"

(* ── Media / embedded ────────────────────────────────────────────── *)

let img = void_tag "img"
let video = tag "video"
let audio = tag "audio"
let source = void_tag "source"
let track = void_tag "track"
let canvas = tag "canvas"
let picture = tag "picture"
let iframe = tag "iframe"
let embed = void_tag "embed"
let object_ = tag "object"
let map = tag "map"
let area = void_tag "area"

(* ── Metadata / scripting ────────────────────────────────────────── *)

let meta = void_tag "meta"
let link = void_tag "link"
let script = tag "script"
let noscript = tag "noscript"
let template = tag "template"
let slot = tag "slot"

(** Create an escaped text node (XSS-safe). *)
let txt s : node = `Html (escape_html s)

(** Create a raw/unescaped HTML node. Use with caution. *)
let raw s : node = `Html s

(** Render a hidden CSRF token input field. *)
let csrf_input token : node =
  `Html (Printf.sprintf {|<input type="hidden" name="_csrf_token" value="%s" />|}
           (escape_html token))

(** Render a field error message span, or empty if no error for the field. *)
let field_error errors field_name : node =
  match List.assoc_opt field_name errors with
  | Some msg ->
      `Html (Printf.sprintf {|<span class="field-error">%s</span>|}
               (escape_html msg))
  | None -> `Html ""

(* ── LiveView support ─────────────────────────────────────────────── *)

(** Extract the raw HTML string from a node. *)
let element_to_string (`Html s : node) : string = s

(* ── Keyed list support ──────────────────────────────────────────── *)

type keyed_item = { key : string; html : string }

let _list_registry : (string * keyed_item list) list ref = ref []

let collect_and_clear_lists () =
  let data = !_list_registry in
  _list_registry := [];
  data

let inject_lv_key key html =
  let pattern = Str.regexp {|<\([a-zA-Z][a-zA-Z0-9]*\)|} in
  (try
     let _ = Str.search_forward pattern html 0 in
     let tag_name = Str.matched_group 1 html in
     let match_start = Str.match_beginning () in
     let match_end = Str.match_end () in
     let before = String.sub html 0 match_start in
     let after = String.sub html match_end (String.length html - match_end) in
     before ^ "<" ^ tag_name
     ^ Printf.sprintf {| data-lv-key="%s"|} (escape_html key)
     ^ after
   with Not_found -> html)

(** Render a keyed list for LiveView diffing. Each item gets a [data-lv-key] attribute. *)
let each ~id ?(tag_name = "div") items ~key render_fn : node =
  let keyed_items =
    List.map
      (fun item ->
        let k = key item in
        let rendered = element_to_string (render_fn item) in
        let html_with_key = inject_lv_key k rendered in
        { key = k; html = html_with_key })
      items
  in
  _list_registry := (id, keyed_items) :: !_list_registry;
  let inner =
    String.concat "" (List.map (fun ki -> ki.html) keyed_items)
  in
  `Html
    (Printf.sprintf {|<%s data-lv-each="%s">%s</%s>|}
       tag_name (escape_html id) inner tag_name)
