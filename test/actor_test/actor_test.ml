open Well_test

let fail msg = raise (Assertion_failed msg)

let write_start name =
  let path =
    match Sys.getenv_opt "ACTOR_TEST_START_LOG" with
    | Some p -> p
    | None -> Filename.concat (Filename.get_temp_dir_name ()) "actor-test-start.log"
  in
  let oc = open_out_gen [Open_creat; Open_append; Open_wronly] 0o644 path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    output_string oc
      (Printf.sprintf "%d START %s crash=%s\n" (Unix.getpid ()) name
         (match Well.Actor._crash_point () with None -> "-" | Some p -> p));
    flush oc);
  Printf.eprintf "START %s crash=%s\n%!" name
    (match Well.Actor._crash_point () with None -> "-" | Some p -> p)

let it ?timeout name fn =
  Well_test.it ?timeout name (fun () ->
    write_start name;
    fn ())

let () =
  match Sys.getenv_opt "ACTOR_LOCK_CHILD" with
  | Some path ->
    (match Well.Actor._try_acquire path with
     | Error e when e.code = "StorageUnavailable" -> exit 0
     | Error e -> prerr_endline e.message; exit 2
     | Ok () -> exit 3)
  | None -> ()

type spawn_helper = {
  pid : int;
  cmd : out_channel;
  ack : in_channel;
  mu : Mutex.t;
}

let spawn_helper : spawn_helper option ref = ref None
let last_spawn_status = ref (Unix.WEXITED 0)

let spawn_direct extra =
  let env = Array.append (Unix.environment ()) (Array.of_list extra) in
  let exe = Sys.argv.(0) in
  let devnull = Unix.openfile "/dev/null" [Unix.O_RDWR] 0o666 in
  Fun.protect ~finally:(fun () -> Unix.close devnull) (fun () ->
    Unix.create_process_env exe [| exe |] env devnull devnull Unix.stderr)

let parse_helper_status line =
  match String.split_on_char ' ' (String.trim line) with
  | ["exit"; n] -> Unix.WEXITED (int_of_string n)
  | ["signal"; n] -> Unix.WSIGNALED (int_of_string n)
  | ["stop"; n] -> Unix.WSTOPPED (int_of_string n)
  | _ -> Unix.WEXITED 127

let run_spawn_helper () =
  let read_line () =
    let buf = Buffer.create 64 in
    let b = Bytes.create 1 in
    let rec loop () =
      match Unix.read Unix.stdin b 0 1 with
      | 0 -> raise End_of_file
      | _ ->
        if Bytes.get b 0 = '\n' then Buffer.contents buf
        else begin Buffer.add_char buf (Bytes.get b 0); loop () end
    in
    loop ()
  in
  let rec loop () =
    let rec extras acc =
      match read_line () with
      | "" -> List.rev acc
      | line -> extras (line :: acc)
    in
    let extra = try extras [] with End_of_file -> exit 0 in
    if extra = [] then loop ()
    else begin
      let pid = spawn_direct extra in
      let _, st = Unix.waitpid [] pid in
      (match st with
       | Unix.WEXITED n -> Printf.printf "exit %d\n" n
       | Unix.WSIGNALED n -> Printf.printf "signal %d\n" n
       | Unix.WSTOPPED n -> Printf.printf "stop %d\n" n);
      flush stdout;
      loop ()
    end
  in
  loop ()

let start_spawn_helper () =
  let exe = Sys.argv.(0) in
  let cmd_r, cmd_w = Unix.pipe () in
  let ack_r, ack_w = Unix.pipe () in
  Unix.set_close_on_exec cmd_w;
  Unix.set_close_on_exec ack_r;
  Unix.clear_close_on_exec cmd_r;
  Unix.clear_close_on_exec ack_w;
  let env = Array.append (Unix.environment ()) [| "ACTOR_SPAWN_HELPER=1" |] in
  let pid = Unix.create_process_env exe [| exe |] env cmd_r ack_w Unix.stderr in
  Unix.close cmd_r;
  Unix.close ack_w;
  let cmd = Unix.out_channel_of_descr cmd_w in
  let ack = Unix.in_channel_of_descr ack_r in
  spawn_helper := Some { pid; cmd; ack; mu = Mutex.create () };
  at_exit (fun () ->
    match !spawn_helper with
    | None -> ()
    | Some h ->
      spawn_helper := None;
      (try close_out_noerr h.cmd with _ -> ());
      (try Unix.kill h.pid Sys.sigterm with _ -> ());
      (try ignore (Unix.waitpid [] h.pid) with _ -> ()))

let spawn_env extra =
  match !spawn_helper with
  | None ->
    let pid = spawn_direct extra in
    let _, st = Unix.waitpid [] pid in
    last_spawn_status := st;
    0
  | Some h ->
    Mutex.lock h.mu;
    Fun.protect ~finally:(fun () -> Mutex.unlock h.mu) (fun () ->
      List.iter (fun e -> output_string h.cmd e; output_char h.cmd '\n') extra;
      output_char h.cmd '\n';
      flush h.cmd;
      last_spawn_status := parse_helper_status (input_line h.ack);
      0)

let wait_ok pid =
  let st = if pid = 0 then !last_spawn_status else snd (Unix.waitpid [] pid) in
  match st with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED n -> fail (Printf.sprintf "child exited %d" n)
  | _ -> fail "child signalled"

let examples =
  let rec find = function
    | [] -> failwith "examples not found"
    | p :: rest -> if Sys.file_exists (Filename.concat p "Reports.cyrograf") then p else find rest
  in
  find [
    "lib/well/actor/examples";
    "../../lib/well/actor/examples";
    "../../../lib/well/actor/examples";
  ]

let tmp_dir prefix =
  let p = Filename.temp_file prefix "" in
  Sys.remove p;
  Unix.mkdir p 0o700;
  p

let rec rm_rf p =
  if Sys.file_exists p then
    if Sys.is_directory p then begin
      Array.iter (fun n -> rm_rf (Filename.concat p n)) (Sys.readdir p);
      Unix.rmdir p
    end else Sys.remove p

