open Js_of_ocaml
open Well_web

module SlotHost = struct
  type state = { ticks : int }
  type msg = Tick
  type emits = unit

  let props : msg Props.t = []
  let init ~dispatch:_ = ({ ticks = 0 }, Cmd.none)
  let update state = function Tick -> ({ ticks = state.ticks + 1 }, Cmd.none)

  let view : 'a. state -> (msg -> unit) -> 'a Html.node -> msg Html.node =
   fun state _dispatch children ->
    let open Html in
    let children : msg Html.node = Obj.magic children in
    element
      ~attrs:[ ("class", "wrap") ]
      ~children:
        [
          element
            ~attrs:[ ("class", "toolbar") ]
            ~children:[ children ]
            "div" ();
          element
            ~attrs:[ ("class", "body") ]
            ~text:("body-" ^ string_of_int state.ticks)
            "div" ();
          element
            ~handlers:[ ("click", on_click Tick) ]
            ~attrs:[ ("class", "tick") ]
            ~text:"tick"
            "button" ();
        ]
      "div" ()
end

module IgnoreHost = struct
  type state = unit
  type msg = unit
  type emits = unit

  let props : msg Props.t = []
  let init ~dispatch:_ = ((), Cmd.none)
  let update state _ = (state, Cmd.none)

  let view _state _dispatch _children : msg Html.node =
    let open Html in
    element ~attrs:[ ("class", "ignore-root") ] ~text:"only-root" "div" ()
end

let () =
  Well_web.component ~module_:(module SlotHost) ~tag_name:"test-slot-host" ();
  Well_web.component ~module_:(module IgnoreHost) ~tag_name:"test-ignore-host"
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

let same_node (a : Dom_html.element Js.t) (b : Dom_html.element Js.t) =
  a == b

let pass body =
  let report = document##createElement (Js.string "pre") in
  report##setAttribute (Js.string "id") (Js.string "test-result");
  report##.textContent := Js.some (Js.string "PASS");
  Dom.appendChild body report;
  Console.console##log (Js.string "projection_test: PASS")

let run_tests () =
  let body = document##.body in
  let host : Dom_html.element Js.t =
    Js.Unsafe.coerce (document##createElement (Js.string "test-slot-host"))
  in
  let btn : Dom_html.element Js.t =
    Js.Unsafe.coerce (document##createElement (Js.string "button"))
  in
  btn##setAttribute (Js.string "id") (Js.string "proj-btn");
  btn##.textContent := Js.some (Js.string "Go");
  Dom.appendChild host btn;
  Dom.appendChild body host;
  let ignore_host : Dom_html.element Js.t =
    Js.Unsafe.coerce
      (document##createElement (Js.string "test-ignore-host"))
  in
  let orphan : Dom_html.element Js.t =
    Js.Unsafe.coerce (document##createElement (Js.string "button"))
  in
  orphan##setAttribute (Js.string "id") (Js.string "orphan-btn");
  Dom.appendChild ignore_host orphan;
  Dom.appendChild body ignore_host;
  schedule 50 (fun () ->
      (match query host "#proj-btn" with
       | None -> failwith "FAIL: projected button not under host"
       | Some found ->
         assert_true "same node identity" (same_node found btn);
         (match
            Js.Opt.to_option (found##closest (Js.string ".toolbar"))
          with
          | None -> failwith "FAIL: projected button not under .toolbar"
          | Some _ -> ());
         assert_true "slot wrapper present"
           (match query host "[data-well-slot]" with
            | Some _ -> true
            | None -> false));
      assert_eq "body text" (text_of (match query host ".body" with
        | Some e -> e
        | None -> failwith "FAIL: missing .body")) "body-0";
      assert_true "orphan not in document under ignore host"
        (match query ignore_host "#orphan-btn" with
         | None -> true
         | Some _ -> false);
      assert_eq "ignore root visible"
        (text_of
           (match query ignore_host ".ignore-root" with
            | Some e -> e
            | None -> failwith "FAIL: missing ignore-root"))
        "only-root";
      (match query host ".tick" with
       | None -> failwith "FAIL: missing tick"
       | Some tick ->
         ignore
           (Js.Unsafe.meth_call tick "click" [||]));
      schedule 50 (fun () ->
          assert_eq "body after tick"
            (text_of
               (match query host ".body" with
                | Some e -> e
                | None -> failwith "FAIL: missing .body after tick"))
            "body-1";
          (match query host "#proj-btn" with
           | None -> failwith "FAIL: projected button lost after re-render"
           | Some found ->
             assert_true "identity after re-render" (same_node found btn));
          pass body))

let () =
  schedule 0 run_tests
