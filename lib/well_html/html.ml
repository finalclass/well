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

let void_tag name ?(id = "") ?(class_ = "") ?(charset = "")
    ?(content = "") ?(name_ = "") ?(lang = "")
    ?(children : string list = []) () =
  ignore children;
  let attrs =
    [
      ("id", id); ("class", class_); ("charset", charset);
      ("content", content); ("name", name_); ("lang", lang);
    ]
  in
  Printf.sprintf "<%s%s />" name (attrs_to_string attrs)

let tag name ?(id = "") ?(class_ = "") ?(lang = "")
    ?(data_lv_click = "") ?(data_lv_submit = "")
    ?(action = "") ?(method_ = "") ?(href = "")
    ?(type_ = "") ?(placeholder = "") ?(value = "")
    ?(name_ = "") ?(charset = "") ?(content = "")
    ?(children = []) () =
  let attrs =
    [
      ("id", id); ("class", class_); ("lang", lang);
      ("data-lv-click", data_lv_click); ("data-lv-submit", data_lv_submit);
      ("action", action); ("method", method_); ("href", href);
      ("type", type_); ("placeholder", placeholder); ("value", value);
      ("name", name_); ("charset", charset); ("content", content);
    ]
  in
  Printf.sprintf "<%s%s>%s</%s>" name (attrs_to_string attrs)
    (String.concat "" children) name

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

let meta ?id ?class_ ?charset ?content ?name_ ?lang ?children () =
  void_tag "meta" ?id ?class_ ?charset ?content ?name_ ?lang ?children ()

let txt s = escape_html s
let raw s = s
