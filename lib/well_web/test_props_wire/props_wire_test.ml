open Js_of_ocaml
open Well_web

module LabelBox = struct
  type state = {
    label : string;
    flagged : bool;
    items : string list;
    updates : int;
  }

  type msg =
    | Set_label of string
    | Set_flagged of bool
    | Set_items of string list

  type emits = unit

  let props : msg Props.t =
    [
      Props.string "label" ~default:"" ~on:(fun v -> Set_label v) ();
      Props.bool "flagged" ~default:false ~on:(fun v -> Set_flagged v) ();
      Props.list "items" ~eq:String.equal ~on:(fun v -> Set_items v);
    ]

  let init ~dispatch:_ =
    ({ label = ""; flagged = false; items = []; updates = 0 }, Cmd.none)

  let update state = function
    | Set_label label ->
      ({ state with label; updates = state.updates + 1 }, Cmd.none)
    | Set_flagged flagged ->
      ({ state with flagged; updates = state.updates + 1 }, Cmd.none)
    | Set_items items ->
      ({ state with items; updates = state.updates + 1 }, Cmd.none)

  let view state _dispatch _children : msg Html.node =
    let open Html in
    let items_txt = String.concat "," state.items in
    let flag_txt = if state.flagged then "yes" else "no" in
    element
      ~attrs:[ ("class", "root") ]
      ~children:
        [
          element ~attrs:[ ("class", "label") ] ~text:state.label "span" ();
          element ~attrs:[ ("class", "flag") ] ~text:flag_txt "span" ();
          element ~attrs:[ ("class", "items") ] ~text:items_txt "span" ();
          element
            ~attrs:[ ("class", "updates") ]
            ~text:(string_of_int state.updates)
            "span"
            ();
          element
            ~attrs:[ ("class", "ctl") ]
            ~bool_attrs:
              (if state.flagged then [ "disabled"; "selected" ] else [])
            ~text:"ctl"
            "button"
            ();
        ]
      "div" ()
end

module EmptyBox = struct
  type state = unit
  type msg = unit
  type emits = unit

  let props : msg Props.t = []
  let init ~dispatch:_ = ((), Cmd.none)
  let update state _ = (state, Cmd.none)

  let view _state _dispatch _children : msg Html.node =
    let open Html in
    element ~attrs:[ ("class", "empty-root") ] ~text:"ok" "div" ()
end

let () =
  Well_web.component ~module_:(module LabelBox) ~tag_name:"test-label-box" ();
  Well_web.component ~module_:(module EmptyBox) ~tag_name:"test-empty-box" ()

let document = Dom_html.window##.document

let text_of (el : Dom_html.element Js.t) : string =
  match Js.Opt.to_option el##.textContent with
  | None -> ""
  | Some s -> Js.to_string s

