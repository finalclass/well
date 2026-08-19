open Js_of_ocaml
open Well_web

module Docs_table = struct
  type state = { loads : int }
  type msg = Reload
  type emits = unit

  let send ~addr (m : msg) = Cmd.send ~addr m

  let props : msg Props.t = []

  let load state = { loads = state.loads + 1 }

  let init ~dispatch:_ = (load { loads = 0 }, Cmd.none)

  let update state = function Reload -> (load state, Cmd.none)

  let view state _dispatch _children : msg Html.node =
    let open Html in
    element
      ~attrs:[ ("class", "loads") ]
      ~text:(string_of_int state.loads)
      "span"
      ()
end

module Project = struct
  type state = { show_docs : bool }

  type msg =
    | Mass_files_closed
    | Reload_other
    | Send_missing
    | Hide_docs
    | Show_docs

  type emits = unit

  let props : msg Props.t = []
  let init ~dispatch:_ = ({ show_docs = true }, Cmd.none)

  let update state = function
    | Mass_files_closed ->
      (state, Docs_table.send ~addr:"project-docs" Reload)
    | Reload_other -> (state, Docs_table.send ~addr:"other-docs" Reload)
    | Send_missing -> (state, Docs_table.send ~addr:"no-such-loop" Reload)
    | Hide_docs -> ({ show_docs = false }, Cmd.none)
    | Show_docs -> ({ show_docs = true }, Cmd.none)

  let view state _dispatch _children : msg Html.node =
    let open Html in
    let docs_slot =
      if state.show_docs then
        element
          ~attrs:[ ("class", "docs-slot") ]
          ~children:
            [
              element "test-docs-table"
                ~addr:"project-docs"
                ~attrs:[ ("class", "docs") ]
                ();
            ]
          "div"
          ()
      else element ~attrs:[ ("class", "docs-slot") ] "div" ()
    in
    element
      ~attrs:[ ("class", "project") ]
      ~children:
        [
            docs_slot;
            element "test-docs-table"
              ~addr:"other-docs"
              ~attrs:[ ("class", "other") ]
              ();
            element
              ~attrs:[ ("class", "close-mass-files") ]
              ~handlers:[ ("click", on_click Mass_files_closed) ]
              ~text:"close"
              "button"
              ();
            element
              ~attrs:[ ("class", "reload-other") ]
              ~handlers:[ ("click", on_click Reload_other) ]
              ~text:"other"
              "button"
              ();
            element
              ~attrs:[ ("class", "send-missing") ]
              ~handlers:[ ("click", on_click Send_missing) ]
              ~text:"missing"
              "button"
              ();
            element
              ~attrs:[ ("class", "hide-docs") ]
              ~handlers:[ ("click", on_click Hide_docs) ]
              ~text:"hide"
              "button"
              ();
            element
              ~attrs:[ ("class", "show-docs") ]
              ~handlers:[ ("click", on_click Show_docs) ]
              ~text:"show"
              "button"
              ();
          ]
      "div"
      ()
end

let () =
  Well_web.component ~module_:(module Docs_table) ~tag_name:"test-docs-table"
    ();
  Well_web.component ~module_:(module Project) ~tag_name:"test-project" ()

let document = Dom_html.window##.document

let text_of (el : Dom_html.element Js.t) : string =
  match Js.Opt.to_option el##.textContent with
  | None -> ""
  | Some s -> Js.to_string s

