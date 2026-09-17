open Actor_types

let config : config option ref = ref None
let running = Atomic.make false
let frozen = ref false
let definitions : (string, Actor_contract.definition) Hashtbl.t = Hashtbl.create 16
let store : Actor_store.t option ref = ref None
let waiters : (string, unit Eio.Promise.u list) Hashtbl.t = Hashtbl.create 16
let now_ms_fn : (unit -> int64) ref =
  ref (fun () -> Int64.of_float (Unix.gettimeofday () *. 1000.))
let hold : (string, unit Eio.Promise.t) Hashtbl.t = Hashtbl.create 8
let hold_u : (string, unit Eio.Promise.u) Hashtbl.t = Hashtbl.create 8
let owner_id = ref "proc"
let active = Atomic.make 0
let activations_finished = Atomic.make 0
let worker_live = Atomic.make 0
let join_timeout_ms = Atomic.make 2000
let shutdown_hang_ms = Atomic.make 0
let after_handle_hook : (actor_id -> unit) option ref = ref None
let inspect_stall_after = ref 0
let inspect_stall_ms = ref 0
let inspect_calls = Atomic.make 0
let inflight : (string, int) Hashtbl.t = Hashtbl.create 16
let pending_unstick : (string, unit) Hashtbl.t = Hashtbl.create 16
let pending_clear : (string * int) list ref = ref []
let last_turn_error : string option ref = ref None
let claim_gap_arm = Atomic.make 0
let unstick_arm = Atomic.make 0
let claim_pause_arm = Atomic.make 0
let finish_arm = Atomic.make 0
let cleanup_copy_arm = Atomic.make 0
let cleanup_retire_arm = Atomic.make 0
let cleanup_retire_budget = Atomic.make 0
let claim_gap_waiting = Atomic.make 0
let unstick_waiting = Atomic.make 0
let claim_pause_waiting = Atomic.make 0
let finish_waiting = Atomic.make 0
let cleanup_copy_waiting = Atomic.make 0
let cleanup_retire_waiting = Atomic.make 0
let state_mu = Mutex.create ()

let with_mu f =
  Mutex.lock state_mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock state_mu) f

let now_ms () =
  let f = with_mu (fun () -> !now_ms_fn) in
  f ()

let own_log msg =
  match Sys.getenv_opt "ACTOR_OWNERSHIP_LOG" with
  | None -> ()
  | Some path ->
    try
      let oc = open_out_gen [Open_creat; Open_append; Open_wronly] 0o644 path in
      Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
        output_string oc
          (Printf.sprintf "%d dom=%d %s\n" (Unix.getpid ()) (Domain.self () :> int) msg);
        flush oc)
    with _ -> ()

let is_runtime_actor name =
  String.starts_with ~prefix:"__well." name

let blocking f =
  (match Actor_store.get_stall_ms () with
   | n when n > 0 ->
     (try Eio_unix.sleep (float_of_int n /. 1000.)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | _ -> Unix.sleepf (float_of_int n /. 1000.))
   | _ -> ());
  try Eio_unix.run_in_systhread ~label:"actor-store" f
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Effect.Unhandled _ -> f ()

let wakeup () = ()

let error_json (e : error) =
  `Assoc [
    "code", `String e.code;
    "message", `String e.message;
    "path", (match e.path with None -> `Null | Some p -> `String p);
  ]

let location_json = function
  | None -> `Null
  | Some (l : location) ->
    `Assoc [
      "node_id", `String l.node_id;
      "message_id", `String l.message_id;
      "actor", (match l.actor with
        | None -> `Null
        | Some a -> `Assoc ["actor_type", `String a.actor_type; "id", `String a.id]);
      "attempt", `Int l.attempt;
      "at_ms", `Intlit (Int64.to_string l.at_ms);
    ]

let diagnostic_to_json (d : diagnostic) =
  `Assoc [
    "error", error_json d.error;
    "location", location_json d.location;
    "missing_branches", `List (List.map (fun s -> `String s) d.missing_branches);
  ]

