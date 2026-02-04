/* Simple JSX-compatible HTML library with XSS protection */
/* Uses polymorphic variants for seamless integration with Blossom responses */

/* Element type for JSX */
type element = [ | `Html(string) | `Text(string) ];

/* HTML escaping for XSS prevention */
let escape_html = (text: string): string => {
  let result = ref(text);
  result := Str.global_replace(Str.regexp("&"), "&amp;", result^);
  result := Str.global_replace(Str.regexp("<"), "&lt;", result^);
  result := Str.global_replace(Str.regexp(">"), "&gt;", result^);
  result := Str.global_replace(Str.regexp("\""), "&quot;", result^);
  result := Str.global_replace(Str.regexp("'"), "&#x27;", result^);
  result^;
};

/* Convert element to string for embedding in HTML */
let element_to_string = (el: element): string =>
  switch (el) {
  | `Text(text) => escape_html(text)
  | `Html(html) => html
  };

/* Helper to render children */
let children_to_string = (children: list(element)): string =>
  children |> List.map(element_to_string) |> List.fold_left((++), "");

/* Helper to render attributes - values are escaped */
let attrs_to_string = (attrs: list((string, string))): string =>
  attrs
  |> List.map(((k, v)) => Printf.sprintf({| %s="%s"|}, k, escape_html(v)))
  |> List.fold_left((++), "");

/* Generic tag builder - returns `Html */
let tag = (name: string, ~attrs: list((string, string))=[], ~children: list(element)=[], ()): element => {
  let html = Printf.sprintf("<%s%s>%s</%s>", name, attrs_to_string(attrs), children_to_string(children), name);
  `Html(html);
};

let self_closing_tag = (name: string, ~attrs: list((string, string))=[], ()): element => {
  let html = Printf.sprintf("<%s%s />", name, attrs_to_string(attrs));
  `Html(html);
};

/* === Text nodes === */

/* Safe text - ESCAPED when used in HTML, plain text/plain when used as response */
/* Usage:
   txt("Hello")                              - static text
   txt(name)                                 - string variable
   txt(Printf.sprintf("Count: %d", num))     - formatted
*/
let txt = (s: string): element => `Text(s);

/* Raw HTML - NOT escaped (use only for trusted content!) */
let raw = (html: string): element => `Html(html);

/* Helper to coerce element to Blossom.response_body - useful in if/else with mixed types */
let asResponse = (el: element): Blossom.response_body => (el :> Blossom.response_body);

