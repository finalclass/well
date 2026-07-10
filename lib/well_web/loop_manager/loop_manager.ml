[@@@warning "-69"]

type 'a envelope = {
  instance_id : string;
  payload : 'a;
}

let handle_msg ~instance_id envelope =
  let key = Component_access.state_key ~instance_id in
  let state_env : Component_access.state Component_access.envelope =
    Obj.magic { instance_id; payload = State_access.load key }
  in
  let msg_env : Component_access.msg Component_access.envelope =
    Obj.magic envelope
  in
  let updated_env =
    Component_access.update_state ~instance_id state_env msg_env
  in
  let (new_state, cmd) : Component_access.state * Component_access.cmd =
    (Obj.magic updated_env : _ envelope).payload
  in
  State_access.persist key new_state;
  let state_env' : Component_access.state Component_access.envelope =
    Obj.magic { instance_id; payload = new_state }
  in
  let vdom_env =
    Component_access.render_view ~instance_id state_env'
  in
  let vdom_bus : _ Message_bus.envelope = Obj.magic vdom_env in
  Message_bus.publish ~topic:"vdom" vdom_bus;
  if not (Component_access.is_cmd_none cmd) then begin
    let cmd_bus : _ Message_bus.envelope =
      Obj.magic ({ instance_id; payload = cmd } : _ envelope)
    in
    Message_bus.publish ~topic:"cmd" cmd_bus
  end