let diagnostic_of_json json : diagnostic =
  match json with
  | `Assoc _ as obj ->
    let err =
      match Actor_json.member "error" obj with
      | Some (`Assoc _ as e) ->
        {
          code = (match Actor_json.member "code" e with Some (`String s) -> s | _ -> "ActorFailed");
          message = (match Actor_json.member "message" e with Some (`String s) -> s | _ -> "");
          path = (match Actor_json.member "path" e with Some (`String s) -> Some s | _ -> None);
        }
      | _ -> error "ActorFailed" "unknown"
    in
    let missing =
      match Actor_json.member "missing_branches" obj with
      | Some (`List xs) -> List.filter_map (function `String s -> Some s | _ -> None) xs
      | _ -> []
    in
    let location =
      match Actor_json.member "location" obj with
      | None | Some `Null -> None
      | Some (`Assoc _ as loc) ->
        Some {
          node_id = (match Actor_json.member "node_id" loc with Some (`String s) -> s | _ -> "");
          message_id = (match Actor_json.member "message_id" loc with Some (`String s) -> s | _ -> "");
          actor =
            (match Actor_json.member "actor" loc with
             | Some (`Assoc _ as a) ->
               (match Actor_json.member "actor_type" a, Actor_json.member "id" a with
                | Some (`String t), Some (`String i) -> Some { actor_type = t; id = i }
                | _ -> None)
             | _ -> None);
          attempt = (match Actor_json.member "attempt" loc with Some (`Int n) -> n | _ -> 0);
          at_ms =
            (match Actor_json.member "at_ms" loc with
             | Some (`Intlit s) -> (try Int64.of_string s with _ -> 0L)
             | Some (`Int n) -> Int64.of_int n
             | _ -> 0L);
        }
      | _ -> None
    in
    { error = err; location; missing_branches = missing }
  | _ -> { error = error "ActorFailed" "invalid diagnostic"; location = None; missing_branches = [] }

let remove_waiter execution_id u =
  with_mu (fun () ->
    match Hashtbl.find_opt waiters execution_id with
    | None -> ()
    | Some us ->
      let us = List.filter (fun x -> x != u) us in
      if us = [] then Hashtbl.remove waiters execution_id
      else Hashtbl.replace waiters execution_id us)

let notify execution_id =
  let us =
    with_mu (fun () ->
      match Hashtbl.find_opt waiters execution_id with
      | None -> []
      | Some us -> Hashtbl.remove waiters execution_id; us)
  in
  List.iter (fun u -> try Eio.Promise.resolve u () with _ -> ()) us

let find_def name =
  with_mu (fun () -> Hashtbl.find_opt definitions name)

let new_id prefix =
  let n = Random.bits () land 0x7fffffff in
  Printf.sprintf "%s-%Lx-%x" prefix (now_ms ()) n

let require_config () =
  match !config with
  | None -> Error (error "NotConfigured" "Actor runtime is not configured")
  | Some c -> Ok c

let catalog () =
  let defs = with_mu (fun () -> Hashtbl.fold (fun _ d acc -> d :: acc) definitions []) in
  Actor_contract.catalog_json defs

let register_type (def : Actor_contract.definition) =
  if !frozen then Error (error "RegistryFrozen" "registry is frozen")
  else
    with_mu (fun () ->
      if Hashtbl.mem definitions def.actor_type then
        Error (error "DuplicateActorType" def.actor_type)
      else
        let conflict = ref false in
        Hashtbl.iter (fun _ (d : Actor_contract.definition) ->
          List.iter (fun (q, (_, h)) ->
            match Actor_contract.find_message def.descriptor q with
            | Some (_, (_, h')) when h <> h' -> conflict := true
            | _ -> ()
          ) d.descriptor.messages
        ) definitions;
        if !conflict then Error (error "InvalidContract" "shared type schema mismatch")
        else (Hashtbl.replace definitions def.actor_type def; Ok ()))

let merged_descriptor () =
  let defs = with_mu (fun () -> Hashtbl.fold (fun _ d acc -> d :: acc) definitions []) in
  match defs with
  | [] ->
    { Actor_contract.format = 1; modules = []; messages = []; actors = []; json = catalog () }
  | d :: _ ->
    let json = catalog () in
    match Actor_contract.parse_descriptor json with
    | Ok desc -> desc
    | Error _ -> d.descriptor

let validate_limits (c : config) =
  let l = c.limits in
  let pos name n = n > 0 || (ignore name; false) in
  if c.store_path = "" then Error (error "InvalidConfiguration" "store_path")
  else if not (
    pos "max_active" l.max_active && pos "domains" l.domains
    && pos "workflow_bytes" l.workflow_bytes && pos "payload_bytes" l.payload_bytes
    && pos "state_bytes" l.state_bytes && pos "nodes" l.nodes
    && pos "group_depth" l.group_depth && pos "emissions" l.emissions
    && pos "deliveries_per_execution" l.deliveries_per_execution
    && pos "active_executions" l.active_executions
    && pos "pending_deliveries" l.pending_deliveries
  ) then Error (error "InvalidConfiguration" "limits must be positive")
  else if c.retry_policy.max_attempts <= 0 then
    Error (error "InvalidConfiguration" "retry policy")
  else if List.length c.retry_policy.delays_ms <> c.retry_policy.max_attempts - 1 then
    Error (error "InvalidConfiguration" "delays_ms length")
  else if List.exists (fun d -> d < 0) c.retry_policy.delays_ms then
    Error (error "InvalidConfiguration" "delays_ms")
  else Ok ()

let configure c =
  if Atomic.get running then Error (error "AlreadyConfigured" "runtime is running")
  else if !config <> None then Error (error "AlreadyConfigured" "already configured")
  else
    match validate_limits c with
    | Error e -> Error e
    | Ok () -> config := Some c; Ok ()

let json_bytes json = String.length (Yojson.Safe.to_string json)

let current_limits () =
  match !config with Some c -> c.limits | None -> default_limits

let workflow_validate json =
  let limits = current_limits () in
  if json_bytes json > limits.workflow_bytes then
    Error [error "InvalidWorkflow" "workflow_bytes"]
  else
    match Actor_workflow.validate (merged_descriptor ()) json with
    | Error e -> Error e
    | Ok wf ->
      if List.length wf.nodes > limits.nodes then
        Error [error "InvalidWorkflow" "nodes"]
      else Ok wf

let decode_output (mt : 'a message_type) (o : output) =
  if o.payload_type <> mt.name || o.schema_hash <> mt.schema_hash then
    Error (error "SchemaMismatch" "output type or hash mismatch")
  else mt.decode o.payload

let snapshot_of db execution_id =
  match Actor_store.load_execution db execution_id with
  | None -> Error (error "UnknownExecution" execution_id)
  | Some (request_id, status, diagnostic, pending, open_groups, deadline, _) ->
    let outputs = Actor_store.load_outputs db execution_id in
    let status =
      match status with
      | "running" -> Running
      | "blocked" ->
        let errs = Actor_store.load_errors db execution_id in
        Blocked (List.map (fun s -> diagnostic_of_json (Yojson.Safe.from_string s)) errs)
      | "completed" -> Completed
      | "failed" ->
        let d = match diagnostic with
          | Some s -> diagnostic_of_json (Yojson.Safe.from_string s)
          | None -> { error = error "ActorFailed" "failed"; location = None; missing_branches = [] }
        in
        Failed d
      | _ -> Running
    in
    Ok {
      execution_id;
      request_id;
      status;
      outputs;
      pending_messages = pending;
      open_groups;
      deadline_ms = deadline;
    }

let inspect execution_id =
  if not (Atomic.get running) then Error (error "NotRunning" "Actor runtime is not running")
  else
    match !store with
    | None -> Error (error "NotRunning" "Actor runtime is not running")
    | Some st ->
      let n = Atomic.fetch_and_add inspect_calls 1 + 1 in
      (match !inspect_stall_ms with
       | ms when ms > 0 && n > !inspect_stall_after ->
         (try Eio_unix.sleep (float_of_int ms /. 1000.)
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | _ -> Unix.sleepf (float_of_int ms /. 1000.))
       | _ -> ());
      blocking (fun () ->
        let db = Actor_store.connect st in
        Fun.protect ~finally:(fun () -> Actor_store.close_db db) (fun () ->
          snapshot_of db execution_id))

let errors execution_id =
  if not (Atomic.get running) then Error (error "NotRunning" "Actor runtime is not running")
  else
    match !store with
    | None -> Error (error "NotRunning" "Actor runtime is not running")
    | Some st ->
      blocking (fun () ->
        let db = Actor_store.connect st in
        Fun.protect ~finally:(fun () -> Actor_store.close_db db) (fun () ->
          match Actor_store.load_execution db execution_id with
          | None -> Error (error "UnknownExecution" execution_id)
          | Some _ ->
            Ok (List.map (fun s -> diagnostic_of_json (Yojson.Safe.from_string s))
                  (Actor_store.load_errors db execution_id))))

let ( let* ) = Result.bind

let fail_exec db (claim : Actor_store.claim) code message missing =
  let loc = {
    node_id = claim.Actor_store.envelope.node_id;
    message_id = claim.message_id;
    actor = Some claim.actor;
    attempt = claim.attempt;
    at_ms = now_ms ();
  } in
  let d = { error = error code message; location = Some loc; missing_branches = missing } in
  let js = Yojson.Safe.to_string (diagnostic_to_json d) in
  let* () = Actor_store.insert_error db claim.execution_id js in
  let* () = Actor_store.set_status db claim.execution_id "failed" (Some js) in
  let* () = Actor_store.discard_execution_inbox db claim.execution_id in
  let* () = Actor_store.invalidate_execution_timers db claim.execution_id in
  let* () = Actor_store.mark_done db claim.message_id in
  let* () =
    if code = "AttemptsExhausted" || code = "ActorFailed" then
      Actor_store.insert_dead db claim.envelope js
    else Ok ()
  in
  notify claim.execution_id;
  Ok d

let check_schema_on_claim _db (claim : Actor_store.claim) =
  let env = claim.Actor_store.envelope in
  match Actor_json.member "actors" env.contracts with
  | Some (`Assoc acts) ->
    List.for_all (fun (name, body) ->
      if is_runtime_actor name then true
      else
        match find_def name, body with
        | Some def, `Assoc _ ->
          (match Actor_json.member "hash" body with
           | Some (`String h) -> def.actor_contract_hash = h
           | _ -> true)
        | None, _ -> false
        | _ -> false
    ) acts
  | _ -> true

let delay_for (c : config) attempt =
  let idx = attempt - 1 in
  if idx < 0 then 0L
  else if idx >= List.length c.retry_policy.delays_ms then
    Int64.of_int (List.hd (List.rev c.retry_policy.delays_ms))
  else Int64.of_int (List.nth c.retry_policy.delays_ms idx)

let wf_of envelope : Actor_workflow.t =
  match Actor_workflow.validate (merged_descriptor ()) envelope.Actor_store.workflow with
  | Ok wf -> wf
  | Error _ ->
    { Actor_workflow.json = envelope.workflow;
      hash = envelope.workflow_hash;
      name = ""; version = ""; entry = ""; input_type = "";
      bindings = []; nodes = [] }

let resolve_dest_address desc (wf : Actor_workflow.t) payload payload_type dest_id =
  match Actor_workflow.node_of dest_id wf.Actor_workflow.nodes with
  | Some (Actor_workflow.Actor _ as n) ->
    Actor_workflow.resolve_address ~desc ~wf ~payload ~payload_type n
  | Some (Join _) ->
    Error (error "InvalidAddress" "join dest resolved later")
  | Some _ -> Ok { actor_type = "__well.step"; id = dest_id }
  | None -> Error (error "InvalidAddress" dest_id)

let child_envelope ~parent:(parent : Actor_store.envelope) ~node_id ~actor_address ~kind
    ~payload_type ~payload ~branch_path ~groups ~message_id =
  { Actor_store.format = 1;
    execution_id = parent.Actor_store.execution_id;
    message_id;
    causation_id = Some parent.message_id;
    workflow = parent.workflow;
    workflow_hash = parent.workflow_hash;
    contracts = parent.contracts;
    node_id;
    actor_address;
    message_kind = kind;
    payload_type;
    payload;
    branch_path;
    groups;
    created_at_ms = now_ms ();
    execution_deadline_ms = parent.execution_deadline_ms;
  }

type group_plan = {
  group_id : string;
  join_node : string;
  item_type : string;
  batch_type : string;
  expected : string;
  deadline_ms : int64;
  next_node : string;
  parent_groups : string;
  branch_path : string;
  source_message_id : string;
  timer_id : string;
}

type turn =
  | Do_commit of {
      state_blob : (string * int) option;
      children : Actor_store.envelope list;
      output : output option;
      group_insert : group_plan option;
      group_received : (string * string * bool) option;
      invalidate_timer : string option;
      open_groups_delta : int;
      join_deadline_ms : int64 option;
    }
  | Do_reschedule of { attempt : int; available_at : int64 }
  | Do_fail of { code : string; message : string; missing : string list }
  | Do_block of diagnostic
  | Do_mark_done

let commit_turn ?(state_blob = None) ?(children = []) ?(output = None)
    ?(group_insert = None) ?(group_received = None) ?(invalidate_timer = None)
    ?(open_groups_delta = 0) ?(join_deadline_ms = None) () =
  Do_commit {
    state_blob; children; output; group_insert; group_received;
    invalidate_timer; open_groups_delta; join_deadline_ms;
  }

let branch_id_of = function
  | `Assoc fs -> (match List.assoc_opt "id" fs with Some (`String id) -> Some id | _ -> None)
  | _ -> None

