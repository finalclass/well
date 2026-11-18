open Js_of_ocaml
open Well_web

let document = Dom_html.window##.document

let schedule delay_ms f =
  ignore
    (Js.Unsafe.meth_call Dom_html.window "setTimeout"
       [|
         Js.Unsafe.inject (Js.wrap_callback f);
         Js.Unsafe.inject delay_ms;
       |])

let first_text = {|a "b" -> c & <d>|}
let second_text = {|x "y" -> z & <w>|}

let report body result =
  let pre = document##createElement (Js.string "pre") in
  pre##setAttribute (Js.string "id") (Js.string "test-result");
  pre##.textContent := Js.some (Js.string result);
  Dom.appendChild body pre;
  Console.console##log (Js.string ("text_escape_test: " ^ result))

let text_of host sel =
  match Js.Opt.to_option (host##querySelector (Js.string sel)) with
  | Some el ->
    Js.Opt.case el##.textContent (fun () -> "") Js.to_string
  | None -> failwith ("missing " ^ sel)

let assert_eq name got expected =
  if got <> expected then
    failwith (Printf.sprintf "%s: got %S expected %S" name got expected)

module Label = struct
  type state = string
  type msg = Swap
  type emits = unit

  let props : msg Props.t = []

  let init ~dispatch:_ = (first_text, Cmd.none)

  let update _ Swap = (second_text, Cmd.none)

  let view state _dispatch _children : msg Html.node =
    let open Html in
    element
      ~children:
        [
          element ~attrs:[ ("class", "label") ] ~children:[ txt state ] "span" ();
          element ~attrs:[ ("class", "swap") ] ~handlers:[ ("click", Msg Swap) ]
            ~children:[ txt "swap" ] "button" ();
        ]
      "div" ()
end

let () =
  Well_web.component ~module_:(module Label) ~tag_name:"test-text-label" ()

let run_tests () =
  let body = document##.body in
  let host : Dom_html.element Js.t =
    Js.Unsafe.coerce (document##createElement (Js.string "test-text-label"))
  in
  Dom.appendChild body host;
  schedule 40 (fun () ->
      try
        assert_eq "blit text" (text_of host ".label") first_text;
        (match Js.Opt.to_option (host##querySelector (Js.string ".swap")) with
         | Some button -> (Js.Unsafe.coerce button : Dom_html.element Js.t)##click
         | None -> failwith "missing .swap");
        schedule 40 (fun () ->
            try
              assert_eq "sync text" (text_of host ".label") second_text;
              report body "PASS"
            with Failure msg -> report body ("FAIL: " ^ msg))
      with Failure msg -> report body ("FAIL: " ^ msg))

let () = schedule 0 run_tests