let query root sel =
  Js.Opt.to_option (root##querySelector (Js.string sel))

let assert_true name cond =
  if not cond then failwith ("FAIL: " ^ name)

let assert_eq name got expected =
  if got <> expected then
    failwith
      (Printf.sprintf "FAIL: %s got=%S expected=%S" name got expected)

let schedule delay_ms f =
  ignore
    (Js.Unsafe.meth_call Dom_html.window "setTimeout"
       [|
         Js.Unsafe.inject (Js.wrap_callback f);
         Js.Unsafe.inject delay_ms;
       |])

let js_string_array (xs : string list) : Js.Unsafe.any =
  let arr = new%js Js.array_empty in
  List.iter (fun s -> ignore (arr##push (Js.string s))) xs;
  Js.Unsafe.inject arr

let set_js_prop el name value =
  Js.Unsafe.set el (Js.string name) value

let define_own_data_prop el name value =
  let _ : Js.Unsafe.any =
    Js.Unsafe.fun_call
      (Js.Unsafe.js_expr
         {|function (el, name, value) {
            Object.defineProperty(el, name, {
              value: value,
              writable: true,
              enumerable: true,
              configurable: true
            });
          }|})
      [|
        Js.Unsafe.inject el; Js.Unsafe.inject (Js.string name); value;
      |]
  in
  ()

let require_q host sel name =
  match query host sel with
  | Some e -> e
  | None -> failwith ("FAIL: missing " ^ name)

let pass body =
  let report = document##createElement (Js.string "pre") in
  report##setAttribute (Js.string "id") (Js.string "test-result");
  report##.textContent := Js.some (Js.string "PASS");
  Dom.appendChild body report;
  Console.console##log (Js.string "props_wire_test: PASS")

let run_tests () =
  let body = document##.body in
  let empty : Dom_html.element Js.t =
    Js.Unsafe.coerce (document##createElement (Js.string "test-empty-box"))
  in
  Dom.appendChild body empty;
  let pre_host : Dom_html.element Js.t =
    Js.Unsafe.coerce (document##createElement (Js.string "test-label-box"))
  in
  define_own_data_prop pre_host "items"
    (js_string_array [ "pre"; "upgrade" ]);
  Dom.appendChild body pre_host;
  let host : Dom_html.element Js.t =
    Js.Unsafe.coerce (document##createElement (Js.string "test-label-box"))
  in
  host##setAttribute (Js.string "label") (Js.string "hello");
  host##setAttribute (Js.string "flagged") (Js.string "true");
  Dom.appendChild body host;
  schedule 40 (fun () ->
      (match query empty ".empty-root" with
       | None -> failwith "FAIL: props=[] empty box did not connect"
       | Some e -> assert_eq "empty box text" (text_of e) "ok");
      assert_eq "pre-upgrade JS array hydrate"
        (text_of (require_q pre_host ".items" ".items"))
        "pre,upgrade";
      set_js_prop pre_host "items" (js_string_array [ "live"; "after" ]);
      schedule 40 (fun () ->
          assert_eq "live property after pre-upgrade transfer"
            (text_of (require_q pre_host ".items" ".items"))
            "live,after";
          assert_eq "attr hydrate label"
            (text_of (require_q host ".label" ".label"))
            "hello";
          assert_eq "attr hydrate flagged"
            (text_of (require_q host ".flag" ".flag"))
            "yes";
          let ctl = require_q host ".ctl" ".ctl" in
          assert_true "bool_attrs disabled present"
            (Js.to_bool (ctl##hasAttribute (Js.string "disabled")));
          assert_true "bool_attrs selected present"
            (Js.to_bool (ctl##hasAttribute (Js.string "selected")));
          assert_true "IDL disabled === true"
            (Js.to_bool (Js.Unsafe.get ctl (Js.string "disabled")));
          Bridge.assign_js_property
            (Obj.magic host : Bridge.element)
            ~name:"items"
            ~value:(Bridge.inject [ "a"; "b"; "c" ]);
          schedule 40 (fun () ->
              assert_eq "property OCaml list set"
                (text_of (require_q host ".items" ".items"))
                "a,b,c";
              set_js_prop host "items" (js_string_array [ "x"; "y" ]);
              schedule 40 (fun () ->
                  assert_eq "property JS array set"
                    (text_of (require_q host ".items" ".items"))
                    "x,y";
                  host##setAttribute (Js.string "label") (Js.string "world");
                  schedule 40 (fun () ->
                      assert_eq "attr change after connect"
                        (text_of (require_q host ".label" ".label"))
                        "world";
                      let updates_before =
                        text_of (require_q host ".updates" ".updates")
                      in
                      host##setAttribute (Js.string "label")
                        (Js.string "world");
                      schedule 40 (fun () ->
                          assert_eq "equal skip identical label"
                            (text_of (require_q host ".updates" ".updates"))
                            updates_before;
                          host##removeAttribute (Js.string "label");
                          host##removeAttribute (Js.string "flagged");
                          schedule 40 (fun () ->
                              assert_eq "attr removal → default label"
                                (text_of (require_q host ".label" ".label"))
                                "";
                              assert_eq "attr removal → default flagged"
                                (text_of (require_q host ".flag" ".flag"))
                                "no";
                              let ctl = require_q host ".ctl" ".ctl" in
                              assert_true "bool_attrs disabled removed"
                                (not
                                   (Js.to_bool
                                      (ctl##hasAttribute
                                         (Js.string "disabled"))));
                              assert_true "bool_attrs selected removed"
                                (not
                                   (Js.to_bool
                                      (ctl##hasAttribute
                                         (Js.string "selected"))));
                              assert_true "IDL disabled === false"
                                (not
                                   (Js.to_bool
                                      (Js.Unsafe.get ctl
                                         (Js.string "disabled"))));
                              host##setAttribute (Js.string "unknown-x")
                                (Js.string "nope");
                              schedule 40 (fun () ->
                                  assert_eq "unknown attr ignored"
                                    (text_of
                                       (require_q host ".label" ".label"))
                                    "";
                                  (match
                                     Bridge.get_parent
                                       (Obj.magic host : Bridge.element)
                                   with
                                   | Some p ->
                                     Bridge.remove_child ~parent:p
                                       ~child:
                                         (Obj.magic host : Bridge.element)
                                   | None -> ());
                                  schedule 40 (fun () ->
                                      Dom.appendChild body host;
                                      schedule 40 (fun () ->
                                          ignore
                                            (require_q host ".label"
                                               ".label reconnect");
                                          pass body))))))))))

let () = schedule 0 run_tests
