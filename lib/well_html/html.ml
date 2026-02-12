type node = [ `Html of string ]

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
        else Some (Printf.sprintf " %s=\"%s\"" k v))
      attrs
  in
  String.concat "" parts

let cat (children : node list) =
  String.concat "" (List.map (fun (`Html s) -> s) children)

let void_tag name ?(id = "") ?(class_ = "") ?(charset = "")
    ?(content = "") ?(name_ = "") ?(lang = "") ?(rel = "") ?(href = "")
    ?(children : node list = []) () : node =
  ignore children;
  let attrs =
    [
      ("id", id); ("class", class_); ("charset", charset);
      ("content", content); ("name", name_); ("lang", lang);
      ("rel", rel); ("href", href);
    ]
  in
  `Html (Printf.sprintf "<%s%s />" name (attrs_to_string attrs))

let tag name ?(id = "") ?(class_ = "") ?(lang = "")
    ?(data_lv_click = "") ?(data_lv_submit = "") ?(data_lv_change = "")
    ?(action = "") ?(method_ = "") ?(href = "")
    ?(type_ = "") ?(placeholder = "") ?(value = "")
    ?(name_ = "") ?(charset = "") ?(content = "")
    ?(src = "")
    ?(children : node list = []) () : node =
  let attrs =
    [
      ("id", id); ("class", class_); ("lang", lang);
      ("data-lv-click", data_lv_click); ("data-lv-submit", data_lv_submit);
      ("data-lv-change", data_lv_change);
      ("action", action); ("method", method_); ("href", href);
      ("type", type_); ("placeholder", placeholder); ("value", value);
      ("name", name_); ("charset", charset); ("content", content);
      ("src", src);
    ]
  in
  `Html
    (Printf.sprintf "<%s%s>%s</%s>" name (attrs_to_string attrs)
       (cat children) name)

let html = tag "html"
let head = tag "head"
let title = tag "title"
let body = tag "body"
let div = tag "div"
let span = tag "span"
let p = tag "p"
let h1 = tag "h1"
let h2 = tag "h2"
let h3 = tag "h3"
let h4 = tag "h4"
let a = tag "a"
let main = tag "main"
let footer = tag "footer"
let header = tag "header"
let nav = tag "nav"
let section = tag "section"
let form = tag "form"
let button = tag "button"
let input = tag "input"
let label = tag "label"
let ul = tag "ul"
let ol = tag "ol"
let li = tag "li"
let strong = tag "strong"
let em = tag "em"
let b = tag "b"
let i = tag "i"
let small = tag "small"
let pre = tag "pre"
let code = tag "code"
let blockquote = tag "blockquote"
let table = tag "table"
let thead = tag "thead"
let tbody = tag "tbody"
let tr = tag "tr"
let th = tag "th"
let td = tag "td"
let textarea = tag "textarea"
let select = tag "select"
let option = tag "option"

let meta ?id ?class_ ?charset ?content ?name_ ?lang ?children () =
  void_tag "meta" ?id ?class_ ?charset ?content ?name_ ?lang ?children ()

let link ?id ?class_ ?charset ?content ?name_ ?lang ?rel ?href ?children () =
  void_tag "link" ?id ?class_ ?charset ?content ?name_ ?lang ?rel ?href ?children ()

let script = tag "script"

let txt s : node = `Html (escape_html s)
let raw s : node = `Html s

let csrf_input token : node =
  `Html (Printf.sprintf {|<input type="hidden" name="_csrf_token" value="%s" />|}
           (escape_html token))

(* ── LiveView support ─────────────────────────────────────────────── *)

let element_to_string (`Html s : node) : string = s

let dynamic id value : node =
  `Html
    (Printf.sprintf {|<span data-lv="%s">%s</span>|}
       (escape_html id) (escape_html value))

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
