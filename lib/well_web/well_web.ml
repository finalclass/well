[@@@warning "-69"]

module type COMPONENT = Component_access.COMPONENT
module Vdom = Html
module Props = Component_access.Props
module Cmd = Component_access.Cmd
type emits = Component_access.emits

type 'a envelope = {
  instance_id : string;
  payload : 'a;
}

module Instance_table = Hashtbl.Make (struct
  type t = Bridge.element
  let hash = Hashtbl.hash
  let equal a b = a == b
end)

type instance_record = {
  instance_id : string;
  state_key : unit ref;
  sub_msg : string;
}

let instances : instance_record Instance_table.t = Instance_table.create 64

let component ~module_ ~tag_name ?(shadow_dom = false) () =
  Component_access.register_type ~module_ ~tag_name ~shadow_dom ();
  Rendering.init ();
  let on_connect dom_element =
    let instance_id =
      Component_access.create_instance ~tag_name ~dom_element
    in
    let state_env = Component_access.init_state ~instance_id in
    let state_key = Component_access.state_key ~instance_id in
    let initial_state : Component_access.state =
      (Obj.magic state_env : Component_access.state envelope).payload
    in
    State_access.persist state_key initial_state;
    let sub_msg =
      Message_bus.subscribe ~topic:"msg"
        (fun env ->
          Loop_manager.handle_msg
            ~instance_id:(Message_bus.instance_id env)
            (Obj.magic env))
    in
    let initial_vdom_env =
      let ca_env : Component_access.state Component_access.envelope =
        Obj.magic state_env
      in
      Component_access.render_view ~instance_id ca_env
    in
    let vdom_bus : _ Message_bus.envelope = Obj.magic initial_vdom_env in
    Message_bus.publish ~topic:"vdom" vdom_bus;
    Instance_table.replace instances dom_element
      { instance_id; state_key; sub_msg }
  in
  let on_disconnect dom_element =
    match Instance_table.find_opt instances dom_element with
    | None -> ()
    | Some record ->
      Component_access.destroy_instance ~instance_id:record.instance_id;
      State_access.destroy record.state_key;
      Message_bus.unsubscribe ~subscription_id:record.sub_msg;
      Instance_table.remove instances dom_element
  in
  Bridge.register_element ~tag_name ~on_connect ~on_disconnect ()
