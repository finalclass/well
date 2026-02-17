(* Service — In-process actor system with mailbox and crash isolation *)

(* ── Types ─────────────────────────────────────────────────────────── *)

type param_info = { pname : string; ptype : string; poptional : bool }
type rpc_info = { rname : string; params : param_info list; returns : param_info list; returns_name : string }

type spec = {
  name : string;
  handler : string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t;
  set_ref : (string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t) -> unit;
  rpcs : rpc_info list;
}

type restart = Permanent | Transient | Temporary

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
  spec : spec;
  mailbox : mailbox_msg Eio.Stream.t;
}

type supervised = {
  mutable status : child_status;
  mutable crashes : float list;
}

(* ── State ─────────────────────────────────────────────────────────── *)

let pending_specs : (spec * restart) list ref = ref []
let actors : (string, actor) Hashtbl.t = Hashtbl.create 8
let supervised_states : (string, supervised) Hashtbl.t = Hashtbl.create 8
let exposed_services : string list ref = ref []

(* Forward ref — set by well.ml
   Takes: POST path, handler (request -> response_json_string) *)
let _register_post_json :
  (string -> (Types.request -> string) -> unit) ref =
  ref (fun _path _handler -> ())

(* Forward ref — set by well.ml, builds rpc_ctx JSON from request *)
let _build_rpc_ctx : (Types.request -> Yojson.Safe.t) ref =
  ref (fun _ -> `Null)

let _cast_sw : Eio.Switch.t option ref = ref None

(* Forward ref — set by well.ml before start_all, provides Eio sleep *)
let _sleep : (float -> unit) ref = ref (fun s -> Unix.sleepf s)

(* ── Registration (at module init time) ──────────────────────────── *)

let register ?(restart = Permanent) spec =
  pending_specs := (spec, restart) :: !pending_specs

let expose name =
  exposed_services := name :: !exposed_services

(* ── Actor loop ──────────────────────────────────────────────────── *)

let actor_loop actor =
  let rec loop () =
    match Eio.Stream.take actor.mailbox with
    | Stop -> ()
    | Call { rpc; ctx; payload; reply } ->
      let result =
        try actor.spec.handler rpc ctx payload
        with exn ->
          Log.log ~level:"error" "service %s rpc %s error: %s"
            actor.spec.name rpc (Printexc.to_string exn);
          `Assoc [("error", `String (Printexc.to_string exn))]
      in
      Eio.Promise.resolve reply result;
      loop ()
  in
  loop ()

(* ── Dispatch function (wired to convenience fns via set_ref) ─────── *)

let dispatch_by_name name rpc ctx payload =
  match Hashtbl.find_opt actors name with
  | None -> `Assoc [("error", `String (name ^ " is down"))]
  | Some actor ->
      let promise, resolver = Eio.Promise.create () in
      Eio.Stream.add actor.mailbox (Call { rpc; ctx; payload; reply = resolver });
      Eio.Promise.await promise

(* ── Expose service over HTTP ─────────────────────────────────────── *)

let expose_http_routes () =
  List.iter (fun name ->
    match Hashtbl.find_opt actors name with
    | None ->
      Log.log ~level:"warn" "cannot expose service '%s' — not registered" name
    | Some actor ->
      List.iter (fun (rpc : rpc_info) ->
        let path = Printf.sprintf "/rpc/%s/%s" name rpc.rname in
        !_register_post_json path (fun req ->
          let ctx = !_build_rpc_ctx req in
          let payload =
            if req.body = "" then `Null
            else Yojson.Safe.from_string req.body
          in
          let result = dispatch_by_name name rpc.rname ctx payload in
          Yojson.Safe.to_string result)
      ) actor.spec.rpcs
  ) !exposed_services

(* ── Supervised actor fiber ────────────────────────────────────────── *)

let supervised_run ~sw spec restart =
  let state = { status = Running; crashes = [] } in
  let max_crashes = 5 in
  let crash_window = 60.0 in
  let rec run backoff =
    let mailbox = Eio.Stream.create 64 in
    let actor = { spec; mailbox } in
    Hashtbl.replace actors spec.name actor;
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
          Log.log ~level:"error" "service %s circuit breaker tripped" spec.name
        end else begin
          state.status <- Restarting { attempts = List.length state.crashes };
          Log.log ~level:"warn" "service %s restarting in %.1fs: %s"
            spec.name backoff msg;
          !_sleep backoff;
          run (min 30.0 (backoff *. 2.0))
        end
  in
  Eio.Fiber.fork ~sw (fun () -> run 1.0);
  state

(* ── Start all actors (called by Well.run) ────────────────────────── *)

let start_all ~sw =
  let specs = List.rev !pending_specs in
  pending_specs := [];
  List.iter (fun (spec, restart) ->
    spec.set_ref (dispatch_by_name spec.name);
    let state = supervised_run ~sw spec restart in
    Hashtbl.replace supervised_states spec.name state
  ) specs;
  expose_http_routes ()

(* ── Health ────────────────────────────────────────────────────────── *)

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

(* ── Unix socket transport (local IPC) ────────────────────────────── *)

let list_services () =
  let result = ref [] in
  Hashtbl.iter (fun name actor ->
    let rpc_names = List.map (fun (r : rpc_info) -> r.rname) actor.spec.rpcs in
    result := (name, rpc_names) :: !result
  ) actors;
  List.sort (fun (a, _) (b, _) -> String.compare a b) !result

let describe_services () =
  let result = ref [] in
  Hashtbl.iter (fun name actor ->
    let rpcs_json = `Assoc (List.map (fun (rpc : rpc_info) ->
      let param_to_json p =
        `Assoc [("name", `String p.pname);
                ("type", `String p.ptype);
                ("optional", `Bool p.poptional)]
      in
      (rpc.rname, `Assoc [
        ("params", `List (List.map param_to_json rpc.params));
        ("returns", `List (List.map param_to_json rpc.returns));
        ("returns_name", `String rpc.returns_name)])
    ) actor.spec.rpcs) in
    result := (name, rpcs_json) :: !result
  ) actors;
  `Assoc (List.sort (fun (a, _) (b, _) -> String.compare a b) !result)

let handle_socket_line line =
  try
    let json = Yojson.Safe.from_string line in
    let service = match json with
      | `Assoc l -> (match List.assoc_opt "service" l with
          | Some (`String s) -> s | _ -> "")
      | _ -> ""
    in
    let rpc = match json with
      | `Assoc l -> (match List.assoc_opt "rpc" l with
          | Some (`String s) -> s | _ -> "")
      | _ -> ""
    in
    let payload = match json with
      | `Assoc l -> (match List.assoc_opt "payload" l with
          | Some p -> p | None -> `Null)
      | _ -> `Null
    in
    if service = "_system" && rpc = "db_diff" then
      let db_path = match payload with
        | `String s -> s
        | _ -> "data/app.sqlite"
      in
      let db = Sqlite3.db_open db_path in
      let entries = Db.diff db in
      ignore (Sqlite3.db_close db);
      let result = `List (List.map Db.diff_entry_to_json entries) in
      Yojson.Safe.to_string (`Assoc [("result", result)])
    else if service = "_system" && rpc = "describe" then
      let result = describe_services () in
      Yojson.Safe.to_string (`Assoc [("result", result)])
    else if service = "_system" && rpc = "list" then
      let services = list_services () in
      let result = `Assoc (List.map (fun (name, rpcs) ->
        (name, `List (List.map (fun r -> `String r) rpcs))
      ) services) in
      Yojson.Safe.to_string (`Assoc [("result", result)])
    else if service = "_system" && rpc = "health" then
      let statuses = health () in
      let result = `Assoc (List.map (fun (name, st) ->
        (name, `String st)
      ) statuses) in
      Yojson.Safe.to_string (`Assoc [("result", result)])
    else
      let result = dispatch_by_name service rpc `Null payload in
      Yojson.Safe.to_string (`Assoc [("result", result)])
  with exn ->
    Yojson.Safe.to_string
      (`Assoc [("error", `String (Printexc.to_string exn))])

