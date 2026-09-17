open Actor_types

type actor_id_spec =
  | Fixed of string
  | Binding of string
  | Input_path of string list

type emission_mode = One | Optional | Many

type node =
  | Actor of {
      actor : string;
      id : actor_id_spec;
      accept : string;
      emission_mode : emission_mode;
      outputs : (string * string) list;
      join : string option;
    }
  | Fork of {
      input_type : string;
      branches : (string * string) list;
      join : string option;
    }
  | Join of {
      item_type : string;
      batch_type : string;
      timeout_ms : int;
      next : string;
    }
  | End of { input_type : string }
  | Drop of { input_type : string }

type t = {
  json : Yojson.Safe.t;
  hash : string;
  name : string;
  version : string;
  entry : string;
  input_type : string;
  bindings : (string * string) list;
  nodes : (string * node) list;
}

type group_frame = {
  group_id : string;
  branch_id : string;
  ordinal : int;
  join_node : string;
}

let node_of id nodes =
  List.assoc_opt id nodes

let json_err path code message = error ~path:(Some path) code message

let as_object path json =
  match json with
  | `Assoc xs -> Ok xs
  | _ -> Error [json_err path "InvalidWorkflow" "expected object"]

let req path fields key =
  match List.assoc_opt key fields with
  | None -> Error [json_err (path ^ "/" ^ key) "InvalidWorkflow" "missing field"]
  | Some v -> Ok v

let as_string path = function
  | `String s -> Ok s
  | _ -> Error [json_err path "InvalidWorkflow" "expected string"]