let query root sel =
  Js.Opt.to_option (root##querySelector (Js.string sel))

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

let click host sel =
  match query host sel with
  | None -> failwith ("FAIL: missing " ^ sel)
  | Some el -> ignore (Js.Unsafe.meth_call el "click" [||])

let loads host sel =
  match query host sel with
  | None -> failwith ("FAIL: missing " ^ sel)
  | Some el -> text_of el

let require_absent host sel name =
  match query host sel with
  | None -> ()
  | Some _ -> failwith ("FAIL: expected absent " ^ name)

let pass body =
  let report = document##createElement (Js.string "pre") in
  report##setAttribute (Js.string "id") (Js.string "test-result");
  report##.textContent := Js.some (Js.string "PASS");
  Dom.appendChild body report;
  Console.console##log (Js.string "addr_send_test: PASS")

let dummy_el () : Bridge.element =
  Obj.magic (document##createElement (Js.string "div"))

let run_registry () =
  let hits_a = ref [] in
  let hits_b = ref [] in
  let id_a =
    Component_access.create_instance ~tag_name:"test-docs-table"
      ~dom_element:(dummy_el ())
  in
  let id_b =
    Component_access.create_instance ~tag_name:"test-docs-table"
      ~dom_element:(dummy_el ())
  in
  ignore
    (Component_access.init_state ~instance_id:id_a ~dispatch:(fun m ->
       hits_a := m :: !hits_a));
  ignore
    (Component_access.init_state ~instance_id:id_b ~dispatch:(fun m ->
       hits_b := m :: !hits_b));
  Component_access.bind_addr ~instance_id:id_a ~addr:"reg-a";
  Component_access.bind_addr ~instance_id:id_b ~addr:"reg-b";
  (match Component_access.dispatch_of_addr ~addr:"reg-a" with
   | Some d -> d (Obj.magic Docs_table.Reload)
   | None -> failwith "FAIL: registry missing reg-a");
  (match Component_access.dispatch_of_addr ~addr:"reg-b" with
   | Some d -> d (Obj.magic Docs_table.Reload)
   | None -> failwith "FAIL: registry missing reg-b");
  (match !hits_a, !hits_b with
   | [ _ ], [ _ ] -> ()
   | _ -> failwith "FAIL: registry two addrs mixed");
  (match Component_access.dispatch_of_addr ~addr:"reg-missing" with
   | None -> ()
   | Some _ -> failwith "FAIL: missing addr bound");
  Component_access.destroy_instance ~instance_id:id_a;
  (match Component_access.dispatch_of_addr ~addr:"reg-a" with
   | None -> ()
   | Some _ -> failwith "FAIL: addr still bound after destroy");
  (match Component_access.dispatch_of_addr ~addr:"reg-b" with
   | Some d -> d (Obj.magic Docs_table.Reload)
   | None -> failwith "FAIL: other addr dropped on destroy");
  (match !hits_b with
   | [ _; _ ] -> ()
   | _ -> failwith "FAIL: remaining loop not hit");
  Component_access.destroy_instance ~instance_id:id_b

let run_tests () =
  run_registry ();
  let body = document##.body in
  let host : Dom_html.element Js.t =
    Js.Unsafe.coerce (document##createElement (Js.string "test-project"))
  in
  Dom.appendChild body host;
  schedule 40 (fun () ->
      assert_eq "docs initial load"
        (loads host ".docs .loads")
        "1";
      assert_eq "other initial load"
        (loads host ".other .loads")
        "1";
      click host ".close-mass-files";
      schedule 40 (fun () ->
          assert_eq "send hits project-docs"
            (loads host ".docs .loads")
            "2";
          assert_eq "other unchanged after docs send"
            (loads host ".other .loads")
            "1";
          click host ".reload-other";
          schedule 40 (fun () ->
              assert_eq "send hits other-docs"
                (loads host ".other .loads")
                "2";
              assert_eq "docs unchanged after other send"
                (loads host ".docs .loads")
                "2";
              click host ".send-missing";
              schedule 40 (fun () ->
                  assert_eq "missing addr leaves docs"
                    (loads host ".docs .loads")
                    "2";
                  assert_eq "missing addr leaves other"
                    (loads host ".other .loads")
                    "2";
                  click host ".hide-docs";
                  schedule 40 (fun () ->
                      require_absent host ".docs" "docs after hide";
                      assert_eq "other still mounted"
                        (loads host ".other .loads")
                        "2";
                      click host ".close-mass-files";
                      schedule 40 (fun () ->
                          assert_eq "send after unbind leaves other"
                            (loads host ".other .loads")
                            "2";
                          click host ".show-docs";
                          schedule 40 (fun () ->
                              assert_eq "docs remount starts at load"
                                (loads host ".docs .loads")
                                "1";
                              click host ".close-mass-files";
                              schedule 40 (fun () ->
                                  assert_eq "send after remount"
                                    (loads host ".docs .loads")
                                    "2";
                                  assert_eq "other still 2"
                                    (loads host ".other .loads")
                                    "2";
                                  pass body))))))))

let () = schedule 0 run_tests
