open Js_of_ocaml

let set_result s =
  Js.Unsafe.set Js.Unsafe.global (Js.string "__W6_RESULT") (Js.string s)

let () =
  let req = Contract_data_browser.Task_access.ListReq.make ~limit:100L () in
  Task_manager.Proxy.list req ~on_done:(function
    | Ok (res : Contract_data_browser.Task_manager.TaskListRes.t) ->
      set_result (Printf.sprintf "ok:%d" (List.length res.tasks))
    | Error e -> set_result ("error:" ^ e))