let as_int path = function
  | `Int n -> Ok n
  | _ -> Error [json_err path "InvalidWorkflow" "expected integer"]

let as_null_or_string path = function
  | `Null -> Ok None
  | `String s -> Ok (Some s)
  | _ -> Error [json_err path "InvalidWorkflow" "expected string or null"]

let parse_id path json =
  match json with
  | `Assoc ["fixed", `String s] ->
    if s = "" || String.length s > 256 then
      Error [json_err path "InvalidWorkflow" "invalid fixed id"]
    else Ok (Fixed s)
  | `Assoc ["binding", `String s] ->
    if ident_node s then Ok (Binding s)
    else Error [json_err path "InvalidWorkflow" "invalid binding"]
  | `Assoc ["input_path", `List xs] ->
    let rec go acc = function
      | [] ->
        if acc = [] then Error [json_err path "InvalidWorkflow" "empty input_path"]
        else Ok (Input_path (List.rev acc))
      | `String s :: rest when ident_field s -> go (s :: acc) rest
      | _ -> Error [json_err path "InvalidWorkflow" "invalid input_path"]
    in
    go [] xs
  | _ -> Error [json_err path "InvalidWorkflow" "invalid id"]

let parse_outputs path json =
  match json with
  | `Assoc pairs ->
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | (k, `String v) :: rest when ident_actor k && ident_node v ->
        go ((k, v) :: acc) rest
      | (k, _) :: _ -> Error [json_err (path ^ "/" ^ k) "InvalidWorkflow" "invalid output"]
    in
    go [] pairs
  | _ -> Error [json_err path "InvalidWorkflow" "outputs"]

let parse_branches path json =
  match json with
  | `List xs ->
    let rec go acc names = function
      | [] ->
        if acc = [] then Error [json_err path "InvalidWorkflow" "empty branches"]
        else Ok (List.rev acc)
      | `Assoc fields :: rest ->
        (match List.assoc_opt "name" fields, List.assoc_opt "next" fields with
         | Some (`String name), Some (`String next) when ident_node name && ident_node next ->
           if List.mem name names then
             Error [json_err path "InvalidWorkflow" ("duplicate branch " ^ name)]
           else go ((name, next) :: acc) (name :: names) rest
         | _ -> Error [json_err path "InvalidWorkflow" "invalid branch"])
      | _ -> Error [json_err path "InvalidWorkflow" "invalid branch"]
    in
    go [] [] xs
  | _ -> Error [json_err path "InvalidWorkflow" "branches"]

let parse_node path json =
  match as_object path json with
  | Error e -> Error e
  | Ok fields ->
    match List.assoc_opt "kind" fields with
    | Some (`String "actor") ->
      (match
         req path fields "actor",
         req path fields "id",
         req path fields "accept",
         req path fields "emission_mode",
         req path fields "outputs",
         req path fields "join"
       with
       | Ok actor, Ok id, Ok accept, Ok mode, Ok outputs, Ok join ->
         let ( let* ) = Result.bind in
         let* actor = as_string (path ^ "/actor") actor in
         let* id = parse_id (path ^ "/id") id in
         let* accept = as_string (path ^ "/accept") accept in
         let* mode =
           match mode with
           | `String "one" -> Ok One
           | `String "optional" -> Ok Optional
           | `String "many" -> Ok Many
           | _ -> Error [json_err (path ^ "/emission_mode") "InvalidWorkflow" "invalid mode"]
         in
         let* outputs = parse_outputs (path ^ "/outputs") outputs in
         let* join = as_null_or_string (path ^ "/join") join in
         if not (ident_actor actor && ident_actor accept) then
           Error [json_err path "InvalidWorkflow" "invalid actor/accept"]
         else Ok (Actor { actor; id; accept; emission_mode = mode; outputs; join })
       | Error e, _, _, _, _, _ | _, Error e, _, _, _, _ | _, _, Error e, _, _, _
       | _, _, _, Error e, _, _ | _, _, _, _, Error e, _ | _, _, _, _, _, Error e -> Error e)
    | Some (`String "fork") ->
      (match req path fields "input_type", req path fields "branches", req path fields "join" with
       | Ok input_type, Ok branches, Ok join ->
         let ( let* ) = Result.bind in
         let* input_type = as_string (path ^ "/input_type") input_type in
         let* branches = parse_branches (path ^ "/branches") branches in
         let* join = as_null_or_string (path ^ "/join") join in
         Ok (Fork { input_type; branches; join })
       | Error e, _, _ | _, Error e, _ | _, _, Error e -> Error e)
    | Some (`String "join") ->
      (match
         req path fields "item_type",
         req path fields "batch_type",
         req path fields "timeout_ms",
         req path fields "next"
       with
       | Ok item, Ok batch, Ok timeout, Ok next ->
         let ( let* ) = Result.bind in
         let* item_type = as_string (path ^ "/item_type") item in
         let* batch_type = as_string (path ^ "/batch_type") batch in
         let* timeout_ms = as_int (path ^ "/timeout_ms") timeout in
         let* next = as_string (path ^ "/next") next in
         if timeout_ms <= 0 then
           Error [json_err (path ^ "/timeout_ms") "InvalidWorkflow" "timeout_ms must be positive"]
         else Ok (Join { item_type; batch_type; timeout_ms; next })
       | Error e, _, _, _ | _, Error e, _, _ | _, _, Error e, _ | _, _, _, Error e -> Error e)
    | Some (`String "end") ->
      (match req path fields "input_type" with
       | Error e -> Error e
       | Ok t -> Result.map (fun input_type -> End { input_type }) (as_string (path ^ "/input_type") t))
    | Some (`String "drop") ->
      (match req path fields "input_type" with
       | Error e -> Error e
       | Ok t -> Result.map (fun input_type -> Drop { input_type }) (as_string (path ^ "/input_type") t))
    | Some _ -> Error [json_err (path ^ "/kind") "InvalidWorkflow" "unknown kind"]
    | None -> Error [json_err path "InvalidWorkflow" "missing kind"]

let incoming_type desc nodes node_id =
  match node_of node_id nodes with
  | None -> None
  | Some (Actor { actor; accept; _ }) ->
    (match Actor_contract.lookup_actor desc actor with
     | None -> None
     | Some meta -> List.assoc_opt accept meta.accepts)
  | Some (Fork { input_type; _ }) -> Some input_type
  | Some (Join { item_type; _ }) -> Some item_type
  | Some (End { input_type }) | Some (Drop { input_type }) -> Some input_type

let outgoing_type desc nodes node_id kind =
  match node_of node_id nodes with
  | Some (Actor { actor; _ }) ->
    (match Actor_contract.lookup_actor desc actor with
     | None -> None
     | Some meta -> List.assoc_opt kind meta.emits)
  | Some (Fork { input_type; _ }) -> Some input_type
  | Some (Join { batch_type; _ }) -> Some batch_type
  | _ -> None

let successors node =
  match node with
  | Actor { outputs; join; _ } ->
    let dests = List.map snd outputs in
    (match join with Some j -> j :: dests | None -> dests)
  | Fork { branches; join; _ } ->
    let dests = List.map snd branches in
    (match join with Some j -> j :: dests | None -> dests)
  | Join { next; _ } -> [next]
  | End _ | Drop _ -> []

let reachable entry nodes =
  let seen = Hashtbl.create 16 in
  let rec go id =
    if Hashtbl.mem seen id then ()
    else begin
      Hashtbl.add seen id ();
      match node_of id nodes with
      | None -> ()
      | Some n -> List.iter go (successors n)
    end
  in
  go entry;
  seen

let has_cycle nodes entry =
  let rec dfs stack id =
    if List.mem id stack then true
    else
      match node_of id nodes with
      | None -> false
      | Some n -> List.exists (dfs (id :: stack)) (successors n)
  in
  dfs [] entry

let join_sources nodes =
  List.fold_left (fun acc (id, n) ->
    match n with
    | Actor { join = Some j; _ } | Fork { join = Some j; _ } ->
      (j, id) :: acc
    | _ -> acc
  ) [] nodes

let rec paths_to ~nodes ~stop ~from visited =
  if from = stop then [[from]]
  else if List.mem from visited then []
  else
    match node_of from nodes with
    | None -> []
    | Some (End _ | Drop _) -> []
    | Some n ->
      let nexts =
        match n with
        | Actor { outputs; join; _ } ->
          (match join with
           | Some j when j = stop -> [j]
           | _ -> List.map snd outputs)
        | Fork { branches; join; _ } ->
          (match join with
           | Some j when j = stop -> [j]
           | _ -> List.map snd branches)
        | Join { next; _ } -> [next]
        | End _ | Drop _ -> []
      in
      List.concat_map (fun n ->
        List.map (fun p -> from :: p) (paths_to ~nodes ~stop ~from:n (from :: visited))
      ) nexts

let open_group_ok ~nodes ~source_id ~join_id =
  let src = List.assoc source_id nodes in
  let starts =
    match src with
    | Actor { outputs; _ } -> List.map snd outputs
    | Fork { branches; _ } -> List.map snd branches
    | _ -> []
  in
  let rec check id stack =
    if id = join_id then Ok ()
    else if List.mem id stack then Error "cycle in join group"
    else
      match node_of id nodes with
      | None -> Error ("unknown node " ^ id)
      | Some (End _) | Some (Drop _) -> Error "end/drop before join"
      | Some (Join { next; _ }) ->
        if List.length stack = 0 then Error "join mismatch"
        else check next (id :: stack)
      | Some (Actor { emission_mode; join; outputs; _ }) ->
        (match join with
         | Some j ->
           (match check j (id :: stack) with
            | Error e -> Error e
            | Ok () -> check join_id stack)
         | None ->
           if emission_mode <> One then Error "fan-out without inner join"
           else
             let rec go = function
               | [] -> Ok ()
               | d :: rest ->
                 match check d (id :: stack) with
                 | Error e -> Error e
                 | Ok () -> go rest
             in
             go (List.map snd outputs))
      | Some (Fork { join; branches; _ }) ->
        (match join with
         | None -> Error "fork without join inside open group"
         | Some j ->
           let rec go = function
             | [] -> check j (id :: stack)
             | (_, n) :: rest ->
               match check n (id :: stack) with
               | Error e -> Error e
               | Ok () -> go rest
           in
           go branches)
  in
  let rec go = function
    | [] -> Ok ()
    | s :: rest ->
      match check s [] with
      | Error e -> Error e
      | Ok () -> go rest
  in
  go starts

let validate desc json =
  match json with
  | `Assoc fields ->
    let errs = ref [] in
    let push e = errs := e :: !errs in
    let get k =
      match List.assoc_opt k fields with
      | None -> push (json_err ("/" ^ k) "InvalidWorkflow" "missing field"); None
      | Some v -> Some v
    in
    let extra = List.filter (fun (k, _) ->
      not (List.mem k ["format"; "name"; "version"; "entry"; "input_type"; "bindings"; "nodes"])
    ) fields in
    List.iter (fun (k, _) -> push (json_err ("/" ^ k) "InvalidWorkflow" "unknown key")) extra;
    (match get "format" with Some (`Int 1) -> () | Some _ -> push (json_err "/format" "InvalidWorkflow" "format must be 1") | None -> ());
    let name = match get "name" with Some (`String s) when s <> "" && String.length s <= 128 -> Some s | Some _ -> push (json_err "/name" "InvalidWorkflow" "invalid name"); None | None -> None in
    let version = match get "version" with Some (`String s) when s <> "" && String.length s <= 128 -> Some s | Some _ -> push (json_err "/version" "InvalidWorkflow" "invalid version"); None | None -> None in
    let entry = match get "entry" with Some (`String s) when ident_node s -> Some s | Some _ -> push (json_err "/entry" "InvalidWorkflow" "invalid entry"); None | None -> None in
    let input_type = match get "input_type" with Some (`String s) when qualified_type s -> Some s | Some _ -> push (json_err "/input_type" "InvalidWorkflow" "invalid input_type"); None | None -> None in
    let bindings =
      match get "bindings" with
      | Some (`Assoc pairs) ->
        List.filter_map (fun (k, v) ->
          if not (ident_node k) then (push (json_err ("/bindings/" ^ k) "InvalidWorkflow" "invalid binding"); None)
          else match v with
            | `String s when s <> "" && String.length s <= 256 -> Some (k, s)
            | _ -> push (json_err ("/bindings/" ^ k) "InvalidWorkflow" "invalid value"); None
        ) pairs
      | Some _ -> push (json_err "/bindings" "InvalidWorkflow" "expected object"); []
      | None -> []
    in
    let nodes_res =
      match get "nodes" with
      | Some (`Assoc pairs) ->
        if pairs = [] then (push (json_err "/nodes" "InvalidWorkflow" "empty nodes"); [])
        else
          List.filter_map (fun (id, body) ->
            if not (ident_node id) then (push (json_err ("/nodes/" ^ id) "InvalidWorkflow" "invalid node id"); None)
            else match parse_node ("/nodes/" ^ id) body with
              | Ok n -> Some (id, n)
              | Error es -> List.iter push es; None
          ) pairs
      | Some _ -> push (json_err "/nodes" "InvalidWorkflow" "expected object"); []
      | None -> []
    in
    (match entry with
     | Some e when not (List.mem_assoc e nodes_res) ->
       push (json_err "/entry" "InvalidWorkflow" "entry does not exist")
     | _ -> ());
    List.iter (fun (id, n) ->
      List.iter (fun dest ->
        if not (List.mem_assoc dest nodes_res) then
          push (json_err ("/nodes/" ^ id) "InvalidWorkflow" ("unknown target " ^ dest))
      ) (successors n)
    ) nodes_res;
    (match entry with
     | Some e when nodes_res <> [] ->
       if has_cycle nodes_res e then
         push (json_err "/nodes" "InvalidWorkflow" "cycle");
       let seen = reachable e nodes_res in
       List.iter (fun (id, _) ->
         if not (Hashtbl.mem seen id) then
           push (json_err ("/nodes/" ^ id) "InvalidWorkflow" "unreachable node")
       ) nodes_res
     | _ -> ());
    (match input_type with
     | Some t ->
       (match Actor_contract.find_message desc t with
        | None -> push (json_err "/input_type" "InvalidWorkflow" "unknown input_type")
        | Some _ -> ())
     | None -> ());
    List.iter (fun (id, n) ->
      match n with
      | Actor { actor; accept; outputs; emission_mode = _; join = _; id = idspec } ->
        (match Actor_contract.lookup_actor desc actor with
         | None -> push (json_err ("/nodes/" ^ id ^ "/actor") "InvalidWorkflow" "unknown actor type")
         | Some meta ->
           if not (List.mem_assoc accept meta.accepts) then
             push (json_err ("/nodes/" ^ id ^ "/accept") "InvalidWorkflow" "unknown accept");
           List.iter (fun (k, _) ->
             if not (List.mem_assoc k outputs) then
               push (json_err ("/nodes/" ^ id ^ "/outputs") "InvalidWorkflow" ("missing output for " ^ k))
           ) meta.emits;
           List.iter (fun (k, dest) ->
             match List.assoc_opt k meta.emits with
             | None -> push (json_err ("/nodes/" ^ id ^ "/outputs/" ^ k) "InvalidWorkflow" "undeclared emission")
             | Some ty ->
               match incoming_type desc nodes_res dest with
               | Some ty' when ty' = ty -> ()
               | Some _ -> push (json_err ("/nodes/" ^ id ^ "/outputs/" ^ k) "InvalidWorkflow" "payload type mismatch")
               | None -> ()
           ) outputs);
        (match idspec with
         | Binding b when not (List.mem_assoc b bindings) ->
           push (json_err ("/nodes/" ^ id ^ "/id") "InvalidWorkflow" "unknown binding")
         | Input_path path ->
           (match incoming_type desc nodes_res id with
            | None -> ()
            | Some ty ->
              (match Actor_contract.find_message desc ty with
               | None -> ()
               | Some (_, (schema, _)) ->
                 let rec walk schema = function
                   | [] ->
                     (match schema with Actor_contract.Primitive "string" -> () | _ ->
                       push (json_err ("/nodes/" ^ id ^ "/id") "InvalidWorkflow" "input_path is not string"))
                   | key :: rest ->
                     match schema with
                     | Actor_contract.Struct fields ->
                       (match List.assoc_opt key fields with
                        | None -> push (json_err ("/nodes/" ^ id ^ "/id") "InvalidWorkflow" "unknown field")
                        | Some (Actor_contract.List _ | Actor_contract.Optional _ | Actor_contract.Variant _) ->
                          push (json_err ("/nodes/" ^ id ^ "/id") "InvalidWorkflow" "input_path through list/optional/variant")
                        | Some s -> walk s rest)
                     | _ -> push (json_err ("/nodes/" ^ id ^ "/id") "InvalidWorkflow" "input_path not a struct")
                 in
                 walk (Actor_contract.resolve_schema desc.messages schema) path))
         | _ -> ())
      | Fork { input_type; branches; _ } ->
        (match Actor_contract.find_message desc input_type with
         | None -> push (json_err ("/nodes/" ^ id ^ "/input_type") "InvalidWorkflow" "unknown type")
         | Some _ -> ());
        List.iter (fun (_, dest) ->
          match incoming_type desc nodes_res dest with
          | Some ty when ty = input_type -> ()
          | Some _ -> push (json_err ("/nodes/" ^ id) "InvalidWorkflow" "fork payload type mismatch")
          | None -> ()
        ) branches
      | Join { item_type; batch_type; next; timeout_ms = _ } ->
        (match Actor_contract.join_batch_schema desc ~item_type ~batch_type with
         | Ok () -> ()
         | Error m -> push (json_err ("/nodes/" ^ id) "InvalidWorkflow" m));
        (match incoming_type desc nodes_res next with
         | Some ty when ty = batch_type -> ()
         | Some _ -> push (json_err ("/nodes/" ^ id ^ "/next") "InvalidWorkflow" "batch type mismatch")
         | None -> ())
      | End { input_type } | Drop { input_type } ->
        (match Actor_contract.find_message desc input_type with
         | None -> push (json_err ("/nodes/" ^ id) "InvalidWorkflow" "unknown type")
         | Some _ -> ())
    ) nodes_res;
    let sources = join_sources nodes_res in
    let by_join = Hashtbl.create 8 in
    List.iter (fun (j, src) ->
      match Hashtbl.find_opt by_join j with
      | Some src' ->
        push (json_err ("/nodes/" ^ j) "InvalidWorkflow" ("join has two sources " ^ src ^ " and " ^ src'))
      | None -> Hashtbl.add by_join j src
    ) sources;
    Hashtbl.iter (fun j src ->
      match open_group_ok ~nodes:nodes_res ~source_id:src ~join_id:j with
      | Ok () -> ()
      | Error m -> push (json_err ("/nodes/" ^ src) "InvalidWorkflow" m)
    ) by_join;
    List.iter (fun (id, n) ->
      match n with
      | Join _ ->
        if not (Hashtbl.mem by_join id) then
          push (json_err ("/nodes/" ^ id) "InvalidWorkflow" "join has no source")
      | _ -> ()
    ) nodes_res;
    (match entry, input_type with
     | Some e, Some t ->
       (match incoming_type desc nodes_res e with
        | Some t' when t' = t -> ()
        | Some _ -> push (json_err "/input_type" "InvalidWorkflow" "entry payload mismatch")
        | None -> ())
     | _ -> ());
    if !errs <> [] then Error (List.rev !errs)
    else
      (match name, version, entry, input_type with
       | Some name, Some version, Some entry, Some input_type ->
         let copy = Yojson.Safe.from_string (Yojson.Safe.to_string json) in
         Ok {
           json = copy;
           hash = Actor_jcs.hash_json copy;
           name; version; entry; input_type; bindings; nodes = nodes_res;
         }
       | _ -> Error (List.rev !errs))
  | _ -> Error [json_err "" "InvalidWorkflow" "expected object"]

let to_json (t : t) = Yojson.Safe.from_string (Yojson.Safe.to_string t.json)

let resolve_address ~desc ~wf ~payload ~payload_type node =
  match node with
  | Actor { actor; id; _ } ->
    (match id with
     | Fixed s -> Ok { actor_type = actor; id = s }
     | Binding name ->
       (match List.assoc_opt name wf.bindings with
        | Some s when s <> "" -> Ok { actor_type = actor; id = s }
        | _ -> Error (error "InvalidAddress" ("binding " ^ name)))
     | Input_path path ->
       (match Actor_contract.read_input_path desc ~payload_type payload path with
        | Ok s -> Ok { actor_type = actor; id = s }
        | Error e -> Error e))
  | _ -> Error (error "InvalidAddress" "not an actor node")

let contracts_json desc wf =
  let types = ref [] in
  let add_t t =
    match Actor_contract.find_message desc t with
    | Some (_, (_, h)) -> types := (t, h) :: !types
    | None -> ()
  in
  add_t wf.input_type;
  List.iter (fun (_, n) ->
    match n with
    | Actor { actor; _ } ->
      (match Actor_contract.lookup_actor desc actor with
       | Some meta ->
         List.iter (fun (_, t) -> add_t t) meta.accepts;
         List.iter (fun (_, t) -> add_t t) meta.emits
       | None -> ())
    | Fork { input_type; _ } -> add_t input_type
    | Join { item_type; batch_type; _ } -> add_t item_type; add_t batch_type
    | End { input_type } | Drop { input_type } -> add_t input_type
  ) wf.nodes;
  let messages =
    `Assoc (List.sort compare (List.map (fun (n, h) -> n, `String h) !types)
            |> List.fold_left (fun acc (n, h) -> if List.mem_assoc n acc then acc else (n, h) :: acc) [])
  in
  let actors =
    let acc = ref [] in
    List.iter (fun (_, n) ->
      match n with
      | Actor { actor; _ } ->
        (match Actor_contract.lookup_actor desc actor with
         | Some meta when not (List.mem_assoc actor !acc) ->
           acc := (actor, `Assoc [
             "version", `Int meta.version;
             "hash", `String meta.actor_contract_hash
           ]) :: !acc
         | _ -> ())
      | _ -> ()
    ) wf.nodes;
    `Assoc (List.rev !acc)
  in
  `Assoc ["messages", messages; "actors", actors]
