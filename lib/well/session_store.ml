(* Session store — uses shared well.sqlite, thread-safe via Mutex *)

let mu = Mutex.create ()
let _tables_created = Atomic.make false

let ensure_table () =
  if not (Atomic.get _tables_created) then begin
    let db = Db.well_db () in
    let _ =
      Sqlite3.exec db
        {|CREATE TABLE IF NOT EXISTS _well_sessions (
            session_id TEXT NOT NULL,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (session_id, key)
          )|}
    in
    Atomic.set _tables_created true
  end

let with_lock f =
  Mutex.lock mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock mu) f

let get ~session_id ~key =
  with_lock @@ fun () ->
  ensure_table ();
  let db = Db.well_db () in
  let sql = "SELECT value FROM _well_sessions WHERE session_id = ? AND key = ?" in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT session_id) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT key) in
  let result =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Some (Sqlite3.column_text stmt 0)
    | _ -> None
  in
  let _ = Sqlite3.finalize stmt in
  result

let set ~session_id ~key ~value =
  with_lock @@ fun () ->
  ensure_table ();
  let db = Db.well_db () in
  let sql =
    {|INSERT OR REPLACE INTO _well_sessions (session_id, key, value, updated_at)
      VALUES (?, ?, ?, ?)|}
  in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT session_id) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT key) in
  let _ = Sqlite3.bind stmt 3 (Sqlite3.Data.TEXT value) in
  let _ = Sqlite3.bind stmt 4 (Sqlite3.Data.FLOAT (Unix.gettimeofday ())) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let delete ~session_id ~key =
  with_lock @@ fun () ->
  ensure_table ();
  let db = Db.well_db () in
  let sql = "DELETE FROM _well_sessions WHERE session_id = ? AND key = ?" in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT session_id) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT key) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let clear ~session_id =
  with_lock @@ fun () ->
  ensure_table ();
  let db = Db.well_db () in
  let sql = "DELETE FROM _well_sessions WHERE session_id = ?" in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT session_id) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let get_all_with_prefix ~session_id ~prefix =
  with_lock @@ fun () ->
  ensure_table ();
  let db = Db.well_db () in
  let sql =
    "SELECT key, value FROM _well_sessions WHERE session_id = ? AND key LIKE ?"
  in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT session_id) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT (prefix ^ "%")) in
  let results = ref [] in
  while Sqlite3.step stmt = Sqlite3.Rc.ROW do
    let key = Sqlite3.column_text stmt 0 in
    let value = Sqlite3.column_text stmt 1 in
    results := (key, value) :: !results
  done;
  let _ = Sqlite3.finalize stmt in
  List.rev !results

let delete_all_with_prefix ~session_id ~prefix =
  with_lock @@ fun () ->
  ensure_table ();
  let db = Db.well_db () in
  let sql = "DELETE FROM _well_sessions WHERE session_id = ? AND key LIKE ?" in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT session_id) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT (prefix ^ "%")) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let copy_and_delete ~old_session_id ~new_session_id =
  with_lock @@ fun () ->
  ensure_table ();
  let db = Db.well_db () in
  let sql = "INSERT INTO _well_sessions (session_id, key, value, updated_at) \
             SELECT ?, key, value, ? FROM _well_sessions WHERE session_id = ?" in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT new_session_id) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.FLOAT (Unix.gettimeofday ())) in
  let _ = Sqlite3.bind stmt 3 (Sqlite3.Data.TEXT old_session_id) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  let del = Sqlite3.prepare db "DELETE FROM _well_sessions WHERE session_id = ?" in
  let _ = Sqlite3.bind del 1 (Sqlite3.Data.TEXT old_session_id) in
  let _ = Sqlite3.step del in
  let _ = Sqlite3.finalize del in
  ()

let check () =
  with_lock @@ fun () ->
  try
    ensure_table ();
    let db = Db.well_db () in
    let stmt = Sqlite3.prepare db "SELECT 1" in
    let ok = Sqlite3.step stmt = Sqlite3.Rc.ROW in
    let _ = Sqlite3.finalize stmt in
    ok
  with _ -> false

let cleanup ?(max_age_days = 30) () =
  with_lock @@ fun () ->
  ensure_table ();
  let db = Db.well_db () in
  let cutoff =
    Unix.gettimeofday () -. (float_of_int max_age_days *. 86400.0)
  in
  let sql = "DELETE FROM _well_sessions WHERE updated_at < ?" in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.FLOAT cutoff) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let close () =
  Atomic.set _tables_created false