let handle_join db (claim : Actor_store.claim) (wf : Actor_workflow.t) desc =
  let env = claim.Actor_store.envelope in
  match List.rev env.groups with
  | [] -> Do_fail { code = "InvalidGroup"; message = "join without group"; missing = [] }
  | frame :: parent_rev ->
    let parent = List.rev parent_rev in
    match Actor_store.load_group db frame.group_id with
    | None -> Do_fail { code = "InvalidGroup"; message = "unknown group"; missing = [] }
    | Some g when g.Actor_store.closed -> Do_mark_done
    | Some g ->
      let now = now_ms () in
      if now >= g.deadline_ms || env.message_kind = "__well.timer" then
        let expected = Yojson.Safe.from_string g.expected in
        let received = Yojson.Safe.from_string g.received in
        let got = match received with `List xs -> List.filter_map branch_id_of xs | _ -> [] in
        let need = match expected with `List xs -> List.filter_map branch_id_of xs | _ -> [] in
        let missing = List.filter (fun id -> not (List.mem id got)) need in
        Do_fail { code = "JoinTimeout"; message = "join timeout"; missing }
      else
        let expected = match Yojson.Safe.from_string g.expected with `List xs -> xs | _ -> [] in
        let received = match Yojson.Safe.from_string g.received with `List xs -> xs | _ -> [] in
        let branch = frame.branch_id in
        let prior_message =
          List.find_map (fun item ->
            match item with
            | `Assoc fs when branch_id_of item = Some branch ->
              (match List.assoc_opt "message_id" fs with
               | Some (`String m) -> Some m
               | _ -> Some "")
            | _ -> None
          ) received
        in
        match prior_message with
        | Some m when m = env.message_id -> Do_mark_done
        | Some _ ->
          Do_fail { code = "DuplicateBranch"; message = "duplicate branch " ^ branch; missing = [] }
        | None ->
          let item = `Assoc [
            "id", `String branch;
            "ordinal", `Int frame.ordinal;
            "payload", env.payload;
            "message_id", `String env.message_id;
          ] in
          let received = received @ [item] in
          let complete = List.length received = List.length expected in
          if not complete then
            commit_turn
              ~group_received:(Some (frame.group_id, Yojson.Safe.to_string (`List received), false))
              ~join_deadline_ms:(Some g.deadline_ms)
              ()
          else
            let ordered =
              List.sort (fun a b ->
                let ord x = match x with `Assoc fs -> (match List.assoc_opt "ordinal" fs with Some (`Int n) -> n | _ -> 0) | _ -> 0 in
                compare (ord a) (ord b)
              ) received
            in
            let items = List.map (function `Assoc fs -> (match List.assoc_opt "payload" fs with Some p -> p | _ -> `Null) | p -> p) ordered in
            let batch = `List [`List items] in
            let next = g.next_node in
            let path =
              g.branch_path |> Yojson.Safe.from_string |> function
              | `List xs -> List.filter_map (function `Int n -> Some n | _ -> None) xs
              | _ -> env.branch_path
            in
            let dest_kind, dest_addr, payload_type =
              match Actor_workflow.node_of next wf.Actor_workflow.nodes with
              | Some (Actor_workflow.Actor { accept; _ } as n) ->
                let addr = Actor_workflow.resolve_address ~desc ~wf ~payload:batch ~payload_type:g.batch_type n in
                (accept, Result.value addr ~default:{ actor_type = "__well.step"; id = next }, g.batch_type)
              | Some (End _) -> ("end", { actor_type = "__well.step"; id = next }, g.batch_type)
              | Some (Join _) -> ("item", { actor_type = "__well.join"; id = next }, g.batch_type)
              | _ -> ("step", { actor_type = "__well.step"; id = next }, g.batch_type)
            in
            let child = child_envelope ~parent:env ~node_id:next
                ~actor_address:(Some dest_addr) ~kind:dest_kind
                ~payload_type ~payload:batch ~branch_path:path ~groups:parent
                ~message_id:(new_id "msg")
            in
            commit_turn
              ~children:[child]
              ~group_received:(Some (frame.group_id, Yojson.Safe.to_string (`List received), true))
              ~invalidate_timer:(Some ("join:" ^ frame.group_id))
              ~open_groups_delta:(-1)
              ~join_deadline_ms:(Some g.deadline_ms)
              ()

type emission_plan = {
  children : Actor_store.envelope list;
  group_insert : group_plan option;
  open_groups_delta : int;
}

let emit_children (claim : Actor_store.claim) cfg (wf : Actor_workflow.t) desc ~emissions ~mode ~join_opt ~outputs =
  let env = claim.Actor_store.envelope in
  let n = List.length emissions in
  let payload_ok =
    List.for_all (fun (_, _, payload) -> json_bytes payload <= cfg.limits.payload_bytes) emissions
  in
  (match mode with
   | Actor_workflow.One when n <> 1 -> Error (error "InvalidEmission" "expected one emission")
   | Actor_workflow.Optional when n > 1 -> Error (error "InvalidEmission" "expected optional emission")
   | _ when n > cfg.limits.emissions -> Error (error "LimitExceeded" "too many emissions")
   | _ when not payload_ok -> Error (error "LimitExceeded" "payload")
   | _ -> Ok ())
  |> function
  | Error e -> Error e
  | Ok () ->
    match join_opt, emissions with
    | Some join_id, [] ->
      (match Actor_workflow.node_of join_id wf.Actor_workflow.nodes with
       | Some (Actor_workflow.Join { batch_type; next; item_type = _; timeout_ms = _ }) ->
         let batch = `List [`List []] in
         let dest_addr, kind =
           match Actor_workflow.node_of next wf.nodes with
           | Some (Actor_workflow.Actor { accept; _ } as n) ->
             (match Actor_workflow.resolve_address ~desc ~wf ~payload:batch ~payload_type:batch_type n with
              | Ok a -> Some a, accept
              | Error _ -> Some { actor_type = "__well.step"; id = next }, accept)
           | _ -> Some { actor_type = "__well.step"; id = next }, "end"
         in
         let child = child_envelope ~parent:env ~node_id:next ~actor_address:dest_addr
             ~kind ~payload_type:batch_type ~payload:batch
             ~branch_path:env.branch_path ~groups:env.groups ~message_id:(new_id "msg")
         in
         Ok { children = [child]; group_insert = None; open_groups_delta = 0 }
       | _ -> Error (error "InvalidGroup" "join missing"))
    | Some join_id, items ->
      if List.length env.groups >= cfg.limits.group_depth then
        Error (error "LimitExceeded" "group_depth")
      else
      (match Actor_workflow.node_of join_id wf.nodes with
       | Some (Actor_workflow.Join { item_type; batch_type; timeout_ms; next }) ->
         let group_id = new_id "grp" in
         let expected =
           `List (List.mapi (fun i _ ->
             `Assoc ["id", `String (string_of_int i); "ordinal", `Int i]) items)
         in
         let deadline = Int64.add (now_ms ()) (Int64.of_int timeout_ms) in
         let parent_groups = Yojson.Safe.to_string (`List (List.map (fun g ->
           `Assoc ["group_id", `String g.Actor_workflow.group_id;
                   "branch_id", `String g.branch_id;
                   "ordinal", `Int g.ordinal;
                   "join_node", `String g.join_node]) env.groups))
         in
         let branch_path = Yojson.Safe.to_string (`List (List.map (fun n -> `Int n) env.branch_path)) in
         let plan = {
           group_id; join_node = join_id; item_type; batch_type;
           expected = Yojson.Safe.to_string expected; deadline_ms = deadline;
           next_node = next; parent_groups; branch_path;
           source_message_id = env.message_id; timer_id = "join:" ^ group_id;
         } in
         let children = List.mapi (fun i (kind, payload_type, payload) ->
           let dest = List.assoc kind outputs in
           let frame = Actor_workflow.{ group_id; branch_id = string_of_int i; ordinal = i; join_node = join_id } in
           let groups = env.groups @ [frame] in
           let addr, msg_kind =
             match Actor_workflow.node_of dest wf.nodes with
             | Some (Actor_workflow.Join _) ->
               Some { actor_type = "__well.join"; id = group_id }, "item"
             | Some (Actor_workflow.Actor { accept; _ } as n) ->
               (match Actor_workflow.resolve_address ~desc ~wf ~payload ~payload_type n with
                | Ok a -> Some a, accept
                | Error _ -> Some { actor_type = "__well.step"; id = dest }, accept)
             | Some (End _) -> Some { actor_type = "__well.step"; id = dest }, "end"
             | Some (Drop _) -> Some { actor_type = "__well.step"; id = dest }, "drop"
             | Some (Fork _) -> Some { actor_type = "__well.step"; id = dest }, "fork"
             | None -> Some { actor_type = "__well.step"; id = dest }, kind
           in
           child_envelope ~parent:env ~node_id:dest ~actor_address:addr ~kind:msg_kind
             ~payload_type ~payload
             ~branch_path:(env.branch_path @ [i]) ~groups ~message_id:(new_id "msg")
         ) items in
         Ok { children; group_insert = Some plan; open_groups_delta = 1 }
       | _ -> Error (error "InvalidGroup" "join missing"))
    | None, items ->
      let rec go i acc = function
        | [] -> Ok { children = List.rev acc; group_insert = None; open_groups_delta = 0 }
        | (kind, payload_type, payload) :: rest ->
          match List.assoc_opt kind outputs with
          | None -> Error (error "InvalidEmission" ("no route for " ^ kind))
          | Some dest ->
            match Actor_workflow.node_of dest wf.nodes with
            | None -> Error (error "InvalidAddress" dest)
            | Some node ->
              let addr, msg_kind =
                match node with
                | Actor_workflow.Actor { accept; _ } ->
                  (match Actor_workflow.resolve_address ~desc ~wf ~payload ~payload_type node with
                   | Ok a -> Some a, accept
                   | Error _ -> None, accept)
                | Join _ ->
                  (match List.rev env.groups with
                   | f :: _ -> Some { actor_type = "__well.join"; id = f.group_id }, "item"
                   | [] -> Some { actor_type = "__well.join"; id = dest }, "item")
                | End _ -> Some { actor_type = "__well.step"; id = dest }, "end"
                | Drop _ -> Some { actor_type = "__well.step"; id = dest }, "drop"
                | Fork _ -> Some { actor_type = "__well.step"; id = dest }, "fork"
              in
              let addr =
                match addr with
                | Some a -> Some a
                | None ->
                  (match Actor_workflow.resolve_address ~desc ~wf ~payload ~payload_type node with
                   | Ok a -> Some a
                   | Error _ -> Some { actor_type = "__well.step"; id = dest })
              in
              let child = child_envelope ~parent:env ~node_id:dest ~actor_address:addr
                  ~kind:msg_kind ~payload_type ~payload
                  ~branch_path:(env.branch_path @ [i]) ~groups:env.groups
                  ~message_id:(new_id "msg")
              in
              go (i + 1) (child :: acc) rest
      in
      go 0 [] items

