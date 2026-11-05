type rpc_ctx = Well.rpc_ctx = {
  session_id : string;
  request_id : string;
  user_id : string option;
  user_name : string option;
  locale : string;
  session_data : (string * string) list;
}

let rpc_ctx_to_wire = Well.rpc_ctx_to_wire
let rpc_ctx_of_wire = Well.rpc_ctx_of_wire
