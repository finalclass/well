(** Actor -- sequential, stateful actor with mailbox, crash isolation, and supervised restarts. *)

(* ── Types ─────────────────────────────────────────────────────────── *)

(** Restart strategy: [Permanent] always restarts, [Transient] on crash only, [Temporary] never. *)
type restart = Permanent | Transient | Temporary

(** Current status of a supervised actor. *)
type child_status =
  | Running
  | Restarting of { attempts : int }
  | Down of string

type mailbox_msg =
  | Call of {
      rpc : string;
      ctx : Yojson.Safe.t;
      payload : Yojson.Safe.t;
      reply : Yojson.Safe.t Eio.Promise.u;
    }
  | Stop

type actor = {
  spec : Service.spec;
  mailbox : mailbox_msg Eio.Stream.t;
}

type supervised = {
  mutable status : child_status;
  mutable crashes : float list;
}

(* ── State ─────────────────────────────────────────────────────────── *)

let pending_specs : (Service.spec * restart) list ref = ref []
let actors : (string, actor) Hashtbl.t = Hashtbl.create 8
let supervised_states : (string, supervised) Hashtbl.t = Hashtbl.create 8

(* ── Registration (at module init time) ──────────────────────────── *)

(** Register an actor spec to be started when [Well.run] is called. *)
let register ?(restart = Permanent) spec =
  pending_specs := (spec, restart) :: !pending_specs

(* ── Actor loop (sequential — one message at a time) ─────────────── *)

let actor_loop actor =
  let rec loop () =
    match Eio.Stream.take actor.mailbox with
    | Stop -> ()
    | Call { rpc; ctx; payload; reply } ->
      let result =
        try actor.spec.handler rpc ctx payload
        with exn ->
          Log.log ~level:"error" "actor %s rpc %s error: %s"
            actor.spec.name rpc (Printexc.to_string exn);
          `Assoc [("error", `String (Printexc.to_string exn))]
      in
      Eio.Promise.resolve reply result;
      loop ()
  in
  loop ()

(* ── Dispatch via mailbox ─────────────────────────────────────────── *)

(** Send an RPC message to a named actor's mailbox and await the reply. *)
let dispatch name rpc ctx payload =
  match Hashtbl.find_opt actors name with
  | None -> `Assoc [("error", `String (name ^ " is down"))]
  | Some actor ->
      let promise, resolver = Eio.Promise.create () in
      Eio.Stream.add actor.mailbox (Call { rpc; ctx; payload; reply = resolver });
      Eio.Promise.await promise

(* ── Supervised actor fiber ────────────────────────────────────────── *)