/* === Document === */
let html = (~lang: string="en", ~children: list(element)=[], ()): element => {
  let content = "<!DOCTYPE html>\n" ++ Printf.sprintf({|<html lang="%s">%s</html>|}, escape_html(lang), children_to_string(children));
  `Html(content);
};

/* === Head elements === */
let head = (~children: list(element)=[], ()): element =>
  tag("head", ~children, ());

let title = (~children: list(element)=[], ()): element =>
  tag("title", ~children, ());

let meta = (~charset: string="", ~name: string="", ~content: string="", ~children: list(element)=[], ()): element => {
  let _ = children;
  let attrs = [
    charset != "" ? [("charset", charset)] : [],
    name != "" ? [("name", name)] : [],
    content != "" ? [("content", content)] : [],
  ] |> List.flatten;
  self_closing_tag("meta", ~attrs, ());
};

let style = (~children: list(element)=[], ()): element =>
  tag("style", ~children, ());

let link = (~rel: string="", ~href: string="", ~children: list(element)=[], ()): element => {
  let _ = children;
  let attrs = [
    rel != "" ? [("rel", rel)] : [],
    href != "" ? [("href", href)] : [],
  ] |> List.flatten;
  self_closing_tag("link", ~attrs, ());
};

/* === Body elements === */
let body = (~className: string="", ~children: list(element)=[], ()): element => {
  let attrs = className != "" ? [("class", className)] : [];
  tag("body", ~attrs, ~children, ());
};

let div = (~className: string="", ~id: string="", ~children: list(element)=[], ()): element => {
  let attrs = [
    className != "" ? [("class", className)] : [],
    id != "" ? [("id", id)] : [],
  ] |> List.flatten;
  tag("div", ~attrs, ~children, ());
};

let span = (~className: string="", ~children: list(element)=[], ()): element => {
  let attrs = className != "" ? [("class", className)] : [];
  tag("span", ~attrs, ~children, ());
};

let p = (~className: string="", ~children: list(element)=[], ()): element => {
  let attrs = className != "" ? [("class", className)] : [];
  tag("p", ~attrs, ~children, ());
};

let h1 = (~className: string="", ~children: list(element)=[], ()): element => {
  let attrs = className != "" ? [("class", className)] : [];
  tag("h1", ~attrs, ~children, ());
};

let h2 = (~className: string="", ~children: list(element)=[], ()): element => {
  let attrs = className != "" ? [("class", className)] : [];
  tag("h2", ~attrs, ~children, ());
};

let a = (~href: string="", ~className: string="", ~children: list(element)=[], ()): element => {
  let attrs = [
    href != "" ? [("href", href)] : [],
    className != "" ? [("class", className)] : [],
  ] |> List.flatten;
  tag("a", ~attrs, ~children, ());
};

let ul = (~className: string="", ~children: list(element)=[], ()): element => {
  let attrs = className != "" ? [("class", className)] : [];
  tag("ul", ~attrs, ~children, ());
};

let li = (~className: string="", ~children: list(element)=[], ()): element => {
  let attrs = className != "" ? [("class", className)] : [];
  tag("li", ~attrs, ~children, ());
};

let code = (~children: list(element)=[], ()): element =>
  tag("code", ~children, ());

/* === Form elements === */
let form = (~method_: string="", ~action: string="", ~className: string="", ~children: list(element)=[], ()): element => {
  let attrs = [
    method_ != "" ? [("method", method_)] : [],
    action != "" ? [("action", action)] : [],
    className != "" ? [("class", className)] : [],
  ] |> List.flatten;
  tag("form", ~attrs, ~children, ());
};

let input = (~type_: string="text", ~name: string="", ~placeholder: string="", ~required: bool=false, ~value: string="", ~children: list(element)=[], ()): element => {
  let _ = children;
  let attrs = [
    [("type", type_)],
    name != "" ? [("name", name)] : [],
    placeholder != "" ? [("placeholder", placeholder)] : [],
    required ? [("required", "required")] : [],
    value != "" ? [("value", value)] : [],
  ] |> List.flatten;
  self_closing_tag("input", ~attrs, ());
};

let button = (~type_: string="submit", ~className: string="", ~children: list(element)=[], ()): element => {
  let attrs = [
    [("type", type_)],
    className != "" ? [("class", className)] : [],
  ] |> List.flatten;
  tag("button", ~attrs, ~children, ());
};

let label = (~for_: string="", ~children: list(element)=[], ()): element => {
  let attrs = for_ != "" ? [("for", for_)] : [];
  tag("label", ~attrs, ~children, ());
};

let textarea = (~name: string="", ~placeholder: string="", ~rows: int=3, ~children: list(element)=[], ()): element => {
  let attrs = [
    name != "" ? [("name", name)] : [],
    placeholder != "" ? [("placeholder", placeholder)] : [],
    [("rows", string_of_int(rows))],
  ] |> List.flatten;
  tag("textarea", ~attrs, ~children, ());
};

let select = (~name: string="", ~children: list(element)=[], ()): element => {
  let attrs = name != "" ? [("name", name)] : [];
  tag("select", ~attrs, ~children, ());
};

let option = (~value: string="", ~selected: bool=false, ~children: list(element)=[], ()): element => {
  let attrs = [
    value != "" ? [("value", value)] : [],
    selected ? [("selected", "selected")] : [],
  ] |> List.flatten;
  tag("option", ~attrs, ~children, ());
};

/* === Media === */
let img = (~src: string="", ~alt: string="", ~className: string="", ~children: list(element)=[], ()): element => {
  let _ = children;
  let attrs = [
    src != "" ? [("src", src)] : [],
    alt != "" ? [("alt", alt)] : [],
    className != "" ? [("class", className)] : [],
  ] |> List.flatten;
  self_closing_tag("img", ~attrs, ());
};

/* === Misc === */
let br = (~children: list(element)=[], ()): element => {
  let _ = children;
  self_closing_tag("br", ());
};

let hr = (~children: list(element)=[], ()): element => {
  let _ = children;
  self_closing_tag("hr", ());
};

/* === LiveView Support === */

/* Dynamic value - renders with data-lv attribute for LiveView updates */
/* Usage: {dynamic("count", string_of_int(count))} */
let dynamic = (id: string, value: string): element => {
  `Html(Printf.sprintf({|<span data-lv="%s">%s</span>|}, escape_html(id), escape_html(value)));
};

