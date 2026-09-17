type actor_id = { actor_type : string; id : string }
type execution_id = string

type error = {
  code : string;
  message : string;
  path : string option;
}

type failure = Retry of string | Fail of string

type context = {
  self : actor_id;
  execution_id : execution_id;
  message_id : string;
  attempt : int;
  deadline_ms : int64;
}

type limits = {
  max_active : int;
  domains : int;
  workflow_bytes : int;
  payload_bytes : int;
  state_bytes : int;
  nodes : int;
  group_depth : int;
  emissions : int;
  deliveries_per_execution : int;
  active_executions : int;
  pending_deliveries : int;
}

type retry_policy = { max_attempts : int; delays_ms : int list }

type config = {
  store_path : string;
  limits : limits;
  retry_policy : retry_policy;
}

type 'a message_type = {
  name : string;
  schema_hash : string;
  encode : 'a -> Yojson.Safe.t;
  decode : Yojson.Safe.t -> ('a, error) result;
}

type packed_message =
  | Message : 'a message_type * 'a -> packed_message

type location = {
  node_id : string;
  message_id : string;
  actor : actor_id option;
  attempt : int;
  at_ms : int64;
}

type diagnostic = {
  error : error;
  location : location option;
  missing_branches : string list;
}

type output = {
  path : int list;
  payload_type : string;
  schema_hash : string;
  payload : Yojson.Safe.t;
}

type execution_status =
  | Running
  | Blocked of diagnostic list
  | Completed
  | Failed of diagnostic

type snapshot = {
  execution_id : execution_id;
  request_id : string;
  status : execution_status;
  outputs : output list;
  pending_messages : int;
  open_groups : int;
  deadline_ms : int64;
}

type await_result = Terminal of snapshot | Wait_timeout of snapshot

let error ?(path = None) code message = { code; message; path }

let json_int_min = -9007199254740991L
let json_int_max = 9007199254740991L

let int_in_json_range n =
  let n = Int64.of_int n in
  n >= json_int_min && n <= json_int_max

let default_limits = {
  max_active = 64;
  domains = 1;
  workflow_bytes = 256 * 1024;
  payload_bytes = 1024 * 1024;
  state_bytes = 1024 * 1024;
  nodes = 256;
  group_depth = 16;
  emissions = 256;
  deliveries_per_execution = 100_000;
  active_executions = 10_000;
  pending_deliveries = 100_000;
}

let default_retry_policy = {
  max_attempts = 5;
  delays_ms = [1000; 2000; 4000; 8000];
}

let actor_id_key (a : actor_id) = a.actor_type ^ "/" ^ a.id

let ident_actor name =
  let len = String.length name in
  len >= 1 && len <= 64
  && name.[0] >= 'A' && name.[0] <= 'Z'
  && String.for_all (function 'A'..'Z' | 'a'..'z' | '0'..'9' | '_' -> true | _ -> false) name

let ident_field name =
  let len = String.length name in
  len >= 1 && len <= 64
  && name.[0] >= 'a' && name.[0] <= 'z'
  && String.for_all (function 'A'..'Z' | 'a'..'z' | '0'..'9' | '_' -> true | _ -> false) name

let ident_node name =
  let len = String.length name in
  len >= 1 && len <= 64
  && ((name.[0] >= 'A' && name.[0] <= 'Z') || (name.[0] >= 'a' && name.[0] <= 'z'))
  && String.for_all (function 'A'..'Z' | 'a'..'z' | '0'..'9' | '_' -> true | _ -> false) name

let qualified_type name =
  match String.split_on_char '.' name with
  | [m; t] -> ident_actor m && ident_actor t
  | _ -> false

let ocaml_keywords = [
  "and"; "as"; "assert"; "asr"; "begin"; "class"; "constraint"; "do";
  "done"; "downto"; "else"; "end"; "exception"; "external"; "false";
  "for"; "fun"; "function"; "functor"; "if"; "in"; "include"; "inherit";
  "initializer"; "land"; "lazy"; "let"; "lor"; "lsl"; "lsr"; "lxor";
  "match"; "method"; "mod"; "module"; "mutable"; "new"; "nonrec";
  "object"; "of"; "open"; "or"; "private"; "rec"; "sig"; "struct";
  "then"; "to"; "true"; "try"; "type"; "val"; "virtual"; "when";
  "while"; "with"
]

let escape_keyword name =
  if List.mem name ocaml_keywords then name ^ "'" else name

let snake_case name =
  let buf = Buffer.create (String.length name) in
  String.iteri (fun i c ->
    if c >= 'A' && c <= 'Z' then begin
      if i > 0 then Buffer.add_char buf '_';
      Buffer.add_char buf (Char.lowercase_ascii c)
    end else Buffer.add_char buf c
  ) name;
  Buffer.contents buf

let ocaml_module_name name = String.capitalize_ascii (snake_case name)
