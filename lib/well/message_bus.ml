(* MessageBus — SQLite-backed persistent pub/sub with wildcard matching *)
(* IDesign Method: "message bus is merely a queued Pub/Sub" *)

(* ── Types ─────────────────────────────────────────────────────────── *)

type event = {
  id : int;
  channel : string;
  payload : Yojson.Safe.t;
  created_at : float;
}

(* ── SQLite singleton ──────────────────────────────────────────────── *)

let db : Sqlite3.db option ref = ref None

let get_db () =
  match !db with
  | Some d -> d
  | None ->
      (try Unix.mkdir "data" 0o755
       with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      let path = "data/events.sqlite" in
      let d = Sqlite3.db_open path in
      let _ = Sqlite3.exec d "PRAGMA journal_mode=WAL" in
      let _ = Sqlite3.exec d "PRAGMA synchronous=NORMAL" in
      let _ =
        Sqlite3.exec d
          {|CREATE TABLE IF NOT EXISTS _well_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              channel TEXT NOT NULL,
              payload TEXT NOT NULL,
              created_at REAL NOT NULL
            )|}
      in
      let _ =
        Sqlite3.exec d
          {|CREATE INDEX IF NOT EXISTS idx_well_events_channel
            ON _well_events(channel)|}
      in
      db := Some d;
      d

let init () = ignore (get_db ())

(* ── Wildcard matching ─────────────────────────────────────────────── *)

let matches_pattern pattern channel =
  let plen = String.length pattern in
  if plen = 0 then channel = ""
  else if pattern.[plen - 1] = '*' then
    let prefix = String.sub pattern 0 (plen - 1) in
    let prefix_len = String.length prefix in
    String.length channel >= prefix_len
    && String.sub channel 0 prefix_len = prefix
  else pattern = channel

(* ── Subscriber registry ──────────────────────────────────────────── *)

let _mu = Mutex.create ()
let _next_id = ref 0

(* id -> (pattern, callback) *)
let subscribers : (int, string * (event -> unit)) Hashtbl.t =
  Hashtbl.create 16

let subscribe pattern cb =
  Mutex.lock _mu;
  let id = incr _next_id; !_next_id in
  Hashtbl.replace subscribers id (pattern, cb);
  Mutex.unlock _mu;
  id

let unsubscribe id =
  Mutex.lock _mu;
  Hashtbl.remove subscribers id;
  Mutex.unlock _mu

(* ── Notify ────────────────────────────────────────────────────────── *)

let notify event =
  Mutex.lock _mu;
  let matching =
    Hashtbl.fold
      (fun _id (pattern, cb) acc ->
        if matches_pattern pattern event.channel then cb :: acc
        else acc)
      subscribers []
  in
  Mutex.unlock _mu;
  List.iter (fun cb -> (try cb event with _ -> ())) matching

(* ── Publish ───────────────────────────────────────────────────────── *)

let publish ?(ephemeral = false) channel payload =
  let now = Unix.gettimeofday () in
  if ephemeral then begin
    let event = { id = 0; channel; payload; created_at = now } in
    notify event;
    0
  end else begin
    let db = get_db () in
    let sql =
      "INSERT INTO _well_events (channel, payload, created_at) VALUES (?, ?, ?)"
    in
    let stmt = Sqlite3.prepare db sql in
    let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT channel) in
    let _ =
      Sqlite3.bind stmt 2
        (Sqlite3.Data.TEXT (Yojson.Safe.to_string payload))
    in
    let _ = Sqlite3.bind stmt 3 (Sqlite3.Data.FLOAT now) in
    let _ = Sqlite3.step stmt in
    let id = Int64.to_int (Sqlite3.last_insert_rowid db) in
    let _ = Sqlite3.finalize stmt in
    let event = { id; channel; payload; created_at = now } in
    notify event;
    id
  end

(* ── Replay ────────────────────────────────────────────────────────── *)

let close () =
  match !db with
  | Some d -> ignore (Sqlite3.db_close d); db := None
  | None -> ()

let replay ?(since_id = 0) pattern cb =
  let db = get_db () in
  let sql =
    "SELECT id, channel, payload, created_at FROM _well_events \
     WHERE id > ? ORDER BY id ASC"
  in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int since_id)) in
  let rec loop () =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
        let channel = Sqlite3.column_text stmt 1 in
        if matches_pattern pattern channel then begin
          let id = Int64.to_int (Sqlite3.column_int64 stmt 0) in
          let payload_str = Sqlite3.column_text stmt 2 in
          let payload =
            try Yojson.Safe.from_string payload_str
            with _ -> `Null
          in
          let created_at =
            match Sqlite3.column stmt 3 with
            | Sqlite3.Data.FLOAT f -> f
            | _ -> 0.0
          in
          let event = { id; channel; payload; created_at } in
          (try cb event with _ -> ())
        end;
        loop ()
    | _ ->
        let _ = Sqlite3.finalize stmt in
        ()
  in
  loop ()

(* ── Prune ────────────────────────────────────────────────────────── *)

let prune ~keep_since_id () =
  let db = get_db () in
  let sql = "DELETE FROM _well_events WHERE id <= ?" in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int keep_since_id)) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  Sqlite3.changes db

(* ── Typed topic descriptor ────────────────────────────────────────── *)

type 'a typed_event = {
  id : int;
  value : 'a;
  created_at : float;
}

type 'a topic = {
  t_channel : string;
  to_yojson : 'a -> Yojson.Safe.t;
  of_yojson : Yojson.Safe.t -> ('a, string) result;
}

let make_topic channel to_yojson of_yojson =
  { t_channel = channel; to_yojson; of_yojson }

let publish_typed ?(ephemeral = false) t value =
  publish ~ephemeral t.t_channel (t.to_yojson value)

let subscribe_typed t f =
  subscribe t.t_channel (fun event ->
    match t.of_yojson event.payload with
    | Ok v -> f { id = event.id; value = v; created_at = event.created_at }
    | Error _ -> ())

let replay_typed ?(since_id = 0) t f =
  replay ~since_id t.t_channel (fun event ->
    match t.of_yojson event.payload with
    | Ok v -> f { id = event.id; value = v; created_at = event.created_at }
    | Error _ -> ())