/* === Keyed List Support === */

/* A keyed item: key + rendered HTML string */
type keyed_item = {
  key: string,
  html: string,
};

/* Mutable list registry - accumulates keyed list data during render.
   Safe with Eio cooperative scheduling (no yield between render and collect). */
let _list_registry: ref(list((string, list(keyed_item)))) = ref([]);

/* Collect accumulated list data and clear the registry */
let collect_and_clear_lists = (): list((string, list(keyed_item))) => {
  let data = _list_registry^;
  _list_registry := [];
  data;
};

/* Inject data-lv-key="key" into the first opening tag of an HTML string */
let inject_lv_key = (key: string, html: string): string => {
  /* Find the first '>' that closes the opening tag */
  let pattern = Str.regexp("<\\([a-zA-Z][a-zA-Z0-9]*\\)");
  try({
    let _ = Str.search_forward(pattern, html, 0);
    let tag_name = Str.matched_group(1, html);
    let match_start = Str.match_beginning();
    let match_end = Str.match_end();
    let before = Stdlib.String.sub(html, 0, match_start);
    let after = Stdlib.String.sub(html, match_end, Stdlib.String.length(html) - match_end);
    before ++ "<" ++ tag_name ++ Printf.sprintf({| data-lv-key="%s"|}, escape_html(key)) ++ after;
  }) {
  | Stdlib.Not_found => html
  };
};

/* Render a keyed list of items.
   Each item gets a data-lv-key attribute, and the container gets data-lv-each.
   Items are registered in _list_registry for diff tracking.

   Usage:
     each(~id="todos", ~tag="ul", items, ~key=item => item.id, item =>
       <li className={item.done_ ? "done" : ""}> {txt(item.text)} </li>
     )
*/
let each = (
  ~id: string,
  ~tag: string="div",
  items: list('a),
  ~key: 'a => string,
  render_fn: 'a => element,
): element => {
  let keyed_items = List.map((item) => {
    let k = key(item);
    let rendered = element_to_string(render_fn(item));
    let html_with_key = inject_lv_key(k, rendered);
    { key: k, html: html_with_key };
  }, items);

  /* Register in list registry for diffing */
  _list_registry := [(id, keyed_items), ..._list_registry^];

  let inner = keyed_items
    |> List.map((ki) => ki.html)
    |> List.fold_left((++), "");

  `Html(Printf.sprintf({|<%s data-lv-each="%s">%s</%s>|}, tag, escape_html(id), inner, tag));
};

/* LiveView click handler attribute */
let lvClick = (action: string): (string, string) => ("data-lv-click", action);

/* LiveView input handler attribute */
let lvChange = (action: string): (string, string) => ("data-lv-change", action);

/* LiveView submit handler attribute */
let lvSubmit = (action: string): (string, string) => ("data-lv-submit", action);

/* Generic tag with custom attributes */
let tagWithAttrs = (
  name: string,
  ~attrs: list((string, string))=[],
  ~children: list(element)=[],
  ()
): element => {
  tag(name, ~attrs, ~children, ());
};

/* Button with LiveView click handler */
let lvButton = (
  ~click: string,
  ~className: string="",
  ~children: list(element)=[],
  ()
): element => {
  let attrs = [
    ("data-lv-click", click),
    ...className != "" ? [("class", className)] : [],
  ];
  tag("button", ~attrs, ~children, ());
};

/* LiveView container - embeds a LiveView component with SSR */
let liveView = (
  ~endpoint: string,
  ~props: list((string, string))=[],
  ~className: string="",
  ~children: list(element)=[],
  ()
): element => {
  let props_json =
    `Assoc(List.map(((k, v)) => (k, `String(v)), props))
    |> Yojson.Safe.to_string;

  let attrs = [
    ("data-liveview", endpoint),
    ("data-props", props_json),
    ...className != "" ? [("class", className)] : [],
  ];

  tag("live-view", ~attrs, ~children, ());
};

/* Script tag for LiveView client */
let liveViewScript = (): element => {
  `Html({|<script src="/static/v2/live-view.js" type="module"></script>|});
};
