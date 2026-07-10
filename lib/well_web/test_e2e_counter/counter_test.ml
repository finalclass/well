(* E2E test dla runtime well.web: Counter komponent.

   Udowadnia, że cała architektura (Bridge, MessageBus, StateAccess,
   ComponentAccess, LoopManager, Rendering) działa razem end-to-end w
   przeglądarce. Pętla: DOM click → Rendering handler → publish "msg" →
   LoopManager.handle_msg → ComponentAccess.update → StateAccess.persist →
   ComponentAccess.render_view → publish "vdom" → Rendering.sync → DOM.

   Counter: div > [button "−", span count, button "+", button reset].
   Init = 0, Increment/Decrement = ±1, Reset = 0. *)

open Well_web

module Counter = struct
  type state = { count : int }
  type msg = Increment | Decrement | Reset
  type emits = Changed of int

  let props : msg Props.t = []

  let init ~dispatch:_ = ({ count = 0 }, Cmd.none)

  let update state : msg -> state * (msg, emits) Cmd.t = function
    | Increment -> ({ count = state.count + 1 }, Cmd.emit (Changed (state.count + 1)))
    | Decrement -> ({ count = state.count - 1 }, Cmd.emit (Changed (state.count - 1)))
    | Reset -> ({ count = 0 }, Cmd.emit (Changed 0))

  let view state dispatch _children : msg Html.node =
    let open Html in
    let count_txt = string_of_int state.count in
    let _ = dispatch in
    element
      ~attrs:[ ("style", "display:flex; gap:8px; align-items:center;") ]
      ~children:[
        element
          ~handlers:[ ("click", on_click Decrement) ]
          ~text:"-"
          "button" ();
        element
          ~attrs:[ ("style", "font-family:monospace; width:32px; text-align:center;")
                 ; ("class", "count") ]
          ~text:count_txt
          "span" ();
        element
          ~handlers:[ ("click", on_click Increment) ]
          ~text:"+"
          "button" ();
        element
          ~handlers:[ ("click", on_click Reset) ]
          ~text:"reset"
          "button" ();
      ]
      "div" ()
end

let () =
  Well_web.component ~module_:(module Counter) ~tag_name:"test-counter" ()
