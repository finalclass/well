(* Contract AST types — pure types, no logic *)

type prim_type =
  | String
  | Int
  | Float
  | Bool
  | Void
  | Date
  | Record
  | Ctx

type type_info =
  | Prim of prim_type
  | Custom of { module_name : string; msg_name : string }
  | List of type_info
  | Optional of type_info

type property = {
  name : string;
  type_info : type_info;
  optional : bool;
}

type constructor = {
  name : string;
  payload : type_info;
}

type msg_kind =
  | Struct of property list
  | Variant of constructor list

type msg = {
  name : string;
  kind : msg_kind;
}

type rpc = {
  name : string;
  request_msg : string;
  response_msg : string;
}

type service = {
  rpcs : rpc list;
}

type contract_module = {
  name : string;
  service : service option;
  msgs : msg list;
}
