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
  ) specs

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
