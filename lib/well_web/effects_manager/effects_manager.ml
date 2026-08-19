[@@@warning "-27-69"]

type 'a envelope = {
  instance_id : string;
  payload : 'a;
}

let publish_msg ~instance_id msg_obj =
  Message_bus.publish ~topic:"msg"
    (Message_bus.create ~instance_id (Obj.obj (Obj.repr msg_obj)))

let run_one ~instance_id (cmd : Component_access.cmd) =
  let typed : (Obj.t, Obj.t) Component_access.Cmd.t =
    Obj.obj (Obj.repr cmd)
  in
  Component_access.Cmd.iter typed
    ~none:(fun () -> ())
    ~msg:(fun m -> publish_msg ~instance_id m)
    ~emit:(fun e ->
      try
        let host = Component_access.dom_element ~instance_id in
        Bridge.dispatch_event host ~name:"well-emit" ~payload:(Bridge.inject e)
      with _ -> ())
    ~emit_dom:(fun ~name ~detail ->
      try
        let host = Component_access.dom_element ~instance_id in
        let payload =
          match detail with
          | None -> Bridge.inject Js_of_ocaml.Js.null
          | Some d -> Bridge.inject (Obj.obj d)
        in
        Bridge.dispatch_event host ~name ~payload
      with _ -> ())
    ~focus:(fun selector ->
      let cb _ =
        try
          let host = Component_access.dom_element ~instance_id in
          match Bridge.query_selector_in host selector with
          | None -> ()
          | Some el -> Bridge.focus el
        with _ -> ()
      in
      Bridge.request_animation_frame (Bridge.fn1 cb))
    ~perform:(fun f ->
      let dispatch (m : Obj.t) = publish_msg ~instance_id m in
      try f ~dispatch with _ -> ())
    ~send:(fun ~addr packed ->
      match Component_access.dispatch_of_addr ~addr with
      | None -> ()
      | Some dispatch ->
        try dispatch (Obj.obj packed : Component_access.msg) with _ -> ())

let handle_cmd ~instance_id envelope =
  let cmd : Component_access.cmd =
    try
      let env : _ Message_bus.envelope = Obj.magic envelope in
      (Obj.magic (Message_bus.payload env) : Component_access.cmd)
    with _ ->
      try (Obj.magic envelope.payload : Component_access.cmd)
      with _ -> (Obj.magic Component_access.Cmd.none : Component_access.cmd)
  in
  run_one ~instance_id cmd