let handle_app (claim : Actor_store.claim) cfg (wf : Actor_workflow.t) desc def =
  let env = claim.Actor_store.envelope in
  let module R = (val def.Actor_contract.raw) in
  match claim.state_version with
  | Some v when v <> R.state_version ->
    Do_block {
      error = error "SchemaMismatch" "state_version";
      location = Some { node_id = env.node_id; message_id = env.message_id;
                        actor = Some claim.actor; attempt = claim.attempt; at_ms = now_ms () };
      missing_branches = [];
    }
  | _ ->
    let state =
      match claim.state_blob with
      | None -> R.init claim.actor
      | Some blob ->
        match R.state_of_wire (Yojson.Safe.from_string blob) with
        | Ok s -> s
        | Error _ -> raise (Failure "state")
    in
    let ctx = {
      self = claim.actor;
      execution_id = claim.execution_id;
      message_id = claim.message_id;
      attempt = claim.attempt;
      deadline_ms = env.execution_deadline_ms;
    } in
    match R.inbound_of_wire ~kind:env.message_kind env.payload with
    | Error msg -> Do_fail { code = "InvalidInput"; message = msg; missing = [] }
    | Ok inbound ->
      match R.handle ctx state inbound with
      | Error (Retry msg) ->
        let attempt = claim.attempt + 1 in
        if attempt >= cfg.retry_policy.max_attempts then
          Do_fail { code = "AttemptsExhausted"; message = msg; missing = [] }
        else
          let avail = Int64.add (now_ms ()) (delay_for cfg attempt) in
          Do_reschedule { attempt; available_at = avail }
      | Error (Fail msg) -> Do_fail { code = "ActorFailed"; message = msg; missing = [] }
      | Ok (state', outs) ->
        let emission_mode, join_opt, outputs =
          match Actor_workflow.node_of env.node_id wf.nodes with
          | Some (Actor_workflow.Actor { emission_mode; join; outputs; _ }) ->
            emission_mode, join, outputs
          | _ -> Actor_workflow.One, None, []
        in
        let rec pack acc = function
          | [] -> Ok (List.rev acc)
          | o :: rest ->
            let kind, payload = R.outbound_to_wire o in
            match List.assoc_opt kind def.emits with
            | None -> Error (error "InvalidEmission" kind)
            | Some payload_type ->
              match Actor_contract.validate_payload desc ~payload_type payload with
              | Error e -> Error e
              | Ok _ -> pack ((kind, payload_type, payload) :: acc) rest
        in
        match pack [] outs with
        | Error e -> Do_fail { code = e.code; message = e.message; missing = [] }
        | Ok packed ->
          match emit_children claim cfg wf desc ~emissions:packed
                  ~mode:emission_mode ~join_opt ~outputs
          with
          | Error e -> Do_fail { code = e.code; message = e.message; missing = [] }
          | Ok plan ->
            let blob = Yojson.Safe.to_string (R.state_to_wire state') in
            if String.length blob > cfg.limits.state_bytes then
              Do_fail { code = "LimitExceeded"; message = "state"; missing = [] }
            else
              commit_turn
                ~state_blob:(Some (blob, R.state_version))
                ~children:plan.children
                ~group_insert:plan.group_insert
                ~open_groups_delta:plan.open_groups_delta
                ()

let handle_fork (claim : Actor_store.claim) cfg (wf : Actor_workflow.t) desc =
  let env = claim.Actor_store.envelope in
  match Actor_workflow.node_of env.node_id wf.Actor_workflow.nodes with
  | Some (Actor_workflow.Fork { branches; join; input_type }) ->
    let packed = List.map (fun (name, dest) ->
      ignore dest; (name, input_type, env.payload)
    ) branches in
    let outputs = List.map (fun (name, dest) -> (name, dest)) branches in
    (match emit_children claim cfg wf desc ~emissions:packed
             ~mode:Many ~join_opt:join ~outputs
     with
     | Error e -> Do_fail { code = e.code; message = e.message; missing = [] }
     | Ok plan ->
       commit_turn
         ~children:plan.children
         ~group_insert:plan.group_insert
         ~open_groups_delta:plan.open_groups_delta
         ())
  | _ -> Do_fail { code = "InvalidWorkflow"; message = "not a fork"; missing = [] }

let handle_end (claim : Actor_store.claim) ~drop =
  let env = claim.Actor_store.envelope in
  let output =
    if drop then None
    else
      let hash =
        match Actor_contract.find_message (merged_descriptor ()) env.payload_type with
        | Some (_, (_, h)) -> h
        | None -> ""
      in
      Some {
        path = env.branch_path;
        payload_type = env.payload_type;
        schema_hash = hash;
        payload = env.payload;
      }
  in
  commit_turn ~output ()

let block_diag (claim : Actor_store.claim) message =
  {
    error = error "SchemaMismatch" message;
    location = Some {
      node_id = claim.Actor_store.envelope.node_id;
      message_id = claim.message_id;
      actor = Some claim.actor;
      attempt = claim.attempt;
      at_ms = now_ms ();
    };
    missing_branches = [];
  }

let compute_turn db (claim : Actor_store.claim) cfg =
  let env = claim.Actor_store.envelope in
  if not (check_schema_on_claim db claim) then
    Do_block (block_diag claim "contract")
  else
    let desc = merged_descriptor () in
    let wf = wf_of env in
    match Actor_workflow.node_of env.node_id wf.nodes with
    | Some (Actor_workflow.Fork _) -> handle_fork claim cfg wf desc
    | Some (Actor_workflow.End _) -> handle_end claim ~drop:false
    | Some (Actor_workflow.Drop _) -> handle_end claim ~drop:true
    | Some (Actor_workflow.Join _) -> handle_join db claim wf desc
    | Some (Actor_workflow.Actor _) when claim.actor.actor_type = "__well.join" ->
      handle_join db claim wf desc
    | Some (Actor_workflow.Actor _) ->
      (match find_def claim.actor.actor_type with
       | None -> Do_block (block_diag claim "missing actor type")
       | Some def -> handle_app claim cfg wf desc def)
    | None when claim.actor.actor_type = "__well.join" ->
      handle_join db claim wf desc
    | None -> Do_fail { code = "InvalidWorkflow"; message = "unknown node"; missing = [] }

let write_children db children =
  let rec go i = function
    | [] -> Ok ()
    | child :: rest ->
      let* () = Actor_store.insert_outbox db child ~seq:i in
      go (i + 1) rest
  in
  go 0 children

let apply_commit db (claim : Actor_store.claim) cfg
    ~state_blob ~children ~output ~group_insert ~group_received ~invalidate_timer ~open_groups_delta
    ~join_deadline_ms =
  let env = claim.Actor_store.envelope in
  if now_ms () >= env.execution_deadline_ms then
    let* _ = fail_exec db claim "ExecutionTimeout" "deadline" [] in Ok ()
  else
    match join_deadline_ms with
    | Some dl when now_ms () >= dl ->
      let missing =
        match group_received with
        | Some (gid, received, _) ->
          (match Actor_store.load_group db gid with
           | None -> []
           | Some g ->
             let expected = match Yojson.Safe.from_string g.expected with `List xs -> List.filter_map branch_id_of xs | _ -> [] in
             let got = match Yojson.Safe.from_string received with `List xs -> List.filter_map branch_id_of xs | _ -> [] in
             List.filter (fun id -> not (List.mem id got)) expected)
        | None -> []
      in
      let* _ = fail_exec db claim "JoinTimeout" "join timeout" missing in Ok ()
    | _ ->
    let n_children = List.length children in
    let deliveries = Actor_store.deliveries_of db claim.execution_id in
    let pending_global = Actor_store.count_pending db in
    if deliveries + n_children > cfg.limits.deliveries_per_execution then
      let* _ = fail_exec db claim "LimitExceeded" "deliveries" [] in Ok ()
    else if pending_global + n_children > cfg.limits.pending_deliveries then
      let* _ = fail_exec db claim "LimitExceeded" "pending_deliveries" [] in Ok ()
    else
      let* () =
        match state_blob with
        | None -> Ok ()
        | Some (blob, version) ->
          Actor_store.upsert_state db claim.actor blob version (claim.state_revision + 1)
      in
      let () = Actor_store.check_crash "commit_turn:after_state" in
      let* () =
        match output with
        | None -> Ok ()
        | Some o -> Actor_store.add_output db o claim.execution_id
      in
      let* () =
        match group_insert with
        | None -> Ok ()
        | Some g ->
          let* () = Actor_store.insert_group db
              ~group_id:g.group_id ~execution_id:claim.execution_id
              ~join_node:g.join_node ~item_type:g.item_type ~batch_type:g.batch_type
              ~expected:g.expected ~deadline_ms:g.deadline_ms ~next_node:g.next_node
              ~parent_groups:g.parent_groups ~branch_path:g.branch_path
              ~source_message_id:g.source_message_id
          in
          Actor_store.insert_timer db ~timer_id:g.timer_id
            ~execution_id:claim.execution_id ~kind:"join" ~fire_at:g.deadline_ms
            ~payload:g.group_id
      in
      let () = Actor_store.check_crash "commit_turn:after_groups" in
      let* () =
        match group_received with
        | None -> Ok ()
        | Some (gid, received, closed) ->
          Actor_store.save_group_received db gid received closed
      in
      let* () =
        match invalidate_timer with
        | None -> Ok ()
        | Some tid -> Actor_store.invalidate_timer db tid
      in
      let* () =
        if open_groups_delta = 0 then Ok ()
        else Actor_store.bump_open_groups db claim.execution_id open_groups_delta
      in
      let* () = write_children db children in
      let () = Actor_store.check_crash "commit_turn:after_outbox" in
      let* () =
        if n_children = 0 then Ok ()
        else Actor_store.add_deliveries db claim.execution_id n_children
      in
      let* () = Actor_store.mark_done db claim.message_id in
      let pending = Actor_store.pending_of db claim.execution_id in
      let exec = Actor_store.load_execution db claim.execution_id in
      let open_g, status =
        match exec with
        | Some (_, st, _, _, og, _, _) -> og, st
        | None -> 0, "missing"
      in
      let out_left = pending + n_children in
      let* () = Actor_store.set_pending db claim.execution_id out_left in
      if status = "running" && open_g = 0 && pending = 0 && children = [] then begin
        let* () = Actor_store.set_status db claim.execution_id "completed" None in
        let* () = Actor_store.invalidate_execution_timers db claim.execution_id in
        notify claim.execution_id;
        Ok ()
      end else Ok ()

let apply_turn db (claim : Actor_store.claim) cfg turn =
  match Actor_store.recheck_claim db ~owner:!owner_id claim with
  | Actor_store.Claim_already_committed -> Ok ()
  | Actor_store.Claim_lost ->
    let* _ = Actor_store.recover_if_claimed db claim.message_id in Ok ()
  | Actor_store.Claim_discard_after_failure ->
    let loc = {
      node_id = claim.Actor_store.envelope.node_id;
      message_id = claim.message_id;
      actor = Some claim.actor;
      attempt = claim.attempt;
      at_ms = now_ms ();
    } in
    let d = {
      error = error "DiscardedAfterFailure" "in-flight after terminal";
      location = Some loc; missing_branches = [];
    } in
    let js = Yojson.Safe.to_string (diagnostic_to_json d) in
    let* () = Actor_store.insert_error db claim.execution_id js in
    Actor_store.mark_done db claim.message_id
  | Actor_store.Claim_ready ->
    match turn with
    | Do_commit { state_blob; children; output; group_insert; group_received; invalidate_timer; open_groups_delta; join_deadline_ms } ->
      apply_commit db claim cfg ~state_blob ~children ~output ~group_insert
        ~group_received ~invalidate_timer ~open_groups_delta ~join_deadline_ms
    | Do_reschedule { attempt; available_at } ->
      Actor_store.reschedule db claim.message_id ~attempt ~available_at
    | Do_fail { code; message; missing } ->
      let* _ = fail_exec db claim code message missing in Ok ()
    | Do_block d ->
      let js = Yojson.Safe.to_string (diagnostic_to_json d) in
      let* () = Actor_store.insert_error db claim.execution_id js in
      let* () = Actor_store.set_status db claim.execution_id "blocked" (Some js) in
      Actor_store.release_claim db claim.message_id
    | Do_mark_done ->
      Actor_store.mark_done db claim.message_id

let rec deliver_outbox db = function
  | [] -> Ok ()
  | (mid, env_s) :: rest ->
    let env = Actor_store.envelope_of_json (Yojson.Safe.from_string env_s) in
    if Actor_store.execution_is_blocked db env.execution_id then
      deliver_outbox db rest
    else if Actor_store.inbox_has db mid then
      let* () = Actor_store.mark_outbox_delivered db mid in
      deliver_outbox db rest
    else
      let* () = Actor_store.insert_inbox db env ~attempt:0 ~available_at:0L in
      let* () = Actor_store.mark_outbox_delivered db mid in
      deliver_outbox db rest

let fail_execution_timeout db execution_id =
  let d = { error = error "ExecutionTimeout" "deadline"; location = None; missing_branches = [] } in
  let js = Yojson.Safe.to_string (diagnostic_to_json d) in
  match Actor_store.set_status_if db execution_id ~allowed:["running"; "blocked"] "failed" (Some js) with
  | Error "no_row" -> Ok ()
  | Error e -> Error e
  | Ok () ->
    let* () = Actor_store.insert_error db execution_id js in
    let* () = Actor_store.discard_execution_inbox db execution_id in
    let* () = Actor_store.invalidate_execution_timers db execution_id in
    notify execution_id;
    Ok ()

let rec fire_timers db = function
  | [] -> Ok ()
  | (timer_id, execution_id, kind, payload) :: rest ->
    if Actor_store.execution_is_blocked db execution_id && kind <> "execution" then
      fire_timers db rest
    else
    let* () = Actor_store.mark_timer_delivered db timer_id in
    let* () =
      if kind = "join" then
        let env = {
          Actor_store.format = 1;
          execution_id;
          message_id = new_id "timer";
          causation_id = None;
          workflow = `Assoc [];
          workflow_hash = "";
          contracts = `Assoc [];
          node_id = payload;
          actor_address = Some { actor_type = "__well.join"; id = payload };
          message_kind = "__well.timer";
          payload_type = "void";
          payload = `Null;
          branch_path = [];
          groups = [{ group_id = payload; branch_id = ""; ordinal = 0; join_node = payload }];
          created_at_ms = now_ms ();
          execution_deadline_ms = Int64.add (now_ms ()) 1L;
        } in
        match Actor_store.load_execution db execution_id with
        | Some (_, status, _, _, _, deadline, wf) when status = "running" ->
          let env = { env with workflow = Yojson.Safe.from_string wf; execution_deadline_ms = deadline } in
          Actor_store.insert_inbox db env ~attempt:0 ~available_at:0L
        | _ -> Ok ()
      else if kind = "execution" then
        fail_execution_timeout db execution_id
      else Ok ()
    in
    fire_timers db rest

let note_pending_unstick mid =
  with_mu (fun () -> Hashtbl.replace pending_unstick mid ())

let note_pending_clear mid gen =
  with_mu (fun () ->
    if not (List.exists (fun (m, g) -> m = mid && g = gen) !pending_clear) then
      pending_clear := (mid, gen) :: !pending_clear)

let remove_pending_clear mid gen =
  with_mu (fun () ->
    pending_clear := List.filter (fun (m, g) -> not (m = mid && g = gen)) !pending_clear)

let inflight_inc mid =
  with_mu (fun () ->
    Hashtbl.replace inflight mid (1 + Option.value ~default:0 (Hashtbl.find_opt inflight mid)))

let inflight_dec mid =
  with_mu (fun () ->
    match Hashtbl.find_opt inflight mid with
    | Some n when n > 1 -> Hashtbl.replace inflight mid (n - 1)
    | _ -> Hashtbl.remove inflight mid)

let wait_armed flag waiting =
  if Atomic.get flag = 1 then begin
    Atomic.incr waiting;
    (try
       while Atomic.get flag = 1 && Atomic.get running do
         try Eio_unix.sleep 0.001
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | _ -> Unix.sleepf 0.001
       done
     with exn -> Atomic.decr waiting; raise exn);
    Atomic.decr waiting
  end

let wait_cleanup_retire () =
  if Atomic.get cleanup_retire_arm <> 1 then ()
  else
    let rec loop () =
      if Atomic.get cleanup_retire_arm <> 1 || not (Atomic.get running) then ()
      else
        let n = Atomic.get cleanup_retire_budget in
        if n > 0 && Atomic.compare_and_set cleanup_retire_budget n (n - 1) then ()
        else begin
          Atomic.incr cleanup_retire_waiting;
          (try
             while Atomic.get cleanup_retire_arm = 1
                   && Atomic.get running
                   && Atomic.get cleanup_retire_budget <= 0 do
               try Eio_unix.sleep 0.001
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | _ -> Unix.sleepf 0.001
             done
           with exn -> Atomic.decr cleanup_retire_waiting; raise exn);
          Atomic.decr cleanup_retire_waiting;
          loop ()
        end
    in
    loop ()

let finish_activation st (claim : Actor_store.claim) =
  wait_armed finish_arm finish_waiting;
  let db = Actor_store.connect st in
  Fun.protect ~finally:(fun () -> Actor_store.close_db db) (fun () ->
    match Actor_store.retire_activation db
            ~message_id:claim.message_id
            ~generation:claim.inflight_gen
    with
    | Ok () -> ()
    | Error _ ->
      note_pending_clear claim.message_id claim.inflight_gen;
      (match Actor_store.inbox_status db claim.message_id with
       | Some "claimed" -> note_pending_unstick claim.message_id
       | _ -> ()))

let process_pending_clear db =
  let clears = with_mu (fun () -> !pending_clear) in
  (if clears <> [] then wait_armed cleanup_copy_arm cleanup_copy_waiting);
  List.iter (fun (mid, gen) ->
    wait_cleanup_retire ();
    match Actor_store.retire_activation db ~message_id:mid ~generation:gen with
    | Ok () -> remove_pending_clear mid gen
    | Error _ -> ()) clears

let recover_activation db (claim : Actor_store.claim) =
  match Actor_store.recover_if_claimed db claim.message_id with
  | Ok `Committed | Ok `Ready | Ok `Released | Ok `Missing -> ()
  | Error _ ->
    Actor_store.bump_storage_error db;
    note_pending_unstick claim.message_id

let await_hold (claim : Actor_store.claim) =
  let key = actor_id_key claim.actor in
  match with_mu (fun () -> Hashtbl.find_opt hold key) with
  | Some p -> Eio.Promise.await p
  | None -> ()

let run_activation cfg st (claim : Actor_store.claim) =
  try
    await_hold claim;
    let rdb = Actor_store.connect st in
    let turn =
      Fun.protect ~finally:(fun () -> Actor_store.close_db rdb) (fun () ->
        compute_turn rdb claim cfg)
    in
    (match with_mu (fun () -> !after_handle_hook) with Some f -> f claim.actor | None -> ());
    Actor_store.check_crash "after_handle_before_commit";
    let wdb = Actor_store.connect st in
    Fun.protect ~finally:(fun () -> Actor_store.close_db wdb) (fun () ->
      match Actor_store.with_tx wdb
              ~crash_before:"commit_turn:before_commit"
              ~crash_after:"commit_turn:after_commit"
              (fun () -> apply_turn wdb claim cfg turn)
      with
      | Ok () ->
        (match turn with
         | Do_commit { group_received = Some (_, _, true); _ } ->
           Actor_store.check_crash "join_complete:after_commit"
         | _ -> ())
      | Error msg ->
        with_mu (fun () -> last_turn_error := Some msg);
        Actor_store.bump_storage_error wdb;
        recover_activation wdb claim)
  with
  | Eio.Cancel.Cancelled _ as exn ->
    let wdb = Actor_store.connect st in
    Fun.protect ~finally:(fun () -> Actor_store.close_db wdb) (fun () ->
      match Actor_store.release_claim wdb claim.message_id with
      | Ok () -> ()
      | Error _ -> note_pending_unstick claim.message_id);
    raise exn
  | exn ->
    let wdb = Actor_store.connect st in
    Fun.protect ~finally:(fun () -> Actor_store.close_db wdb) (fun () ->
      let attempt = claim.attempt + 1 in
      match Actor_store.with_tx wdb ~crash_before:"" ~crash_after:"" (fun () ->
        if attempt >= cfg.retry_policy.max_attempts then
          let* _ = fail_exec wdb claim "AttemptsExhausted" (Printexc.to_string exn) [] in Ok ()
        else
          Actor_store.reschedule wdb claim.message_id ~attempt
            ~available_at:(Int64.add (now_ms ()) (delay_for cfg attempt)))
      with
      | Ok () -> ()
      | Error _ -> recover_activation wdb claim)

let rec scheduler_loop ~sw cfg st =
  if not (Atomic.get running) then begin
    let ms = Atomic.get shutdown_hang_ms in
    if ms > 0 then Unix.sleepf (float_of_int ms /. 1000.)
  end else
    let db = Actor_store.connect st in
    Fun.protect ~finally:(fun () -> Actor_store.close_db db) (fun () ->
      process_pending_clear db;
      let ids =
        with_mu (fun () ->
          Hashtbl.fold (fun mid () acc -> mid :: acc) pending_unstick [])
      in
      (if ids <> [] then wait_armed unstick_arm unstick_waiting);
      let ids =
        with_mu (fun () ->
          Hashtbl.fold (fun mid () acc -> mid :: acc) pending_unstick [])
      in
      (match Actor_store.unstick_message_ids db ids with
       | Error _ -> ()
       | Ok () ->
         List.iter (fun mid ->
           match Actor_store.inbox_status db mid with
           | Some "claimed" ->
             (match Actor_store.inflight_generation db mid with
              | None -> ()
              | Some g ->
                let stale =
                  with_mu (fun () ->
                    List.exists (fun (m, gen) -> m = mid && gen = g) !pending_clear)
                in
                if not stale then
                  with_mu (fun () -> Hashtbl.remove pending_unstick mid))
           | _ -> with_mu (fun () -> Hashtbl.remove pending_unstick mid)) ids);
      let pending_out = Actor_store.undelivered_outbox db in
      (match Actor_store.with_tx db
               ~crash_before:(if pending_out = [] then "" else "deliver_outbox:before_commit")
               ~crash_after:(if pending_out = [] then "" else "deliver_outbox:after_commit")
               (fun () ->
         let* () = Actor_store.discard_terminal_inbox db in
         let* () = deliver_outbox db pending_out in
         fire_timers db (Actor_store.due_timers db (now_ms ())))
       with Ok () | Error _ -> ());
      wait_armed claim_pause_arm claim_pause_waiting;
      process_pending_clear db;
      let rec take_slot () =
        let n = Atomic.get active in
        if n >= cfg.limits.max_active then false
        else if Atomic.compare_and_set active n (n + 1) then true
        else take_slot ()
      in
      let rec fill () =
        if not (take_slot ()) then ()
        else
          let claimed = ref None in
          match Actor_store.with_tx db ~crash_before:"" ~crash_after:"" (fun () ->
              match Actor_store.claim_turn db ~owner:!owner_id ~now:(now_ms ()) with
              | Ok (Some claim) ->
                inflight_inc claim.message_id;
                claimed := Some claim;
                Ok (Some claim)
              | other -> other)
          with
          | Ok (Some claim) ->
            wait_armed claim_gap_arm claim_gap_waiting;
            Eio.Fiber.fork ~sw (fun () ->
              Fun.protect ~finally:(fun () ->
                finish_activation st claim;
                inflight_dec claim.message_id;
                Atomic.decr active;
                Atomic.incr activations_finished;
                wakeup ()) (fun () ->
                run_activation cfg st claim));
            fill ()
          | _ ->
            (match !claimed with
             | Some c -> inflight_dec c.message_id
             | None -> ());
            Atomic.decr active
      in
      fill ());
    (try Eio_unix.sleep 0.02 with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | _ -> Unix.sleepf 0.02);
    scheduler_loop ~sw cfg st

let start ~sw =
  frozen := true;
  match !config with
  | None -> Ok ()
  | Some cfg ->
    match Actor_store.acquire cfg.store_path with
    | Error e -> Error e
    | Ok st ->
      match Actor_store.init st with
      | Error e -> Actor_store.release st; Error e
      | Ok () ->
        let db = Actor_store.connect st in
        Fun.protect ~finally:(fun () -> Actor_store.close_db db) (fun () ->
          Actor_store.recover db);
        store := Some st;
        Atomic.set running true;
        owner_id := Printf.sprintf "p%d" (Unix.getpid ());
        Eio.Switch.on_release sw (fun () ->
          Atomic.set running false);

        let rec spawn n =
          if n <= 0 then ()
          else begin
            Atomic.incr worker_live;
            Eio.Fiber.fork_daemon ~sw (fun () ->
              Fun.protect ~finally:(fun () ->
                own_log "worker exit";
                Atomic.decr worker_live) (fun () ->
                own_log "worker start";
                try
                  Eio.Domain_manager.run (Env.domain_mgr ()) (fun () ->
                    Eio.Switch.run (fun wsw -> scheduler_loop ~sw:wsw cfg st))
                with
                | Eio.Cancel.Cancelled _ -> ()
                | Invalid_argument _ | Failure _ ->
                  (try scheduler_loop ~sw cfg st with Eio.Cancel.Cancelled _ -> ()));
              `Stop_daemon);
            spawn (n - 1)
          end
        in
        spawn (max 1 cfg.limits.domains);
        wakeup ();
        Ok ()

let send ~request_id ~timeout_ms (wf : Actor_workflow.t) packed =
  if not (Atomic.get running) then Error (error "NotRunning" "Actor runtime is not running")
  else if request_id = "" || String.length request_id > 128 then
    Error (error "InvalidInput" "request_id")
  else if timeout_ms <= 0 || timeout_ms > 2_592_000_000 then
    Error (error "InvalidInput" "timeout_ms")
  else
    match !config, !store with
    | Some cfg, Some st ->
      let Message (mt, value) = packed in
      if mt.name <> wf.Actor_workflow.input_type then
        Error (error "InvalidInput" "payload type does not match workflow")
      else
        let payload = try mt.encode value with Invalid_argument _ -> raise (Invalid_argument "encode") in
        if json_bytes payload > cfg.limits.payload_bytes
           || json_bytes wf.json > cfg.limits.workflow_bytes then
          Error (error "LimitExceeded" "payload or workflow")
        else
        (match Actor_contract.validate_payload (merged_descriptor ()) ~payload_type:mt.name payload with
         | Error e -> Error e
         | Ok schema_hash ->
           let admission =
             Actor_jcs.canonicalize (`Assoc [
               "workflow", wf.json;
               "payload_type", `String mt.name;
               "schema_hash", `String schema_hash;
               "payload", payload;
               "timeout_ms", `Int timeout_ms;
             ])
           in
           blocking (fun () ->
             let db = Actor_store.connect st in
             Fun.protect ~finally:(fun () -> Actor_store.close_db db) (fun () ->
               let execution_id = new_id "ex" in
               let now = now_ms () in
               let deadline = Int64.add now (Int64.of_int timeout_ms) in
               let desc = merged_descriptor () in
               let contracts = Actor_workflow.contracts_json desc wf in
               let entry_node = List.assoc wf.entry wf.nodes in
               let addr, kind =
                 match entry_node with
                 | Actor_workflow.Actor { accept; _ } ->
                   (match Actor_workflow.resolve_address ~desc ~wf ~payload ~payload_type:mt.name entry_node with
                    | Ok a -> Some a, accept
                    | Error _ -> None, accept)
                 | Fork _ -> Some { actor_type = "__well.step"; id = wf.entry }, "fork"
                 | End _ -> Some { actor_type = "__well.step"; id = wf.entry }, "end"
                 | Drop _ -> Some { actor_type = "__well.step"; id = wf.entry }, "drop"
                 | Join _ -> Some { actor_type = "__well.join"; id = wf.entry }, "item"
               in
               let addr =
                 match addr with
                 | Some a -> Some a
                 | None ->
                   (match Actor_workflow.resolve_address ~desc ~wf ~payload ~payload_type:mt.name entry_node with
                    | Ok a -> Some a
                    | Error _ -> Some { actor_type = "__well.step"; id = wf.entry })
               in
               let env = {
                 Actor_store.format = 1;
                 execution_id;
                 message_id = new_id "msg";
                 causation_id = None;
                 workflow = wf.json;
                 workflow_hash = wf.hash;
                 contracts;
                 node_id = wf.entry;
                 actor_address = addr;
                 message_kind = kind;
                 payload_type = mt.name;
                 payload;
                 branch_path = [];
                 groups = [];
                 created_at_ms = now;
                 execution_deadline_ms = deadline;
               } in
               match Actor_store.with_tx db
                       ~crash_before:"admit:before_commit"
                       ~crash_after:"admit:after_commit"
                       (fun () ->
                          match Actor_store.find_request db request_id with
                          | Some (eid, jcs, _) when jcs = admission -> Ok (`Idempotent eid)
                          | Some _ -> Ok (`Fail (error "IdempotencyConflict" request_id))
                          | None ->
                            if Actor_store.count_running db >= cfg.limits.active_executions
                               || Actor_store.count_pending db >= cfg.limits.pending_deliveries then
                              Ok (`Fail (error "Overloaded" "admission limit"))
                            else
                              match Actor_store.insert_execution db ~execution_id ~request_id
                                      ~admission_jcs:admission
                                      ~workflow:(Yojson.Safe.to_string wf.json)
                                      ~workflow_hash:wf.hash
                                      ~timeout_ms ~deadline_ms:deadline ~now
                              with
                              | Error e -> Error e
                              | Ok () ->
                                let* () = Actor_store.insert_timer db
                                  ~timer_id:("exec:" ^ execution_id)
                                  ~execution_id ~kind:"execution" ~fire_at:deadline ~payload:execution_id
                                in
                                let* () = Actor_store.insert_inbox db env ~attempt:0 ~available_at:now in
                                Ok (`New execution_id))
               with
               | Error msg -> Error (error "StorageUnavailable" msg)
               | Ok (`Idempotent eid) -> Ok eid
               | Ok (`Fail e) -> Error e
               | Ok (`New eid) -> wakeup (); Ok eid)))
    | _ -> Error (error "NotRunning" "Actor runtime is not running")

let await ~timeout_ms execution_id =
  if not (Atomic.get running) then Error (error "NotRunning" "Actor runtime is not running")
  else if timeout_ms <= 0 then Error (error "InvalidInput" "timeout_ms")
  else
    let terminal snap =
      match snap.status with Completed | Failed _ -> true | Running | Blocked _ -> false
    in
    match inspect execution_id with
    | Error e -> Error e
    | Ok snap when terminal snap -> Ok (Terminal snap)
    | Ok _ ->
      let p, u = Eio.Promise.create () in
      with_mu (fun () ->
        let rest = Option.value ~default:[] (Hashtbl.find_opt waiters execution_id) in
        Hashtbl.replace waiters execution_id (u :: rest));
      Fun.protect ~finally:(fun () -> remove_waiter execution_id u) (fun () ->
        match inspect execution_id with
        | Error e -> Error e
        | Ok snap when terminal snap -> Ok (Terminal snap)
        | Ok _ ->
          let deadline = Unix.gettimeofday () +. (float_of_int timeout_ms /. 1000.) in
          let rec wait () =
            match inspect execution_id with
            | Error e -> Error e
            | Ok snap when terminal snap -> Ok (Terminal snap)
            | Ok snap ->
              if Unix.gettimeofday () >= deadline then Ok (Wait_timeout snap)
              else begin
                (match Eio.Promise.peek p with
                 | Some () -> ()
                 | None ->
                   (try Eio_unix.sleep 0.01 with
                    | Eio.Cancel.Cancelled _ as exn -> raise exn
                    | _ -> Unix.sleepf 0.01));
                wait ()
              end
          in
          wait ())

let verify_resume db execution_id =
  let envelopes = Actor_store.load_execution_envelopes db execution_id in
  let rec check_env = function
    | [] -> Ok ()
    | ((env : Actor_store.envelope), actor) :: rest ->
      let claim = {
        Actor_store.message_id = env.message_id;
        execution_id = env.execution_id;
        actor;
        envelope = env;
        attempt = 0;
        inflight_gen = 0;
        state_blob = None;
        state_version = None;
        state_revision = 0;
      } in
      if not (check_schema_on_claim db claim) then
        Error (error "SchemaMismatch" "contract")
      else
        match find_def actor.actor_type with
        | None when is_runtime_actor actor.actor_type ->
          check_env rest
        | None -> Error (error "SchemaMismatch" ("missing actor type " ^ actor.actor_type))
        | Some def ->
          match Actor_store.load_state db actor with
          | Some (_, version, _) when version <> def.Actor_contract.state_version ->
            Error (error "SchemaMismatch" "state_version")
          | _ -> check_env rest
  in
  check_env envelopes

let resume execution_id =
  if not (Atomic.get running) then Error [error "NotRunning" "Actor runtime is not running"]
  else
    match !store with
    | None -> Error [error "NotRunning" "Actor runtime is not running"]
    | Some st ->
      blocking (fun () ->
        let db = Actor_store.connect st in
        Fun.protect ~finally:(fun () -> Actor_store.close_db db) (fun () ->
          match Actor_store.with_tx db ~crash_before:"" ~crash_after:"" (fun () ->
            match Actor_store.load_execution db execution_id with
            | None -> Ok (`Fail (error "UnknownExecution" execution_id))
            | Some (_, status, _, _, _, deadline, _) ->
              if status <> "blocked" then
                Ok (`Fail (error "InvalidOperation" "resume requires Blocked"))
              else if now_ms () >= deadline then
                let d = { error = error "ExecutionTimeout" "deadline"; location = None; missing_branches = [] } in
                let js = Yojson.Safe.to_string (diagnostic_to_json d) in
                match Actor_store.set_status_if db execution_id ~allowed:["blocked"] "failed" (Some js) with
                | Error "no_row" -> Ok (`Fail (error "InvalidOperation" "resume requires Blocked"))
                | Error e -> Error e
                | Ok () ->
                  let* () = Actor_store.insert_error db execution_id js in
                  Ok (`Fail (error "ExecutionTimeout" "deadline"))
              else
                match verify_resume db execution_id with
                | Error e -> Ok (`Fail e)
                | Ok () ->
                  match Actor_store.set_status_if db execution_id ~allowed:["blocked"] "running" None with
                  | Error "no_row" -> Ok (`Fail (error "InvalidOperation" "resume requires Blocked"))
                  | Error e -> Error e
                  | Ok () -> Ok `Resumed)
          with
          | Error msg -> Error [error "StorageUnavailable" msg]
          | Ok (`Fail e) -> Error [e]
          | Ok `Resumed -> wakeup (); Ok ()))

let abandon execution_id ~reason =
  if not (Atomic.get running) then Error (error "NotRunning" "Actor runtime is not running")
  else
    match !store with
    | None -> Error (error "NotRunning" "Actor runtime is not running")
    | Some st ->
      blocking (fun () ->
        let db = Actor_store.connect st in
        Fun.protect ~finally:(fun () -> Actor_store.close_db db) (fun () ->
          let d = { error = error "Abandoned" reason; location = None; missing_branches = [] } in
          let js = Yojson.Safe.to_string (diagnostic_to_json d) in
          match Actor_store.with_tx db ~crash_before:"" ~crash_after:"" (fun () ->
            match Actor_store.load_execution db execution_id with
            | None -> Ok (`Fail (error "UnknownExecution" execution_id))
            | Some (_, "failed", Some diag, _, _, _, _) ->
              let old = diagnostic_of_json (Yojson.Safe.from_string diag) in
              if old.error.code = "Abandoned" then Ok `Already else Ok (`Fail (error "InvalidOperation" "already terminal"))
            | Some (_, "running", _, _, _, _, _) | Some (_, "blocked", _, _, _, _, _) ->
              (match Actor_store.set_status_if db execution_id
                      ~allowed:["running"; "blocked"] "failed" (Some js)
              with
              | Error "no_row" -> Ok (`Fail (error "InvalidOperation" "already terminal"))
              | Error e -> Error e
              | Ok () ->
                let* () = Actor_store.insert_error db execution_id js in
                let* () = Actor_store.discard_execution_inbox db execution_id in
                let* () = Actor_store.invalidate_execution_timers db execution_id in
                Ok `Abandoned)
            | Some _ -> Ok (`Fail (error "InvalidOperation" "already terminal")))
          with
          | Error msg -> Error (error "StorageUnavailable" msg)
          | Ok (`Fail e) -> Error e
          | Ok `Already -> Ok ()
          | Ok `Abandoned -> notify execution_id; Ok ()))

let metrics () =
  if not (Atomic.get running) then invalid_arg "Well.Actor.metrics: runtime is not running";
  match !store with
  | None -> invalid_arg "Well.Actor.metrics: runtime is not running"
  | Some st ->
    blocking (fun () ->
      let db = Actor_store.connect st in
      Fun.protect ~finally:(fun () -> Actor_store.close_db db) (fun () ->
        Actor_store.metrics db))

let activations_finished_count () = Atomic.get activations_finished

let waiter_count () =
  with_mu (fun () ->
    Hashtbl.fold (fun _ us n -> n + List.length us) waiters 0)
let set_after_handle f = with_mu (fun () -> after_handle_hook := Some f)
let now_ms_export () = now_ms ()

let wait_workers () =
  let budget = max 1 (Atomic.get join_timeout_ms / 10) in
  let rec loop n =
    let live = Atomic.get worker_live in
    if live <= 0 then true
    else if n <= 0 then begin
      own_log (Printf.sprintf "join timeout live=%d" live);
      false
    end else begin Unix.sleepf 0.01; loop (n - 1) end
  in
  loop budget

let stop () = Atomic.set running false

let set_running v = Atomic.set running v
let worker_live_count () = Atomic.get worker_live
let set_join_timeout_ms n = Atomic.set join_timeout_ms (max 10 n)
let set_shutdown_hang_ms n = Atomic.set shutdown_hang_ms (max 0 n)
let set_claim_gap_arm n = Atomic.set claim_gap_arm n
let set_unstick_arm n = Atomic.set unstick_arm n
let set_claim_pause_arm n = Atomic.set claim_pause_arm n
let set_finish_arm n = Atomic.set finish_arm n
let set_cleanup_copy_arm n = Atomic.set cleanup_copy_arm n
let set_cleanup_retire_arm n = Atomic.set cleanup_retire_arm n
let set_cleanup_retire_budget n = Atomic.set cleanup_retire_budget n
let claim_gap_waiting_count () = Atomic.get claim_gap_waiting
let unstick_waiting_count () = Atomic.get unstick_waiting
let claim_pause_waiting_count () = Atomic.get claim_pause_waiting
let finish_waiting_count () = Atomic.get finish_waiting
let cleanup_copy_waiting_count () = Atomic.get cleanup_copy_waiting
let cleanup_retire_waiting_count () = Atomic.get cleanup_retire_waiting
let last_turn_error_msg () = with_mu (fun () -> !last_turn_error)
let set_force_inflight_delete_error msg = Actor_store.set_force_inflight_delete_error msg

let reset_barrier_arms () =
  Atomic.set claim_gap_arm 0;
  Atomic.set unstick_arm 0;
  Atomic.set claim_pause_arm 0;
  Atomic.set finish_arm 0;
  Atomic.set cleanup_copy_arm 0;
  Atomic.set cleanup_retire_arm 0;
  Atomic.set cleanup_retire_budget 0

let reset () =
  Atomic.set running false;
  if wait_workers () then begin
    frozen := false;
    if not (Actor_store.flush_pending_close ()) then begin
      own_log "reset aborted: pending close";
      reset_barrier_arms ();
      Actor_store.reset_test_hooks ()
    end else begin
    (match !store with Some s -> Actor_store.release s | None -> ());
    store := None;
    config := None;
    with_mu (fun () ->
      Hashtbl.clear definitions;
      Hashtbl.clear waiters;
      Hashtbl.clear hold;
      Hashtbl.clear hold_u;
      Hashtbl.clear inflight;
      Hashtbl.clear pending_unstick;
      pending_clear := [];
      last_turn_error := None;
      after_handle_hook := None;
      now_ms_fn := (fun () -> Int64.of_float (Unix.gettimeofday () *. 1000.)));
    Atomic.set active 0;
    Atomic.set activations_finished 0;
    Atomic.set worker_live 0;
    inspect_stall_after := 0;
    inspect_stall_ms := 0;
    Atomic.set inspect_calls 0;
    Atomic.set join_timeout_ms 2000;
    Atomic.set shutdown_hang_ms 0;
    reset_barrier_arms ();
    Actor_store.reset_ephemeral ()
    end
  end else begin
    own_log "reset aborted: workers live";
    reset_barrier_arms ();
    Actor_store.reset_test_hooks ()
  end

let set_now_ms n =
  with_mu (fun () -> now_ms_fn := (fun () -> n));
  wakeup ()
let use_system_clock () =
  with_mu (fun () ->
    now_ms_fn := (fun () -> Int64.of_float (Unix.gettimeofday () *. 1000.)))

let hold_actor (a : actor_id) =
  let p, u = Eio.Promise.create () in
  with_mu (fun () ->
    Hashtbl.replace hold (actor_id_key a) p;
    Hashtbl.replace hold_u (actor_id_key a) u)

let release_actor (a : actor_id) =
  let k = actor_id_key a in
  let u =
    with_mu (fun () ->
      let u = Hashtbl.find_opt hold_u k in
      Hashtbl.remove hold k;
      Hashtbl.remove hold_u k;
      u)
  in
  (match u with
   | Some u -> (try Eio.Promise.resolve u () with _ -> ())
   | None -> ());
  wakeup ()

let set_crash p = Actor_store.set_crash_point p
let set_force_write_error ?(sticky = false) msg =
  Actor_store.set_force_write_error ~sticky msg
let set_ambiguous_commit v = Actor_store.set_ambiguous_commit v
let set_store_stall_ms n = Actor_store.set_stall_ms n
let set_inspect_stall ~after ms =
  inspect_stall_after := after;
  inspect_stall_ms := ms;
  Atomic.set inspect_calls 0
let inspect_call_count () = Atomic.get inspect_calls

let store_pragma name =
  match !store with
  | None -> Error (error "NotRunning" "Actor runtime is not running")
  | Some st ->
    blocking (fun () ->
      let db = Actor_store.connect st in
      Fun.protect ~finally:(fun () -> Actor_store.close_db db) (fun () ->
        Actor_store.with_stmt db ("PRAGMA " ^ name) (fun stmt ->
          match Sqlite3.step stmt with
          | Sqlite3.Rc.ROW -> Ok (Sqlite3.column_text stmt 0)
          | _ -> Error (error "StorageUnavailable" name))))

let store_exec sql =
  match !store with
  | None -> Error (error "NotRunning" "Actor runtime is not running")
  | Some st ->
    blocking (fun () ->
      let db = Actor_store.connect st in
      Fun.protect ~finally:(fun () -> Actor_store.close_db db) (fun () ->
        match Actor_store.exec db sql with
        | Ok () -> Ok ()
        | Error msg -> Error (error "StorageUnavailable" msg)))
