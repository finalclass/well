(* Session store — SQLite with WAL, thread-safe via Mutex *)

let db : Sqlite3.db option ref = ref None
let mu = Mutex.create ()

let get_db () =
  match !db with
  | Some d -> d
  | None ->
      let path = "data/sessions.sqlite" in
      (try Unix.mkdir "data" 0o755
       with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      let d = Sqlite3.db_open path in
      let _ = Sqlite3.exec d "PRAGMA journal_mode=WAL" in
      let _ = Sqlite3.exec d "PRAGMA synchronous=NORMAL" in
      let _ =
        Sqlite3.exec d
          {|CREATE TABLE IF NOT EXISTS sessions (
              session_id TEXT NOT NULL,
              key TEXT NOT NULL,
              value TEXT NOT NULL,
              updated_at REAL NOT NULL,
              PRIMARY KEY (session_id, key)
            )|}
      in
      db := Some d;
      d

let with_lock f =
  Mutex.lock mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock mu) f

let get ~session_id ~key =
  with_lock @@ fun () ->
  let db = get_db () in
  let sql = "SELECT value FROM sessions WHERE session_id = ? AND key = ?" in
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
  let db = get_db () in
  let sql =
    {|INSERT OR REPLACE INTO sessions (session_id, key, value, updated_at)
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
  let db = get_db () in
  let sql = "DELETE FROM sessions WHERE session_id = ? AND key = ?" in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT session_id) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT key) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let clear ~session_id =
  with_lock @@ fun () ->
  let db = get_db () in
  let sql = "DELETE FROM sessions WHERE session_id = ?" in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT session_id) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let get_all_with_prefix ~session_id ~prefix =
  with_lock @@ fun () ->
  let db = get_db () in
  let sql =
    "SELECT key, value FROM sessions WHERE session_id = ? AND key LIKE ?"
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
  let db = get_db () in
  let sql = "DELETE FROM sessions WHERE session_id = ? AND key LIKE ?" in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT session_id) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT (prefix ^ "%")) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let copy_and_delete ~old_session_id ~new_session_id =
  with_lock @@ fun () ->
  let db = get_db () in
  let sql = "INSERT INTO sessions (session_id, key, value, updated_at) \
             SELECT ?, key, value, ? FROM sessions WHERE session_id = ?" in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT new_session_id) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.FLOAT (Unix.gettimeofday ())) in
  let _ = Sqlite3.bind stmt 3 (Sqlite3.Data.TEXT old_session_id) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  let del = Sqlite3.prepare db "DELETE FROM sessions WHERE session_id = ?" in
  let _ = Sqlite3.bind del 1 (Sqlite3.Data.TEXT old_session_id) in
  let _ = Sqlite3.step del in
  let _ = Sqlite3.finalize del in
  ()

let check () =
  with_lock @@ fun () ->
  try
    let db = get_db () in
    let stmt = Sqlite3.prepare db "SELECT 1" in
    let ok = Sqlite3.step stmt = Sqlite3.Rc.ROW in
    let _ = Sqlite3.finalize stmt in
    ok
  with _ -> false

let cleanup ?(max_age_days = 30) () =
  with_lock @@ fun () ->
  let db = get_db () in
  let cutoff =
    Unix.gettimeofday () -. (float_of_int max_age_days *. 86400.0)
  in
  let sql = "DELETE FROM sessions WHERE updated_at < ?" in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.FLOAT cutoff) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let close () =
  with_lock @@ fun () ->
  match !db with
  | Some d -> ignore (Sqlite3.db_close d); db := None
  | None -> ()