let supervised_run ~sw spec restart =
  let state = { status = Running; crashes = [] } in
  let max_crashes = 5 in
  let crash_window = 60.0 in
  let rec run backoff =
    let mailbox = Eio.Stream.create 64 in
    let actor = { spec; mailbox } in
    Hashtbl.replace actors spec.name actor;
    (* Register into unified dispatch table *)
    Service.register_handler spec.name {
      dispatch = dispatch spec.name;
      rpcs = spec.rpcs;
      kind = `Actor;
    };
    state.status <- Running;
    let result =
      try actor_loop actor; `Normal
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> `Crashed (Printexc.to_string exn)
    in
    Hashtbl.remove actors spec.name;
    match result, restart with
    | `Normal, Permanent -> run 1.0
    | `Normal, _ -> ()
    | `Crashed _, Temporary ->
        state.status <- Down "crashed (temporary)"
    | `Crashed msg, (Permanent | Transient) ->
        let now = Unix.gettimeofday () in
        state.crashes <- now :: List.filter (fun t -> now -. t < crash_window) state.crashes;
        if List.length state.crashes > max_crashes then begin
          state.status <- Down (Printf.sprintf "circuit breaker: %d crashes in %.0fs"
            (List.length state.crashes) crash_window);
          Log.log ~level:"error" "actor %s circuit breaker tripped" spec.name
        end else begin
          state.status <- Restarting { attempts = List.length state.crashes };
          Log.log ~level:"warn" "actor %s restarting in %.1fs: %s"
            spec.name backoff msg;
          Env.sleep backoff;
          run (min 30.0 (backoff *. 2.0))
        end
  in
  Eio.Fiber.fork ~sw (fun () -> run 1.0);
  state

(* ── Start all actors (called by Well.run) ────────────────────────── *)

(** Start all registered actors as supervised fibers (called by [Well.run]). *)
let start_all ~sw =
  let specs = List.rev !pending_specs in
  pending_specs := [];
  List.iter (fun (spec, restart) ->
    let state = supervised_run ~sw spec restart in
    Hashtbl.replace supervised_states spec.name state;
    spec.set_ref (Service.dispatch_by_name spec.name)
  ) specs;
  match Actor_runtime.start ~sw with
  | Ok () -> ()
  | Error e -> failwith ("Well.Actor.start: " ^ e.message)

(* ── Health ────────────────────────────────────────────────────────── *)

(** Return the health status of all supervised actors. *)
let health () =
  let result = ref [] in
  Hashtbl.iter (fun name state ->
    let st = match state.status with
      | Running -> "running"
      | Restarting { attempts } -> Printf.sprintf "restarting (attempt %d)" attempts
      | Down reason -> "down: " ^ reason
    in
    result := (name, st) :: !result
  ) supervised_states;
  List.sort (fun (a, _) (b, _) -> String.compare a b) !result

(* Wire actor health into Service.full_health *)
let () = Service._actor_health := health

type actor_id = Actor_types.actor_id = { actor_type : string; id : string }
type execution_id = Actor_types.execution_id
type error = Actor_types.error = { code : string; message : string; path : string option }
type failure = Actor_types.failure = Retry of string | Fail of string
type context = Actor_types.context = {
  self : actor_id;
  execution_id : execution_id;
  message_id : string;
  attempt : int;
  deadline_ms : int64;
}
type limits = Actor_types.limits = {
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
type retry_policy = Actor_types.retry_policy = { max_attempts : int; delays_ms : int list }
type config = Actor_types.config = {
  store_path : string;
  limits : limits;
  retry_policy : retry_policy;
}
type 'a message_type = 'a Actor_types.message_type
type packed_message = Actor_types.packed_message =
  | Message : 'a message_type * 'a -> packed_message
type location = Actor_types.location = {
  node_id : string;
  message_id : string;
  actor : actor_id option;
  attempt : int;
  at_ms : int64;
}
type diagnostic = Actor_types.diagnostic = {
  error : error;
  location : location option;
  missing_branches : string list;
}
type output = Actor_types.output = {
  path : int list;
  payload_type : string;
  schema_hash : string;
  payload : Yojson.Safe.t;
}
type execution_status = Actor_types.execution_status =
  | Running
  | Blocked of diagnostic list
  | Completed
  | Failed of diagnostic
type snapshot = Actor_types.snapshot = {
  execution_id : execution_id;
  request_id : string;
  status : execution_status;
  outputs : output list;
  pending_messages : int;
  open_groups : int;
  deadline_ms : int64;
}
type await_result = Actor_types.await_result =
  | Terminal of snapshot
  | Wait_timeout of snapshot

type descriptor = Actor_contract.descriptor
type definition = Actor_contract.definition

let default_limits = Actor_types.default_limits
let default_retry_policy = Actor_types.default_retry_policy
let configure = Actor_runtime.configure
let register_type = Actor_runtime.register_type
let catalog = Actor_runtime.catalog

module Workflow = struct
  type t = Actor_workflow.t
  let validate = Actor_runtime.workflow_validate
  let to_json = Actor_workflow.to_json
end

let message_type_name (mt : _ message_type) = mt.Actor_types.name

let encode (mt : 'a message_type) (v : 'a) =
  let json = mt.Actor_types.encode v in
  match mt.decode json with
  | Ok _ -> json
  | Error _ -> invalid_arg "Well.Actor.encode: codec produced invalid wire"

let decode (mt : 'a message_type) json = mt.Actor_types.decode json

let send = Actor_runtime.send
let inspect = Actor_runtime.inspect
let await = Actor_runtime.await
let decode_output = Actor_runtime.decode_output
let errors = Actor_runtime.errors
let resume = Actor_runtime.resume
let abandon = Actor_runtime.abandon
let metrics = Actor_runtime.metrics

module Generated = struct
  module type RAW_ACTOR = Actor_contract.RAW_ACTOR
  let descriptor = Actor_contract.parse_descriptor
  let define = Actor_contract.define
  let message_type = Actor_contract.message_type
end

module Contract = struct
  let build = Actor_contract.build
end

let _reset = Actor_runtime.reset
let _stop = Actor_runtime.stop
let _set_running = Actor_runtime.set_running
let _worker_live = Actor_runtime.worker_live_count
let _set_join_timeout_ms = Actor_runtime.set_join_timeout_ms
let _set_shutdown_hang_ms = Actor_runtime.set_shutdown_hang_ms
let _set_claim_gap_arm = Actor_runtime.set_claim_gap_arm
let _set_unstick_arm = Actor_runtime.set_unstick_arm
let _claim_gap_waiting = Actor_runtime.claim_gap_waiting_count
let _unstick_waiting = Actor_runtime.unstick_waiting_count
let _set_claim_pause_arm = Actor_runtime.set_claim_pause_arm
let _claim_pause_waiting = Actor_runtime.claim_pause_waiting_count
let _set_finish_arm = Actor_runtime.set_finish_arm
let _finish_waiting = Actor_runtime.finish_waiting_count
let _set_cleanup_copy_arm = Actor_runtime.set_cleanup_copy_arm
let _cleanup_copy_waiting = Actor_runtime.cleanup_copy_waiting_count
let _set_cleanup_retire_arm = Actor_runtime.set_cleanup_retire_arm
let _cleanup_retire_waiting = Actor_runtime.cleanup_retire_waiting_count
let _set_cleanup_retire_budget = Actor_runtime.set_cleanup_retire_budget
let _note_pending_unstick = Actor_runtime.note_pending_unstick
let _last_turn_error = Actor_runtime.last_turn_error_msg
let _set_force_inflight_delete_error = Actor_runtime.set_force_inflight_delete_error
let _pin_busy_close path = Actor_store.pin_busy_close path
let _unpin_busy_close = Actor_store.unpin_busy_close
let _pending_close_count = Actor_store.pending_close_count
let _set_now_ms = Actor_runtime.set_now_ms
let _use_system_clock = Actor_runtime.use_system_clock
let _hold = Actor_runtime.hold_actor
let _release = Actor_runtime.release_actor
let _set_crash = Actor_runtime.set_crash
let _set_max_page_count = Actor_store.set_max_page_count
let _store_pragma = Actor_runtime.store_pragma
let _store_exec = Actor_runtime.store_exec
let _crash_point () = Actor_store.get_crash_point ()
let _set_force_write_error ?sticky msg = Actor_runtime.set_force_write_error ?sticky msg
let _set_store_stall_ms = Actor_runtime.set_store_stall_ms
let _set_inspect_stall = Actor_runtime.set_inspect_stall
let _inspect_call_count = Actor_runtime.inspect_call_count
let _set_ambiguous_commit = Actor_runtime.set_ambiguous_commit
let _try_acquire path =
  match Actor_store.acquire path with
  | Ok t -> Actor_store.release t; Ok ()
  | Error e -> Error e
let _wakeup = Actor_runtime.wakeup
let _activations_finished = Actor_runtime.activations_finished_count
let _waiter_count = Actor_runtime.waiter_count
let _set_after_handle = Actor_runtime.set_after_handle
let _now_ms = Actor_runtime.now_ms_export
let _canonicalize = Actor_jcs.canonicalize