let descriptor () =
  let out = tmp_dir "actor-desc-" in
  match Well.Actor.Contract.build ~source_dir:examples ~output_dir:out with
  | Error e -> failwith (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
  | Ok () ->
    let d = Yojson.Safe.from_file (Filename.concat out "descriptor.json") in
    match Well.Actor.Generated.descriptor d with
    | Ok d -> rm_rf out; d
    | Error _ -> rm_rf out; failwith "descriptor"

let request_type desc =
  match Well.Actor.Generated.message_type desc ~name:"Reports.Request"
          ~encode:(fun (id, sub) -> `List [`String id; `String sub])
          ~decode:(function
            | `List [`String id; `String sub] -> Ok (id, sub)
            | _ -> Error "request")
  with Ok t -> t | Error e -> failwith e.message

let request_list_type desc =
  match Well.Actor.Generated.message_type desc ~name:"Reports.RequestList"
          ~encode:(fun xs -> `List [`List (List.map (fun (id, sub) -> `List [`String id; `String sub]) xs)])
          ~decode:(fun _ -> Error "unused")
  with Ok t -> t | Error e -> failwith e.message

let summary_type desc =
  match Well.Actor.Generated.message_type desc ~name:"Reports.Summary"
          ~encode:(fun s -> `List [`String s])
          ~decode:(function `List [`String s] -> Ok s | _ -> Error "summary")
  with Ok t -> t | Error e -> failwith e.message

let reporter_handles : (string, int) Hashtbl.t = Hashtbl.create 8
let effect_keys : (string, unit) Hashtbl.t = Hashtbl.create 16
let test_mu = Mutex.create ()
let with_test_mu f =
  Mutex.lock test_mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock test_mu) f
let reporter_inits = Atomic.make 0
let effect_calls = Atomic.make 0
let decision_handles = Atomic.make 0
let live_handles = Atomic.make 0
let max_live_handles = Atomic.make 0
let current_store = ref ""
let reporter_count id =
  with_test_mu (fun () -> Option.value ~default:0 (Hashtbl.find_opt reporter_handles id))
let reporter_bump id =
  with_test_mu (fun () ->
    Hashtbl.replace reporter_handles id
      (1 + Option.value ~default:0 (Hashtbl.find_opt reporter_handles id)))
let reporter_len () = with_test_mu (fun () -> Hashtbl.length reporter_handles)
let reporter_clear () = with_test_mu (fun () -> Hashtbl.clear reporter_handles)
let effect_remember mid =
  with_test_mu (fun () -> Hashtbl.replace effect_keys mid ())
let effect_clear () = with_test_mu (fun () -> Hashtbl.clear effect_keys)

let log_fx key =
  if !current_store <> "" then
    let oc = open_out_gen [Open_creat; Open_append] 0o600 (!current_store ^ ".fx") in
    output_string oc (key ^ "\n");
    close_out oc

let read_fx store =
  let p = store ^ ".fx" in
  if not (Sys.file_exists p) then []
  else
    let ic = open_in p in
    let rec go acc =
      try go (input_line ic :: acc) with End_of_file -> close_in ic; List.rev acc
    in
    go []

module Decision = struct
  type state = unit
  type inbound = Request of (string * string)
  type outbound = Accepted of (string * string) | Rejected of string
  let state_version = 1
  let init _ = ()
  let state_to_wire () = `Null
  let state_of_wire _ = Ok ()
  let inbound_of_wire ~kind json =
    match kind, json with
    | "Choose", `List [`String id; `String sub] -> Ok (Request (id, sub))
    | _ -> Error "decision inbound"
  let outbound_to_wire = function
    | Accepted (id, sub) -> "Accepted", `List [`String id; `String sub]
    | Rejected text -> "Rejected", `List [`String text]
  let handle (ctx : Well.Actor.context) () = function
    | Request (id, sub) ->
      Atomic.incr decision_handles;
      log_fx ctx.message_id;
      if sub = "reject" then Ok ((), [Rejected "rejected"])
      else if sub = "none" || sub = "quiet" then Ok ((), [])
      else if sub = "two" then Ok ((), [Accepted (id, sub); Accepted (id, sub)])
      else Ok ((), [Accepted (id, sub)])
end

module Reporter = struct
  type state = { mutable count : int }
  type inbound = Generate of (string * string)
  type outbound = Produced of (string * string)
  let state_version = 1
  let init _ = Atomic.incr reporter_inits; { count = 0 }
  let state_to_wire s = `Int s.count
  let state_of_wire = function `Int n when n >= 0 -> Ok { count = n } | _ -> Error "state"
  let inbound_of_wire ~kind json =
    match kind, json with
    | "Generate", `List [`String id; `String sub] -> Ok (Generate (id, sub))
    | _ -> Error "reporter inbound"
  let outbound_to_wire = function
    | Produced (src, text) -> "Produced", `List [`String src; `String text]
  let handle ctx state = function
    | Generate (_id, sub) ->
      let id = ctx.Well.Actor.self.id in
      reporter_bump id;
      effect_remember ctx.message_id;
      Atomic.incr effect_calls;
      log_fx ctx.message_id;
      let n = Atomic.fetch_and_add live_handles 1 + 1 in
      let rec bump () =
        let m = Atomic.get max_live_handles in
        if n > m && not (Atomic.compare_and_set max_live_handles m n) then bump ()
      in
      bump ();
      Fun.protect ~finally:(fun () -> Atomic.decr live_handles) (fun () ->
        if sub = "always-retry" then Error (Well.Actor.Retry "always")
        else if sub = "fail-hard" && ctx.Well.Actor.self.id = "finance" then
          Error (Well.Actor.Fail "hard")
        else if sub = "mutate-retry" && ctx.Well.Actor.attempt = 0 then begin
          state.count <- state.count + 100;
          Error (Well.Actor.Retry "mutate")
        end else if sub = "backoff" && ctx.Well.Actor.attempt = 0 then
          Error (Well.Actor.Retry "backoff")
        else Ok ({ count = state.count + 1 }, [Produced (id, sub)]))
end

module Spawner = struct
  type state = unit
  type inbound = Generate of (string * string) list
  type outbound = Requested of (string * string)
  let state_version = 1
  let init _ = ()
  let state_to_wire () = `Null
  let state_of_wire _ = Ok ()
  let inbound_of_wire ~kind json =
    match kind, json with
    | "Generate", `List [`List xs] ->
      let rec go acc = function
        | [] -> Ok (Generate (List.rev acc))
        | `List [`String id; `String sub] :: rest -> go ((id, sub) :: acc) rest
        | _ -> Error "list"
      in
      go [] xs
    | _ -> Error "spawner inbound"
  let outbound_to_wire = function
    | Requested (id, sub) -> "Requested", `List [`String id; `String sub]
  let handle _ () = function
    | Generate xs -> Ok ((), List.map (fun x -> Requested x) xs)
end

module Combiner = struct
  type state = unit
  type inbound = Combine of Yojson.Safe.t
  type outbound = Produced of (string * string)
  let state_version = 1
  let init _ = ()
  let state_to_wire () = `Null
  let state_of_wire _ = Ok ()
  let inbound_of_wire ~kind json =
    match kind with
    | "Combine" -> Ok (Combine json)
    | _ -> Error "combiner"
  let outbound_to_wire = function
    | Produced (src, text) -> "Produced", `List [`String src; `String text]
  let handle ctx () = function
    | Combine (`List [`List items]) ->
      let texts =
        List.map (function `List [`String _; `String t] -> t | _ -> "") items
      in
      Ok ((), [Produced (ctx.Well.Actor.self.id, String.concat " " texts)])
    | Combine _ -> Ok ((), [Produced (ctx.Well.Actor.self.id, "")])
end

module Summary = struct
  type state = unit
  type inbound = Build of Yojson.Safe.t
  type outbound = Built of string
  let state_version = 1
  let init _ = ()
  let state_to_wire () = `Null
  let state_of_wire _ = Ok ()
  let inbound_of_wire ~kind json =
    match kind with "Build" -> Ok (Build json) | _ -> Error "summary"
  let outbound_to_wire = function
    | Built t -> "Built", `List [`String t]
  let handle _ () = function
    | Build (`List [`List items]) ->
      let texts = List.map (function `List [`String _; `String t] -> t | `List [`String t] -> t | _ -> "") items in
      Ok ((), [Built (String.concat " " texts)])
    | Build _ -> Ok ((), [Built ""])
end

module Wrapper = struct
  type state = unit
  type inbound = Open of Yojson.Safe.t
  type outbound = unit
  let state_version = 1
  let init _ = ()
  let state_to_wire () = `Null
  let state_of_wire _ = Ok ()
  let inbound_of_wire ~kind json =
    match kind with "Open" -> Ok (Open json) | _ -> Error "wrapper"
  let outbound_to_wire () = "Closed", `Null
  let handle _ () = function Open _ -> Ok ((), [])
end

let define desc name (module R : Well.Actor.Generated.RAW_ACTOR) =
  match Well.Actor.Generated.define desc ~actor_type:name (module R) with
  | Ok d -> d
  | Error e -> failwith (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")

let register_all desc =
  let ok d = match Well.Actor.register_type d with Ok () -> () | Error e -> failwith e.message in
  ok (define desc "ReportDecision" (module Decision));
  ok (define desc "Reporter" (module Reporter));
  ok (define desc "ReportSpawner" (module Spawner));
  ok (define desc "ReportCombiner" (module Combiner));
  ok (define desc "SummaryBuilder" (module Summary))

let with_runtime
    ?(limits = Well.Actor.default_limits)
    ?(retry_policy = Well.Actor.default_retry_policy)
    ?(register = register_all)
    ?max_pages f =
  Well.Actor._reset ();
  (match max_pages with
   | Some n -> Well.Actor._set_max_page_count (Some n)
   | None -> ());
  reporter_clear ();
  effect_clear ();
  Atomic.set reporter_inits 0;
  Atomic.set effect_calls 0;
  Atomic.set decision_handles 0;
  Atomic.set live_handles 0;
  Atomic.set max_live_handles 0;
  let dir = tmp_dir "actor-rt-" in
  let store_path = Filename.concat dir "store.sqlite" in
  current_store := store_path;
  let cfg = {
    Well.Actor.store_path;
    limits;
    retry_policy;
  } in
  match Well.Actor.configure cfg with
  | Error e -> rm_rf dir; failwith e.message
  | Ok () ->
    let desc = descriptor () in
    register desc;
    Fun.protect ~finally:(fun () -> Well.Actor._reset (); rm_rf dir) (fun () ->
      Eio_main.run (fun env ->
        Well.Env.set env;
        Eio.Switch.run (fun sw ->
          Well.Actor.start_all ~sw;
          Fun.protect ~finally:Well.Actor._stop (fun () -> f desc))))

let with_existing_store store_path f =
  Well.Actor._reset ();
  reporter_clear ();
  effect_clear ();
  Atomic.set reporter_inits 0;
  Atomic.set effect_calls 0;
  Atomic.set decision_handles 0;
  Atomic.set live_handles 0;
  Atomic.set max_live_handles 0;
  current_store := store_path;
  let cfg = {
    Well.Actor.store_path;
    limits = Well.Actor.default_limits;
    retry_policy = Well.Actor.default_retry_policy;
  } in
  match Well.Actor.configure cfg with
  | Error e -> failwith e.message
  | Ok () ->
    let desc = descriptor () in
    register_all desc;
    Fun.protect ~finally:(fun () -> Well.Actor._reset ()) (fun () ->
      Eio_main.run (fun env ->
        Well.Env.set env;
        Eio.Switch.run (fun sw ->
          Well.Actor.start_all ~sw;
          Fun.protect ~finally:Well.Actor._stop (fun () -> f desc))))

let execution_of_request path request_id =
  try
    let db = Sqlite3.db_open ~mutex:`FULL path in
    Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db)) (fun () ->
      ignore (Sqlite3.exec db "PRAGMA journal_mode=WAL");
      ignore (Sqlite3.busy_timeout db 5000);
      let stmt = Sqlite3.prepare db "SELECT execution_id FROM executions WHERE request_id = ?" in
      Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
        ignore (Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT request_id));
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW -> Some (Sqlite3.column_text stmt 0)
        | _ -> None))
  with Sqlite3.Error _ -> None

let with_db path f =
  let db = Sqlite3.db_open ~mutex:`FULL path in
  ignore (Sqlite3.exec db "PRAGMA journal_mode=WAL");
  ignore (Sqlite3.busy_timeout db 5000);
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db)) (fun () -> f db)

let scalar path sql =
  with_db path (fun db ->
    let stmt = Sqlite3.prepare db sql in
    Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> Int64.to_int (Sqlite3.column_int64 stmt 0)
      | _ -> 0))

let scalar_text path sql =
  with_db path (fun db ->
    let stmt = Sqlite3.prepare db sql in
    Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> Sqlite3.column_text stmt 0
      | _ -> ""))

let sqlite_step_done db stmt what =
  match Sqlite3.step stmt with
  | Sqlite3.Rc.DONE -> ()
  | rc ->
    fail (Printf.sprintf "%s rc=%s errmsg=%s"
            what (Sqlite3.Rc.to_string rc) (Sqlite3.errmsg db))

let sqlite_full_msg m =
  let u = String.uppercase_ascii m in
  u = "FULL" || (
    let rec has i =
      i + 4 <= String.length u && (String.sub u i 4 = "FULL" || has (i + 1))
    in has 0)

let rec wait_until n pred =
  if pred () then ()
  else if n <= 0 then fail "wait timeout"
  else begin Well.Env.sleep 0.05; wait_until (n - 1) pred end

let rec wait_cond n mk_msg pred =
  if pred () then ()
  else if n <= 0 then fail (mk_msg ())
  else begin Well.Env.sleep 0.05; wait_cond (n - 1) mk_msg pred end

let inflight_gen path =
  scalar path "SELECT IFNULL((SELECT generation FROM inflight LIMIT 1), 0)"

let seq_next_gen path =
  scalar path "SELECT IFNULL((SELECT next_gen FROM activation_seq LIMIT 1), 0)"

let inbox_status path =
  scalar_text path "SELECT IFNULL((SELECT status FROM inbox LIMIT 1), '-')"

let metric_int json key =
  match json with
  | `Assoc fs ->
    (match List.assoc_opt key fs with
     | Some (`Int n) -> n
     | Some (`Intlit s) -> (try int_of_string s with _ -> -1)
     | _ -> -1)
  | _ -> -1

let actor_node ~actor ~id ~accept ~mode ~outputs ?(join = `Null) () =
  `Assoc [
    "kind", `String "actor";
    "actor", `String actor;
    "id", id;
    "accept", `String accept;
    "emission_mode", `String mode;
    "outputs", `Assoc (List.map (fun (k, v) -> k, `String v) outputs);
    "join", join;
  ]

let end_node ty = `Assoc ["kind", `String "end"; "input_type", `String ty]
let drop_node ty = `Assoc ["kind", `String "drop"; "input_type", `String ty]

let workflow ~name ~entry ~input ?(bindings = []) nodes =
  `Assoc [
    "format", `Int 1;
    "name", `String name;
    "version", `String "1";
    "entry", `String entry;
    "input_type", `String input;
    "bindings", `Assoc (List.map (fun (k, v) -> k, `String v) bindings);
    "nodes", `Assoc nodes;
  ]

let envelope_json store sql =
  Yojson.Safe.from_string (scalar_text store sql)

let json_assoc = function `Assoc fs -> fs | _ -> []

let register_wrapper () =
  let src = tmp_dir "wrap-src-" in
  let out = tmp_dir "wrap-out-" in
  let oc = open_out (Filename.concat src "Wrap.toml") in
  output_string oc
    "[msg.Box.struct]\nname = \"string\"\nflag = { type = \"string\", optional = true }\ntag = \"Tag\"\n[msg.Tag.variant]\nA = \"string\"\nB = \"void\"\n[actor]\nname = \"Wrapper\"\nversion = 1\n[actor.accepts]\nOpen = \"Box\"\n";
  close_out oc;
  match Well.Actor.Contract.build ~source_dir:src ~output_dir:out with
  | Error e ->
    rm_rf src; rm_rf out;
    failwith (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
  | Ok () ->
    let d = Yojson.Safe.from_file (Filename.concat out "descriptor.json") in
    rm_rf src; rm_rf out;
    match Well.Actor.Generated.descriptor d with
    | Error _ -> failwith "wrapper descriptor"
    | Ok wdesc ->
      match Well.Actor.Generated.define wdesc ~actor_type:"Wrapper" (module Wrapper) with
      | Error e ->
        failwith (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
      | Ok def ->
        (match Well.Actor.register_type def with
         | Error e -> failwith e.message
         | Ok () -> wdesc)

let bump_state_version path actor_type version =
  with_db path (fun db ->
    let sql = Printf.sprintf
        "UPDATE actor_state SET state_version = %d WHERE actor_type = '%s'"
        version actor_type
    in
    ignore (Sqlite3.exec db sql))

let crash_child ?(wf = "choice.json") ?(timeout_ms = 60000) store point request_id =
  spawn_env [
    "ACTOR_CRASH_CHILD=" ^ store;
    "ACTOR_CRASH_POINT=" ^ point;
    "ACTOR_CRASH_REQ=" ^ request_id;
    "ACTOR_CRASH_WF=" ^ wf;
    "ACTOR_CRASH_TIMEOUT=" ^ string_of_int timeout_ms;
  ]

let wait_crash pid =
  if pid = 0 then ()
  else
    match Unix.waitpid [] pid with
    | _, Unix.WEXITED _ | _, Unix.WSIGNALED _ | _, Unix.WSTOPPED _ -> ()

let await_ok ?(timeout_ms = 5000) id =
  match Well.Actor.await ~timeout_ms id with
  | Ok (Well.Actor.Terminal s) -> s
  | Ok (Wait_timeout _) -> failwith "timeout"
  | Error e -> failwith e.message

let run_choice store request_id crash_point complete =
  Well.Actor._reset ();
  current_store := store;
  let cfg = {
    Well.Actor.store_path = store;
    limits = Well.Actor.default_limits;
    retry_policy = Well.Actor.default_retry_policy;
  } in
  (match Well.Actor.configure cfg with Ok () -> () | Error e -> prerr_endline e.message; exit 4);
  let desc = descriptor () in
  register_all desc;
  (match crash_point with None -> () | Some p -> Well.Actor._set_crash (Some p));
  (try
     Eio_main.run (fun env ->
       Well.Env.set env;
       Eio.Switch.run (fun sw ->
         Well.Actor.start_all ~sw;
         let wf_file =
           Option.value ~default:"choice.json" (Sys.getenv_opt "ACTOR_CRASH_WF")
         in
         let wf_json = Yojson.Safe.from_file (Filename.concat examples wf_file) in
         match Well.Actor.Workflow.validate wf_json with
         | Error _ -> ()
         | Ok wf ->
           let mt = request_type desc in
           let timeout_ms =
             Option.value ~default:60000
               (Option.bind (Sys.getenv_opt "ACTOR_CRASH_TIMEOUT") int_of_string_opt)
           in
           match Well.Actor.send ~request_id ~timeout_ms wf
                   (Well.Actor.Message (mt, ("finance", "Q3"))) with
           | Error _ -> ()
           | Ok id ->
             if complete then ignore (Well.Actor.await ~timeout_ms:5000 id)
             else Well.Env.sleep 4.))
   with _ -> ())

let () =
  match Sys.getenv_opt "ACTOR_CRASH_CHILD" with
  | Some store ->
    let point = Option.value ~default:"after_handle_before_commit"
        (Sys.getenv_opt "ACTOR_CRASH_POINT") in
    let req = Option.value ~default:"d02" (Sys.getenv_opt "ACTOR_CRASH_REQ") in
    run_choice store req (Some point) false;
    exit 1
  | None ->
    match Sys.getenv_opt "ACTOR_RUN_CHILD" with
    | Some store ->
      let req = Option.value ~default:"run" (Sys.getenv_opt "ACTOR_RUN_REQ") in
      run_choice store req None true;
      exit 0
    | None ->
      match Sys.getenv_opt "ACTOR_SPAWN_HELPER" with
      | Some _ -> run_spawn_helper ()
      | None -> start_spawn_helper ()

let () =
  Well_test.default_timeout 60.;
  describe "Actor admission" (fun () ->
    it "A01 configure once and freeze register" (fun () ->
      Well.Actor._reset ();
      let dir = tmp_dir "a01-" in
      let cfg = {
        Well.Actor.store_path = Filename.concat dir "s.sqlite";
        limits = Well.Actor.default_limits;
        retry_policy = Well.Actor.default_retry_policy;
      } in
      expect (match Well.Actor.configure cfg with Ok () -> true | Error _ -> false) |> to_be_true;
      expect (match Well.Actor.configure cfg with Error e -> e.code | Ok () -> "")
      |> to_equal_string "AlreadyConfigured";
      let bad = { cfg with retry_policy = { max_attempts = 3; delays_ms = [1] } } in
      Well.Actor._reset ();
      expect (match Well.Actor.configure bad with Error e -> e.code | Ok () -> "")
      |> to_equal_string "InvalidConfiguration";
      let zlim = { Well.Actor.default_limits with max_active = 0 } in
      Well.Actor._reset ();
      expect (match Well.Actor.configure { cfg with limits = zlim } with
        | Error e -> e.code | Ok () -> "")
      |> to_equal_string "InvalidConfiguration";
      expect Well.Actor.default_retry_policy.max_attempts |> to_equal_int 5;
      expect (List.length Well.Actor.default_retry_policy.delays_ms) |> to_equal_int 4;
      expect (List.nth Well.Actor.default_retry_policy.delays_ms 0) |> to_equal_int 1000;
      expect (List.nth Well.Actor.default_retry_policy.delays_ms 1) |> to_equal_int 2000;
      expect (List.nth Well.Actor.default_retry_policy.delays_ms 2) |> to_equal_int 4000;
      expect (List.nth Well.Actor.default_retry_policy.delays_ms 3) |> to_equal_int 8000;
      rm_rf dir);

    it "A03 send before start is NotRunning" (fun () ->
      Well.Actor._reset ();
      let dir = tmp_dir "a03-" in
      let cfg = {
        Well.Actor.store_path = Filename.concat dir "s.sqlite";
        limits = Well.Actor.default_limits;
        retry_policy = Well.Actor.default_retry_policy;
      } in
      ignore (Well.Actor.configure cfg);
      let desc = descriptor () in
      register_all desc;
      let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
      match Well.Actor.Workflow.validate wf_json with
      | Error _ -> fail "validate"
      | Ok wf ->
        let mt = request_type desc in
        (match Well.Actor.send ~request_id:"r1" ~timeout_ms:60000 wf
                 (Well.Actor.Message (mt, ("finance", "Q3"))) with
         | Error e -> expect e.code |> to_equal_string "NotRunning"
         | Ok _ -> fail "should not run");
        rm_rf dir);

    it "A02 validate does not run handle" (fun () ->
      Well.Actor._reset ();
      reporter_clear ();
      Atomic.set reporter_inits 0;
      Atomic.set decision_handles 0;
      Atomic.set effect_calls 0;
      let desc = descriptor () in
      register_all desc;
      expect (Atomic.get reporter_inits) |> to_equal_int 0;
      expect (Atomic.get decision_handles) |> to_equal_int 0;
      expect (Atomic.get effect_calls) |> to_equal_int 0;
      let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
      match Well.Actor.Workflow.validate wf_json with
      | Ok _ ->
        expect (Atomic.get reporter_inits) |> to_equal_int 0;
        expect (Atomic.get decision_handles) |> to_equal_int 0;
        expect (Atomic.get effect_calls) |> to_equal_int 0
      | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; "));
  );

  describe "Actor workflows" (fun () ->
    it "W05 choice Rejected path only" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"choice-rej" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "reject"))) with
          | Error e -> fail e.message
          | Ok id ->
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            expect (List.length snap.outputs) |> to_equal_int 1;
            expect (List.hd snap.outputs).payload_type |> to_equal_string "Reports.Summary"));

    it "W01 choice Accepted path" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"choice-1" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            expect (List.length snap.outputs > 0) |> to_be_true));

    it "W01 three-reports join order" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"three-1" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true));

    it "W01 nested-reports" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "nested-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"nested-1" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true));

    it "W01 dynamic-reports and empty list" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "dynamic-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_list_type desc in
          (match Well.Actor.send ~request_id:"dyn-empty" ~timeout_ms:60000 wf
                   (Well.Actor.Message (mt, [])) with
           | Error e -> fail e.message
           | Ok id ->
             let snap = await_ok id in
             expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true);
          match Well.Actor.send ~request_id:"dyn-two" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, [("finance", "Q3"); ("sales", "Q3")])) with
          | Error e -> fail e.message
          | Ok id ->
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true));

    it "W02 invalid workflow" (fun () ->
      with_runtime (fun _desc ->
        let json = `Assoc [
          "format", `Int 1;
          "name", `String "bad";
          "version", `String "1";
          "entry", `String "missing";
          "input_type", `String "Reports.Request";
          "bindings", `Assoc [];
          "nodes", `Assoc [];
        ] in
        match Well.Actor.Workflow.validate json with
        | Ok _ -> fail "expected invalid"
        | Error errs ->
          expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs) |> to_be_true));

    it "W08 defensive copy" (fun () ->
      with_runtime (fun desc ->
        let json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let stored = Well.Actor.Workflow.to_json wf in
          let mutated =
            match json with
            | `Assoc fs -> `Assoc (("entry", `String "missing") :: List.remove_assoc "entry" fs)
            | other -> other
          in
          expect (Yojson.Safe.to_string stored <> Yojson.Safe.to_string mutated) |> to_be_true;
          (match stored with
           | `Assoc fs ->
             expect (match List.assoc "entry" fs with `String s -> s | _ -> "")
             |> to_equal_string "decide"
           | _ -> fail "copy");
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"w08" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true));

    it "W03 payload mismatch is rejected before admission" (fun () ->
      with_runtime (fun _desc ->
        let json = workflow ~name:"w03" ~entry:"decide" ~input:"Reports.Request" [
          "decide", actor_node ~actor:"ReportDecision" ~id:(`Assoc ["fixed", `String "default"])
            ~accept:"Choose" ~mode:"one" ~outputs:["Accepted", "summary"; "Rejected", "rejected"] ();
          "summary", actor_node ~actor:"SummaryBuilder" ~id:(`Assoc ["fixed", `String "default"])
            ~accept:"Build" ~mode:"one" ~outputs:["Built", "done"] ();
          "done", end_node "Reports.Summary";
          "rejected", end_node "Reports.Summary";
        ] in
        match Well.Actor.Workflow.validate json with
        | Ok _ -> fail "expected payload mismatch"
        | Error errs ->
          expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs)
          |> to_be_true));

    it "W05 zero or two emissions at one fail without state" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          let run req sub =
            match Well.Actor.send ~request_id:req ~timeout_ms:60000 wf
                    (Well.Actor.Message (mt, ("finance", sub))) with
            | Error e -> fail e.message
            | Ok id ->
              match Well.Actor.await ~timeout_ms:5000 id with
              | Ok (Well.Actor.Terminal s) ->
                expect (match s.status with
                  | Well.Actor.Failed d when d.error.code = "InvalidEmission" -> true
                  | _ -> false) |> to_be_true;
                expect (List.length s.outputs) |> to_equal_int 0
              | Ok (Wait_timeout _) -> fail "timeout"
              | Error e -> fail e.message
          in
          run "w05-none" "none";
          run "w05-two" "two";
          expect (scalar !current_store "SELECT COUNT(*) FROM actor_state") |> to_equal_int 0));

    it "W07 missing output drop and optional zero" (fun () ->
      with_runtime (fun desc ->
        let missing = workflow ~name:"w07-miss" ~entry:"decide" ~input:"Reports.Request" [
          "decide", actor_node ~actor:"ReportDecision" ~id:(`Assoc ["fixed", `String "default"])
            ~accept:"Choose" ~mode:"one" ~outputs:["Accepted", "done"] ();
          "done", end_node "Reports.Request";
        ] in
        (match Well.Actor.Workflow.validate missing with
         | Ok _ -> fail "missing Rejected output"
         | Error errs ->
           expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs)
           |> to_be_true);
        let drop_wf = workflow ~name:"w07-drop" ~entry:"decide" ~input:"Reports.Request" [
          "decide", actor_node ~actor:"ReportDecision" ~id:(`Assoc ["fixed", `String "default"])
            ~accept:"Choose" ~mode:"one" ~outputs:["Accepted", "sink"; "Rejected", "rej"] ();
          "sink", drop_node "Reports.Request";
          "rej", drop_node "Reports.Summary";
        ] in
        (match Well.Actor.Workflow.validate drop_wf with
         | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
         | Ok wf ->
           let mt = request_type desc in
           match Well.Actor.send ~request_id:"w07-drop" ~timeout_ms:60000 wf
                   (Well.Actor.Message (mt, ("finance", "Q3"))) with
           | Error e -> fail e.message
           | Ok id ->
             let snap = await_ok id in
             expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
             expect (List.length snap.outputs) |> to_equal_int 0);
        let opt_wf = workflow ~name:"w07-opt" ~entry:"decide" ~input:"Reports.Request" [
          "decide", actor_node ~actor:"ReportDecision" ~id:(`Assoc ["fixed", `String "default"])
            ~accept:"Choose" ~mode:"optional" ~outputs:["Accepted", "done"; "Rejected", "rej"] ();
          "done", end_node "Reports.Request";
          "rej", end_node "Reports.Summary";
        ] in
        match Well.Actor.Workflow.validate opt_wf with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"w07-opt" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "quiet"))) with
          | Error e -> fail e.message
          | Ok id ->
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            expect (List.length snap.outputs) |> to_equal_int 0));

    it "W10 two nodes share actor type and id" (fun () ->
      with_runtime (fun desc ->
        let json = workflow ~name:"w10" ~entry:"start" ~input:"Reports.Request" [
          "start", `Assoc [
            "kind", `String "fork";
            "input_type", `String "Reports.Request";
            "branches", `List [
              `Assoc ["name", `String "a"; "next", `String "left"];
              `Assoc ["name", `String "b"; "next", `String "right"];
            ];
            "join", `String "collect";
          ];
          "left", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "shared"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "collect"] ();
          "right", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "shared"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "collect"] ();
          "collect", `Assoc [
            "kind", `String "join";
            "item_type", `String "Reports.Report";
            "batch_type", `String "Reports.ReportBatch";
            "timeout_ms", `Int 30000;
            "next", `String "done";
          ];
          "done", end_node "Reports.ReportBatch";
        ] in
        match Well.Actor.Workflow.validate json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"w10" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            expect (reporter_count "shared")
            |> to_equal_int 2));

    it "J05 static join graph errors" (fun () ->
      with_runtime (fun _desc ->
        let end_before = workflow ~name:"j05a" ~entry:"start" ~input:"Reports.Request" [
          "start", `Assoc [
            "kind", `String "fork";
            "input_type", `String "Reports.Request";
            "branches", `List [
              `Assoc ["name", `String "a"; "next", `String "early"];
              `Assoc ["name", `String "b"; "next", `String "collect"];
            ];
            "join", `String "collect";
          ];
          "early", end_node "Reports.Request";
          "collect", `Assoc [
            "kind", `String "join";
            "item_type", `String "Reports.Request";
            "batch_type", `String "Reports.ReportBatch";
            "timeout_ms", `Int 1000;
            "next", `String "done";
          ];
          "done", end_node "Reports.ReportBatch";
        ] in
        (match Well.Actor.Workflow.validate end_before with
         | Ok _ -> fail "end before join"
         | Error errs ->
           expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs)
           |> to_be_true);
        let two_src = workflow ~name:"j05b" ~entry:"start" ~input:"Reports.Request" [
          "start", `Assoc [
            "kind", `String "fork";
            "input_type", `String "Reports.Request";
            "branches", `List [
              `Assoc ["name", `String "a"; "next", `String "left"];
              `Assoc ["name", `String "b"; "next", `String "right"];
            ];
            "join", `Null;
          ];
          "left", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "finance"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "collect"] ~join:(`String "collect") ();
          "right", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "sales"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "collect"] ~join:(`String "collect") ();
          "collect", `Assoc [
            "kind", `String "join";
            "item_type", `String "Reports.Report";
            "batch_type", `String "Reports.ReportBatch";
            "timeout_ms", `Int 1000;
            "next", `String "done";
          ];
          "done", end_node "Reports.ReportBatch";
        ] in
        (match Well.Actor.Workflow.validate two_src with
         | Ok _ -> fail "two sources"
         | Error errs ->
           expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs)
           |> to_be_true);
        let fanout = workflow ~name:"j05c" ~entry:"start" ~input:"Reports.Request" [
          "start", `Assoc [
            "kind", `String "fork";
            "input_type", `String "Reports.Request";
            "branches", `List [
              `Assoc ["name", `String "a"; "next", `String "spawn"];
            ];
            "join", `String "collect";
          ];
          "spawn", actor_node ~actor:"ReportSpawner" ~id:(`Assoc ["fixed", `String "default"])
            ~accept:"Generate" ~mode:"many" ~outputs:["Requested", "collect"] ();
          "collect", `Assoc [
            "kind", `String "join";
            "item_type", `String "Reports.Request";
            "batch_type", `String "Reports.ReportBatch";
            "timeout_ms", `Int 1000;
            "next", `String "done";
          ];
          "done", end_node "Reports.ReportBatch";
        ] in
        (match Well.Actor.Workflow.validate fanout with
        | Ok _ -> fail "fan-out without inner join"
        | Error errs ->
          expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs)
          |> to_be_true);
        let drop_before = workflow ~name:"j05d" ~entry:"start" ~input:"Reports.Request" [
          "start", `Assoc [
            "kind", `String "fork";
            "input_type", `String "Reports.Request";
            "branches", `List [
              `Assoc ["name", `String "a"; "next", `String "early"];
              `Assoc ["name", `String "b"; "next", `String "collect"];
            ];
            "join", `String "collect";
          ];
          "early", drop_node "Reports.Request";
          "collect", `Assoc [
            "kind", `String "join";
            "item_type", `String "Reports.Request";
            "batch_type", `String "Reports.ReportBatch";
            "timeout_ms", `Int 1000;
            "next", `String "done";
          ];
          "done", end_node "Reports.ReportBatch";
        ] in
        (match Well.Actor.Workflow.validate drop_before with
         | Ok _ -> fail "drop before join"
         | Error errs ->
           expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs)
           |> to_be_true);
        let foreign = workflow ~name:"j05e" ~entry:"start" ~input:"Reports.Request" [
          "start", `Assoc [
            "kind", `String "fork";
            "input_type", `String "Reports.Request";
            "branches", `List [
              `Assoc ["name", `String "a"; "next", `String "left"];
              `Assoc ["name", `String "b"; "next", `String "right"];
            ];
            "join", `String "collect";
          ];
          "left", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "finance"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "collect"] ();
          "right", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "sales"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "collect"] ~join:(`String "other") ();
          "other", `Assoc [
            "kind", `String "join";
            "item_type", `String "Reports.Report";
            "batch_type", `String "Reports.ReportBatch";
            "timeout_ms", `Int 1000;
            "next", `String "done";
          ];
          "collect", `Assoc [
            "kind", `String "join";
            "item_type", `String "Reports.Report";
            "batch_type", `String "Reports.ReportBatch";
            "timeout_ms", `Int 1000;
            "next", `String "done";
          ];
          "done", end_node "Reports.ReportBatch";
        ] in
        (match Well.Actor.Workflow.validate foreign with
         | Ok _ -> fail "foreign group"
         | Error errs ->
           expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs)
           |> to_be_true);
        let skip = workflow ~name:"j05f" ~entry:"start" ~input:"Reports.Request" [
          "start", `Assoc [
            "kind", `String "fork";
            "input_type", `String "Reports.Request";
            "branches", `List [
              `Assoc ["name", `String "bundle"; "next", `String "nested"];
              `Assoc ["name", `String "stock"; "next", `String "stock"];
            ];
            "join", `String "collect";
          ];
          "nested", `Assoc [
            "kind", `String "fork";
            "input_type", `String "Reports.Request";
            "branches", `List [
              `Assoc ["name", `String "finance"; "next", `String "finance"];
              `Assoc ["name", `String "sales"; "next", `String "sales"];
            ];
            "join", `String "inner";
          ];
          "finance", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "finance"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "collect"] ();
          "sales", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "sales"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "inner"] ();
          "inner", `Assoc [
            "kind", `String "join";
            "item_type", `String "Reports.Report";
            "batch_type", `String "Reports.ReportBatch";
            "timeout_ms", `Int 1000;
            "next", `String "collect";
          ];
          "stock", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "stock"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "collect"] ();
          "collect", `Assoc [
            "kind", `String "join";
            "item_type", `String "Reports.Report";
            "batch_type", `String "Reports.ReportBatch";
            "timeout_ms", `Int 1000;
            "next", `String "done";
          ];
          "done", end_node "Reports.ReportBatch";
        ] in
        match Well.Actor.Workflow.validate skip with
        | Ok _ -> fail "skip nesting"
        | Error errs ->
          expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs)
          |> to_be_true));

    it "A05 idempotent send" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          let packed = Well.Actor.Message (mt, ("finance", "Q3")) in
          match Well.Actor.send ~request_id:"idem-1" ~timeout_ms:60000 wf packed,
                Well.Actor.send ~request_id:"idem-1" ~timeout_ms:60000 wf packed
          with
          | Ok a, Ok b -> expect a |> to_equal_string b
          | Error e, _ | _, Error e -> fail e.message));

    it "R01 legacy register still works without store" (fun () ->
      Well.Actor._reset ();
      Eio_main.run (fun env ->
        Well.Env.set env;
        Eio.Switch.run (fun sw ->
          Well.Actor.start_all ~sw;
          expect (List.length (Well.Actor.health ())) |> to_equal_int 0;
          (try ignore (Well.Actor.metrics ()); fail "metrics should fail"
           with Invalid_argument _ -> ())));
      let _running : Well.Actor.child_status = Running in
      let _restarting : Well.Actor.child_status = Restarting { attempts = 1 } in
      let _down : Well.Actor.child_status = Down "x" in
      ());
  );

  describe "Actor scheduler and durability" (fun () ->
    it "S01 held address does not block another id" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "Reporter"; id = "finance" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"s01" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            Well.Env.sleep 0.4;
            expect (reporter_count "finance")
            |> to_equal_int 0;
            expect (reporter_count "sales" > 0)
            |> to_be_true;
            Well.Actor._release { actor_type = "Reporter"; id = "finance" };
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true));

    it "S04 older input keeps its place during backoff" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          let send req sub reporter =
            Well.Actor.send ~request_id:req ~timeout_ms:60000 wf
              (Well.Actor.Message (mt, (reporter, sub)))
          in
          (match send "s04-old" "backoff" "finance" with
           | Error e -> fail e.message
           | Ok _ -> ());
          wait_until 40 (fun () -> reporter_count "finance" = 1);
          (match send "s04-new" "Q3" "finance", send "s04-other" "Q3" "sales" with
           | Error e, _ | _, Error e -> fail e.message
           | Ok newer, Ok other ->
             wait_until 40 (fun () -> reporter_count "sales" > 0);
             expect (reporter_count "finance")
             |> to_equal_int 1;
             expect (reporter_count "sales" > 0)
             |> to_be_true;
             ignore (await_ok other);
             let old =
               match execution_of_request !current_store "s04-old" with
               | Some id -> id | None -> fail "missing old"
             in
             ignore (await_ok old);
             ignore (await_ok newer);
             expect (reporter_count "finance")
             |> to_equal_int 3)));

    it "S06 second activation of held id does not start handle" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          let send n =
            Well.Actor.send ~request_id:n ~timeout_ms:60000 wf
              (Well.Actor.Message (mt, ("finance", "Q3")))
          in
          match send "s06-a", send "s06-b" with
          | Error e, _ | _, Error e -> fail e.message
          | Ok a, Ok b ->
            Well.Env.sleep 0.3;
            expect (Atomic.get decision_handles) |> to_equal_int 0;
            Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
            ignore (await_ok a);
            ignore (await_ok b);
            expect (Atomic.get decision_handles) |> to_equal_int 2));

    it "S08 mismatched state_version blocks and keeps inbox" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          (match Well.Actor.send ~request_id:"s08-1" ~timeout_ms:60000 wf
                   (Well.Actor.Message (mt, ("finance", "Q3"))) with
           | Error e -> fail e.message
           | Ok id -> ignore (await_ok id));
          bump_state_version !current_store "Reporter" 99;
          match Well.Actor.send ~request_id:"s08-2" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            Well.Env.sleep 0.4;
            let snap = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap.status with Well.Actor.Blocked _ -> true | _ -> false) |> to_be_true;
            (match Well.Actor.resume id with
             | Error errs ->
               expect (List.exists (fun (e : Well.Actor.error) -> e.code = "SchemaMismatch") errs)
               |> to_be_true
             | Ok () -> fail "resume should reject");
            let snap2 = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap2.status with Well.Actor.Blocked _ -> true | _ -> false) |> to_be_true));

    it "A10 resume rejects non-blocked and abandon is idempotent" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"a10" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "reject"))) with
          | Error e -> fail e.message
          | Ok id ->
            ignore (await_ok id);
            (match Well.Actor.resume id with
             | Error errs ->
               expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidOperation") errs)
               |> to_be_true
             | Ok () -> fail "resume completed");
            (match Well.Actor.abandon id ~reason:"x" with
             | Error e -> expect e.code |> to_equal_string "InvalidOperation"
             | Ok () -> fail "abandon completed")));

    it "D11 handle finishing after deadline does not commit" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"d11" ~timeout_ms:1000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            Well.Env.sleep 0.15;
            let snap = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap.status with Well.Actor.Running -> true | _ -> false) |> to_be_true;
            expect (Atomic.get decision_handles) |> to_equal_int 0;
            Well.Actor._set_now_ms (Int64.add snap.deadline_ms 5L);
            Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
            (match Well.Actor.await ~timeout_ms:3000 id with
             | Ok (Well.Actor.Terminal s) ->
               expect (match s.status with
                 | Well.Actor.Failed d when d.error.code = "ExecutionTimeout" -> true
                 | _ -> false) |> to_be_true;
               expect (reporter_len ()) |> to_equal_int 0;
               expect (scalar !current_store "SELECT COUNT(*) FROM outbox") |> to_equal_int 0;
               expect (scalar !current_store "SELECT COUNT(*) FROM actor_state") |> to_equal_int 0
             | Ok (Wait_timeout _) -> fail "timeout"
             | Error e -> fail e.message)));

    it "E07 emission limit fails without partial commit" (fun () ->
      let limits = { Well.Actor.default_limits with emissions = 1 } in
      with_runtime ~limits (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"e07" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            (match Well.Actor.await ~timeout_ms:5000 id with
             | Ok (Well.Actor.Terminal s) ->
               expect (match s.status with
                 | Well.Actor.Failed d when d.error.code = "LimitExceeded" -> true
                 | _ -> false) |> to_be_true;
               expect (List.length s.outputs) |> to_equal_int 0
             | Ok (Wait_timeout _) -> fail "timeout"
             | Error e -> fail e.message)));

    it "E08 admission overload leaves existing execution running" (fun () ->
      let limits = { Well.Actor.default_limits with active_executions = 1 } in
      with_runtime ~limits (fun desc ->
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          let packed = Well.Actor.Message (mt, ("finance", "Q3")) in
          let first =
            match Well.Actor.send ~request_id:"e08-a" ~timeout_ms:60000 wf packed with
            | Error e -> fail e.message
            | Ok id -> id
          in
          (match Well.Actor.send ~request_id:"e08-b" ~timeout_ms:60000 wf packed with
           | Error e -> expect e.code |> to_equal_string "Overloaded"
           | Ok _ -> fail "should overload");
          Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
          ignore (await_ok first)));

    it "D07 write failure does not admit a partial execution" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._set_force_write_error ~sticky:true (Some "disk full");
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"d07" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> expect e.code |> to_equal_string "StorageUnavailable"
          | Ok _ -> fail "admission should fail"));

    it "D07 commit write failure does not persist domain state" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"d07c" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            Well.Actor._set_force_write_error ~sticky:true (Some "disk full");
            Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
            Well.Env.sleep 0.3;
            let snap = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap.status with Well.Actor.Completed -> false | _ -> true) |> to_be_true;
            expect (scalar !current_store "SELECT COUNT(*) FROM actor_state") |> to_equal_int 0;
            Well.Actor._set_force_write_error None));

    it "D07 runtime SQLITE_FULL rejects admission without a partial execution" (fun () ->
      let baseline = ref 0 in
      with_runtime (fun _ ->
        match Well.Actor._store_pragma "page_count" with
        | Ok s -> baseline := int_of_string s
        | Error e -> fail e.message);
      with_runtime ~max_pages:(!baseline + 8) (fun desc ->
        (match Well.Actor._store_pragma "journal_mode" with
         | Ok s -> expect (String.lowercase_ascii s) |> to_equal_string "wal"
         | Error e -> fail e.message);
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          let rec grow i acc =
            if i > 40 then acc
            else
              match Well.Actor.send ~request_id:("d07g" ^ string_of_int i) ~timeout_ms:60000 wf
                      (Well.Actor.Message (mt, ("finance", "Q3"))) with
              | Ok _ -> grow (i + 1) (acc + 1)
              | Error e ->
                expect e.code |> to_equal_string "StorageUnavailable";
                if not (sqlite_full_msg e.message) then fail ("grow err " ^ e.message);
                acc
          in
          let n = grow 1 0 in
          expect (n > 0) |> to_be_true;
          let before = scalar !current_store "SELECT COUNT(*) FROM executions" in
          expect before |> to_equal_int n;
          (match Well.Actor.send ~request_id:"d07rt" ~timeout_ms:60000 wf
                   (Well.Actor.Message (mt, ("finance", "Q3"))) with
           | Error e ->
             expect e.code |> to_equal_string "StorageUnavailable";
             if not (sqlite_full_msg e.message) then fail ("send err " ^ e.message)
           | Ok _ -> fail "admission should fail");
          expect (scalar !current_store "SELECT COUNT(*) FROM executions") |> to_equal_int before));

    it "D07 admitted execution survives later SQLITE_FULL then recovers" (fun () ->
      let after_admit = ref 0 in
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"d07meas" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok _ ->
            match Well.Actor._store_pragma "page_count" with
            | Ok s -> after_admit := int_of_string s
            | Error e -> fail e.message);
      with_runtime ~max_pages:(!after_admit + 4) (fun desc ->
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"d07rcv" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            expect (scalar !current_store "SELECT COUNT(*) FROM executions") |> to_equal_int 1;
            let rec grow i =
              if i > 40 then fail "later admission never hit SQLITE_FULL"
              else
                match Well.Actor.send ~request_id:("d07c" ^ string_of_int i) ~timeout_ms:60000 wf
                        (Well.Actor.Message (mt, ("finance", "Q3"))) with
                | Ok _ -> grow (i + 1)
                | Error e ->
                  expect e.code |> to_equal_string "StorageUnavailable";
                  if not (sqlite_full_msg e.message) then fail ("later send " ^ e.message)
            in
            grow 1;
            expect (scalar !current_store
                      ("SELECT COUNT(*) FROM executions WHERE execution_id = '" ^ id ^ "'"))
            |> to_equal_int 1;
            expect (scalar !current_store "SELECT COUNT(*) FROM actor_state") |> to_equal_int 0;
            Well.Actor._set_max_page_count None;
            Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
            let snap = await_ok ~timeout_ms:15000 id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true));

    it "D07 CommitTurn SQLITE_FULL in WAL rolls back and recovers admitted input" (fun () ->
      with_runtime (fun desc ->
        (match Well.Actor._store_pragma "journal_mode" with
         | Ok s -> expect (String.lowercase_ascii s) |> to_equal_string "wal"
         | Error e -> fail e.message);
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          let fat = String.make 80000 'x' in
          match Well.Actor.send ~request_id:"d07ct" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", fat))) with
          | Error e -> fail e.message
          | Ok id ->
            wait_until 40 (fun () ->
              scalar !current_store "SELECT COUNT(*) FROM inbox WHERE status = 'claimed'" = 1);
            expect (scalar !current_store "SELECT COUNT(*) FROM executions") |> to_equal_int 1;
            (match Well.Actor._store_exec
                     "CREATE TABLE IF NOT EXISTS filler (id INTEGER PRIMARY KEY, b BLOB NOT NULL)"
             with
             | Error e -> fail e.message
             | Ok () -> ());
            let pages =
              match Well.Actor._store_pragma "page_count" with
              | Ok s -> int_of_string s
              | Error e -> fail e.message
            in
            Well.Actor._set_max_page_count (Some (pages + 2));
            let rec fill i =
              if i > 200 then fail "filler never hit SQLITE_FULL"
              else
                match Well.Actor._store_exec "INSERT INTO filler(b) VALUES (zeroblob(4096))" with
                | Ok () ->
                  ignore (Well.Actor._store_exec "PRAGMA wal_checkpoint(TRUNCATE)");
                  fill (i + 1)
                | Error e ->
                  expect e.code |> to_equal_string "StorageUnavailable";
                  if not (sqlite_full_msg e.message) then fail ("filler " ^ e.message)
            in
            fill 1;
            (match Well.Actor._store_pragma "page_count" with
             | Ok s -> Well.Actor._set_max_page_count (Some (int_of_string s))
             | Error e -> fail e.message);
            (match Well.Actor._store_pragma "journal_mode" with
             | Ok s -> expect (String.lowercase_ascii s) |> to_equal_string "wal"
             | Error e -> fail e.message);
            let finished = Well.Actor._activations_finished () in
            Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
            let rec wait_ct n =
              let fin = Well.Actor._activations_finished () in
              let st = scalar !current_store "SELECT COUNT(*) FROM actor_state" in
              let ob = scalar !current_store "SELECT COUNT(*) FROM outbox" in
              if fin > finished && st = 0 && ob = 0 then ()
              else if n <= 0 then
                fail (Printf.sprintf "commit-full wait fin=%d->%d state=%d outbox=%d"
                        finished fin st ob)
              else begin Well.Env.sleep 0.05; wait_ct (n - 1) end
            in
            wait_ct 40;
            (match Well.Actor._last_turn_error () with
             | Some m when sqlite_full_msg m -> ()
             | Some m -> fail ("CommitTurn error was not FULL: " ^ m)
             | None -> fail "CommitTurn produced no store error");
            expect (scalar !current_store
                      ("SELECT COUNT(*) FROM executions WHERE execution_id = '" ^ id ^ "'"))
            |> to_equal_int 1;
            expect (scalar !current_store
                      "SELECT COUNT(*) FROM inbox WHERE status IN ('ready','claimed')")
            |> to_equal_int 1;
            expect (match Well.Actor.inspect id with
              | Ok s -> (match s.status with Well.Actor.Completed -> false | _ -> true)
              | Error _ -> false)
            |> to_be_true;
            Well.Actor._set_max_page_count None;
            (match Well.Actor._store_exec "DROP TABLE IF EXISTS filler" with
             | Error e -> fail e.message
             | Ok () -> ());
            let snap =
              match Well.Actor.await ~timeout_ms:8000 id with
              | Ok (Well.Actor.Terminal s) -> s
              | Ok (Wait_timeout s) ->
                fail (Printf.sprintf
                        "recover timeout status_pending=%d inbox=%s claim=%s"
                        s.pending_messages
                        (scalar_text !current_store "SELECT status FROM inbox LIMIT 1")
                        (scalar_text !current_store
                           "SELECT IFNULL(claim_owner,'') FROM inbox LIMIT 1"))
              | Error e -> fail e.message
            in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            expect (scalar !current_store
                      "SELECT COUNT(*) FROM actor_state WHERE actor_type = 'ReportDecision'")
            |> to_equal_int 1));

    it "D08 ambiguous commit is resolved from durable message id" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"d08" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            Well.Actor._set_ambiguous_commit true;
            Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            expect (Atomic.get decision_handles) |> to_equal_int 1));

    it "D09 second process cannot open the store" (fun () ->
      with_runtime (fun _desc ->
        let pid = spawn_env [ "ACTOR_LOCK_CHILD=" ^ !current_store ] in
        wait_ok pid));

    it "reset does not release the store when a worker exceeds join timeout" (fun () ->
      with_runtime (fun _desc ->
        Well.Actor._set_join_timeout_ms 100;
        Well.Actor._set_shutdown_hang_ms 400;
        Well.Actor._reset ();
        expect (Well.Actor._worker_live () > 0) |> to_be_true;
        let pid = spawn_env [ "ACTOR_LOCK_CHILD=" ^ !current_store ] in
        wait_ok pid;
        wait_until 80 (fun () -> Well.Actor._worker_live () = 0);
        Well.Actor._set_join_timeout_ms 2000;
        Well.Actor._set_shutdown_hang_ms 0));

    it "reset does not release the store when pending close remains busy" (fun () ->
      with_runtime (fun _desc ->
        Well.Actor._stop ();
        wait_until 80 (fun () -> Well.Actor._worker_live () = 0);
        expect (Well.Actor._pin_busy_close !current_store > 0) |> to_be_true;
        Fun.protect ~finally:Well.Actor._unpin_busy_close (fun () ->
          Well.Actor._reset ();
          let pid = spawn_env [ "ACTOR_LOCK_CHILD=" ^ !current_store ] in
          wait_ok pid)));

    it "D02 crash before commit retries the same input" (fun () ->
      let dir = tmp_dir "d02-" in
      let store = Filename.concat dir "store.sqlite" in
      wait_crash (crash_child store "after_handle_before_commit" "d02");
      with_existing_store store (fun _desc ->
        match execution_of_request store "d02" with
        | None -> fail "admission lost"
        | Some eid ->
          match Well.Actor.await ~timeout_ms:15000 eid with
          | Ok (Well.Actor.Terminal s) ->
            expect (match s.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true
          | Ok (Wait_timeout _) -> fail "timeout after restart"
          | Error e -> fail e.message);
      rm_rf dir);

    it "D01 crash after admission retries the same execution id" (fun () ->
      let dir = tmp_dir "d01-" in
      let store = Filename.concat dir "store.sqlite" in
      wait_crash (crash_child store "admit:after_commit" "d01");
      let first = execution_of_request store "d01" in
      expect (first <> None) |> to_be_true;
      with_existing_store store (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json, first with
        | Error _, _ | _, None -> fail "setup"
        | Ok wf, Some eid ->
          let mt = request_type desc in
          (match Well.Actor.send ~request_id:"d01" ~timeout_ms:60000 wf
                   (Well.Actor.Message (mt, ("finance", "Q3"))) with
           | Error e -> fail e.message
           | Ok id -> expect id |> to_equal_string eid);
          let snap = await_ok ~timeout_ms:15000 eid in
          expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true);
      rm_rf dir);

    it "D03 crash inside CommitTurn leaves no partial writes" (fun () ->
      let dir = tmp_dir "d03-" in
      let store = Filename.concat dir "store.sqlite" in
      wait_crash (crash_child store "commit_turn:before_commit" "d03");
      expect (scalar store "SELECT COUNT(*) FROM outbox") |> to_equal_int 0;
      expect (scalar store "SELECT COUNT(*) FROM actor_state") |> to_equal_int 0;
      Unix.sleepf 0.1;
      with_existing_store store (fun _desc ->
        match execution_of_request store "d03" with
        | None -> fail "admission lost"
        | Some eid ->
          match Well.Actor.await ~timeout_ms:15000 eid with
          | Ok (Well.Actor.Terminal s) ->
            expect (match s.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true
          | Ok (Wait_timeout s) ->
            fail (match s.status with
              | Well.Actor.Running -> "still running"
              | Well.Actor.Blocked _ -> "blocked"
              | Well.Actor.Completed -> "completed after wait timeout"
              | Well.Actor.Failed d -> "failed " ^ d.error.code)
          | Error e -> fail e.message);
      rm_rf dir);

    it "D04 crash after CommitTurn still delivers outbox" (fun () ->
      let dir = tmp_dir "d04-" in
      let store = Filename.concat dir "store.sqlite" in
      wait_crash (crash_child store "commit_turn:after_commit" "d04");
      expect (scalar store "SELECT COUNT(*) FROM outbox") |> to_equal_int 1;
      expect (scalar store "SELECT COUNT(*) FROM actor_state WHERE actor_type = 'ReportDecision'")
      |> to_equal_int 1;
      with_existing_store store (fun _desc ->
        match execution_of_request store "d04" with
        | None -> fail "admission lost"
        | Some eid ->
          let snap = await_ok ~timeout_ms:15000 eid in
          expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
          expect (scalar store "SELECT revision FROM actor_state WHERE actor_type = 'ReportDecision'")
          |> to_equal_int 1);
      rm_rf dir);

    it "D05 redelivery of outbox processes the receiver once" (fun () ->
      let dir = tmp_dir "d05-" in
      let store = Filename.concat dir "store.sqlite" in
      wait_crash (crash_child store "deliver_outbox:after_commit" "d05");
      with_existing_store store (fun _desc ->
        match execution_of_request store "d05" with
        | None -> fail "admission lost"
        | Some eid ->
          let snap = await_ok ~timeout_ms:15000 eid in
          expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
          expect (scalar store "SELECT COUNT(*) FROM inbox WHERE actor_type = 'Reporter'")
          |> to_equal_int 1);
      rm_rf dir);

    it "D10 blocked envelopes resume after matching code is loaded" (fun () ->
      let dir = tmp_dir "d10-" in
      let store = Filename.concat dir "store.sqlite" in
      with_existing_store store (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"d10-1" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id -> ignore (await_ok id));
      bump_state_version store "Reporter" 99;
      with_existing_store store (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"d10-2" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            Well.Env.sleep 0.4;
            let snap = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap.status with Well.Actor.Blocked _ -> true | _ -> false) |> to_be_true;
            expect (scalar store "SELECT COUNT(*) FROM inbox WHERE status = 'ready' AND actor_type = 'Reporter'")
            |> to_equal_int 1);
      bump_state_version store "Reporter" 1;
      with_existing_store store (fun _desc ->
        match execution_of_request store "d10-2" with
        | None -> fail "lost"
        | Some eid ->
          (match Well.Actor.resume eid with
           | Error e -> fail (String.concat ";" (List.map (fun (e : Well.Actor.error) -> e.message) e))
           | Ok () -> ());
          let snap = await_ok eid in
          expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true);
      rm_rf dir);

    it "resume after fork join with internal runtime actors" (fun () ->
      with_runtime (fun desc ->
        let choice = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        let three = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate choice, Well.Actor.Workflow.validate three with
        | Error _, _ | _, Error _ -> fail "validate"
        | Ok choice_wf, Ok three_wf ->
          let mt = request_type desc in
          (match Well.Actor.send ~request_id:"fork-seed" ~timeout_ms:60000 choice_wf
                   (Well.Actor.Message (mt, ("finance", "Q3"))) with
           | Error e -> fail e.message
           | Ok id -> ignore (await_ok id));
          bump_state_version !current_store "Reporter" 99;
          match Well.Actor.send ~request_id:"fork-block" ~timeout_ms:60000 three_wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            Well.Env.sleep 0.4;
            let snap = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap.status with Well.Actor.Blocked _ -> true | _ -> false) |> to_be_true;
            bump_state_version !current_store "Reporter" 1;
            (match Well.Actor.resume id with
             | Error e -> fail (String.concat ";" (List.map (fun (e : Well.Actor.error) -> e.message) e))
             | Ok () -> ());
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true));

    it "blocked execution keeps join timers until resume" (fun () ->
      with_runtime (fun desc ->
        let choice = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        let three = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate choice, Well.Actor.Workflow.validate three with
        | Error _, _ | _, Error _ -> fail "validate"
        | Ok choice_wf, Ok three_wf ->
          let mt = request_type desc in
          (match Well.Actor.send ~request_id:"tmr-seed" ~timeout_ms:60000 choice_wf
                   (Well.Actor.Message (mt, ("finance", "Q3"))) with
           | Error e -> fail e.message
           | Ok id -> ignore (await_ok id));
          bump_state_version !current_store "Reporter" 99;
          match Well.Actor.send ~request_id:"tmr-block" ~timeout_ms:60000 three_wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            Well.Env.sleep 0.4;
            let snap = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap.status with Well.Actor.Blocked _ -> true | _ -> false) |> to_be_true;
            Well.Actor._set_now_ms (Int64.add snap.deadline_ms (-20000L));
            Well.Env.sleep 0.15;
            expect (scalar !current_store
                      "SELECT COUNT(*) FROM timers WHERE kind = 'join' AND delivered = 0 AND invalidated = 0")
            |> to_equal_int 1;
            bump_state_version !current_store "Reporter" 1;
            (match Well.Actor.resume id with
             | Error e -> fail (String.concat ";" (List.map (fun (e : Well.Actor.error) -> e.message) e))
             | Ok () -> ());
            match Well.Actor.await ~timeout_ms:5000 id with
            | Ok (Well.Actor.Terminal s) ->
              expect (match s.status with
                | Well.Actor.Failed d when d.error.code = "JoinTimeout" -> true
                | _ -> false) |> to_be_true
            | Ok (Wait_timeout _) -> fail "timeout"
            | Error e -> fail e.message));

    it "blocked execution timeout fails without resume" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          (match Well.Actor.send ~request_id:"tex-seed" ~timeout_ms:60000 wf
                   (Well.Actor.Message (mt, ("finance", "Q3"))) with
           | Error e -> fail e.message
           | Ok id -> ignore (await_ok id));
          bump_state_version !current_store "Reporter" 99;
          match Well.Actor.send ~request_id:"tex-block" ~timeout_ms:5000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            Well.Env.sleep 0.3;
            let snap = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap.status with Well.Actor.Blocked _ -> true | _ -> false) |> to_be_true;
            Well.Actor._set_now_ms (Int64.add snap.deadline_ms 10L);
            Well.Env.sleep 0.25;
            let snap2 = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap2.status with
              | Well.Actor.Failed d when d.error.code = "ExecutionTimeout" -> true
              | _ -> false) |> to_be_true));

    it "resume and abandon propagate storage errors" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          (match Well.Actor.send ~request_id:"err-seed" ~timeout_ms:60000 wf
                   (Well.Actor.Message (mt, ("finance", "Q3"))) with
           | Error e -> fail e.message
           | Ok id -> ignore (await_ok id));
          bump_state_version !current_store "Reporter" 99;
          match Well.Actor.send ~request_id:"err-block" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            Well.Env.sleep 0.3;
            bump_state_version !current_store "Reporter" 1;
            Well.Actor._set_force_write_error ~sticky:true (Some "disk");
            (match Well.Actor.resume id with
             | Error errs ->
               expect (List.exists (fun (e : Well.Actor.error) -> e.code = "StorageUnavailable") errs)
               |> to_be_true
             | Ok () -> fail "resume should fail");
            let snap = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap.status with Well.Actor.Blocked _ -> true | _ -> false) |> to_be_true;
            (match Well.Actor.abandon id ~reason:"stop" with
             | Error e -> expect e.code |> to_equal_string "StorageUnavailable"
             | Ok () -> fail "abandon should fail");
            Well.Actor._set_force_write_error None;
            let snap2 = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap2.status with Well.Actor.Blocked _ -> true | _ -> false) |> to_be_true));

    it "store stall does not block HTTP on the same domain" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          let lock_held = Atomic.make false in
          Eio.Switch.run (fun sw ->
            let net = Well.Env.net () in
            let port = 41000 + (Random.int 1000) in
            let sock =
              Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:4
                (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
            in
            Eio.Fiber.fork ~sw (fun () ->
              let flow, _ = Eio.Net.accept ~sw sock in
              Eio.Flow.copy_string
                "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK" flow);
            let begin_ok = Atomic.make false in
            Eio.Fiber.fork ~sw (fun () ->
              Eio_unix.run_in_systhread (fun () ->
                let db = Sqlite3.db_open ~mutex:`FULL !current_store in
                ignore (Sqlite3.busy_timeout db 5000);
                (match Sqlite3.exec db "BEGIN IMMEDIATE" with
                 | Sqlite3.Rc.OK -> Atomic.set begin_ok true
                 | _ -> ());
                Atomic.set lock_held true;
                Unix.sleepf 0.7;
                ignore (Sqlite3.exec db "ROLLBACK");
                ignore (Sqlite3.db_close db)));
            while not (Atomic.get lock_held) do Eio_unix.sleep 0.01 done;
            expect (Atomic.get begin_ok) |> to_be_true;
            let send_done = Atomic.make false in
            let send_res = ref (Error { Well.Actor.code = ""; message = ""; path = None }) in
            Eio.Fiber.both
              (fun () ->
                send_res := Well.Actor.send ~request_id:"stall-1" ~timeout_ms:60000 wf
                              (Well.Actor.Message (mt, ("finance", "Q3")));
                Atomic.set send_done true)
              (fun () ->
                let resp = Well.fetch_with_net ~net (Printf.sprintf "http://127.0.0.1:%d/" port) in
                expect resp.status |> to_equal_int 200;
                expect (Atomic.get send_done) |> to_be_false);
            (match !send_res with
             | Ok _ -> ()
             | Error e -> fail e.message))));

    it "resume does not revive an abandoned execution" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          (match Well.Actor.send ~request_id:"race-seed" ~timeout_ms:60000 wf
                   (Well.Actor.Message (mt, ("finance", "Q3"))) with
           | Error e -> fail e.message
           | Ok id -> ignore (await_ok id));
          bump_state_version !current_store "Reporter" 99;
          match Well.Actor.send ~request_id:"race-block" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            Well.Env.sleep 0.3;
            bump_state_version !current_store "Reporter" 1;
            (match Well.Actor.abandon id ~reason:"race" with
             | Error e -> fail e.message
             | Ok () -> ());
            (match Well.Actor.resume id with
             | Ok () -> fail "resume revived Abandoned"
             | Error errs ->
               expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidOperation") errs)
               |> to_be_true);
            let snap = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap.status with
              | Well.Actor.Failed d when d.error.code = "Abandoned" -> true
              | _ -> false) |> to_be_true));

    it "abandon wins over in-flight commit" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"race-commit" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            Well.Env.sleep 0.15;
            let finished = Well.Actor._activations_finished () in
            (match Well.Actor.abandon id ~reason:"stop-inflight" with
             | Error e -> fail e.message
             | Ok () -> ());
            Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
            let rec wait_done n =
              if n <= 0 then fail "activation did not finish"
              else if Well.Actor._activations_finished () > finished then ()
              else begin Well.Env.sleep 0.05; wait_done (n - 1) end
            in
            wait_done 40;
            expect (Atomic.get decision_handles) |> to_equal_int 1;
            match Well.Actor.await ~timeout_ms:5000 id with
            | Ok (Well.Actor.Terminal s) ->
              expect (match s.status with
                | Well.Actor.Failed d when d.error.code = "Abandoned" -> true
                | _ -> false) |> to_be_true;
              expect (scalar !current_store "SELECT COUNT(*) FROM actor_state") |> to_equal_int 0;
              expect (scalar !current_store "SELECT COUNT(*) FROM outbox") |> to_equal_int 0
            | Ok (Wait_timeout _) -> fail "timeout"
            | Error e -> fail e.message));

    it "S05 max_active is respected across worker domains" (fun () ->
      let limits = { Well.Actor.default_limits with max_active = 1; domains = 2 } in
      with_runtime ~limits (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"s05" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            ignore (await_ok id);
            expect (Atomic.get max_live_handles <= 1) |> to_be_true));

    it "live claim stays exclusive across schedulers and recovers after write error" (fun () ->
      let limits = { Well.Actor.default_limits with max_active = 2; domains = 2 } in
      with_runtime ~limits (fun desc ->
        Well.Actor._set_claim_gap_arm 1;
        Well.Actor._hold { actor_type = "Reporter"; id = "finance" };
        let json = workflow ~name:"excl" ~entry:"report" ~input:"Reports.Request" [
          "report", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "finance"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "done"] ();
          "done", end_node "Reports.Report";
        ] in
        match Well.Actor.Workflow.validate json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          let send req =
            Well.Actor.send ~request_id:req ~timeout_ms:60000 wf
              (Well.Actor.Message (mt, ("finance", "Q3")))
          in
          match send "excl-a" with
          | Error e -> fail e.message
          | Ok id1 ->
            wait_until 40 (fun () ->
              scalar !current_store "SELECT COUNT(*) FROM inbox WHERE status = 'claimed'" = 1
              && Well.Actor._claim_gap_waiting () > 0);
            expect (scalar !current_store "SELECT COUNT(*) FROM inflight") |> to_equal_int 1;
            let mid = scalar_text !current_store
                "SELECT message_id FROM inbox WHERE status = 'claimed' LIMIT 1"
            in
            (match send "excl-b" with
             | Error e -> fail e.message
             | Ok id2 ->
               Well.Actor._set_unstick_arm 1;
               Well.Actor._note_pending_unstick mid;
               Well.Actor._note_pending_unstick "ghost-unstick";
               wait_until 40 (fun () -> Well.Actor._unstick_waiting () > 0);
               Well.Actor._set_unstick_arm 0;
               wait_until 40 (fun () -> Well.Actor._unstick_waiting () = 0);
               expect (scalar !current_store "SELECT COUNT(*) FROM inbox WHERE status = 'claimed'")
               |> to_equal_int 1;
               expect (scalar_text !current_store
                         "SELECT message_id FROM inbox WHERE status = 'claimed' LIMIT 1")
               |> to_equal_string mid;
               expect (scalar !current_store "SELECT COUNT(*) FROM inbox WHERE status = 'ready'")
               |> to_equal_int 1;
               Well.Actor._set_claim_gap_arm 0;
               wait_until 40 (fun () -> Well.Actor._claim_gap_waiting () = 0);
               expect (reporter_count "finance") |> to_equal_int 0;
               expect (Atomic.get live_handles) |> to_equal_int 0;
               expect (Atomic.get max_live_handles <= 1) |> to_be_true;
               Well.Actor._set_force_write_error ~sticky:true (Some "disk full");
               Well.Actor._release { actor_type = "Reporter"; id = "finance" };
               wait_until 40 (fun () ->
                 scalar !current_store "SELECT COUNT(*) FROM actor_state" = 0
                 && Well.Actor._last_turn_error () <> None);
               expect (Atomic.get max_live_handles <= 1) |> to_be_true;
               Well.Actor._set_force_write_error None;
               ignore (await_ok ~timeout_ms:15000 id1);
               ignore (await_ok ~timeout_ms:15000 id2);
               expect (Atomic.get max_live_handles <= 1) |> to_be_true)));

    it "failed inflight DELETE is retried while inbox stays claimed" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "Reporter"; id = "finance" };
        let json = workflow ~name:"if-cl" ~entry:"report" ~input:"Reports.Request" [
          "report", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "finance"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "done"] ();
          "done", end_node "Reports.Report";
        ] in
        match Well.Actor.Workflow.validate json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"if-cl" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            wait_until 40 (fun () ->
              scalar !current_store "SELECT COUNT(*) FROM inbox WHERE status = 'claimed'" = 1);
            let finished = Well.Actor._activations_finished () in
            Well.Actor._set_force_inflight_delete_error (Some "inflight delete");
            Well.Actor._set_force_write_error ~sticky:true (Some "disk full");
            Well.Actor._release { actor_type = "Reporter"; id = "finance" };
            wait_until 40 (fun () ->
              Well.Actor._activations_finished () > finished
              && Well.Actor._last_turn_error () <> None);
            expect (scalar_text !current_store "SELECT status FROM inbox LIMIT 1")
            |> to_equal_string "claimed";
            expect (scalar !current_store "SELECT COUNT(*) FROM inflight") |> to_equal_int 1;
            expect (scalar !current_store "SELECT COUNT(*) FROM actor_state") |> to_equal_int 0;
            Well.Actor._set_force_write_error None;
            Well.Actor._set_force_inflight_delete_error None;
            let snap = await_ok ~timeout_ms:15000 id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            wait_until 40 (fun () ->
              scalar !current_store "SELECT COUNT(*) FROM inflight" = 0);
            expect (Atomic.get max_live_handles <= 1) |> to_be_true));

    it "failed inflight DELETE is retried after inbox is ready" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "Reporter"; id = "finance" };
        let json = workflow ~name:"if-rd" ~entry:"report" ~input:"Reports.Request" [
          "report", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "finance"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "done"] ();
          "done", end_node "Reports.Report";
        ] in
        match Well.Actor.Workflow.validate json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"if-rd" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            wait_until 40 (fun () ->
              scalar !current_store "SELECT COUNT(*) FROM inbox WHERE status = 'claimed'" = 1);
            let finished = Well.Actor._activations_finished () in
            Well.Actor._set_claim_pause_arm 1;
            wait_until 40 (fun () -> Well.Actor._claim_pause_waiting () > 0);
            Well.Actor._set_force_inflight_delete_error (Some "inflight delete");
            Well.Actor._set_force_write_error (Some "disk full");
            Well.Actor._release { actor_type = "Reporter"; id = "finance" };
            let rec wait_ready n =
              let fin = Well.Actor._activations_finished () in
              let st = scalar_text !current_store "SELECT status FROM inbox LIMIT 1" in
              let err = Well.Actor._last_turn_error () in
              if fin > finished && err <> None && st = "ready" then ()
              else if n <= 0 then
                fail (Printf.sprintf "ready-delete wait fin=%d->%d status=%s err=%s"
                        finished fin st (match err with None -> "-" | Some m -> m))
              else begin Well.Env.sleep 0.05; wait_ready (n - 1) end
            in
            wait_ready 40;
            expect (scalar !current_store "SELECT COUNT(*) FROM inflight") |> to_equal_int 1;
            expect (scalar !current_store "SELECT COUNT(*) FROM actor_state") |> to_equal_int 0;
            Well.Actor._set_force_inflight_delete_error None;
            Well.Actor._set_claim_pause_arm 0;
            let snap = await_ok ~timeout_ms:15000 id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            wait_until 40 (fun () ->
              scalar !current_store "SELECT COUNT(*) FROM inflight" = 0);
            expect (Atomic.get max_live_handles <= 1) |> to_be_true));

    it "old finalizer does not release a newer claim of the same message" (fun () ->
      let limits = { Well.Actor.default_limits with max_active = 2; domains = 2 } in
      with_runtime ~limits (fun desc ->
        let held = Atomic.make false in
        Well.Actor._set_after_handle (fun a ->
          if Atomic.compare_and_set held false true then Well.Actor._hold a);
        Well.Actor._hold { actor_type = "Reporter"; id = "finance" };
        Well.Actor._set_finish_arm 1;
        let json = workflow ~name:"fin-new" ~entry:"report" ~input:"Reports.Request" [
          "report", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "finance"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "done"] ();
          "done", end_node "Reports.Report";
        ] in
        match Well.Actor.Workflow.validate json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"fin-new" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            wait_until 40 (fun () ->
              scalar !current_store "SELECT COUNT(*) FROM inbox WHERE status = 'claimed'" = 1);
            Well.Actor._set_claim_pause_arm 1;
            wait_cond 80
              (fun () ->
                Printf.sprintf "pause waiting=%d" (Well.Actor._claim_pause_waiting ()))
              (fun () -> Well.Actor._claim_pause_waiting () >= 2);
            Well.Actor._set_force_write_error (Some "disk full");
            Well.Actor._release { actor_type = "Reporter"; id = "finance" };
            wait_cond 80
              (fun () ->
                Printf.sprintf "old finalizer park fin=%d err=%s status=%s gen=%d wait=%d"
                  (Well.Actor._activations_finished ())
                  (match Well.Actor._last_turn_error () with None -> "-" | Some m -> m)
                  (inbox_status !current_store)
                  (inflight_gen !current_store)
                  (Well.Actor._finish_waiting ()))
              (fun () ->
                Well.Actor._finish_waiting () > 0
                && Well.Actor._last_turn_error () <> None
                && inbox_status !current_store = "ready"
                && inflight_gen !current_store = 1
                && scalar !current_store "SELECT COUNT(*) FROM inflight" = 1);
            Well.Actor._set_claim_pause_arm 0;
            wait_cond 80
              (fun () ->
                Printf.sprintf "new claim during old finish status=%s gen=%d wait=%d"
                  (inbox_status !current_store)
                  (inflight_gen !current_store)
                  (Well.Actor._finish_waiting ()))
              (fun () ->
                Well.Actor._finish_waiting () > 0
                && inflight_gen !current_store = 2
                && inbox_status !current_store = "claimed"
                && scalar !current_store "SELECT COUNT(*) FROM inflight" = 1);
            expect (seq_next_gen !current_store) |> to_equal_int 2;
            expect (Atomic.get max_live_handles <= 1) |> to_be_true;
            expect (Atomic.get live_handles) |> to_equal_int 0;
            Well.Actor._set_finish_arm 0;
            wait_cond 80
              (fun () ->
                Printf.sprintf "old finalizer still parked wait=%d" (Well.Actor._finish_waiting ()))
              (fun () -> Well.Actor._finish_waiting () = 0);
            expect (inbox_status !current_store) |> to_equal_string "claimed";
            expect (inflight_gen !current_store) |> to_equal_int 2;
            expect (scalar !current_store "SELECT COUNT(*) FROM inflight") |> to_equal_int 1;
            expect (seq_next_gen !current_store) |> to_equal_int 2;
            expect (Atomic.get max_live_handles <= 1) |> to_be_true;
            Well.Actor._set_force_write_error None;
            Well.Actor._release { actor_type = "Reporter"; id = "finance" };
            let snap = await_ok ~timeout_ms:15000 id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            wait_until 40 (fun () ->
              scalar !current_store "SELECT COUNT(*) FROM inflight" = 0);
            expect (reporter_count "finance") |> to_equal_int 2;
            expect (Atomic.get max_live_handles <= 1) |> to_be_true));

    it "two schedulers cannot drop a newer activation between stale cleanups" (fun () ->
      let limits = { Well.Actor.default_limits with max_active = 2; domains = 2 } in
      with_runtime ~limits (fun desc ->
        let held = Atomic.make false in
        Well.Actor._set_after_handle (fun a ->
          if Atomic.compare_and_set held false true then Well.Actor._hold a);
        Well.Actor._hold { actor_type = "Reporter"; id = "finance" };
        let json = workflow ~name:"two-clr" ~entry:"report" ~input:"Reports.Request" [
          "report", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "finance"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "done"] ();
          "done", end_node "Reports.Report";
        ] in
        match Well.Actor.Workflow.validate json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"two-clr" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            wait_until 40 (fun () ->
              scalar !current_store "SELECT COUNT(*) FROM inbox WHERE status = 'claimed'" = 1);
            Well.Actor._set_claim_pause_arm 1;
            wait_cond 80
              (fun () ->
                Printf.sprintf "pause waiting=%d" (Well.Actor._claim_pause_waiting ()))
              (fun () -> Well.Actor._claim_pause_waiting () >= 2);
            let finished = Well.Actor._activations_finished () in
            Well.Actor._set_force_inflight_delete_error (Some "inflight delete");
            Well.Actor._set_force_write_error (Some "disk full");
            Well.Actor._release { actor_type = "Reporter"; id = "finance" };
            wait_cond 80
              (fun () ->
                Printf.sprintf "stale cleanup seed fin=%d->%d err=%s status=%s inflight=%d gen=%d"
                  finished (Well.Actor._activations_finished ())
                  (match Well.Actor._last_turn_error () with None -> "-" | Some m -> m)
                  (inbox_status !current_store)
                  (scalar !current_store "SELECT COUNT(*) FROM inflight")
                  (inflight_gen !current_store))
              (fun () ->
                Well.Actor._activations_finished () > finished
                && Well.Actor._last_turn_error () <> None
                && inbox_status !current_store = "ready"
                && scalar !current_store "SELECT COUNT(*) FROM inflight" = 1
                && inflight_gen !current_store = 1);
            expect (seq_next_gen !current_store) |> to_equal_int 1;
            Well.Actor._set_cleanup_copy_arm 1;
            Well.Actor._set_force_inflight_delete_error None;
            Well.Actor._set_claim_pause_arm 0;
            wait_cond 80
              (fun () ->
                Printf.sprintf "cleanup copy waiting=%d" (Well.Actor._cleanup_copy_waiting ()))
              (fun () -> Well.Actor._cleanup_copy_waiting () >= 2);
            Well.Actor._set_cleanup_retire_budget 1;
            Well.Actor._set_cleanup_retire_arm 1;
            Well.Actor._set_cleanup_copy_arm 0;
            wait_cond 80
              (fun () ->
                Printf.sprintf "new claim between cleanups status=%s gen=%d inflight=%d retire_wait=%d"
                  (inbox_status !current_store)
                  (inflight_gen !current_store)
                  (scalar !current_store "SELECT COUNT(*) FROM inflight")
                  (Well.Actor._cleanup_retire_waiting ()))
              (fun () ->
                Well.Actor._cleanup_retire_waiting () >= 1
                && inbox_status !current_store = "claimed"
                && inflight_gen !current_store = 2
                && scalar !current_store "SELECT COUNT(*) FROM inflight" = 1);
            expect (seq_next_gen !current_store) |> to_equal_int 2;
            expect (Atomic.get max_live_handles <= 1) |> to_be_true;
            Well.Actor._set_cleanup_retire_arm 0;
            wait_cond 80
              (fun () ->
                Printf.sprintf "second cleanup still parked wait=%d" (Well.Actor._cleanup_retire_waiting ()))
              (fun () -> Well.Actor._cleanup_retire_waiting () = 0);
            expect (inbox_status !current_store) |> to_equal_string "claimed";
            expect (inflight_gen !current_store) |> to_equal_int 2;
            expect (scalar !current_store "SELECT COUNT(*) FROM inflight") |> to_equal_int 1;
            expect (seq_next_gen !current_store) |> to_equal_int 2;
            Well.Actor._release { actor_type = "Reporter"; id = "finance" };
            let snap = await_ok ~timeout_ms:15000 id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            wait_until 40 (fun () ->
              scalar !current_store "SELECT COUNT(*) FROM inflight" = 0);
            expect (reporter_count "finance") |> to_equal_int 2;
            expect (Atomic.get max_live_handles <= 1) |> to_be_true));

    it "C09 JCS distinguishes adjacent floats and sorts object keys" (fun () ->
      let next1 = Int64.float_of_bits (Int64.succ (Int64.bits_of_float 1.0)) in
      let a = Well.Actor._canonicalize (`Float 1.0) in
      let b = Well.Actor._canonicalize (`Float next1) in
      expect (a <> b) |> to_be_true;
      expect (Well.Actor._canonicalize (`Float 0.000001)) |> to_equal_string "0.000001";
      let o1 = Well.Actor._canonicalize (`Assoc ["b", `Int 1; "a", `Int 2]) in
      let o2 = Well.Actor._canonicalize (`Assoc ["a", `Int 2; "b", `Int 1]) in
      expect o1 |> to_equal_string o2;
      let arr1 = Well.Actor._canonicalize (`List [`Int 1; `Int 2]) in
      let arr2 = Well.Actor._canonicalize (`List [`Int 2; `Int 1]) in
      expect (arr1 <> arr2) |> to_be_true;
      let adm f =
        Well.Actor._canonicalize (`Assoc [
          "payload", `Float f;
          "payload_type", `String "t";
          "schema_hash", `String "h";
          "timeout_ms", `Int 1;
          "workflow", `Assoc [];
        ])
      in
      expect (adm 1.0 <> adm next1) |> to_be_true);

    it "S05 ready addresses rotate instead of starving" (fun () ->
      let limits = { Well.Actor.default_limits with max_active = 1 } in
      with_runtime ~limits (fun desc ->
        Well.Actor._hold { actor_type = "Reporter"; id = "finance" };
        Well.Actor._hold { actor_type = "Reporter"; id = "stock" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          let send req reporter =
            Well.Actor.send ~request_id:req ~timeout_ms:60000 wf
              (Well.Actor.Message (mt, (reporter, "Q3")))
          in
          (match send "rr-a1" "finance", send "rr-a2" "finance", send "rr-z" "stock" with
           | Error e, _, _ | _, Error e, _ | _, _, Error e -> fail e.message
           | Ok _, Ok _, Ok _ -> ());
          Well.Env.sleep 0.25;
          Well.Actor._release { actor_type = "Reporter"; id = "finance" };
          Well.Env.sleep 0.25;
          let claimed =
            with_db !current_store (fun db ->
              let stmt = Sqlite3.prepare db
                  "SELECT actor_id FROM inbox WHERE actor_type = 'Reporter' AND status = 'claimed'"
              in
              Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
                match Sqlite3.step stmt with
                | Sqlite3.Rc.ROW -> Sqlite3.column_text stmt 0
                | _ -> ""))
          in
          Well.Actor._release { actor_type = "Reporter"; id = "stock" };
          expect claimed |> to_equal_string "stock"));

    it "S06 abandoned address stays exclusive until activation ends" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"ex1" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok first ->
            Well.Env.sleep 0.2;
            let finished = Well.Actor._activations_finished () in
            (match Well.Actor.abandon first ~reason:"stop" with
             | Error e -> fail e.message
             | Ok () -> ());
            match Well.Actor.send ~request_id:"ex2" ~timeout_ms:60000 wf
                    (Well.Actor.Message (mt, ("finance", "Q3"))) with
            | Error e -> fail e.message
            | Ok second ->
              Well.Env.sleep 0.2;
              expect (Atomic.get decision_handles) |> to_equal_int 0;
              expect (Well.Actor._activations_finished ()) |> to_equal_int finished;
              Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
              let rec wait n =
                if n <= 0 then fail "first activation stuck"
                else if Well.Actor._activations_finished () > finished then ()
                else begin Well.Env.sleep 0.05; wait (n - 1) end
              in
              wait 40;
              expect (Atomic.get decision_handles >= 1) |> to_be_true;
              (match Well.Actor.errors first with
               | Error e -> fail e.message
               | Ok diags ->
                 expect (List.exists (fun (d : Well.Actor.diagnostic) ->
                   d.error.code = "DiscardedAfterFailure") diags) |> to_be_true);
              ignore (await_ok second)));

    it "J08 join deadline is rechecked at commit" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._set_after_handle (fun a ->
          if a.actor_type = "__well.join" then
            Well.Actor._set_now_ms (Int64.add (Well.Actor._now_ms ()) 40_000L));
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"j08" ~timeout_ms:120000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            match Well.Actor.await ~timeout_ms:5000 id with
            | Ok (Well.Actor.Terminal s) ->
              expect (match s.status with
                | Well.Actor.Failed d when d.error.code = "JoinTimeout" -> true
                | _ -> false) |> to_be_true
            | Ok (Wait_timeout _) -> fail "timeout"
            | Error e -> fail e.message));

    it "diagnostic location round-trips through inspect" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"diag-1" ~timeout_ms:1000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            Well.Env.sleep 0.15;
            Well.Actor._set_after_handle (fun _ ->
              Well.Actor._set_now_ms (Int64.add (Well.Actor._now_ms ()) 5000L));
            Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
            match Well.Actor.await ~timeout_ms:3000 id with
            | Ok (Well.Actor.Terminal s) ->
              (match s.status with
               | Well.Actor.Failed d ->
                 (match d.location with
                  | None -> fail "location missing"
                  | Some loc ->
                    expect (loc.message_id <> "") |> to_be_true;
                    expect (loc.node_id <> "") |> to_be_true)
               | _ -> fail "expected failed")
            | Ok (Wait_timeout _) -> fail "timeout"
            | Error e -> fail e.message));

    it "A08 await timeout does not cancel execution" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"a08" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            (match Well.Actor.await ~timeout_ms:80 id with
             | Ok (Well.Actor.Wait_timeout s) ->
               expect (match s.status with Well.Actor.Running -> true | _ -> false) |> to_be_true
             | Ok (Terminal _) -> fail "finished too soon"
             | Error e -> fail e.message);
            Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true));

    it "A09 decode_output checks name and hash" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          let st = summary_type desc in
          match Well.Actor.send ~request_id:"a09" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "reject"))) with
          | Error e -> fail e.message
          | Ok id ->
            let snap = await_ok id in
            let out = List.hd snap.outputs in
            (match Well.Actor.decode_output st out with
             | Error e -> fail e.message
             | Ok text -> expect (text <> "") |> to_be_true);
            match Well.Actor.decode_output mt out with
            | Ok _ -> fail "structurally similar request type must not decode summary"
            | Error e -> expect e.code |> to_equal_string "SchemaMismatch"));

    it "A05 different payload is IdempotencyConflict" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"a05c" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            ignore (await_ok id);
            (match Well.Actor.send ~request_id:"a05c" ~timeout_ms:60000 wf
                     (Well.Actor.Message (mt, ("sales", "Q3"))) with
             | Error e -> expect e.code |> to_equal_string "IdempotencyConflict"
             | Ok _ -> fail "conflict");
            match Well.Actor.send ~request_id:"a05c" ~timeout_ms:60000 wf
                    (Well.Actor.Message (mt, ("finance", "Q3"))) with
            | Error e -> fail e.message
            | Ok id2 -> expect id2 |> to_equal_string id));

    it "C03 C07 message witness and raw wire validation" (fun () ->
      let module BadDecision = struct
        include Decision
        let outbound_to_wire = function
          | Accepted _ -> "Accepted", `List [`Int 1; `Int 2]
          | Rejected text -> "Rejected", `List [`String text]
      end in
      let register desc =
        let ok d = match Well.Actor.register_type d with Ok () -> () | Error e -> failwith e.message in
        ok (define desc "ReportDecision" (module BadDecision));
        ok (define desc "Reporter" (module Reporter));
        ok (define desc "ReportSpawner" (module Spawner));
        ok (define desc "ReportCombiner" (module Combiner));
        ok (define desc "SummaryBuilder" (module Summary))
      in
      with_runtime ~register (fun desc ->
        let mt = request_type desc in
        let st = summary_type desc in
        expect (Well.Actor.message_type_name mt) |> to_equal_string "Reports.Request";
        (match Well.Actor.decode st (Well.Actor.encode mt ("finance", "Q3")) with
         | Ok _ -> fail "request wire must not decode as summary"
         | Error e -> expect e.code |> to_equal_string "InvalidInput");
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          match Well.Actor.send ~request_id:"c07" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            match Well.Actor.await ~timeout_ms:5000 id with
            | Ok (Well.Actor.Terminal s) ->
              expect (match s.status with
                | Well.Actor.Failed d when d.error.code = "InvalidInput" || d.error.code = "InvalidEmission" -> true
                | _ -> false) |> to_be_true
            | Ok (Wait_timeout _) -> fail "timeout"
            | Error e -> fail e.message));

    it "S02 concurrent first entries commit one init" (fun () ->
      with_runtime (fun desc ->
        let json = workflow ~name:"s02" ~entry:"report" ~input:"Reports.Request" [
          "report", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "same"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "done"] ();
          "done", end_node "Reports.Report";
        ] in
        match Well.Actor.Workflow.validate json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          let send req =
            Well.Actor.send ~request_id:req ~timeout_ms:60000 wf
              (Well.Actor.Message (mt, ("same", "Q3")))
          in
          let a = ref (Error { Well.Actor.code = ""; message = ""; path = None }) in
          let b = ref (Error { Well.Actor.code = ""; message = ""; path = None }) in
          Eio.Fiber.both
            (fun () -> a := send "s02-a")
            (fun () -> b := send "s02-b");
          (match !a, !b with
           | Error e, _ | _, Error e -> fail e.message
           | Ok id1, Ok id2 ->
             ignore (await_ok id1);
             ignore (await_ok id2);
             expect (Atomic.get reporter_inits) |> to_equal_int 1;
             expect (reporter_count "same")
             |> to_equal_int 2;
             expect (scalar !current_store
                       "SELECT revision FROM actor_state WHERE actor_type = 'Reporter' AND actor_id = 'same'")
             |> to_equal_int 2)));

    it "S03 retry discards mutated working state" (fun () ->
      let retry_policy = { Well.Actor.max_attempts = 5; delays_ms = [10; 20; 40; 80] } in
      with_runtime ~retry_policy (fun desc ->
        let json = workflow ~name:"s03" ~entry:"report" ~input:"Reports.Request" [
          "report", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "mut"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "done"] ();
          "done", end_node "Reports.Report";
        ] in
        match Well.Actor.Workflow.validate json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          (match Well.Actor.send ~request_id:"s03-seed" ~timeout_ms:60000 wf
                   (Well.Actor.Message (mt, ("mut", "Q3"))) with
           | Error e -> fail e.message
           | Ok id -> ignore (await_ok id));
          match Well.Actor.send ~request_id:"s03-mut" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("mut", "mutate-retry"))) with
          | Error e -> fail e.message
          | Ok id ->
            ignore (await_ok id);
            expect (scalar_text !current_store
                      "SELECT blob FROM actor_state WHERE actor_type = 'Reporter' AND actor_id = 'mut'")
            |> to_equal_string "2"));

    it "S07 switch cancel releases claim without consuming attempt" (fun () ->
      Well.Actor._reset ();
      reporter_clear ();
      Atomic.set decision_handles 0;
      let dir = tmp_dir "s07-" in
      let store_path = Filename.concat dir "store.sqlite" in
      current_store := store_path;
      let cfg = {
        Well.Actor.store_path;
        limits = Well.Actor.default_limits;
        retry_policy = Well.Actor.default_retry_policy;
      } in
      (match Well.Actor.configure cfg with Ok () -> () | Error e -> fail e.message);
      let desc = descriptor () in
      register_all desc;
      Fun.protect ~finally:(fun () -> Well.Actor._reset (); rm_rf dir) (fun () ->
        Eio_main.run (fun env ->
          Well.Env.set env;
          (try
             Eio.Switch.run (fun sw ->
               Well.Actor.start_all ~sw;
               Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
               let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
               match Well.Actor.Workflow.validate wf_json with
               | Error _ -> fail "validate"
               | Ok wf ->
                 let mt = request_type desc in
                 match Well.Actor.send ~request_id:"s07" ~timeout_ms:60000 wf
                         (Well.Actor.Message (mt, ("finance", "Q3"))) with
                 | Error e -> fail e.message
                 | Ok _ ->
                   wait_until 40 (fun () ->
                     scalar store_path "SELECT COUNT(*) FROM inbox WHERE status = 'claimed'" = 1);
                   Well.Actor._stop ();
                   raise Exit)
           with Exit -> ());
          Well.Actor._stop ();
          expect (scalar store_path "SELECT COUNT(*) FROM inbox WHERE status = 'claimed'")
          |> to_equal_int 0;
          expect (scalar store_path "SELECT attempt FROM inbox LIMIT 1") |> to_equal_int 0;
          expect (scalar store_path "SELECT COUNT(*) FROM inbox WHERE status = 'ready'")
          |> to_equal_int 1)));

    it "J02 duplicate message_id counts once" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "Reporter"; id = "stock" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"j02" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            wait_until 80 (fun () ->
              scalar !current_store
                "SELECT COUNT(*) FROM inbox WHERE actor_type = '__well.join' AND status = 'done'" >= 2);
            let mid = scalar_text !current_store
                "SELECT message_id FROM inbox WHERE actor_type = '__well.join' AND status = 'done' LIMIT 1"
            in
            with_db !current_store (fun db ->
              let sql = "UPDATE inbox SET status = 'ready', claim_owner = NULL WHERE message_id = ? AND status = 'done'" in
              let stmt = Sqlite3.prepare db sql in
              ignore (Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT mid));
              sqlite_step_done db stmt "j02 reopen";
              ignore (Sqlite3.finalize stmt));
            wait_until 80 (fun () ->
              scalar_text !current_store
                (Printf.sprintf "SELECT status FROM inbox WHERE message_id = '%s'" mid) = "done");
            (match Well.Actor.inspect id with
             | Error e -> fail e.message
             | Ok s ->
               expect (match s.status with
                 | Well.Actor.Failed d when d.error.code = "DuplicateBranch" -> false
                 | _ -> true) |> to_be_true);
            Well.Actor._release { actor_type = "Reporter"; id = "stock" };
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true));

    it "J02 different result of same branch is DuplicateBranch" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "Reporter"; id = "stock" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"j02b" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            wait_until 80 (fun () ->
              scalar !current_store
                "SELECT COUNT(*) FROM inbox WHERE actor_type = '__well.join' AND status = 'done'" >= 2);
            let dup =
              with_db !current_store (fun db ->
                let stmt = Sqlite3.prepare db
                    "SELECT execution_id, actor_id, envelope FROM inbox WHERE actor_type = '__well.join' AND status = 'done' LIMIT 1"
                in
                Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
                  match Sqlite3.step stmt with
                  | Sqlite3.Rc.ROW ->
                    Some (Sqlite3.column_text stmt 0,
                          Sqlite3.column_text stmt 1,
                          Sqlite3.column_text stmt 2)
                  | _ -> None))
            in
            (match dup with
             | None -> fail "no join row"
             | Some (eid, aid, env_s) ->
               let env = Yojson.Safe.from_string env_s in
               let new_id = "dup-branch-msg" in
               let env =
                 match env with
                 | `Assoc fs -> `Assoc (("message_id", `String new_id) :: List.remove_assoc "message_id" fs)
                 | other -> other
               in
               with_db !current_store (fun db ->
                 let ins = Sqlite3.prepare db
                     "INSERT INTO inbox(message_id, execution_id, actor_type, actor_id, seq, envelope, status, attempt, available_at_ms) VALUES(?,?,?,?,?,?, 'ready', 0, 0)"
                 in
                 Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize ins)) (fun () ->
                   ignore (Sqlite3.bind ins 1 (Sqlite3.Data.TEXT new_id));
                   ignore (Sqlite3.bind ins 2 (Sqlite3.Data.TEXT eid));
                   ignore (Sqlite3.bind ins 3 (Sqlite3.Data.TEXT "__well.join"));
                   ignore (Sqlite3.bind ins 4 (Sqlite3.Data.TEXT aid));
                   ignore (Sqlite3.bind ins 5 (Sqlite3.Data.INT 99L));
                   ignore (Sqlite3.bind ins 6 (Sqlite3.Data.TEXT (Yojson.Safe.to_string env)));
                   ignore (Sqlite3.busy_timeout db 5000);
                   (match
                      Eio_unix.run_in_systhread (fun () ->
                        let rec ins_step n =
                          match Sqlite3.step ins with
                          | Sqlite3.Rc.DONE -> Ok ()
                          | (Sqlite3.Rc.BUSY | Sqlite3.Rc.LOCKED) when n > 0 ->
                            Unix.sleepf 0.05;
                            ins_step (n - 1)
                          | rc ->
                            Error (Printf.sprintf "j02 dup insert rc=%s errmsg=%s"
                                     (Sqlite3.Rc.to_string rc) (Sqlite3.errmsg db))
                        in
                        ins_step 40)
                    with
                    | Ok () -> ()
                    | Error e -> fail e))));
            (match Well.Actor.await ~timeout_ms:5000 id with
             | Ok (Well.Actor.Terminal s) ->
               expect (match s.status with
                 | Well.Actor.Failed d when d.error.code = "DuplicateBranch" -> true
                 | _ -> false) |> to_be_true
             | Ok (Wait_timeout _) -> fail "timeout"
             | Error e -> fail e.message);
            Well.Actor._release { actor_type = "Reporter"; id = "stock" }));

    it "J03 two executions do not mix join groups" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          let send req =
            Well.Actor.send ~request_id:req ~timeout_ms:60000 wf
              (Well.Actor.Message (mt, ("unused", "Q3")))
          in
          match send "j03-a", send "j03-b" with
          | Error e, _ | _, Error e -> fail e.message
          | Ok a, Ok b ->
            let sa = await_ok a and sb = await_ok b in
            expect (match sa.status, sb.status with
              | Well.Actor.Completed, Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            expect (a <> b) |> to_be_true;
            expect (List.length sa.outputs) |> to_equal_int 1;
            expect (List.length sb.outputs) |> to_equal_int 1;
            expect (scalar !current_store "SELECT COUNT(*) FROM groups") |> to_equal_int 2));

    it "J07 restart after partial join keeps expected set" (fun () ->
      let dir = tmp_dir "j07-" in
      let store = Filename.concat dir "store.sqlite" in
      current_store := store;
      Well.Actor._reset ();
      reporter_clear ();
      let cfg = {
        Well.Actor.store_path = store;
        limits = Well.Actor.default_limits;
        retry_policy = Well.Actor.default_retry_policy;
      } in
      (match Well.Actor.configure cfg with Ok () -> () | Error e -> fail e.message);
      let desc = descriptor () in
      register_all desc;
      let expected = ref "" in
      let deadline = ref 0L in
      Fun.protect ~finally:(fun () -> Well.Actor._reset ()) (fun () ->
        Eio_main.run (fun env ->
          Well.Env.set env;
          Eio.Switch.run (fun sw ->
            Well.Actor.start_all ~sw;
            Fun.protect ~finally:Well.Actor._stop (fun () ->
              Well.Actor._hold { actor_type = "Reporter"; id = "stock" };
              let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
              match Well.Actor.Workflow.validate wf_json with
              | Error _ -> fail "validate"
              | Ok wf ->
                let mt = request_type desc in
                match Well.Actor.send ~request_id:"j07" ~timeout_ms:120000 wf
                        (Well.Actor.Message (mt, ("unused", "Q3"))) with
                | Error e -> fail e.message
                | Ok _ ->
                  wait_until 80 (fun () ->
                    let recvd = scalar_text store "SELECT received FROM groups LIMIT 1" in
                    if recvd = "" then false
                    else
                      match Yojson.Safe.from_string recvd with
                      | `List xs -> List.length xs = 2
                      | _ -> false);
                  expected := scalar_text store "SELECT expected FROM groups LIMIT 1";
                  deadline := Int64.of_string (scalar_text store "SELECT deadline_ms FROM groups LIMIT 1")))));
      expect (scalar store "SELECT closed FROM groups LIMIT 1") |> to_equal_int 0;
      expect (!expected <> "") |> to_be_true;
      with_existing_store store (fun _desc ->
        match execution_of_request store "j07" with
        | None -> fail "lost"
        | Some eid ->
          expect (scalar_text store "SELECT expected FROM groups LIMIT 1") |> to_equal_string !expected;
          expect (Int64.equal
                    (Int64.of_string (scalar_text store "SELECT deadline_ms FROM groups LIMIT 1"))
                    !deadline) |> to_be_true;
          let snap = await_ok ~timeout_ms:15000 eid in
          expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
          expect (scalar store "SELECT closed FROM groups LIMIT 1") |> to_equal_int 1);
      rm_rf dir);

    it "E01 crash before commit retries one idempotent key" (fun () ->
      let dir = tmp_dir "e01-" in
      let store = Filename.concat dir "store.sqlite" in
      wait_crash (crash_child store "after_handle_before_commit" "e01");
      with_existing_store store (fun _desc ->
        match execution_of_request store "e01" with
        | None -> fail "admission lost"
        | Some eid ->
          ignore (await_ok ~timeout_ms:15000 eid);
          let keys = read_fx store in
          let uniq = List.sort_uniq compare keys in
          expect (List.length uniq >= 1) |> to_be_true;
          expect (List.length uniq < List.length keys) |> to_be_true);
      rm_rf dir);

    it "E02 retry without dedup can run handle twice" (fun () ->
      let dir = tmp_dir "e02-" in
      let store = Filename.concat dir "store.sqlite" in
      wait_crash (crash_child store "after_handle_before_commit" "e02");
      with_existing_store store (fun _desc ->
        match execution_of_request store "e02" with
        | None -> fail "admission lost"
        | Some eid ->
          ignore (await_ok ~timeout_ms:15000 eid);
          expect (List.length (read_fx store) >= 2) |> to_be_true;
          let m = Well.Actor.metrics () in
          expect (match m with `Assoc fs -> not (List.mem_assoc "exactly_once" fs) | _ -> false)
          |> to_be_true);
      rm_rf dir);

    it "E03 five attempts then dead-letter" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._set_now_ms 1_000_000L;
        let json = workflow ~name:"e03" ~entry:"report" ~input:"Reports.Request" [
          "report", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "fin"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "done"] ();
          "done", end_node "Reports.Report";
        ] in
        match Well.Actor.Workflow.validate json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"e03-a" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("fin", "always-retry"))) with
          | Error e -> fail e.message
          | Ok id ->
            let handles () = reporter_count "fin" in
            let attempt () = scalar !current_store "SELECT attempt FROM inbox WHERE actor_id = 'fin'" in
            let avail () =
              Int64.of_string (scalar_text !current_store
                "SELECT available_at_ms FROM inbox WHERE actor_id = 'fin' LIMIT 1")
            in
            wait_until 80 (fun () -> attempt () >= 1);
            expect (Int64.equal (avail ()) 1_001_000L) |> to_be_true;
            Well.Actor._set_now_ms 1_001_000L;
            wait_until 80 (fun () -> attempt () >= 2);
            expect (Int64.equal (avail ()) 1_003_000L) |> to_be_true;
            Well.Actor._set_now_ms 1_003_000L;
            wait_until 80 (fun () -> attempt () >= 3);
            expect (Int64.equal (avail ()) 1_007_000L) |> to_be_true;
            Well.Actor._set_now_ms 1_007_000L;
            wait_until 80 (fun () -> attempt () >= 4);
            expect (Int64.equal (avail ()) 1_015_000L) |> to_be_true;
            Well.Actor._set_now_ms 1_015_000L;
            (match Well.Actor.await ~timeout_ms:5000 id with
             | Ok (Well.Actor.Terminal s) ->
               expect (match s.status with
                 | Well.Actor.Failed d when d.error.code = "AttemptsExhausted" -> true
                 | _ -> false) |> to_be_true
             | Ok (Wait_timeout _) -> fail "timeout"
             | Error e -> fail e.message);
            expect (handles ()) |> to_equal_int 5;
            expect (scalar !current_store "SELECT COUNT(*) FROM dead_letters") |> to_equal_int 1;
            match Well.Actor.send ~request_id:"e03-b" ~timeout_ms:60000 wf
                    (Well.Actor.Message (mt, ("fin", "Q3"))) with
            | Error e -> fail e.message
            | Ok id2 ->
              let snap = await_ok id2 in
              expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true));

    it "E09 metrics match durable queues" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"e09" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            wait_until 40 (fun () ->
              metric_int (Well.Actor.metrics ()) "active_activations" >= 1);
            let m = Well.Actor.metrics () in
            expect (metric_int m "running_executions") |> to_equal_int 1;
            expect (metric_int m "active_activations" >= 1) |> to_be_true;
            Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
            ignore (await_ok id);
            let m2 = Well.Actor.metrics () in
            expect (metric_int m2 "running_executions") |> to_equal_int 0;
            expect (metric_int m2 "active_activations") |> to_equal_int 0));

    it "E07 group depth limit fails without partial commit" (fun () ->
      let limits = { Well.Actor.default_limits with group_depth = 1 } in
      with_runtime ~limits (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "nested-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"e07g" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            match Well.Actor.await ~timeout_ms:5000 id with
            | Ok (Well.Actor.Terminal s) ->
              expect (match s.status with
                | Well.Actor.Failed d when d.error.code = "LimitExceeded" -> true
                | _ -> false) |> to_be_true;
              expect (List.length s.outputs) |> to_equal_int 0
            | Ok (Wait_timeout _) -> fail "timeout"
            | Error e -> fail e.message));

    it "R03 register_type does not change Service catalog" (fun () ->
      let before_list = Well.Service.list_services () in
      let before_desc = Well.Service.describe_services () in
      with_runtime (fun _desc ->
        expect (Well.Service.list_services () = before_list) |> to_be_true;
        expect (Well.Service.describe_services () = before_desc) |> to_be_true;
        let health = Well.Service.full_health () in
        expect (List.exists (fun (n, _) -> n = "Reporter") health) |> to_be_false));

    it "R03 register_type does not change HTTP RPC routes" (fun () ->
      Well.Actor._reset ();
      let probe = {
        Well.Service.name = "ProbeRpc";
        handler = (fun rpc _ _ -> if rpc = "Ping" then `String "pong" else `Null);
        set_ref = ignore;
        rpcs = [{ rname = "Ping"; params = []; returns = []; returns_name = "void" }];
      } in
      let paths routes = List.map (fun (_, p, _) -> p) routes in
      let body_has_pong s =
        let rec idx i =
          i + 4 <= String.length s && (String.sub s i 4 = "pong" || idx (i + 1))
        in idx 0
      in
      let run_probe ~with_actor f =
        Well.Service.register probe;
        Well.Service.expose "ProbeRpc";
        Eio_main.run (fun env ->
          Well.Env.set env;
          Mirage_crypto_rng_unix.use_default ();
          let net = Well.Env.net () in
          Eio.Switch.run (fun sw ->
            Well.Service._register_post_json := (fun path handler ->
              Well.post path (fun req ->
                let result_json = handler req in
                Well.json (Yojson.Safe.from_string result_json)));
            Well.Service._build_rpc_ctx := (fun _ -> `Null);
            Well.Service.start_all ~sw;
            (if with_actor then Well.Actor.start_all ~sw else ());
            let port = 43000 + (Random.int 1000) in
            let sock =
              Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:4
                (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
            in
            let ping () =
              let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
              let accepted = ref None in
              let connected = ref None in
              Eio.Fiber.both
                (fun () ->
                  let flow, _ = Eio.Net.accept ~sw sock in
                  accepted := Some flow)
                (fun () -> connected := Some (Eio.Net.connect ~sw net addr));
              let server_flow = Option.get !accepted in
              let client_flow = Option.get !connected in
              let body = "null" in
              let req =
                Printf.sprintf
                  "POST /rpc/ProbeRpc/Ping HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
                  (String.length body) body
              in
              let resp = ref "" in
              Eio.Fiber.both
                (fun () ->
                  Well.handle_connection server_flow
                    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)))
                (fun () ->
                  Eio.Flow.copy_string req client_flow;
                  let reader = Eio.Buf_read.of_flow ~max_size:65536 client_flow in
                  resp := Eio.Buf_read.take_all reader);
              !resp
            in
            f ping (paths (Well.list_routes ()))))
      in
      let before_body = ref "" in
      run_probe ~with_actor:false (fun ping ps ->
        let r = ping () in
        expect (String.length r > 12 && String.sub r 0 12 = "HTTP/1.1 200") |> to_be_true;
        expect (body_has_pong r) |> to_be_true;
        before_body := r;
        expect (List.mem "/rpc/ProbeRpc/Ping" ps) |> to_be_true);
      Well.Actor._reset ();
      let dir = tmp_dir "r03rpc-" in
      let store_path = Filename.concat dir "store.sqlite" in
      let cfg = {
        Well.Actor.store_path;
        limits = Well.Actor.default_limits;
        retry_policy = Well.Actor.default_retry_policy;
      } in
      (match Well.Actor.configure cfg with Ok () -> () | Error e -> fail e.message);
      let desc = descriptor () in
      register_all desc;
      Fun.protect ~finally:(fun () -> Well.Actor._reset (); rm_rf dir) (fun () ->
        run_probe ~with_actor:true (fun ping ps ->
          let r = ping () in
          expect (String.length r > 12 && String.sub r 0 12 = "HTTP/1.1 200") |> to_be_true;
          expect (body_has_pong r) |> to_be_true;
          expect (List.mem "/rpc/ProbeRpc/Ping" ps) |> to_be_true;
          expect (List.exists (fun p ->
            let n = String.length p in
            n >= 14 && String.sub p 0 14 = "/rpc/Reporter/") ps) |> to_be_false;
          expect (List.exists (fun (n, _) -> n = "Reporter") (Well.Service.list_services ()))
          |> to_be_false;
          expect (List.exists (fun (n, _) -> n = "Reporter") (Well.Service.full_health ()))
          |> to_be_false)));

    it "R04 mixed legacy service actor and new actor" (fun () ->
      Well.Actor._reset ();
      reporter_clear ();
      Atomic.set decision_handles 0;
      let dir = tmp_dir "r04-" in
      let store_path = Filename.concat dir "store.sqlite" in
      current_store := store_path;
      let legacy = {
        Well.Service.name = "LegacyActor";
        handler = (fun rpc _ _ -> if rpc = "Echo" then `String "echo" else `Null);
        set_ref = ignore;
        rpcs = [{ rname = "Echo"; params = []; returns = []; returns_name = "void" }];
      } in
      Well.Actor.register legacy;
      let cfg = {
        Well.Actor.store_path;
        limits = Well.Actor.default_limits;
        retry_policy = Well.Actor.default_retry_policy;
      } in
      (match Well.Actor.configure cfg with Ok () -> () | Error e -> fail e.message);
      let desc = descriptor () in
      register_all desc;
      let run_body sw =
        Well.Actor.start_all ~sw;
        Well.Service.register_handler "ProbeService" {
          dispatch = (fun rpc _ _ -> if rpc = "Ping" then `String "pong" else `Null);
          rpcs = [{ rname = "Ping"; params = []; returns = []; returns_name = "void" }];
          kind = `Service;
        };
        (match Well.Service.dispatch_by_name "ProbeService" "Ping" `Null `Null with
         | `String "pong" -> ()
         | _ -> fail "service dispatch");
        (match Well.Actor.dispatch "LegacyActor" "Echo" `Null `Null with
         | `String "echo" -> ()
         | _ -> fail "legacy actor");
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"r04" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "reject"))) with
          | Error e -> fail e.message
          | Ok id ->
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            expect (List.exists (fun (n, _) -> n = "LegacyActor") (Well.Actor.health ())) |> to_be_true;
            expect (List.exists (fun (n, _) -> n = "ProbeService") (Well.Service.list_services ()))
            |> to_be_true;
            Well.Actor._stop ();
            raise Exit
      in
      Fun.protect ~finally:(fun () -> Well.Actor._reset (); rm_rf dir) (fun () ->
        Eio_main.run (fun env ->
          Well.Env.set env;
          try Eio.Switch.run run_body with Exit -> ())));

    it "A01 register_type after start is frozen and duplicate rejected" (fun () ->
      with_runtime (fun desc ->
        (match Well.Actor.register_type (define desc "Reporter" (module Reporter)) with
         | Error e ->
           expect (e.code = "RegistryFrozen" || e.code = "DuplicateActorType") |> to_be_true
         | Ok () -> fail "register after start");
        ()));

    it "A04 send returns while recipient has not started handle" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"a04" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            expect (Atomic.get decision_handles) |> to_equal_int 0;
            let snap = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap.status with Well.Actor.Running -> true | _ -> false) |> to_be_true;
            Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
            ignore (await_ok id)));

    it "A05 failed execution is idempotent and conflicts on other data" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"a05f" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "none"))) with
          | Error e -> fail e.message
          | Ok id ->
            (match Well.Actor.await ~timeout_ms:5000 id with
             | Ok (Well.Actor.Terminal s) ->
               expect (match s.status with Well.Actor.Failed _ -> true | _ -> false) |> to_be_true
             | _ -> fail "expected failed");
            (match Well.Actor.send ~request_id:"a05f" ~timeout_ms:60000 wf
                     (Well.Actor.Message (mt, ("finance", "none"))) with
             | Error e -> fail e.message
             | Ok id2 -> expect id2 |> to_equal_string id);
            match Well.Actor.send ~request_id:"a05f" ~timeout_ms:60000 wf
                    (Well.Actor.Message (mt, ("sales", "Q3"))) with
            | Error e -> expect e.code |> to_equal_string "IdempotencyConflict"
            | Ok _ -> fail "conflict"));

    it "A07 await after complete is immediate and cancel drops waiter" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"a07c" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "reject"))) with
          | Error e -> fail e.message
          | Ok id ->
            ignore (await_ok id);
            let t0 = Unix.gettimeofday () in
            ignore (await_ok ~timeout_ms:30000 id);
            expect (Unix.gettimeofday () -. t0 < 1.0) |> to_be_true;
            Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
            match Well.Actor.send ~request_id:"a07w" ~timeout_ms:60000 wf
                    (Well.Actor.Message (mt, ("finance", "Q3"))) with
            | Error e -> fail e.message
            | Ok id2 ->
              (try
                 Eio.Switch.run (fun sw ->
                   Eio.Fiber.fork ~sw (fun () ->
                     ignore (Well.Actor.await ~timeout_ms:30000 id2));
                   Well.Env.sleep 0.05;
                   raise Exit)
               with Exit -> ());
              Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
              let snap = await_ok id2 in
              expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true));

    it "A07 cancel after waiter during later inspect removes waiter while running" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"a07i" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            Well.Actor._set_inspect_stall ~after:1 400;
            (try
               Eio.Switch.run (fun sw ->
                 Eio.Fiber.fork ~sw (fun () ->
                   ignore (Well.Actor.await ~timeout_ms:30000 id));
                 wait_until 80 (fun () -> Well.Actor._waiter_count () >= 1);
                 wait_until 80 (fun () -> Well.Actor._inspect_call_count () >= 2);
                 raise Exit)
             with Exit -> ());
            Well.Actor._set_inspect_stall ~after:0 0;
            expect (Well.Actor._waiter_count ()) |> to_equal_int 0;
            let snap = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap.status with Well.Actor.Running -> true | _ -> false) |> to_be_true;
            Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
            ignore (await_ok id)));

    it "W02 graph errors include cycle empty fork and duplicate branch" (fun () ->
      with_runtime (fun _desc ->
        let cycle = workflow ~name:"cyc" ~entry:"a" ~input:"Reports.Request" [
          "a", actor_node ~actor:"ReportDecision" ~id:(`Assoc ["fixed", `String "default"])
            ~accept:"Choose" ~mode:"one" ~outputs:["Accepted", "a"; "Rejected", "a"] ();
        ] in
        (match Well.Actor.Workflow.validate cycle with
         | Ok _ -> fail "cycle"
         | Error errs ->
           expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs) |> to_be_true;
           expect (List.exists (fun (e : Well.Actor.error) -> e.path <> None) errs) |> to_be_true);
        let empty_fork = workflow ~name:"ef" ~entry:"start" ~input:"Reports.Request" [
          "start", `Assoc [
            "kind", `String "fork";
            "input_type", `String "Reports.Request";
            "branches", `List [];
            "join", `Null;
          ];
          "done", end_node "Reports.Request";
        ] in
        (match Well.Actor.Workflow.validate empty_fork with
         | Ok _ -> fail "empty fork"
         | Error errs ->
           expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs) |> to_be_true);
        let dup = workflow ~name:"dupb" ~entry:"start" ~input:"Reports.Request" [
          "start", `Assoc [
            "kind", `String "fork";
            "input_type", `String "Reports.Request";
            "branches", `List [
              `Assoc ["name", `String "a"; "next", `String "done"];
              `Assoc ["name", `String "a"; "next", `String "done"];
            ];
            "join", `Null;
          ];
          "done", end_node "Reports.Request";
        ] in
        (match Well.Actor.Workflow.validate dup with
         | Ok _ -> fail "duplicate branch"
         | Error errs ->
           expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs) |> to_be_true);
        let unknown = workflow ~name:"unk" ~entry:"decide" ~input:"Reports.Request" [
          "decide", actor_node ~actor:"ReportDecision" ~id:(`Assoc ["fixed", `String "default"])
            ~accept:"Choose" ~mode:"one" ~outputs:["Accepted", "missing"; "Rejected", "rejected"] ();
          "rejected", end_node "Reports.Summary";
        ] in
        (match Well.Actor.Workflow.validate unknown with
         | Ok _ -> fail "unknown target"
         | Error errs ->
           expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs) |> to_be_true;
           expect (List.exists (fun (e : Well.Actor.error) -> e.path <> None) errs) |> to_be_true);
        let unreachable = workflow ~name:"unr" ~entry:"decide" ~input:"Reports.Request" [
          "decide", actor_node ~actor:"ReportDecision" ~id:(`Assoc ["fixed", `String "default"])
            ~accept:"Choose" ~mode:"one" ~outputs:["Accepted", "done"; "Rejected", "done"] ();
          "done", end_node "Reports.Request";
          "orphan", end_node "Reports.Summary";
        ] in
        (match Well.Actor.Workflow.validate unreachable with
        | Ok _ -> fail "unreachable"
        | Error errs ->
          expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs) |> to_be_true;
          expect (List.exists (fun (e : Well.Actor.error) -> e.path <> None) errs) |> to_be_true);
        let missing_entry = `Assoc [
          "format", `Int 1;
          "name", `String "noentry";
          "version", `String "1";
          "entry", `String "missing";
          "input_type", `String "Reports.Request";
          "bindings", `Assoc [];
          "nodes", `Assoc ["done", end_node "Reports.Request"];
        ] in
        match Well.Actor.Workflow.validate missing_entry with
        | Ok _ -> fail "missing entry"
        | Error errs ->
          expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs) |> to_be_true;
          expect (List.exists (fun (e : Well.Actor.error) -> e.path <> None) errs) |> to_be_true));

    it "W04 input_path and rejected list path" (fun () ->
      with_runtime (fun desc ->
        let ok_path = workflow ~name:"w04ok" ~entry:"report" ~input:"Reports.Request" [
          "report", actor_node ~actor:"Reporter"
            ~id:(`Assoc ["input_path", `List [`String "reporter_id"]])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "done"] ();
          "done", end_node "Reports.Report";
        ] in
        (match Well.Actor.Workflow.validate ok_path with
         | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
         | Ok wf ->
           let mt = request_type desc in
           match Well.Actor.send ~request_id:"w04ok" ~timeout_ms:60000 wf
                   (Well.Actor.Message (mt, ("finance", "Q3"))) with
           | Error e -> fail e.message
           | Ok id ->
             ignore (await_ok id);
             expect (reporter_count "finance")
             |> to_equal_int 1);
        let bad = workflow ~name:"w04bad" ~entry:"spawn" ~input:"Reports.RequestList" [
          "spawn", actor_node ~actor:"ReportSpawner" ~id:(`Assoc ["fixed", `String "default"])
            ~accept:"Generate" ~mode:"many" ~outputs:["Requested", "done"] ();
          "done", actor_node ~actor:"Reporter"
            ~id:(`Assoc ["input_path", `List [`String "requests"]])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "end"] ();
          "end", end_node "Reports.Report";
        ] in
        (match Well.Actor.Workflow.validate bad with
        | Ok _ -> fail "list on input_path"
        | Error errs ->
          expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs)
          |> to_be_true);
        let bound = workflow ~name:"w04bind" ~entry:"report" ~input:"Reports.Request"
            ~bindings:["rid", "sales"] [
          "report", actor_node ~actor:"Reporter"
            ~id:(`Assoc ["binding", `String "rid"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "done"] ();
          "done", end_node "Reports.Report";
        ] in
        match Well.Actor.Workflow.validate bound with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"w04bind" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            ignore (await_ok id);
            expect (reporter_count "sales")
            |> to_equal_int 1));

    it "W09 stored workflow survives definition file change" (fun () ->
      let dir = tmp_dir "w09-" in
      let store = Filename.concat dir "store.sqlite" in
      let wf_path = Filename.concat dir "choice.json" in
      let orig = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
      let oc = open_out wf_path in output_string oc (Yojson.Safe.to_string orig); close_out oc;
      current_store := store;
      Well.Actor._reset ();
      let cfg = {
        Well.Actor.store_path = store;
        limits = Well.Actor.default_limits;
        retry_policy = Well.Actor.default_retry_policy;
      } in
      (match Well.Actor.configure cfg with Ok () -> () | Error e -> fail e.message);
      let desc = descriptor () in
      register_all desc;
      Fun.protect ~finally:(fun () -> Well.Actor._reset (); rm_rf dir) (fun () ->
        Eio_main.run (fun env ->
          Well.Env.set env;
          Eio.Switch.run (fun sw ->
            Well.Actor.start_all ~sw;
            Fun.protect ~finally:Well.Actor._stop (fun () ->
              Well.Actor._hold { actor_type = "ReportDecision"; id = "default" };
              let wf_json = Yojson.Safe.from_file wf_path in
              match Well.Actor.Workflow.validate wf_json with
              | Error _ -> fail "validate"
              | Ok wf ->
                let mt = request_type desc in
                match Well.Actor.send ~request_id:"w09" ~timeout_ms:60000 wf
                        (Well.Actor.Message (mt, ("finance", "Q3"))) with
                | Error e -> fail e.message
                | Ok _ ->
                  let oc = open_out wf_path in
                  output_string oc "{\"format\":1,\"name\":\"changed\"}";
                  close_out oc;
                  Well.Actor._release { actor_type = "ReportDecision"; id = "default" };
                  match execution_of_request store "w09" with
                  | None -> fail "lost"
                  | Some eid -> ignore (await_ok eid))))));

    it "J01 join batch order follows branches not completion order" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          let hold_all () =
            List.iter (fun id -> Well.Actor._hold { actor_type = "Reporter"; id })
              ["finance"; "sales"; "stock"]
          in
          let handles id = reporter_count id in
          let batch_sources req =
            let env = scalar_text !current_store
                (Printf.sprintf
                   "SELECT i.envelope FROM inbox i JOIN executions e ON i.execution_id = e.execution_id WHERE i.actor_type = 'SummaryBuilder' AND e.request_id = '%s' LIMIT 1"
                   req)
            in
            match Yojson.Safe.from_string env with
            | `Assoc fs ->
              (match List.assoc_opt "payload" fs with
               | Some (`List [`List items]) ->
                 List.map (function `List [`String src; _] -> src | _ -> "") items
               | _ -> [])
            | _ -> []
          in
          let received_len () =
            let recvd = scalar_text !current_store "SELECT received FROM groups ORDER BY rowid DESC LIMIT 1" in
            if recvd = "" then 0
            else match Yojson.Safe.from_string recvd with `List xs -> List.length xs | _ -> 0
          in
          let wait_group req =
            wait_until 80 (fun () ->
              match execution_of_request !current_store req with
              | None -> false
              | Some eid ->
                scalar !current_store
                  (Printf.sprintf "SELECT COUNT(*) FROM groups WHERE execution_id = '%s'" eid) >= 1)
          in
          hold_all ();
          (match Well.Actor.send ~request_id:"j01-partial" ~timeout_ms:60000 wf
                   (Well.Actor.Message (mt, ("unused", "Q3"))) with
           | Error e -> fail e.message
           | Ok id ->
             wait_group "j01-partial";
             let before_stock = handles "stock" in
             Well.Actor._release { actor_type = "Reporter"; id = "stock" };
             wait_until 80 (fun () -> handles "stock" > before_stock);
             wait_until 80 (fun () -> received_len () = 1);
             expect (received_len ()) |> to_equal_int 1;
             expect (scalar !current_store
                       "SELECT COUNT(*) FROM inbox WHERE actor_type = 'SummaryBuilder'")
             |> to_equal_int 0;
             expect (scalar !current_store "SELECT COUNT(*) FROM groups WHERE closed = 1")
             |> to_equal_int 0;
             let snap1 = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
             expect snap1.open_groups |> to_equal_int 1;
             let before_fin = handles "finance" in
             Well.Actor._release { actor_type = "Reporter"; id = "finance" };
             wait_until 80 (fun () -> handles "finance" > before_fin);
             wait_until 80 (fun () -> received_len () = 2);
             expect (received_len ()) |> to_equal_int 2;
             expect (scalar !current_store
                       "SELECT COUNT(*) FROM inbox WHERE actor_type = 'SummaryBuilder'")
             |> to_equal_int 0;
             Well.Actor._release { actor_type = "Reporter"; id = "sales" };
             ignore (await_ok id);
             expect (batch_sources "j01-partial" = ["finance"; "sales"; "stock"]) |> to_be_true);
          let orders = [
            ["stock"; "sales"; "finance"];
            ["finance"; "stock"; "sales"];
            ["finance"; "sales"; "stock"];
            ["sales"; "stock"; "finance"];
            ["sales"; "finance"; "stock"];
          ] in
          List.iteri (fun i order ->
            hold_all ();
            let req = Printf.sprintf "j01-p%d" i in
            match Well.Actor.send ~request_id:req ~timeout_ms:60000 wf
                    (Well.Actor.Message (mt, ("unused", "Q3"))) with
            | Error e -> fail e.message
            | Ok id ->
              wait_group req;
              List.iter (fun rid ->
                let before = handles rid in
                Well.Actor._release { actor_type = "Reporter"; id = rid };
                wait_until 80 (fun () -> handles rid > before)
              ) order;
              ignore (await_ok id);
              expect (batch_sources req = ["finance"; "sales"; "stock"]) |> to_be_true
          ) orders));

    it "E04 domain rejection does not retry" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"e04" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "reject"))) with
          | Error e -> fail e.message
          | Ok id ->
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            expect (Atomic.get decision_handles) |> to_equal_int 1;
            expect (scalar !current_store "SELECT COUNT(*) FROM dead_letters") |> to_equal_int 0;
            expect (reporter_len ()) |> to_equal_int 0));

    it "E05 failed branch stops unstarted siblings" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "Reporter"; id = "sales" };
        Well.Actor._hold { actor_type = "Reporter"; id = "stock" };
        let json = workflow ~name:"e05" ~entry:"report" ~input:"Reports.Request" [
          "start", `Assoc [
            "kind", `String "fork";
            "input_type", `String "Reports.Request";
            "branches", `List [
              `Assoc ["name", `String "finance"; "next", `String "finance"];
              `Assoc ["name", `String "sales"; "next", `String "sales"];
              `Assoc ["name", `String "stock"; "next", `String "stock"];
            ];
            "join", `String "collect";
          ];
          "finance", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "finance"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "collect"] ();
          "sales", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "sales"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "collect"] ();
          "stock", actor_node ~actor:"Reporter" ~id:(`Assoc ["fixed", `String "stock"])
            ~accept:"Generate" ~mode:"one" ~outputs:["Produced", "collect"] ();
          "collect", `Assoc [
            "kind", `String "join";
            "item_type", `String "Reports.Report";
            "batch_type", `String "Reports.ReportBatch";
            "timeout_ms", `Int 30000;
            "next", `String "done";
          ];
          "done", end_node "Reports.ReportBatch";
        ] in
        let json =
          match json with
          | `Assoc fs -> `Assoc (("entry", `String "start") :: List.remove_assoc "entry" fs)
          | other -> other
        in
        match Well.Actor.Workflow.validate json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"e05" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "fail-hard"))) with
          | Error e -> fail e.message
          | Ok id ->
            wait_until 80 (fun () ->
              match Well.Actor.inspect id with
              | Ok s -> (match s.status with Well.Actor.Failed _ -> true | _ -> false)
              | _ -> false);
            expect (reporter_count "finance")
            |> to_equal_int 1;
            expect (reporter_count "sales")
            |> to_equal_int 0;
            Well.Actor._release { actor_type = "Reporter"; id = "sales" };
            Well.Actor._release { actor_type = "Reporter"; id = "stock" };
            Well.Env.sleep 0.2;
            expect (reporter_count "sales")
            |> to_equal_int 0));

    it "E08 overload still delivers existing outbox" (fun () ->
      let limits = { Well.Actor.default_limits with active_executions = 1 } in
      with_runtime ~limits (fun desc ->
        Well.Actor._hold { actor_type = "Reporter"; id = "finance" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"e08o-a" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok first ->
            wait_until 40 (fun () ->
              scalar !current_store "SELECT COUNT(*) FROM outbox WHERE delivered = 0" >= 1
              || reporter_count "finance" > 0
              || (match Well.Actor.inspect first with Ok s -> s.pending_messages > 0 | _ -> false));
            (match Well.Actor.send ~request_id:"e08o-b" ~timeout_ms:60000 wf
                     (Well.Actor.Message (mt, ("sales", "Q3"))) with
             | Error e -> expect e.code |> to_equal_string "Overloaded"
             | Ok _ -> fail "should overload");
            Well.Actor._release { actor_type = "Reporter"; id = "finance" };
            ignore (await_ok first);
            expect (reporter_count "finance" > 0)
            |> to_be_true));

    it "R02 without configure start_all does not create a store" (fun () ->
      Well.Actor._reset ();
      let cwd_files = Sys.readdir "." |> Array.to_list in
      Eio_main.run (fun env ->
        Well.Env.set env;
        Eio.Switch.run (fun sw ->
          Well.Actor.start_all ~sw;
          (try ignore (Well.Actor.metrics ()); fail "metrics"
           with Invalid_argument _ -> ());
          let after = Sys.readdir "." |> Array.to_list in
          expect (List.length after >= List.length cwd_files) |> to_be_true;
          expect (List.exists (fun n -> Filename.check_suffix n ".sqlite") after) |> to_be_false));
      Well.Actor._reset ());

    it "D09 lock is available after owner releases" (fun () ->
      Well.Actor._reset ();
      let dir = tmp_dir "d09b-" in
      let store = Filename.concat dir "store.sqlite" in
      current_store := store;
      let cfg = {
        Well.Actor.store_path = store;
        limits = Well.Actor.default_limits;
        retry_policy = Well.Actor.default_retry_policy;
      } in
      (match Well.Actor.configure cfg with Ok () -> () | Error e -> fail e.message);
      let desc = descriptor () in
      register_all desc;
      Fun.protect ~finally:(fun () -> Well.Actor._reset (); rm_rf dir) (fun () ->
        Eio_main.run (fun env ->
          Well.Env.set env;
          (try
             Eio.Switch.run (fun sw ->
               Well.Actor.start_all ~sw;
               let pid = spawn_env [ "ACTOR_LOCK_CHILD=" ^ store ] in
               wait_ok pid;
               Well.Actor._stop ();
               raise Exit)
           with Exit -> ()));
        Well.Actor._reset ();
        match Well.Actor._try_acquire store with
        | Error e -> fail e.message
        | Ok () -> ()));

    it "J06 dynamic one emission yields one-item batch" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "dynamic-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_list_type desc in
          match Well.Actor.send ~request_id:"j06-one" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, [("finance", "Q3")])) with
          | Error e -> fail e.message
          | Ok id ->
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            expect (reporter_count "finance")
            |> to_equal_int 1;
            expect (reporter_len ()) |> to_equal_int 1));

    it "J08 join timer redelivery does not complete twice" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"j08r" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            ignore (await_ok id);
            with_db !current_store (fun db ->
              ignore (Sqlite3.exec db
                "UPDATE timers SET delivered = 0, invalidated = 0 WHERE kind = 'join'"));
            Well.Env.sleep 0.2;
            let snap = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            expect (List.length snap.outputs) |> to_equal_int 1));

    it "D11 original deadline after process restart" (fun () ->
      let dir = tmp_dir "d11r-" in
      let store = Filename.concat dir "store.sqlite" in
      wait_crash (crash_child ~timeout_ms:800 store "admit:after_commit" "d11r");
      let deadline =
        Int64.of_string (scalar_text store "SELECT deadline_ms FROM executions LIMIT 1")
      in
      with_existing_store store (fun _desc ->
        Well.Actor._set_now_ms (Int64.add deadline 20L);
        match execution_of_request store "d11r" with
        | None -> fail "lost"
        | Some eid ->
          (match Well.Actor.await ~timeout_ms:5000 eid with
           | Ok (Well.Actor.Terminal s) ->
             expect (match s.status with
               | Well.Actor.Failed d when d.error.code = "ExecutionTimeout" -> true
               | _ -> false) |> to_be_true;
             expect (Int64.equal s.deadline_ms deadline) |> to_be_true
           | Ok (Wait_timeout _) -> fail "timeout"
           | Error e -> fail e.message));
      rm_rf dir);

    it "W09 restart process keeps stored workflow" (fun () ->
      let dir = tmp_dir "w09r-" in
      let store = Filename.concat dir "store.sqlite" in
      wait_crash (crash_child store "admit:after_commit" "w09r");
      let env = Yojson.Safe.from_string (scalar_text store "SELECT envelope FROM inbox LIMIT 1") in
      let wf_name, has_contracts =
        match env with
        | `Assoc fs ->
          let name =
            match List.assoc_opt "workflow" fs with
            | Some (`Assoc w) ->
              (match List.assoc_opt "name" w with Some (`String n) -> n | _ -> "")
            | _ -> ""
          in
          name, List.mem_assoc "contracts" fs
        | _ -> "", false
      in
      expect wf_name |> to_equal_string "choice";
      expect has_contracts |> to_be_true;
      with_existing_store store (fun _desc ->
        match execution_of_request store "w09r" with
        | None -> fail "lost"
        | Some eid ->
          let snap = await_ok ~timeout_ms:15000 eid in
          expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true);
      rm_rf dir);

    it "R04 same name service handler and actor type" (fun () ->
      with_runtime (fun desc ->
        Well.Service.register_handler "Reporter" {
          dispatch = (fun rpc _ _ -> if rpc = "Ping" then `String "pong" else `Null);
          rpcs = [{ rname = "Ping"; params = []; returns = []; returns_name = "void" }];
          kind = `Service;
        };
        (match Well.Service.dispatch_by_name "Reporter" "Ping" `Null `Null with
         | `String "pong" -> ()
         | _ -> fail "service");
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"r04s" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "reject"))) with
          | Error e -> fail e.message
          | Ok id ->
            ignore (await_ok id);
            (match Well.Service.dispatch_by_name "Reporter" "Ping" `Null `Null with
             | `String "pong" -> ()
             | _ -> fail "service after send")));

    it "W04 optional and variant input_path rejected" (fun () ->
      with_runtime ~register:(fun desc -> register_all desc; ignore (register_wrapper ())) (fun _desc ->
        let opt_path = workflow ~name:"w04opt" ~entry:"w" ~input:"Wrap.Box" [
          "w", actor_node ~actor:"Wrapper"
            ~id:(`Assoc ["input_path", `List [`String "flag"]])
            ~accept:"Open" ~mode:"optional" ~outputs:[] ();
        ] in
        (match Well.Actor.Workflow.validate opt_path with
         | Ok _ -> fail "optional path"
         | Error errs ->
           expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs)
           |> to_be_true);
        let var_path = workflow ~name:"w04var" ~entry:"w" ~input:"Wrap.Box" [
          "w", actor_node ~actor:"Wrapper"
            ~id:(`Assoc ["input_path", `List [`String "tag"]])
            ~accept:"Open" ~mode:"optional" ~outputs:[] ();
        ] in
        match Well.Actor.Workflow.validate var_path with
        | Ok _ -> fail "variant path"
        | Error errs ->
          expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs)
          |> to_be_true));

    it "W06 many identical kinds set branch_path ordinals" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "dynamic-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_list_type desc in
          match Well.Actor.send ~request_id:"w06" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, [("finance", "Q3"); ("finance", "Q3")])) with
          | Error e -> fail e.message
          | Ok id ->
            ignore (await_ok id);
            expect (reporter_count "finance")
            |> to_equal_int 2;
            let paths =
              with_db !current_store (fun db ->
                let stmt = Sqlite3.prepare db
                    "SELECT envelope FROM inbox WHERE actor_type = 'Reporter' ORDER BY seq" in
                Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
                  let rec go acc =
                    match Sqlite3.step stmt with
                    | Sqlite3.Rc.ROW ->
                      let env = Yojson.Safe.from_string (Sqlite3.column_text stmt 0) in
                      let bp =
                        match List.assoc_opt "branch_path" (json_assoc env) with
                        | Some (`List xs) ->
                          List.map (function `Int n -> n | _ -> -1) xs
                        | _ -> []
                      in
                      go (bp :: acc)
                    | _ -> List.rev acc
                  in
                  go []))
            in
            expect (List.mem [0] paths) |> to_be_true;
            expect (List.mem [1] paths) |> to_be_true));

    it "J04 nested join closes inner frame first" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "nested-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"j04" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            let snap = await_ok id in
            expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            expect (scalar !current_store "SELECT COUNT(*) FROM groups WHERE closed = 1")
            |> to_equal_int 2;
            let inner_parent = scalar_text !current_store
                "SELECT parent_groups FROM groups WHERE join_node = 'inner'"
            in
            expect (inner_parent <> "[]" && inner_parent <> "") |> to_be_true;
            let outer_parent = scalar_text !current_store
                "SELECT parent_groups FROM groups WHERE join_node = 'collect'"
            in
            expect (outer_parent = "[]" || outer_parent = "") |> to_be_true;
            let env = envelope_json !current_store
                "SELECT envelope FROM inbox WHERE actor_id = 'finance' LIMIT 1"
            in
            let frames =
              match List.assoc_opt "groups" (json_assoc env) with
              | Some (`List xs) -> List.length xs
              | _ -> 0
            in
            expect frames |> to_equal_int 2));

    it "J07 restart after one of three join results" (fun () ->
      let dir = tmp_dir "j07a-" in
      let store = Filename.concat dir "store.sqlite" in
      current_store := store;
      Well.Actor._reset ();
      reporter_clear ();
      let cfg = {
        Well.Actor.store_path = store;
        limits = Well.Actor.default_limits;
        retry_policy = Well.Actor.default_retry_policy;
      } in
      (match Well.Actor.configure cfg with Ok () -> () | Error e -> fail e.message);
      let desc = descriptor () in
      register_all desc;
      let expected = ref "" in
      let deadline = ref 0L in
      Fun.protect ~finally:(fun () -> Well.Actor._reset ()) (fun () ->
        Eio_main.run (fun env ->
          Well.Env.set env;
          Eio.Switch.run (fun sw ->
            Well.Actor.start_all ~sw;
            Fun.protect ~finally:Well.Actor._stop (fun () ->
              Well.Actor._hold { actor_type = "Reporter"; id = "sales" };
              Well.Actor._hold { actor_type = "Reporter"; id = "stock" };
              let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
              match Well.Actor.Workflow.validate wf_json with
              | Error _ -> fail "validate"
              | Ok wf ->
                let mt = request_type desc in
                match Well.Actor.send ~request_id:"j07-1" ~timeout_ms:120000 wf
                        (Well.Actor.Message (mt, ("unused", "Q3"))) with
                | Error e -> fail e.message
                | Ok _ ->
                  wait_until 80 (fun () ->
                    let recvd = scalar_text store "SELECT received FROM groups LIMIT 1" in
                    if recvd = "" then false
                    else match Yojson.Safe.from_string recvd with
                      | `List xs -> List.length xs = 1
                      | _ -> false);
                  expected := scalar_text store "SELECT expected FROM groups LIMIT 1";
                  deadline := Int64.of_string (scalar_text store "SELECT deadline_ms FROM groups LIMIT 1")))));
      expect (scalar store "SELECT closed FROM groups LIMIT 1") |> to_equal_int 0;
      with_existing_store store (fun _desc ->
        match execution_of_request store "j07-1" with
        | None -> fail "lost"
        | Some eid ->
          expect (scalar_text store "SELECT expected FROM groups LIMIT 1") |> to_equal_string !expected;
          expect (Int64.equal
                    (Int64.of_string (scalar_text store "SELECT deadline_ms FROM groups LIMIT 1"))
                    !deadline) |> to_be_true;
          let recvd = scalar_text store "SELECT received FROM groups LIMIT 1" in
          (match Yojson.Safe.from_string recvd with
           | `List xs -> expect (List.length xs) |> to_equal_int 1
           | _ -> fail "received");
          let snap = await_ok ~timeout_ms:15000 eid in
          expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true);
      rm_rf dir);

    it "J09 join timeout lists missing branches without partial batch" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "Reporter"; id = "finance" };
        Well.Actor._hold { actor_type = "Reporter"; id = "sales" };
        Well.Actor._hold { actor_type = "Reporter"; id = "stock" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"j09" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            wait_until 80 (fun () ->
              scalar !current_store "SELECT COUNT(*) FROM groups" >= 1
              && scalar !current_store "SELECT COUNT(*) FROM timers WHERE kind = 'join'" >= 1);
            let dl = Int64.of_string (scalar_text !current_store
              "SELECT deadline_ms FROM groups LIMIT 1")
            in
            Well.Actor._set_now_ms (Int64.add dl 1L);
            match Well.Actor.await ~timeout_ms:5000 id with
            | Ok (Well.Actor.Terminal s) ->
              (match s.status with
               | Well.Actor.Failed d ->
                 expect d.error.code |> to_equal_string "JoinTimeout";
                 (match List.length d.missing_branches with
                  | 3 -> ()
                  | n -> fail (Printf.sprintf "missing=%d [%s]" n
                                 (String.concat "," d.missing_branches)));
                 expect (List.mem "0" d.missing_branches) |> to_be_true;
                 expect (List.mem "1" d.missing_branches) |> to_be_true;
                 expect (List.mem "2" d.missing_branches) |> to_be_true
               | _ -> fail "expected JoinTimeout");
              (match List.length s.outputs with
               | 0 -> ()
               | n -> fail (Printf.sprintf "outputs=%d" n));
              (match scalar !current_store
                       "SELECT COUNT(*) FROM inbox WHERE actor_type = 'SummaryBuilder'" with
               | 0 -> ()
               | n -> fail (Printf.sprintf "summary_inbox=%d" n));
              (match scalar !current_store
                       "SELECT COUNT(*) FROM inbox WHERE actor_type = '__well.join'" with
               | n when n >= 0 -> ()
               | n -> fail (Printf.sprintf "join_inbox=%d" n))
            | Ok (Wait_timeout _) -> fail "timeout"
            | Error e -> fail e.message));

    it "J10 join results persist while aggregator has not started" (fun () ->
      with_runtime (fun desc ->
        Well.Actor._hold { actor_type = "SummaryBuilder"; id = "default" };
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"j10" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            wait_until 80 (fun () ->
              scalar !current_store "SELECT COUNT(*) FROM groups WHERE closed = 1" = 1
              && scalar !current_store
                   "SELECT COUNT(*) FROM inbox WHERE actor_type = 'SummaryBuilder'" >= 1);
            expect (scalar !current_store "SELECT closed FROM groups LIMIT 1") |> to_equal_int 1;
            let recvd = scalar_text !current_store "SELECT received FROM groups LIMIT 1" in
            (match Yojson.Safe.from_string recvd with
             | `List xs -> expect (List.length xs) |> to_equal_int 3
             | _ -> fail "received");
            let snap = match Well.Actor.inspect id with Ok s -> s | Error e -> failwith e.message in
            expect (match snap.status with Well.Actor.Running -> true | _ -> false) |> to_be_true;
            Well.Actor._release { actor_type = "SummaryBuilder"; id = "default" };
            let done_ = await_ok id in
            expect (match done_.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
            expect (List.length done_.outputs) |> to_equal_int 1));

    it "D03 crash after state write leaves no partial commit" (fun () ->
      let dir = tmp_dir "d03s-" in
      let store = Filename.concat dir "store.sqlite" in
      wait_crash (crash_child store "commit_turn:after_state" "d03s");
      expect (scalar store "SELECT COUNT(*) FROM outbox") |> to_equal_int 0;
      expect (scalar store "SELECT COUNT(*) FROM actor_state") |> to_equal_int 0;
      with_existing_store store (fun _desc ->
        match execution_of_request store "d03s" with
        | None -> fail "admission lost"
        | Some eid ->
          let snap = await_ok ~timeout_ms:15000 eid in
          expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true);
      rm_rf dir);

    it "D03 crash after group write leaves no partial commit" (fun () ->
      let dir = tmp_dir "d03g-" in
      let store = Filename.concat dir "store.sqlite" in
      wait_crash (crash_child ~wf:"three-reports.json" store "commit_turn:after_groups" "d03g");
      expect (scalar store "SELECT COUNT(*) FROM groups") |> to_equal_int 0;
      expect (scalar store "SELECT COUNT(*) FROM outbox") |> to_equal_int 0;
      with_existing_store store (fun _desc ->
        match execution_of_request store "d03g" with
        | None -> fail "admission lost"
        | Some eid ->
          let snap = await_ok ~timeout_ms:15000 eid in
          expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true);
      rm_rf dir);

    it "D03 crash after outbox write leaves no partial commit" (fun () ->
      let dir = tmp_dir "d03o-" in
      let store = Filename.concat dir "store.sqlite" in
      wait_crash (crash_child store "commit_turn:after_outbox" "d03o");
      expect (scalar store "SELECT COUNT(*) FROM outbox") |> to_equal_int 0;
      expect (scalar store "SELECT COUNT(*) FROM actor_state") |> to_equal_int 0;
      with_existing_store store (fun _desc ->
        match execution_of_request store "d03o" with
        | None -> fail "admission lost"
        | Some eid ->
          let snap = await_ok ~timeout_ms:15000 eid in
          expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true);
      rm_rf dir);

    it "A06 bad admission input does not create an execution" (fun () ->
      with_runtime (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          let sum = summary_type desc in
          (match Well.Actor.send ~request_id:"a06-ty" ~timeout_ms:60000 wf
                   (Well.Actor.Message (sum, "nope")) with
           | Error e -> expect e.code |> to_equal_string "InvalidInput"
           | Ok _ -> fail "type");
          (match Well.Actor.send ~request_id:"" ~timeout_ms:60000 wf
                   (Well.Actor.Message (mt, ("finance", "Q3"))) with
           | Error e -> expect e.code |> to_equal_string "InvalidInput"
           | Ok _ -> fail "empty id");
          (match Well.Actor.send ~request_id:"a06-to" ~timeout_ms:0 wf
                   (Well.Actor.Message (mt, ("finance", "Q3"))) with
           | Error e -> expect e.code |> to_equal_string "InvalidInput"
           | Ok _ -> fail "timeout");
          expect (scalar !current_store "SELECT COUNT(*) FROM executions") |> to_equal_int 0));

    it "E07 size node payload state and pending limits" (fun () ->
      let tiny_wf = { Well.Actor.default_limits with workflow_bytes = 32 } in
      with_runtime ~limits:tiny_wf (fun _desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Ok _ -> fail "workflow_bytes"
        | Error errs ->
          expect (List.exists (fun (e : Well.Actor.error) ->
            e.code = "InvalidWorkflow" || e.code = "LimitExceeded") errs) |> to_be_true);
      let tiny_nodes = { Well.Actor.default_limits with nodes = 2 } in
      with_runtime ~limits:tiny_nodes (fun _desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Ok _ -> fail "nodes"
        | Error errs ->
          expect (List.exists (fun (e : Well.Actor.error) -> e.code = "InvalidWorkflow") errs)
          |> to_be_true);
      let tiny_payload = { Well.Actor.default_limits with payload_bytes = 8 } in
      with_runtime ~limits:tiny_payload (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"e07p" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> expect e.code |> to_equal_string "LimitExceeded"
          | Ok _ -> fail "payload");
      let tiny_state = { Well.Actor.default_limits with state_bytes = 3 } in
      with_runtime ~limits:tiny_state (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"e07s" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "reject"))) with
          | Error e -> fail e.message
          | Ok id ->
            match Well.Actor.await ~timeout_ms:5000 id with
            | Ok (Well.Actor.Terminal s) ->
              expect (match s.status with
                | Well.Actor.Failed d when d.error.code = "LimitExceeded" -> true
                | _ -> false) |> to_be_true;
              expect (scalar !current_store "SELECT COUNT(*) FROM actor_state") |> to_equal_int 0
            | Ok (Wait_timeout _) -> fail "timeout"
            | Error e -> fail e.message);
      let tiny_del = { Well.Actor.default_limits with deliveries_per_execution = 1 } in
      with_runtime ~limits:tiny_del (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "three-reports.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"e07d" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("unused", "Q3"))) with
          | Error e -> fail e.message
          | Ok id ->
            match Well.Actor.await ~timeout_ms:5000 id with
            | Ok (Well.Actor.Terminal s) ->
              expect (match s.status with
                | Well.Actor.Failed d when d.error.code = "LimitExceeded" -> true
                | _ -> false) |> to_be_true;
              expect (List.length s.outputs) |> to_equal_int 0
            | Ok (Wait_timeout _) -> fail "timeout"
            | Error e -> fail e.message);
      let tiny_pend = { Well.Actor.default_limits with pending_deliveries = 1 } in
      with_runtime ~limits:tiny_pend (fun desc ->
        let wf_json = Yojson.Safe.from_file (Filename.concat examples "choice.json") in
        match Well.Actor.Workflow.validate wf_json with
        | Error _ -> fail "validate"
        | Ok wf ->
          let mt = request_type desc in
          match Well.Actor.send ~request_id:"e07q-a" ~timeout_ms:60000 wf
                  (Well.Actor.Message (mt, ("finance", "Q3"))) with
          | Error e -> fail e.message
          | Ok first ->
            match Well.Actor.await ~timeout_ms:5000 first with
            | Ok (Well.Actor.Terminal s) ->
              expect (match s.status with
                | Well.Actor.Failed d when d.error.code = "LimitExceeded" -> true
                | _ -> false) |> to_be_true;
              expect (List.length s.outputs) |> to_equal_int 0
            | Ok (Wait_timeout _) -> fail "timeout"
            | Error e -> fail e.message));

    it "W09 outbox after restart keeps workflow and contracts" (fun () ->
      let dir = tmp_dir "w09o-" in
      let store = Filename.concat dir "store.sqlite" in
      wait_crash (crash_child store "commit_turn:after_commit" "w09o");
      let env = Yojson.Safe.from_string (scalar_text store "SELECT envelope FROM outbox LIMIT 1") in
      let fs = json_assoc env in
      let wf_name =
        match List.assoc_opt "workflow" fs with
        | Some (`Assoc w) ->
          (match List.assoc_opt "name" w with Some (`String n) -> n | _ -> "")
        | _ -> ""
      in
      expect wf_name |> to_equal_string "choice";
      expect (List.mem_assoc "contracts" fs) |> to_be_true;
      with_existing_store store (fun _desc ->
        match execution_of_request store "w09o" with
        | None -> fail "lost"
        | Some eid ->
          let snap = await_ok ~timeout_ms:15000 eid in
          expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true);
      rm_rf dir);

    it "C09 JCS exponential bounds" (fun () ->
      expect (Well.Actor._canonicalize (`Float 1e20))
      |> to_equal_string "100000000000000000000";
      expect (Well.Actor._canonicalize (`Float 1e21)) |> to_equal_string "1e+21";
      expect (Well.Actor._canonicalize (`Float 1e-6)) |> to_equal_string "0.000001";
      expect (Well.Actor._canonicalize (`Float 1e-7)) |> to_equal_string "1e-7");

    it "D06 last join result commits one closed group" (fun () ->
      let dir = tmp_dir "d06-" in
      let store = Filename.concat dir "store.sqlite" in
      wait_crash (crash_child ~wf:"three-reports.json" store "join_complete:after_commit" "d06");
      expect (scalar store "SELECT COUNT(*) FROM groups WHERE closed = 1") |> to_equal_int 1;
      expect (scalar store "SELECT COUNT(*) FROM outbox WHERE delivered = 0") |> to_equal_int 1;
      with_existing_store store (fun _desc ->
        match execution_of_request store "d06" with
        | None -> fail "admission lost"
        | Some eid ->
          let snap = await_ok ~timeout_ms:15000 eid in
          expect (match snap.status with Well.Actor.Completed -> true | _ -> false) |> to_be_true;
          expect (List.length snap.outputs) |> to_equal_int 1;
          expect (scalar store "SELECT COUNT(*) FROM groups WHERE closed = 1") |> to_equal_int 1);
      rm_rf dir);
  );
  let filter = Sys.getenv_opt "WELL_TEST_FILTER" in
  run ~filter ~source_file:__FILE__ () |> exit_with_result
