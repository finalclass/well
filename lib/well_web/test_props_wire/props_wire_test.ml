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

module PayloadBox = struct
  type payload = { x : int }

  type state = {
    payload : payload option;
    updates : int;
  }

  type msg = Set_payload of payload
  type emits = unit

  let parse_x_json s =
    try
      let s = String.trim s in
      if s = "" || s.[0] <> '{' then None
      else
        let colon = String.index s ':' in
        let rest =
          String.trim
            (String.sub s (colon + 1) (String.length s - colon - 1))
        in
        let digits =
          if rest <> "" && rest.[String.length rest - 1] = '}' then
            String.trim (String.sub rest 0 (String.length rest - 1))
          else rest
        in
        Some { x = int_of_string digits }
    with _ -> None

  let of_js v =
    try Some { x = Bridge.get_int v "x" } with _ -> None

  let props : msg Props.t =
    [
      Props.attr_or_prop "payload" ~of_string:parse_x_json ~of_js
        ~eq:(fun a b -> a.x = b.x)
        ~on:(fun v -> Set_payload v)
        ();
    ]

  let init ~dispatch:_ = ({ payload = None; updates = 0 }, Cmd.none)

  let update state = function
    | Set_payload payload ->
      ({ payload = Some payload; updates = state.updates + 1 }, Cmd.none)

  let view state _dispatch _children : msg Html.node =
    let open Html in
    let payload_txt =
      match state.payload with
      | None -> "none"
      | Some p -> string_of_int p.x
    in
    element
      ~attrs:[ ("class", "payload-root") ]
      ~children:
        [
          element
            ~attrs:[ ("class", "payload") ]
            ~text:payload_txt
            "span"
            ();
          element
            ~attrs:[ ("class", "payload-updates") ]
            ~text:(string_of_int state.updates)
            "span"
            ();
        ]
      "div"
      ()
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
  Well_web.component ~module_:(module EmptyBox) ~tag_name:"test-empty-box" ();
  Well_web.component
    ~module_:(module PayloadBox)
    ~tag_name:"test-payload-box"
    ()

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

let js_payload_x (n : int) : Js.Unsafe.any =
  Js.Unsafe.fun_call
    (Js.Unsafe.js_expr {|function (n) { return { x: n }; }|})
    [| Js.Unsafe.inject (float_of_int n) |]

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
  let payload_attr : Dom_html.element Js.t =
    Js.Unsafe.coerce
      (document##createElement (Js.string "test-payload-box"))
  in
  payload_attr##setAttribute (Js.string "payload") (Js.string "{\"x\":1}");
  Dom.appendChild body payload_attr;
  let payload_bad : Dom_html.element Js.t =
    Js.Unsafe.coerce
      (document##createElement (Js.string "test-payload-box"))
  in
  payload_bad##setAttribute (Js.string "payload") (Js.string "not-json");
  Dom.appendChild body payload_bad;
  let payload_prop : Dom_html.element Js.t =
    Js.Unsafe.coerce
      (document##createElement (Js.string "test-payload-box"))
  in
  Dom.appendChild body payload_prop;
  let payload_pre : Dom_html.element Js.t =
    Js.Unsafe.coerce
      (document##createElement (Js.string "test-payload-box"))
  in
  define_own_data_prop payload_pre "payload" (js_payload_x 4);
  Dom.appendChild body payload_pre;
  schedule 40 (fun () ->
      (match query empty ".empty-root" with
       | None -> failwith "FAIL: props=[] empty box did not connect"
       | Some e -> assert_eq "empty box text" (text_of e) "ok");
      assert_eq "attr_or_prop JSON attr hydrate"
        (text_of (require_q payload_attr ".payload" ".payload"))
        "1";
      assert_eq "attr_or_prop invalid JSON mounts"
        (text_of (require_q payload_bad ".payload" ".payload"))
        "none";
      assert_eq "attr_or_prop JS object pre-upgrade hydrate"
        (text_of (require_q payload_pre ".payload" ".payload"))
        "4";
      set_js_prop payload_prop "payload" (js_payload_x 3);
      set_js_prop payload_attr "payload" (js_payload_x 9);
      assert_eq "pre-upgrade JS array hydrate"
        (text_of (require_q pre_host ".items" ".items"))
        "pre,upgrade";
      set_js_prop pre_host "items" (js_string_array [ "live"; "after" ]);
      schedule 40 (fun () ->
          assert_eq "live property after pre-upgrade transfer"
            (text_of (require_q pre_host ".items" ".items"))
            "live,after";
          assert_eq "attr_or_prop JS object property hydrate"
            (text_of (require_q payload_prop ".payload" ".payload"))
            "3";
          assert_eq "attr_or_prop property overwrites attr"
            (text_of (require_q payload_attr ".payload" ".payload"))
            "9";
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
