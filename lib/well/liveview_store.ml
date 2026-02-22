(* LiveView persistent storage — uses shared well.sqlite, thread-safe via Mutex *)

let mu = Mutex.create ()
let _tables_created = Atomic.make false

let ensure_table () =
  if not (Atomic.get _tables_created) then begin
    let db = Db.well_db () in
    let _ =
      Sqlite3.exec db
        {|CREATE TABLE IF NOT EXISTS _well_liveview_state (
            user_id TEXT NOT NULL,
            topic TEXT NOT NULL,
            endpoint TEXT NOT NULL,
            model_json TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (user_id, topic)
          )|}
    in
    Atomic.set _tables_created true
  end

let with_lock f =
  Mutex.lock mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock mu) f

let save ~user_id ~topic ~endpoint ~model_json =
  with_lock @@ fun () ->
  ensure_table ();
  let db = Db.well_db () in
  let sql =
    {|INSERT OR REPLACE INTO _well_liveview_state
      (user_id, topic, endpoint, model_json, updated_at)
      VALUES (?, ?, ?, ?, ?)|}
  in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT user_id) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT topic) in
  let _ = Sqlite3.bind stmt 3 (Sqlite3.Data.TEXT endpoint) in
  let _ =
    Sqlite3.bind stmt 4
      (Sqlite3.Data.TEXT (Yojson.Safe.to_string model_json))
  in
  let _ = Sqlite3.bind stmt 5 (Sqlite3.Data.FLOAT (Unix.gettimeofday ())) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let load ~user_id ~topic =
  with_lock @@ fun () ->
  ensure_table ();
  let db = Db.well_db () in
  let sql =
    "SELECT endpoint, model_json FROM _well_liveview_state \
     WHERE user_id = ? AND topic = ?"
  in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT user_id) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT topic) in
  match Sqlite3.step stmt with
  | Sqlite3.Rc.ROW ->
      let endpoint = Sqlite3.column_text stmt 0 in
      let model_json_str = Sqlite3.column_text stmt 1 in
      let _ = Sqlite3.finalize stmt in
      (try Some (endpoint, Yojson.Safe.from_string model_json_str)
       with _ -> None)
  | _ ->
      let _ = Sqlite3.finalize stmt in
      None

let delete ~user_id ~topic =
  with_lock @@ fun () ->
  ensure_table ();
  let db = Db.well_db () in
  let sql =
    "DELETE FROM _well_liveview_state WHERE user_id = ? AND topic = ?"
  in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT user_id) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT topic) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let cleanup ?(max_age_days = 30) () =
  with_lock @@ fun () ->
  ensure_table ();
  let db = Db.well_db () in
  let cutoff =
    Unix.gettimeofday () -. (float_of_int max_age_days *. 86400.0)
  in
  let sql = "DELETE FROM _well_liveview_state WHERE updated_at < ?" in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.FLOAT cutoff) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let close () =
  Atomic.set _tables_created false
