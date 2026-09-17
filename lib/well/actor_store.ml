open Actor_types

let hooks_mu = Mutex.create ()
let with_hooks f =
  Mutex.lock hooks_mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock hooks_mu) f

let crash_point : string option ref = ref None
let force_write_error : string option ref = ref None
let force_write_sticky = ref false
let force_inflight_delete_error : string option ref = ref None
let ambiguous_commit = ref false
let stall_ms = ref 0
let max_page_count : int option ref = ref None

let pending_close : Sqlite3.db list ref = ref []
let pending_close_mu = Mutex.create ()
let pinned_stmt : Sqlite3.stmt option ref = ref None

let remember_pending db =
  Mutex.lock pending_close_mu;
  if not (List.exists (fun d -> d == db) !pending_close) then
    pending_close := db :: !pending_close;
  Mutex.unlock pending_close_mu

let forget_pending db =
  Mutex.lock pending_close_mu;
  pending_close := List.filter (fun d -> d != db) !pending_close;
  Mutex.unlock pending_close_mu

let close_db db =
  if Sqlite3.db_close db then forget_pending db
  else begin
    Gc.major ();
    if Sqlite3.db_close db then forget_pending db
    else remember_pending db
  end

let flush_pending_close () =
  Mutex.lock pending_close_mu;
  let rest =
    List.fold_left (fun acc db ->
      if Sqlite3.db_close db then acc else db :: acc) [] !pending_close
  in
  pending_close := rest;
  Mutex.unlock pending_close_mu;
  rest = [] && !pinned_stmt = None

let pending_close_count () =
  Mutex.lock pending_close_mu;
  let n = List.length !pending_close in
  Mutex.unlock pending_close_mu;
  n

let get_crash_point () = with_hooks (fun () -> !crash_point)
let set_crash_point p = with_hooks (fun () -> crash_point := p)
let get_stall_ms () = with_hooks (fun () -> !stall_ms)
let set_stall_ms n = with_hooks (fun () -> stall_ms := n)
let get_max_page_count () = with_hooks (fun () -> !max_page_count)
let set_max_page_count n = with_hooks (fun () -> max_page_count := n)
let get_force_write_error () = with_hooks (fun () -> !force_write_error)
let set_force_write_error ?(sticky = false) msg =
  with_hooks (fun () ->
    force_write_error := msg;
    force_write_sticky := sticky)
let set_force_inflight_delete_error msg =
  with_hooks (fun () -> force_inflight_delete_error := msg)
let set_ambiguous_commit v = with_hooks (fun () -> ambiguous_commit := v)

let check_crash name =
  match get_crash_point () with
  | Some p when p = name ->
    Printf.eprintf "actor crash_point %s pid=%d\n%!" name (Unix.getpid ());
    Unix._exit 1
  | _ -> ()

type envelope = {
  format : int;
  execution_id : string;
  message_id : string;
  causation_id : string option;
  workflow : Yojson.Safe.t;
  workflow_hash : string;
  contracts : Yojson.Safe.t;
  node_id : string;
  actor_address : actor_id option;
  message_kind : string;
  payload_type : string;
  payload : Yojson.Safe.t;
  branch_path : int list;
  groups : Actor_workflow.group_frame list;
  created_at_ms : int64;
  execution_deadline_ms : int64;
}

let envelope_to_json e =
  let addr =
    match e.actor_address with
    | None -> `Null
    | Some a -> `Assoc ["actor_type", `String a.actor_type; "id", `String a.id]
  in
  let groups =
    `List (List.map (fun (g : Actor_workflow.group_frame) ->
      `Assoc [
        "group_id", `String g.group_id;
        "branch_id", `String g.branch_id;
        "ordinal", `Int g.ordinal;
        "join_node", `String g.join_node;
      ]) e.groups)
  in
  `Assoc [
    "format", `Int e.format;
    "execution_id", `String e.execution_id;
    "message_id", `String e.message_id;
    "causation_id", (match e.causation_id with None -> `Null | Some s -> `String s);
    "workflow", e.workflow;
    "workflow_hash", `String e.workflow_hash;
    "contracts", e.contracts;
    "node_id", `String e.node_id;
    "actor_address", addr;
    "message_kind", `String e.message_kind;
    "payload_type", `String e.payload_type;
    "payload", e.payload;
    "branch_path", `List (List.map (fun n -> `Int n) e.branch_path);
    "groups", groups;
    "created_at_ms", `Intlit (Int64.to_string e.created_at_ms);
    "execution_deadline_ms", `Intlit (Int64.to_string e.execution_deadline_ms);
  ]