let handle_socket_client flow _addr =
  let reader = Eio.Buf_read.of_flow ~max_size:(10 * 1024 * 1024) flow in
  (try
     while true do
       let line = Eio.Buf_read.line reader in
       let line =
         if String.length line > 0 && line.[String.length line - 1] = '\r'
         then String.sub line 0 (String.length line - 1)
         else line
       in
       if line <> "" then begin
         let response = handle_socket_line line in
         Eio.Flow.copy_string (response ^ "\n") flow
       end
     done
   with
   | End_of_file | Eio.Io _ -> ());
  Eio.Flow.close flow

let start_socket ~sw ~net path =
  (try Unix.unlink path with Unix.Unix_error _ -> ());
  let socket = Eio.Net.listen net ~sw ~backlog:16 ~reuse_addr:true
    (`Unix path) in
  Unix.chmod path 0o770;
  Log.log "socket on %s" path;
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect ~finally:(fun () ->
      try Unix.unlink path with Unix.Unix_error _ -> ())
    (fun () ->
      let rec accept_loop () =
        Eio.Net.accept_fork socket ~sw
          ~on_error:(fun exn ->
            match exn with
            | Eio.Cancel.Cancelled _ -> ()
            | _ ->
              Log.log ~level:"error" "socket error: %s"
                (Printexc.to_string exn))
          handle_socket_client;
        accept_loop ()
      in
      try accept_loop ()
      with Eio.Cancel.Cancelled _ -> ()))

(* ── Cast (fire-and-forget) ──────────────────────────────────────── *)

let cast f =
  match !_cast_sw with
  | Some sw ->
    Eio.Fiber.fork ~sw (fun () ->
      try f ()
      with exn ->
        Log.log ~level:"error" "cast error: %s" (Printexc.to_string exn))
  | None ->
    Log.log ~level:"warn" "cast called outside Well.run";
    f ()
