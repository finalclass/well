(* MessageBus — SQLite-backed persistent pub/sub with wildcard matching *)
(* IDesign Method: "message bus is merely a queued Pub/Sub" *)

(* ── Types ─────────────────────────────────────────────────────────── *)

type event = {
  id : int;
  channel : string;
  payload : Yojson.Safe.t;
  created_at : float;
}

(* ── SQLite — uses shared well.sqlite ─────────────────────────────── *)

let _tables_created = Atomic.make false

let ensure_tables db =
  if not (Atomic.get _tables_created) then begin
    let _ =
      Sqlite3.exec db
        {|CREATE TABLE IF NOT EXISTS _well_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            channel TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at REAL NOT NULL
          )|}
    in
    let _ =
      Sqlite3.exec db
        {|CREATE INDEX IF NOT EXISTS idx_well_events_channel
          ON _well_events(channel)|}
    in
    Atomic.set _tables_created true
  end

let init () = Db.with_well_db ensure_tables

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

(* ── Replay mode ─────────────────────────────────────────────────── *)

let replay_mode = ref false
let is_replaying () = !replay_mode

(* ── Subscriber registry ──────────────────────────────────────────── *)

let _mu = Mutex.create ()
let _next_id = ref 0

type subscriber = {
  pattern : string;
  callback : event -> unit;
  live_only : bool;
}

let subscribers : (int, subscriber) Hashtbl.t = Hashtbl.create 16

let subscribe ?(live_only = false) pattern cb =
  Mutex.lock _mu;
  let id = incr _next_id; !_next_id in
  Hashtbl.replace subscribers id { pattern; callback = cb; live_only };
  Mutex.unlock _mu;
  id

let unsubscribe id =
  Mutex.lock _mu;
  Hashtbl.remove subscribers id;
  Mutex.unlock _mu

(* ── Notify ────────────────────────────────────────────────────────── *)

let notify event =
  Mutex.lock _mu;
  let replaying = !replay_mode in
  let matching =
    Hashtbl.fold
      (fun _id sub acc ->
        if matches_pattern sub.pattern event.channel
           && not (sub.live_only && replaying)
        then sub.callback :: acc
        else acc)
      subscribers []
  in
  Mutex.unlock _mu;
  List.iter (fun cb -> (try cb event with _ -> ())) matching

(* ── Publish ───────────────────────────────────────────────────────── *)

let publish ?(ephemeral = false) channel payload =
  let now = Unix.gettimeofday () in
  let ephemeral = ephemeral || !replay_mode in
  if ephemeral then begin
    let event = { id = 0; channel; payload; created_at = now } in
    notify event;
    Telemetry.incr_bus_events ();
    0
  end else begin
    let id = Db.with_well_db (fun db ->
      ensure_tables db;
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
      id)
    in
    let event = { id; channel; payload; created_at = now } in
    notify event;
    Telemetry.incr_bus_events ();
    id
  end

(* ── Replay ────────────────────────────────────────────────────────── *)

let close () =
  Atomic.set _tables_created false

let replay ?(since_id = 0) pattern cb =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let sql =
    "SELECT id, channel, payload, created_at FROM _well_events \
     WHERE id > ? ORDER BY id ASC"
  in
  let stmt = Sqlite3.prepare db sql in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int since_id)) in
  replay_mode := true;
  Fun.protect ~finally:(fun () -> replay_mode := false) (fun () ->
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
    loop ())

(* ── Prune ────────────────────────────────────────────────────────── *)

let prune ~keep_since_id () =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
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

let subscribe_typed ?live_only t f =
  subscribe ?live_only t.t_channel (fun event ->
    match t.of_yojson event.payload with
    | Ok v -> f { id = event.id; value = v; created_at = event.created_at }
    | Error _ -> ())

let replay_typed ?(since_id = 0) t f =
  replay ~since_id t.t_channel (fun event ->
    match t.of_yojson event.payload with
    | Ok v -> f { id = event.id; value = v; created_at = event.created_at }
    | Error _ -> ())

(* ── Keyed topics (channel:key) ──────────────────────────────────── *)

let publish_keyed_typed ?(ephemeral = false) t ~key value =
  publish ~ephemeral (t.t_channel ^ ":" ^ key) (t.to_yojson value)

type 'a keyed_event = {
  key : string;
  event : 'a typed_event;
}

let subscribe_keyed_typed ?live_only t f =
  let pattern = t.t_channel ^ ":*" in
  let prefix_len = String.length t.t_channel + 1 in
  subscribe ?live_only pattern (fun event ->
    match t.of_yojson event.payload with
    | Ok v ->
      let key = String.sub event.channel prefix_len
                  (String.length event.channel - prefix_len) in
      f { key; event = { id = event.id; value = v; created_at = event.created_at } }
    | Error _ -> ())

(* ── Once (subscribe, fire once, auto-unsubscribe) ───────────────── *)

let once channel cb =
  let sub_id = ref 0 in
  sub_id := subscribe channel (fun event ->
    unsubscribe !sub_id;
    cb event);
  !sub_id
