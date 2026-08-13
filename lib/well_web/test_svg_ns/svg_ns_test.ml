open Js_of_ocaml
open Well_web

let svg_ns = "http://www.w3.org/2000/svg"
let html_ns = "http://www.w3.org/1999/xhtml"

let document = Dom_html.window##.document

let schedule delay_ms f =
  ignore
    (Js.Unsafe.meth_call Dom_html.window "setTimeout"
       [|
         Js.Unsafe.inject (Js.wrap_callback f);
         Js.Unsafe.inject delay_ms;
       |])

let ns_of el =
  Js.to_string
    (Js.Unsafe.coerce (Js.Unsafe.get el (Js.string "namespaceURI"))
       : Js.js_string Js.t)

let local_name el =
  Js.to_string
    (Js.Unsafe.coerce (Js.Unsafe.get el (Js.string "localName"))
       : Js.js_string Js.t)

let instanceof el ctor =
  Js.to_bool
    (Js.Unsafe.fun_call
       (Js.Unsafe.js_expr
          "function (el, name) { return el instanceof window[name]; }")
       [| Js.Unsafe.inject el; Js.Unsafe.inject (Js.string ctor) |])

let assert_eq name got expected =
  if got <> expected then
    failwith (Printf.sprintf "FAIL %s: got %S expected %S" name got expected)

let assert_true name cond =
  if not cond then failwith ("FAIL " ^ name)

let query host sel =
  Js.Opt.to_option (host##querySelector (Js.string sel))

let fail_report body msg =
  let report = document##createElement (Js.string "pre") in
  report##setAttribute (Js.string "id") (Js.string "test-result");
  report##.textContent := Js.some (Js.string ("FAIL: " ^ msg));
  Dom.appendChild body report;
  Console.console##error (Js.string ("svg_ns_test: FAIL: " ^ msg))

let pass body =
  let report = document##createElement (Js.string "pre") in
  report##setAttribute (Js.string "id") (Js.string "test-result");
  report##.textContent := Js.some (Js.string "PASS");
  Dom.appendChild body report;
  Console.console##log (Js.string "svg_ns_test: PASS")

module Icon = struct
  type state = unit
  type msg = unit
  type emits = unit

  let props : msg Props.t = []

  let init ~dispatch:_ = ((), Cmd.none)

  let update state _ = (state, Cmd.none)

  let view _state _dispatch _children : msg Html.node =
    let open Html in
    element
      ~attrs:[ ("class", "dg-table-filter-icon") ]
      ~children:
        [
          element
            ~attrs:
              [
                ("viewBox", "0 0 16 16");
                ("aria-hidden", "true");
                ("class", "sort-icon");
              ]
            ~children:
              [
                element
                  ~attrs:
                    [
                      ("d", "M5 3v10M5 3 3 5");
                      ("fill", "none");
                      ("stroke", "currentColor");
                    ]
                  "path" ();
              ]
            "svg" ();
        ]
      "span" ()
end

let () =
  Well_web.component ~module_:(module Icon) ~tag_name:"test-svg-icon" ()

let run_tests () =
  let body = document##.body in
  try
    let svg = Bridge.create_element "svg" in
    let path = Bridge.create_element "path" in
    let div = Bridge.create_element "div" in
    assert_eq "Bridge svg ns" (ns_of svg) svg_ns;
    assert_eq "Bridge path ns" (ns_of path) svg_ns;
    assert_eq "Bridge path localName" (local_name path) "path";
    assert_true "Bridge path SVGPathElement" (instanceof path "SVGPathElement");
    assert_true "Bridge svg SVGElement" (instanceof svg "SVGElement");
    assert_eq "Bridge div ns" (ns_of div) html_ns;
    assert_true "Bridge div not SVGElement" (not (instanceof div "SVGElement"));
    let host : Dom_html.element Js.t =
      Js.Unsafe.coerce (document##createElement (Js.string "test-svg-icon"))
    in
    Dom.appendChild body host;
    schedule 40 (fun () ->
        try
          let svg_el =
            match query host "svg.sort-icon" with
            | Some e -> e
            | None -> failwith "TEA blit missing svg.sort-icon"
          in
          let path_el =
            match query host "svg path" with
            | Some e -> e
            | None -> failwith "TEA blit missing path"
          in
          assert_eq "blit svg ns" (ns_of svg_el) svg_ns;
          assert_eq "blit path ns" (ns_of path_el) svg_ns;
          assert_true "blit path SVGPathElement"
            (instanceof path_el "SVGPathElement");
          assert_true "blit svg SVGSVGElement" (instanceof svg_el "SVGSVGElement");
          (match
             Bridge.get_attribute (Obj.magic svg_el : Bridge.element)
               ~name:"viewBox"
           with
           | Some vb -> assert_eq "blit viewBox" vb "0 0 16 16"
           | None -> failwith "blit svg missing viewBox");
          (match
             Bridge.get_attribute (Obj.magic path_el : Bridge.element) ~name:"d"
           with
           | Some d -> assert_eq "blit path d" d "M5 3v10M5 3 3 5"
           | None -> failwith "blit path missing d");
          pass body
        with Failure msg -> fail_report body msg)
  with Failure msg -> fail_report body msg

let () = schedule 0 run_tests