let int64_of_json = function
  | `Int n -> Int64.of_int n
  | `Intlit s -> Int64.of_string s
  | `Float f -> Int64.of_float f
  | _ -> 0L

let envelope_of_json json =
  match json with
  | `Assoc _ as obj ->
    let s k = match Actor_json.member k obj with Some (`String v) -> v | _ -> "" in
    let j k = match Actor_json.member k obj with Some v -> v | None -> `Null in
    let addr =
      match Actor_json.member "actor_address" obj with
      | Some (`Assoc _ as a) ->
        (match Actor_json.member "actor_type" a, Actor_json.member "id" a with
         | Some (`String t), Some (`String i) -> Some { actor_type = t; id = i }
         | _ -> None)
      | _ -> None
    in
    let groups =
      match Actor_json.member "groups" obj with
      | Some (`List xs) ->
        List.filter_map (function
          | `Assoc _ as g ->
            (match
               Actor_json.member "group_id" g,
               Actor_json.member "branch_id" g,
               Actor_json.member "ordinal" g,
               Actor_json.member "join_node" g
             with
             | Some (`String gid), Some (`String bid), Some (`Int o), Some (`String jn) ->
               Some Actor_workflow.{ group_id = gid; branch_id = bid; ordinal = o; join_node = jn }
             | _ -> None)
          | _ -> None) xs
      | _ -> []
    in
    let branch_path =
      match Actor_json.member "branch_path" obj with
      | Some (`List xs) -> List.filter_map (function `Int n -> Some n | _ -> None) xs
      | _ -> []
    in
    {
      format = (match Actor_json.member "format" obj with Some (`Int n) -> n | _ -> 1);
      execution_id = s "execution_id";
      message_id = s "message_id";
      causation_id = (match Actor_json.member "causation_id" obj with Some (`String v) -> Some v | _ -> None);
      workflow = j "workflow";
      workflow_hash = s "workflow_hash";
      contracts = j "contracts";
      node_id = s "node_id";
      actor_address = addr;
      message_kind = s "message_kind";
      payload_type = s "payload_type";
      payload = j "payload";
      branch_path;
      groups;
      created_at_ms = int64_of_json (j "created_at_ms");
      execution_deadline_ms = int64_of_json (j "execution_deadline_ms");
    }
  | _ -> failwith "envelope"

type t = {
  path : string;
  lock_fd : Unix.file_descr;
}

let exec db sql =
  match Sqlite3.exec db sql with
  | Sqlite3.Rc.OK -> Ok ()
  | rc ->
    let msg = Sqlite3.errmsg db in
    Error (if msg <> "" then msg else Sqlite3.Rc.to_string rc)

let bind_text stmt i s = ignore (Sqlite3.bind stmt i (Sqlite3.Data.TEXT s))
let bind_int stmt i n = ignore (Sqlite3.bind stmt i (Sqlite3.Data.INT (Int64.of_int n)))
let bind_i64 stmt i n = ignore (Sqlite3.bind stmt i (Sqlite3.Data.INT n))
let bind_null stmt i = ignore (Sqlite3.bind stmt i Sqlite3.Data.NULL)

let step_done_raw stmt =
  match Sqlite3.step stmt with
  | Sqlite3.Rc.DONE -> Ok ()
  | rc -> Error (Sqlite3.Rc.to_string rc)

let step_done stmt =
  match with_hooks (fun () ->
    match !force_write_error with
    | Some msg ->
      if not !force_write_sticky then force_write_error := None;
      `Err msg
    | None -> `Go)
  with
  | `Err msg -> Error msg
  | `Go -> step_done_raw stmt

let rooted_stmts : Sqlite3.stmt list ref = ref []
let rooted_mu = Mutex.create ()

let retain_stmt stmt =
  Mutex.lock rooted_mu;
  rooted_stmts := stmt :: !rooted_stmts;
  Mutex.unlock rooted_mu

let release_stmt stmt =
  Mutex.lock rooted_mu;
  rooted_stmts := List.filter (fun s -> s != stmt) !rooted_stmts;
  Mutex.unlock rooted_mu

let reset_stmt_roots () =
  Mutex.lock rooted_mu;
  rooted_stmts := [];
  Mutex.unlock rooted_mu

let with_stmt db sql f =
  let stmt = Sqlite3.prepare db sql in
  retain_stmt stmt;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sqlite3.finalize stmt);
      release_stmt stmt)
    (fun () -> f stmt)

let open_db path =
  let db = Sqlite3.db_open ~mutex:`FULL path in
  ignore (Sqlite3.busy_timeout db 5000);
  ignore (Sqlite3.exec db "PRAGMA journal_mode=WAL");
  ignore (Sqlite3.exec db "PRAGMA synchronous=FULL");
  (match get_max_page_count () with
   | Some n -> ignore (Sqlite3.exec db (Printf.sprintf "PRAGMA max_page_count=%d" n))
   | None -> ());
  db

let pin_busy_close path =
  (match !pinned_stmt with
   | Some s -> ignore (Sqlite3.finalize s); pinned_stmt := None
   | None -> ());
  let db = open_db path in
  let stmt = Sqlite3.prepare db "SELECT 1" in
  ignore (Sqlite3.step stmt);
  pinned_stmt := Some stmt;
  remember_pending db;
  pending_close_count ()

let unpin_busy_close () =
  match !pinned_stmt with
  | None -> ()
  | Some s ->
    ignore (Sqlite3.finalize s);
    pinned_stmt := None;
    ignore (flush_pending_close ())

let schema = {|
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS executions (
  execution_id TEXT PRIMARY KEY,
  request_id TEXT NOT NULL UNIQUE,
  admission_jcs TEXT NOT NULL,
  workflow TEXT NOT NULL,
  workflow_hash TEXT NOT NULL,
  status TEXT NOT NULL,
  timeout_ms INTEGER NOT NULL,
  deadline_ms INTEGER NOT NULL,
  created_at_ms INTEGER NOT NULL,
  diagnostic TEXT,
  pending_messages INTEGER NOT NULL DEFAULT 0,
  open_groups INTEGER NOT NULL DEFAULT 0,
  deliveries INTEGER NOT NULL DEFAULT 0,
  tokens INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS inbox (
  message_id TEXT PRIMARY KEY,
  execution_id TEXT NOT NULL,
  actor_type TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  envelope TEXT NOT NULL,
  status TEXT NOT NULL,
  attempt INTEGER NOT NULL,
  available_at_ms INTEGER NOT NULL,
  claim_owner TEXT
);
CREATE INDEX IF NOT EXISTS inbox_addr ON inbox(actor_type, actor_id, status, seq);
CREATE INDEX IF NOT EXISTS inbox_exec ON inbox(execution_id);
CREATE TABLE IF NOT EXISTS inflight (
  message_id TEXT PRIMARY KEY,
  generation INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS activation_seq (
  message_id TEXT PRIMARY KEY,
  next_gen INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS outbox (
  message_id TEXT PRIMARY KEY,
  execution_id TEXT NOT NULL,
  envelope TEXT NOT NULL,
  delivered INTEGER NOT NULL DEFAULT 0,
  seq INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS actor_state (
  actor_type TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  blob TEXT NOT NULL,
  state_version INTEGER NOT NULL,
  revision INTEGER NOT NULL,
  PRIMARY KEY (actor_type, actor_id)
);
CREATE TABLE IF NOT EXISTS groups (
  group_id TEXT PRIMARY KEY,
  execution_id TEXT NOT NULL,
  join_node TEXT NOT NULL,
  item_type TEXT NOT NULL,
  batch_type TEXT NOT NULL,
  expected TEXT NOT NULL,
  received TEXT NOT NULL,
  deadline_ms INTEGER NOT NULL,
  closed INTEGER NOT NULL,
  next_node TEXT NOT NULL,
  parent_groups TEXT NOT NULL,
  branch_path TEXT NOT NULL,
  source_message_id TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS timers (
  timer_id TEXT PRIMARY KEY,
  execution_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  fire_at_ms INTEGER NOT NULL,
  payload TEXT NOT NULL,
  invalidated INTEGER NOT NULL DEFAULT 0,
  delivered INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS outputs (
  execution_id TEXT NOT NULL,
  path TEXT NOT NULL,
  payload_type TEXT NOT NULL,
  schema_hash TEXT NOT NULL,
  payload TEXT NOT NULL,
  PRIMARY KEY (execution_id, path)
);
CREATE TABLE IF NOT EXISTS errors (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  execution_id TEXT NOT NULL,
  diagnostic TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS dead_letters (
  message_id TEXT PRIMARY KEY,
  envelope TEXT NOT NULL,
  diagnostic TEXT NOT NULL
);
|}

let acquire path =
  let lock_path = path ^ ".lock" in
  let fd = Unix.openfile lock_path [Unix.O_CREAT; Unix.O_RDWR] 0o644 in
  try
    Unix.lockf fd Unix.F_TLOCK 0;
    Ok { path; lock_fd = fd }
  with Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) ->
    Unix.close fd;
    Error (error "StorageUnavailable" "store is owned by another process")

let release t =
  (try Unix.lockf t.lock_fd Unix.F_ULOCK 0 with _ -> ());
  (try Unix.close t.lock_fd with _ -> ())

let connect t = open_db t.path

let init t =
  let db = connect t in
  match exec db schema with
  | Error msg -> close_db db; Error (error "StorageUnavailable" msg)
  | Ok () ->
    let version =
      with_stmt db "SELECT value FROM meta WHERE key = 'schema_version'" (fun stmt ->
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW -> Some (Sqlite3.column_text stmt 0)
        | _ -> None)
    in
    match version with
    | Some v when v <> "1" ->
      close_db db;
      Error (error "StorageUnavailable" ("unsupported store version " ^ v))
    | Some _ ->
      ignore (exec db "CREATE TABLE IF NOT EXISTS inflight (message_id TEXT PRIMARY KEY, generation INTEGER NOT NULL DEFAULT 1)");
      ignore (exec db "ALTER TABLE inflight ADD COLUMN generation INTEGER NOT NULL DEFAULT 1");
      ignore (exec db "CREATE TABLE IF NOT EXISTS activation_seq (message_id TEXT PRIMARY KEY, next_gen INTEGER NOT NULL)");
      ignore (close_db db); Ok ()
    | None ->
      (match exec db "INSERT INTO meta(key,value) VALUES('schema_version','1')" with
       | Error msg -> ignore (close_db db); Error (error "StorageUnavailable" msg)
       | Ok () ->
         ignore (exec db "INSERT OR IGNORE INTO meta(key,value) VALUES('dead_letters','0')");
         ignore (exec db "INSERT OR IGNORE INTO meta(key,value) VALUES('storage_errors','0')");
         close_db db;
         Ok ())

let last_claim = ref ("", "")
let last_claim_mu = Mutex.create ()

let reset_test_hooks () =
  with_hooks (fun () ->
    crash_point := None;
    force_write_error := None;
    force_write_sticky := false;
    ambiguous_commit := false;
    stall_ms := 0;
    max_page_count := None;
    force_inflight_delete_error := None)

let reset_ephemeral () =
  reset_test_hooks ();
  Mutex.lock last_claim_mu;
  last_claim := ("", "");
  Mutex.unlock last_claim_mu;
  reset_stmt_roots ()

let recover db =
  Mutex.lock last_claim_mu;
  last_claim := ("", "");
  Mutex.unlock last_claim_mu;
  ignore (exec db "CREATE TABLE IF NOT EXISTS inflight (message_id TEXT PRIMARY KEY, generation INTEGER NOT NULL DEFAULT 1)");
  ignore (exec db "ALTER TABLE inflight ADD COLUMN generation INTEGER NOT NULL DEFAULT 1");
  ignore (exec db "CREATE TABLE IF NOT EXISTS activation_seq (message_id TEXT PRIMARY KEY, next_gen INTEGER NOT NULL)");
  ignore (exec db "DELETE FROM inflight");
  ignore (exec db "UPDATE inbox SET status = 'ready', claim_owner = NULL WHERE status = 'claimed'")

let with_tx db ~crash_before ~crash_after f =
  match exec db "BEGIN IMMEDIATE" with
  | Error msg -> Error msg
  | Ok () ->
    (match get_stall_ms () with
     | n when n > 0 ->
       (try Eio_unix.sleep (float_of_int n /. 1000.)
        with _ -> Unix.sleepf (float_of_int n /. 1000.))
     | _ -> ());
    match f () with
    | Error e -> ignore (exec db "ROLLBACK"); Error e
    | Ok v ->
      check_crash crash_before;
      match exec db "COMMIT" with
      | Error msg -> ignore (exec db "ROLLBACK"); Error msg
      | Ok () ->
        check_crash crash_after;
        if with_hooks (fun () ->
          let v = !ambiguous_commit in
          if v then ambiguous_commit := false;
          v)
        then Error "commit_ambiguous"
        else Ok v

let bump_storage_error db =
  ignore (exec db "UPDATE meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'storage_errors'")

let next_seq db actor_type actor_id =
  with_stmt db
    "SELECT COALESCE(MAX(seq), 0) FROM inbox WHERE actor_type = ? AND actor_id = ?"
    (fun stmt ->
      bind_text stmt 1 actor_type;
      bind_text stmt 2 actor_id;
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> Int64.to_int (Sqlite3.column_int64 stmt 0) + 1
      | _ -> 1)

let insert_inbox db (envelope : envelope) ~attempt ~available_at =
  let addr = match envelope.actor_address with
    | Some a -> a
    | None -> { actor_type = "__well.step"; id = envelope.message_id }
  in
  let seq = next_seq db addr.actor_type addr.id in
  with_stmt db
    {|INSERT INTO inbox(message_id, execution_id, actor_type, actor_id, seq, envelope, status, attempt, available_at_ms)
      VALUES(?,?,?,?,?,?, 'ready', ?, ?)|}
    (fun stmt ->
      bind_text stmt 1 envelope.message_id;
      bind_text stmt 2 envelope.execution_id;
      bind_text stmt 3 addr.actor_type;
      bind_text stmt 4 addr.id;
      bind_int stmt 5 seq;
      bind_text stmt 6 (Yojson.Safe.to_string (envelope_to_json envelope));
      bind_int stmt 7 attempt;
      bind_i64 stmt 8 available_at;
      step_done stmt)

let insert_outbox db (envelope : envelope) ~seq =
  with_stmt db
    "INSERT INTO outbox(message_id, execution_id, envelope, delivered, seq) VALUES(?,?,?,0,?)"
    (fun stmt ->
      bind_text stmt 1 envelope.message_id;
      bind_text stmt 2 envelope.execution_id;
      bind_text stmt 3 (Yojson.Safe.to_string (envelope_to_json envelope));
      bind_int stmt 4 seq;
      step_done stmt)

let find_request db request_id =
  with_stmt db
    "SELECT execution_id, admission_jcs, status FROM executions WHERE request_id = ?"
    (fun stmt ->
      bind_text stmt 1 request_id;
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        Some (Sqlite3.column_text stmt 0, Sqlite3.column_text stmt 1, Sqlite3.column_text stmt 2)
      | _ -> None)

let count_running db =
  with_stmt db
    "SELECT COUNT(*) FROM executions WHERE status IN ('running','blocked')"
    (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> Int64.to_int (Sqlite3.column_int64 stmt 0)
      | _ -> 0)

let count_pending db =
  with_stmt db
    "SELECT (SELECT COUNT(*) FROM inbox WHERE status IN ('ready','claimed')) + (SELECT COUNT(*) FROM outbox WHERE delivered = 0)"
    (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> Int64.to_int (Sqlite3.column_int64 stmt 0)
      | _ -> 0)

let insert_execution db ~execution_id ~request_id ~admission_jcs ~workflow ~workflow_hash
    ~timeout_ms ~deadline_ms ~now =
  with_stmt db
    {|INSERT INTO executions(execution_id, request_id, admission_jcs, workflow, workflow_hash,
        status, timeout_ms, deadline_ms, created_at_ms, pending_messages, tokens, deliveries)
      VALUES(?,?,?,?,?,'running',?,?,?,1,1,1)|}
    (fun stmt ->
      bind_text stmt 1 execution_id;
      bind_text stmt 2 request_id;
      bind_text stmt 3 admission_jcs;
      bind_text stmt 4 workflow;
      bind_text stmt 5 workflow_hash;
      bind_int stmt 6 timeout_ms;
      bind_i64 stmt 7 deadline_ms;
      bind_i64 stmt 8 now;
      step_done stmt)

type claim = {
  message_id : string;
  execution_id : string;
  actor : actor_id;
  envelope : envelope;
  attempt : int;
  inflight_gen : int;
  state_blob : string option;
  state_version : int option;
  state_revision : int;
}

let load_state db actor =
  with_stmt db
    "SELECT blob, state_version, revision FROM actor_state WHERE actor_type = ? AND actor_id = ?"
    (fun stmt ->
      bind_text stmt 1 actor.actor_type;
      bind_text stmt 2 actor.id;
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        Some (Sqlite3.column_text stmt 0,
              Int64.to_int (Sqlite3.column_int64 stmt 1),
              Int64.to_int (Sqlite3.column_int64 stmt 2))
      | _ -> None)

let rec claim_turn db ~owner ~now =
  let last_type, last_id =
    Mutex.lock last_claim_mu;
    let v = !last_claim in
    Mutex.unlock last_claim_mu;
    v
  in
  let row =
    with_stmt db
      {|SELECT actor_type, actor_id, message_id, execution_id, envelope, attempt
        FROM inbox i
        WHERE status = 'ready' AND available_at_ms <= ?
          AND EXISTS (
            SELECT 1 FROM executions e
            WHERE e.execution_id = i.execution_id AND e.status = 'running')
          AND NOT EXISTS (
            SELECT 1 FROM inbox c
            WHERE c.actor_type = i.actor_type AND c.actor_id = i.actor_id AND c.status = 'claimed')
          AND seq = (
            SELECT MIN(seq) FROM inbox s
            WHERE s.actor_type = i.actor_type AND s.actor_id = i.actor_id
              AND s.status IN ('ready','claimed'))
        ORDER BY
          CASE
            WHEN i.actor_type > ? THEN 0
            WHEN i.actor_type = ? AND i.actor_id > ? THEN 0
            ELSE 1
          END,
          i.actor_type, i.actor_id
        LIMIT 1|}
      (fun stmt ->
        bind_i64 stmt 1 now;
        bind_text stmt 2 last_type;
        bind_text stmt 3 last_type;
        bind_text stmt 4 last_id;
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          Some (
            Sqlite3.column_text stmt 0,
            Sqlite3.column_text stmt 1,
            Sqlite3.column_text stmt 2,
            Sqlite3.column_text stmt 3,
            Sqlite3.column_text stmt 4,
            Int64.to_int (Sqlite3.column_int64 stmt 5)
          )
        | _ -> None)
  in
  match row with
  | None -> Ok None
  | Some (at, aid, mid, eid, env, attempt) ->
    match with_stmt db
      "UPDATE inbox SET status = 'claimed', claim_owner = ? WHERE message_id = ? AND status = 'ready'"
      (fun stmt ->
        bind_text stmt 1 owner;
        bind_text stmt 2 mid;
        step_done stmt)
    with
    | Error e -> Error e
    | Ok () when Sqlite3.changes db <> 1 -> claim_turn db ~owner ~now
    | Ok () ->
      match with_stmt db
        {|INSERT INTO activation_seq(message_id, next_gen) VALUES (?, 1)
          ON CONFLICT(message_id) DO UPDATE SET next_gen = next_gen + 1
          RETURNING next_gen|}
        (fun stmt ->
          bind_text stmt 1 mid;
          match Sqlite3.step stmt with
          | Sqlite3.Rc.ROW -> Ok (Int64.to_int (Sqlite3.column_int64 stmt 0))
          | rc -> Error (Sqlite3.Rc.to_string rc))
      with
      | Error e -> Error e
      | Ok gen ->
      match with_stmt db
        {|INSERT INTO inflight(message_id, generation) VALUES (?, ?)
          ON CONFLICT(message_id) DO UPDATE SET generation = excluded.generation|}
        (fun stmt ->
          bind_text stmt 1 mid;
          bind_int stmt 2 gen;
          step_done stmt)
      with
      | Error e -> Error e
      | Ok () ->
      Mutex.lock last_claim_mu;
      last_claim := (at, aid);
      Mutex.unlock last_claim_mu;
      let actor = { actor_type = at; id = aid } in
      let envelope = envelope_of_json (Yojson.Safe.from_string env) in
      let st = load_state db actor in
      Ok (Some {
        message_id = mid;
        execution_id = eid;
        actor;
        envelope;
        attempt;
        inflight_gen = gen;
        state_blob = Option.map (fun (b, _, _) -> b) st;
        state_version = Option.map (fun (_, v, _) -> v) st;
        state_revision = Option.value ~default:0 (Option.map (fun (_, _, r) -> r) st);
      })

let upsert_state db actor blob version revision =
  with_stmt db
    {|INSERT INTO actor_state(actor_type, actor_id, blob, state_version, revision)
      VALUES(?,?,?,?,?)
      ON CONFLICT(actor_type, actor_id) DO UPDATE SET
        blob = excluded.blob,
        state_version = excluded.state_version,
        revision = excluded.revision|}
    (fun stmt ->
      bind_text stmt 1 actor.actor_type;
      bind_text stmt 2 actor.id;
      bind_text stmt 3 blob;
      bind_int stmt 4 version;
      bind_int stmt 5 revision;
      step_done stmt)

let mark_done db message_id =
  with_stmt db "UPDATE inbox SET status = 'done', claim_owner = NULL WHERE message_id = ?"
    (fun stmt -> bind_text stmt 1 message_id; step_done stmt)

let reschedule db message_id ~attempt ~available_at =
  with_stmt db
    "UPDATE inbox SET status = 'ready', claim_owner = NULL, attempt = ?, available_at_ms = ? WHERE message_id = ?"
    (fun stmt ->
      bind_int stmt 1 attempt;
      bind_i64 stmt 2 available_at;
      bind_text stmt 3 message_id;
      step_done stmt)

let release_claim db message_id =
  with_stmt db
    "UPDATE inbox SET status = 'ready', claim_owner = NULL WHERE message_id = ? AND status = 'claimed'"
    (fun stmt -> bind_text stmt 1 message_id; step_done stmt)

let clear_inflight db message_id generation =
  match with_hooks (fun () -> !force_inflight_delete_error) with
  | Some msg -> Error msg
  | None ->
    with_stmt db "DELETE FROM inflight WHERE message_id = ? AND generation = ?"
      (fun stmt ->
        bind_text stmt 1 message_id;
        bind_int stmt 2 generation;
        step_done_raw stmt)

let retire_activation db ~message_id ~generation =
  match with_hooks (fun () -> !force_inflight_delete_error) with
  | Some msg -> Error msg
  | None ->
    match exec db "BEGIN IMMEDIATE" with
    | Error e -> Error e
    | Ok () ->
      let body =
        match with_stmt db
          "DELETE FROM inflight WHERE message_id = ? AND generation = ?"
          (fun stmt ->
            bind_text stmt 1 message_id;
            bind_int stmt 2 generation;
            step_done_raw stmt)
        with
        | Error e -> Error e
        | Ok () ->
          with_stmt db
            {|UPDATE inbox SET status = 'ready', claim_owner = NULL
              WHERE message_id = ? AND status = 'claimed'
                AND NOT EXISTS (
                  SELECT 1 FROM inflight WHERE message_id = ?)|}
            (fun stmt ->
              bind_text stmt 1 message_id;
              bind_text stmt 2 message_id;
              step_done_raw stmt)
      in
      match body with
      | Error e -> ignore (exec db "ROLLBACK"); Error e
      | Ok () ->
        match exec db "COMMIT" with
        | Error e -> ignore (exec db "ROLLBACK"); Error e
        | Ok () -> Ok ()

let inflight_generation db message_id =
  with_stmt db "SELECT generation FROM inflight WHERE message_id = ?" (fun stmt ->
    bind_text stmt 1 message_id;
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Some (Int64.to_int (Sqlite3.column_int64 stmt 0))
    | _ -> None)

let unstick_message_ids db ids =
  match ids with
  | [] -> Ok ()
  | ids ->
    let marks = String.concat "," (List.map (fun _ -> "?") ids) in
    let sql =
      "UPDATE inbox SET status = 'ready', claim_owner = NULL WHERE status = 'claimed' AND message_id IN ("
      ^ marks ^ ") AND message_id NOT IN (SELECT message_id FROM inflight)"
    in
    with_stmt db sql (fun stmt ->
      List.iteri (fun i id -> bind_text stmt (i + 1) id) ids;
      step_done stmt)

let insert_error db execution_id diagnostic =
  with_stmt db "INSERT INTO errors(execution_id, diagnostic) VALUES(?,?)"
    (fun stmt ->
      bind_text stmt 1 execution_id;
      bind_text stmt 2 diagnostic;
      step_done stmt)

let insert_dead db (envelope : envelope) diagnostic =
  with_stmt db "INSERT OR REPLACE INTO dead_letters(message_id, envelope, diagnostic) VALUES(?,?,?)"
    (fun stmt ->
      bind_text stmt 1 envelope.message_id;
      bind_text stmt 2 (Yojson.Safe.to_string (envelope_to_json envelope));
      bind_text stmt 3 diagnostic;
      step_done stmt)
  |> function
  | Ok () -> ignore (exec db "UPDATE meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'dead_letters'"); Ok ()
  | Error e -> Error e

let set_status db execution_id status diagnostic =
  with_stmt db "UPDATE executions SET status = ?, diagnostic = ? WHERE execution_id = ?"
    (fun stmt ->
      bind_text stmt 1 status;
      (match diagnostic with None -> bind_null stmt 2 | Some s -> bind_text stmt 2 s);
      bind_text stmt 3 execution_id;
      step_done stmt)

let set_status_if db execution_id ~allowed status diagnostic =
  let ins = String.concat "," (List.map (fun _ -> "?") allowed) in
  let sql =
    "UPDATE executions SET status = ?, diagnostic = ? WHERE execution_id = ? AND status IN ("
    ^ ins ^ ")"
  in
  with_stmt db sql (fun stmt ->
    bind_text stmt 1 status;
    (match diagnostic with None -> bind_null stmt 2 | Some s -> bind_text stmt 2 s);
    bind_text stmt 3 execution_id;
    List.iteri (fun i s -> bind_text stmt (4 + i) s) allowed;
    match step_done stmt with
    | Error e -> Error e
    | Ok () ->
      if Sqlite3.changes db = 1 then Ok () else Error "no_row")

let add_output db (o : output) execution_id =
  let path = String.concat "." (List.map string_of_int o.path) in
  with_stmt db
    "INSERT OR REPLACE INTO outputs(execution_id, path, payload_type, schema_hash, payload) VALUES(?,?,?,?,?)"
    (fun stmt ->
      bind_text stmt 1 execution_id;
      bind_text stmt 2 path;
      bind_text stmt 3 o.payload_type;
      bind_text stmt 4 o.schema_hash;
      bind_text stmt 5 (Yojson.Safe.to_string o.payload);
      step_done stmt)

let insert_group db ~group_id ~execution_id ~join_node ~item_type ~batch_type
    ~expected ~deadline_ms ~next_node ~parent_groups ~branch_path ~source_message_id =
  with_stmt db
    {|INSERT INTO groups(group_id, execution_id, join_node, item_type, batch_type, expected, received,
        deadline_ms, closed, next_node, parent_groups, branch_path, source_message_id)
      VALUES(?,?,?,?,?,?, '[]', ?, 0, ?, ?, ?, ?)|}
    (fun stmt ->
      bind_text stmt 1 group_id;
      bind_text stmt 2 execution_id;
      bind_text stmt 3 join_node;
      bind_text stmt 4 item_type;
      bind_text stmt 5 batch_type;
      bind_text stmt 6 expected;
      bind_i64 stmt 7 deadline_ms;
      bind_text stmt 8 next_node;
      bind_text stmt 9 parent_groups;
      bind_text stmt 10 branch_path;
      bind_text stmt 11 source_message_id;
      step_done stmt)

type group_row = {
  execution_id : string;
  join_node : string;
  item_type : string;
  batch_type : string;
  expected : string;
  received : string;
  deadline_ms : int64;
  closed : bool;
  next_node : string;
  parent_groups : string;
  branch_path : string;
  source_message_id : string;
}

let load_group db group_id =
  with_stmt db
    {|SELECT execution_id, join_node, item_type, batch_type, expected, received, deadline_ms, closed,
             next_node, parent_groups, branch_path, source_message_id
      FROM groups WHERE group_id = ?|}
    (fun stmt ->
      bind_text stmt 1 group_id;
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        Some {
          execution_id = Sqlite3.column_text stmt 0;
          join_node = Sqlite3.column_text stmt 1;
          item_type = Sqlite3.column_text stmt 2;
          batch_type = Sqlite3.column_text stmt 3;
          expected = Sqlite3.column_text stmt 4;
          received = Sqlite3.column_text stmt 5;
          deadline_ms = Sqlite3.column_int64 stmt 6;
          closed = Int64.to_int (Sqlite3.column_int64 stmt 7) <> 0;
          next_node = Sqlite3.column_text stmt 8;
          parent_groups = Sqlite3.column_text stmt 9;
          branch_path = Sqlite3.column_text stmt 10;
          source_message_id = Sqlite3.column_text stmt 11;
        }
      | _ -> None)

let save_group_received db group_id received closed =
  with_stmt db "UPDATE groups SET received = ?, closed = ? WHERE group_id = ?"
    (fun stmt ->
      bind_text stmt 1 received;
      bind_int stmt 2 (if closed then 1 else 0);
      bind_text stmt 3 group_id;
      step_done stmt)

let insert_timer db ~timer_id ~execution_id ~kind ~fire_at ~payload =
  with_stmt db
    "INSERT INTO timers(timer_id, execution_id, kind, fire_at_ms, payload, invalidated, delivered) VALUES(?,?,?,?,?,0,0)"
    (fun stmt ->
      bind_text stmt 1 timer_id;
      bind_text stmt 2 execution_id;
      bind_text stmt 3 kind;
      bind_i64 stmt 4 fire_at;
      bind_text stmt 5 payload;
      step_done stmt)

let invalidate_timer db timer_id =
  with_stmt db "UPDATE timers SET invalidated = 1 WHERE timer_id = ?"
    (fun stmt -> bind_text stmt 1 timer_id; step_done stmt)

let invalidate_execution_timers db execution_id =
  with_stmt db "UPDATE timers SET invalidated = 1 WHERE execution_id = ? AND delivered = 0"
    (fun stmt -> bind_text stmt 1 execution_id; step_done stmt)

let due_timers db now =
  let acc = ref [] in
  ignore (with_stmt db
    {|SELECT timer_id, execution_id, kind, payload FROM timers
      WHERE invalidated = 0 AND delivered = 0 AND fire_at_ms <= ?|}
    (fun stmt ->
      bind_i64 stmt 1 now;
      while Sqlite3.step stmt = Sqlite3.Rc.ROW do
        acc := (Sqlite3.column_text stmt 0,
                Sqlite3.column_text stmt 1,
                Sqlite3.column_text stmt 2,
                Sqlite3.column_text stmt 3) :: !acc
      done));
  List.rev !acc

let mark_timer_delivered db timer_id =
  with_stmt db "UPDATE timers SET delivered = 1 WHERE timer_id = ?"
    (fun stmt -> bind_text stmt 1 timer_id; step_done stmt)

let undelivered_outbox db =
  let acc = ref [] in
  ignore (with_stmt db
    "SELECT message_id, envelope FROM outbox WHERE delivered = 0 ORDER BY seq"
    (fun stmt ->
      while Sqlite3.step stmt = Sqlite3.Rc.ROW do
        acc := (Sqlite3.column_text stmt 0, Sqlite3.column_text stmt 1) :: !acc
      done));
  List.rev !acc

let mark_outbox_delivered db message_id =
  with_stmt db "UPDATE outbox SET delivered = 1 WHERE message_id = ?"
    (fun stmt -> bind_text stmt 1 message_id; step_done stmt)

let inbox_has db message_id =
  with_stmt db "SELECT 1 FROM inbox WHERE message_id = ?" (fun stmt ->
    bind_text stmt 1 message_id;
    Sqlite3.step stmt = Sqlite3.Rc.ROW)

let load_execution db execution_id =
  with_stmt db
    {|SELECT request_id, status, diagnostic, pending_messages, open_groups, deadline_ms, workflow
      FROM executions WHERE execution_id = ?|}
    (fun stmt ->
      bind_text stmt 1 execution_id;
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        Some (Sqlite3.column_text stmt 0,
              Sqlite3.column_text stmt 1,
              (match Sqlite3.column stmt 2 with Sqlite3.Data.TEXT s -> Some s | _ -> None),
              Int64.to_int (Sqlite3.column_int64 stmt 3),
              Int64.to_int (Sqlite3.column_int64 stmt 4),
              Sqlite3.column_int64 stmt 5,
              Sqlite3.column_text stmt 6)
      | _ -> None)

let load_outputs db execution_id =
  let acc = ref [] in
  ignore (with_stmt db
    "SELECT path, payload_type, schema_hash, payload FROM outputs WHERE execution_id = ?"
    (fun stmt ->
      bind_text stmt 1 execution_id;
      while Sqlite3.step stmt = Sqlite3.Rc.ROW do
        let path =
          Sqlite3.column_text stmt 0
          |> String.split_on_char '.'
          |> List.filter_map (fun s -> try Some (int_of_string s) with _ -> None)
        in
        acc := {
          path;
          payload_type = Sqlite3.column_text stmt 1;
          schema_hash = Sqlite3.column_text stmt 2;
          payload = Yojson.Safe.from_string (Sqlite3.column_text stmt 3);
        } :: !acc
      done));
  List.sort (fun (a : output) (b : output) -> Stdlib.compare a.path b.path) !acc

let load_errors db execution_id =
  let acc = ref [] in
  ignore (with_stmt db
    "SELECT diagnostic FROM errors WHERE execution_id = ? ORDER BY id"
    (fun stmt ->
      bind_text stmt 1 execution_id;
      while Sqlite3.step stmt = Sqlite3.Rc.ROW do
        acc := Sqlite3.column_text stmt 0 :: !acc
      done));
  List.rev !acc

let metrics db =
  let gauge sql =
    with_stmt db sql (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> Int64.to_int (Sqlite3.column_int64 stmt 0)
      | _ -> 0)
  in
  let meta key =
    with_stmt db "SELECT value FROM meta WHERE key = ?" (fun stmt ->
      bind_text stmt 1 key;
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> (try int_of_string (Sqlite3.column_text stmt 0) with _ -> 0)
      | _ -> 0)
  in
  `Assoc [
    "active_activations", `Int (gauge "SELECT COUNT(*) FROM inbox WHERE status = 'claimed'");
    "ready_actors", `Int (gauge "SELECT COUNT(DISTINCT actor_type || '/' || actor_id) FROM inbox WHERE status = 'ready'");
    "pending_inbox", `Int (gauge "SELECT COUNT(*) FROM inbox WHERE status IN ('ready','claimed')");
    "pending_outbox", `Int (gauge "SELECT COUNT(*) FROM outbox WHERE delivered = 0");
    "open_joins", `Int (gauge "SELECT COUNT(*) FROM groups WHERE closed = 0");
    "running_executions", `Int (gauge "SELECT COUNT(*) FROM executions WHERE status = 'running'");
    "blocked_executions", `Int (gauge "SELECT COUNT(*) FROM executions WHERE status = 'blocked'");
    "dead_letters", `Int (meta "dead_letters");
    "storage_errors", `Int (meta "storage_errors");
  ]

let discard_execution_inbox db execution_id =
  with_stmt db
    "UPDATE inbox SET status = 'discarded', claim_owner = NULL WHERE execution_id = ? AND status = 'ready'"
    (fun stmt -> bind_text stmt 1 execution_id; step_done stmt)

let bump_open_groups db execution_id delta =
  with_stmt db "UPDATE executions SET open_groups = open_groups + ? WHERE execution_id = ?"
    (fun stmt -> bind_int stmt 1 delta; bind_text stmt 2 execution_id; step_done stmt)

let set_pending db execution_id n =
  with_stmt db "UPDATE executions SET pending_messages = ? WHERE execution_id = ?"
    (fun stmt -> bind_int stmt 1 n; bind_text stmt 2 execution_id; step_done stmt)

let add_deliveries db execution_id n =
  with_stmt db "UPDATE executions SET deliveries = deliveries + ? WHERE execution_id = ?"
    (fun stmt -> bind_int stmt 1 n; bind_text stmt 2 execution_id; step_done stmt)

let deliveries_of db execution_id =
  with_stmt db "SELECT deliveries FROM executions WHERE execution_id = ?" (fun stmt ->
    bind_text stmt 1 execution_id;
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Int64.to_int (Sqlite3.column_int64 stmt 0)
    | _ -> 0)

let pending_of db execution_id =
  with_stmt db
    "SELECT COUNT(*) FROM inbox WHERE execution_id = ? AND status IN ('ready','claimed')"
    (fun stmt ->
      bind_text stmt 1 execution_id;
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> Int64.to_int (Sqlite3.column_int64 stmt 0)
      | _ -> 0)

let inbox_status db message_id =
  with_stmt db "SELECT status FROM inbox WHERE message_id = ?" (fun stmt ->
    bind_text stmt 1 message_id;
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Some (Sqlite3.column_text stmt 0)
    | _ -> None)

let recover_if_claimed db message_id =
  match inbox_status db message_id with
  | Some "done" | Some "discarded" -> Ok `Committed
  | Some "ready" -> Ok `Ready
  | Some "claimed" ->
    (match release_claim db message_id with
     | Ok () -> Ok `Released
     | Error e -> Error e)
  | _ -> Ok `Missing

type claim_check =
  | Claim_ready
  | Claim_already_committed
  | Claim_discard_after_failure
  | Claim_lost

let recheck_claim db ~owner (claim : claim) =
  let inbox =
    with_stmt db "SELECT status, claim_owner FROM inbox WHERE message_id = ?" (fun stmt ->
      bind_text stmt 1 claim.message_id;
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        Some (Sqlite3.column_text stmt 0,
              (match Sqlite3.column stmt 1 with Sqlite3.Data.TEXT s -> Some s | _ -> None))
      | _ -> None)
  in
  match inbox with
  | Some ("done", _) -> Claim_already_committed
  | Some ("discarded", _) ->
    (match load_execution db claim.execution_id with
     | Some (_, "failed", _, _, _, _, _) | Some (_, "completed", _, _, _, _, _) ->
       Claim_discard_after_failure
     | _ -> Claim_already_committed)
  | Some ("claimed", Some o) when o = owner ->
    (match load_execution db claim.execution_id with
     | Some (_, "running", _, _, _, _, _) | Some (_, "blocked", _, _, _, _, _) ->
       let rev =
         match load_state db claim.actor with
         | Some (_, _, r) -> r
         | None -> 0
       in
       if rev <> claim.state_revision then Claim_lost
       else Claim_ready
     | Some (_, "failed", _, _, _, _, _) | Some (_, "completed", _, _, _, _, _) ->
       Claim_discard_after_failure
     | _ -> Claim_lost)
  | _ -> Claim_lost

let discard_terminal_inbox db =
  with_stmt db
    {|UPDATE inbox SET status = 'discarded', claim_owner = NULL
      WHERE status = 'ready'
        AND execution_id IN (
          SELECT execution_id FROM executions WHERE status IN ('failed','completed'))|}
    (fun stmt -> step_done stmt)

let load_execution_envelopes db execution_id =
  let acc = ref [] in
  ignore (with_stmt db
    "SELECT envelope, actor_type, actor_id FROM inbox WHERE execution_id = ? AND status IN ('ready','claimed')"
    (fun stmt ->
      bind_text stmt 1 execution_id;
      while Sqlite3.step stmt = Sqlite3.Rc.ROW do
        let env = envelope_of_json (Yojson.Safe.from_string (Sqlite3.column_text stmt 0)) in
        let actor = { actor_type = Sqlite3.column_text stmt 1; id = Sqlite3.column_text stmt 2 } in
        acc := (env, actor) :: !acc
      done));
  List.rev !acc

let execution_is_blocked db execution_id =
  match load_execution db execution_id with
  | Some (_, "blocked", _, _, _, _, _) -> true
  | _ -> false

let ready_count db execution_id =
  with_stmt db
    "SELECT COUNT(*) FROM inbox WHERE execution_id = ? AND status = 'ready'"
    (fun stmt ->
      bind_text stmt 1 execution_id;
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> Int64.to_int (Sqlite3.column_int64 stmt 0)
      | _ -> 0)
