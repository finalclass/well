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
}

let instances : instance_record Instance_table.t = Instance_table.create 64

let runtime_ready = ref false

let ensure_runtime () =
  if not !runtime_ready then begin
    runtime_ready := true;
    Rendering.init ();
    ignore
      (Message_bus.subscribe ~topic:"msg" (fun env ->
         Loop_manager.handle_msg
           ~instance_id:(Message_bus.instance_id env)
           (Obj.magic env)));
    ignore
      (Message_bus.subscribe ~topic:"cmd" (fun env ->
         Effects_manager.handle_cmd
           ~instance_id:(Message_bus.instance_id env)
           (Obj.magic env)))
  end

let publish_msg ~instance_id (m : Component_access.msg) =
  Message_bus.publish ~topic:"msg"
    (Message_bus.create ~instance_id (Obj.obj (Obj.repr m)))

let publish_cmd ~instance_id (cmd : Component_access.cmd) =
  if not (Component_access.is_cmd_none cmd) then
    let cmd_bus : _ Message_bus.envelope =
      Obj.magic ({ instance_id; payload = cmd } : _ envelope)
    in
    Message_bus.publish ~topic:"cmd" cmd_bus

let component ~module_ ~tag_name ?(shadow_dom = false) () =
  Component_access.register_type ~module_ ~tag_name ~shadow_dom ();
  ensure_runtime ();
  let observed = Inputs.observed_attribute_names ~tag_name in
  let prop_names = Inputs.property_names ~tag_name in
  let on_connect dom_element =
    let instance_id =
      Component_access.create_instance ~tag_name ~dom_element
    in
    let dispatch_msg (m : Component_access.msg) =
      publish_msg ~instance_id m
    in
    let init_env =
      Component_access.init_state ~instance_id ~dispatch:dispatch_msg
    in
    let (initial_state, init_cmd) :
          Component_access.state * Component_access.cmd =
      (Obj.magic init_env : _ envelope).payload
    in
    let state_key = Component_access.state_key ~instance_id in
    State_access.persist state_key initial_state;
    let hydrated =
      Inputs.hydrate_instance ~instance_id ~host:dom_element
        ~initial_state
    in
    let state_env' : Component_access.state Component_access.envelope =
      Obj.magic { instance_id; payload = hydrated }
    in
    Component_access.capture_projection ~instance_id;
    let initial_vdom_env =
      Component_access.render_view ~instance_id state_env'
    in
    let vdom_bus : _ Message_bus.envelope = Obj.magic initial_vdom_env in
    Message_bus.publish ~topic:"vdom" vdom_bus;
    Instance_table.replace instances dom_element { instance_id; state_key };
    publish_cmd ~instance_id init_cmd
  in
  let on_disconnect dom_element =
    match Instance_table.find_opt instances dom_element with
    | None -> ()
    | Some record ->
      Rendering.destroy_instance ~instance_id:record.instance_id;
      Inputs.forget_instance ~instance_id:record.instance_id;
      Component_access.destroy_instance ~instance_id:record.instance_id;
      State_access.destroy record.state_key;
      Instance_table.remove instances dom_element
  in
  let on_attribute_change host ~name ~old_value ~new_value =
    Inputs.handle_attribute_change ~host ~name ~old_value ~new_value
  in
  let on_property_set host ~name ~value =
    Inputs.handle_property_set ~host ~name ~value
  in
  Bridge.register_element ~tag_name ~on_connect ~on_disconnect
    ~observed_attributes:observed
    ~on_attribute_change
    ~property_names:prop_names
    ~on_property_set
    ()
