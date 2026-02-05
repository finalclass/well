(* LiveView persistent storage — SQLite with WAL *)

let db : Sqlite3.db option ref = ref None

let get_db () =
  match !db with
  | Some d -> d
  | None ->
      let path = "data/liveview.sqlite" in
      (try Unix.mkdir "data" 0o755
       with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      let d = Sqlite3.db_open path in
      let _ = Sqlite3.exec d "PRAGMA journal_mode=WAL" in
      let _ = Sqlite3.exec d "PRAGMA synchronous=NORMAL" in
      let _ =
        Sqlite3.exec d
          {|CREATE TABLE IF NOT EXISTS liveview_state (
              user_id TEXT NOT NULL,
              topic TEXT NOT NULL,
              endpoint TEXT NOT NULL,
              model_json TEXT NOT NULL,
              updated_at REAL NOT NULL,
              PRIMARY KEY (user_id, topic)
            )|}
      in
      db := Some d;
      d

let save ~user_id ~topic ~endpoint ~model_json =
  let db = get_db () in
  let sql =
    {|INSERT OR REPLACE INTO liveview_state
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
  let db = get_db () in
  let sql =
    "SELECT endpoint, model_json FROM liveview_state \
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
  let db = get_db () in
  let sql =
    "DELETE FROM liveview_state WHERE user_id = ? AND topic = ?"
  in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT user_id) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT topic) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let cleanup ?(max_age_days = 30) () =
  let db = get_db () in
  let cutoff =
    Unix.gettimeofday () -. (float_of_int max_age_days *. 86400.0)
  in
  let sql = "DELETE FROM liveview_state WHERE updated_at < ?" in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.FLOAT cutoff) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()
