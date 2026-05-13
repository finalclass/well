(** MessageBus — SQLite-backed persistent pub/sub with wildcard matching.

    Events are stored in [_well_events] table for replay and pruning.
    Supports typed topics, keyed topics, and ephemeral (in-memory only) events. *)

(* IDesign Method: "message bus is merely a queued Pub/Sub" *)

(* ── Types ─────────────────────────────────────────────────────────── *)

(** A raw event as stored in SQLite. *)
type event = {
  id : int;
  channel : string;
  payload : Yojson.Safe.t;
  created_at : float;
}

(* ── SQLite — uses shared well.sqlite ─────────────────────────────── *)

let ensure_tables, _reset_tables =
  Db.once_resettable (fun db ->
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
    ())

(** Initialize the events table in the framework database. Idempotent. *)
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

(** Returns [true] while a [replay] call is in progress. *)
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

(** Subscribe to events matching [pattern] (trailing [*] for wildcard).
    Returns a subscription id for [unsubscribe]. If [~live_only] is true,
    the callback is skipped during replay. *)
let subscribe ?(live_only = false) pattern cb =
  Mutex.lock _mu;
  let id = incr _next_id; !_next_id in
  Hashtbl.replace subscribers id { pattern; callback = cb; live_only };
  Mutex.unlock _mu;
  id

(** Remove a subscription by its id. *)
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

(** Publish an event to [channel] with JSON [payload]. Returns the event id.
    If [~ephemeral] is true, the event is broadcast to subscribers but not
    persisted to SQLite (returns 0). Forced ephemeral during replay. *)
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
      ignore
        (Db.exec db
           "INSERT INTO _well_events (channel, payload, created_at) VALUES (?, ?, ?)"
           [ Text channel; Text (Yojson.Safe.to_string payload); Float now ]);
      let id = Int64.to_int (Sqlite3.last_insert_rowid db) in
      id)
    in
    let event = { id; channel; payload; created_at = now } in
    notify event;
    Telemetry.incr_bus_events ();
    id
  end

(* ── Replay ────────────────────────────────────────────────────────── *)

(** Reset internal state. Called during shutdown. *)
let close () =
  _reset_tables ()

(** Replay persisted events from SQLite matching [pattern], starting after
    [since_id]. Sets [replay_mode] during execution. *)
let replay ?(since_id = 0) pattern cb =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let sql =
    "SELECT id, channel, payload, created_at FROM _well_events \
     WHERE id > ? ORDER BY id ASC"
  in
  replay_mode := true;
  Fun.protect ~finally:(fun () -> replay_mode := false) (fun () ->
    ignore
      (Db.query db sql [ Int since_id ] (fun row ->
         let channel = row.text 1 in
         if matches_pattern pattern channel then begin
           let payload =
             try Yojson.Safe.from_string (row.text 2)
             with _ -> `Null
           in
           let event =
             { id = row.int 0; channel; payload; created_at = row.float 3 }
           in
           (try cb event with _ -> ())
         end)))

(* ── Prune ────────────────────────────────────────────────────────── *)

(** Delete persisted events with id <= [keep_since_id]. Returns the number
    of deleted rows. *)
let prune ~keep_since_id () =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  Db.exec db "DELETE FROM _well_events WHERE id <= ?" [ Int keep_since_id ]

(* ── Typed topic descriptor ────────────────────────────────────────── *)

(** A deserialized event carrying a typed value. *)
type 'a typed_event = {
  id : int;
  value : 'a;
  created_at : float;
}

(** A typed topic descriptor binding a channel name to serialization functions. *)
type 'a topic = {
  t_channel : string;
  to_yojson : 'a -> Yojson.Safe.t;
  of_yojson : Yojson.Safe.t -> ('a, string) result;
}

(** Create a typed topic for the given channel with serialization functions. *)
let topic channel to_yojson of_yojson =
  { t_channel = channel; to_yojson; of_yojson }

(** Publish a typed value to a topic. Serializes via [t.to_yojson]. *)
let publish_typed ?(ephemeral = false) t value =
  publish ~ephemeral t.t_channel (t.to_yojson value)

(** Subscribe to a typed topic. Events that fail deserialization are silently dropped. *)
let subscribe_typed ?live_only t f =
  subscribe ?live_only t.t_channel (fun event ->
    match t.of_yojson event.payload with
    | Ok v -> f { id = event.id; value = v; created_at = event.created_at }
    | Error _ -> ())

(** Replay persisted events for a typed topic, starting after [since_id]. *)
let replay_typed ?(since_id = 0) t f =
  replay ~since_id t.t_channel (fun event ->
    match t.of_yojson event.payload with
    | Ok v -> f { id = event.id; value = v; created_at = event.created_at }
    | Error _ -> ())

(* ── Keyed topics (channel:key) ──────────────────────────────────── *)

(** Publish to a keyed topic. The channel becomes [topic:key]. *)
let publish_keyed_typed ?(ephemeral = false) t ~key value =
  publish ~ephemeral (t.t_channel ^ ":" ^ key) (t.to_yojson value)

(** A typed event with its key extracted from the channel suffix. *)
type 'a keyed_event = {
  key : string;
  event : 'a typed_event;
}

(** Subscribe to all keys of a keyed topic using wildcard [topic:*].
    The key is extracted from the channel name and passed in [keyed_event]. *)
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

(** Subscribe to [channel], fire the callback once, then auto-unsubscribe. *)
let once channel cb =
  let sub_id = ref 0 in
  sub_id := subscribe channel (fun event ->
    unsubscribe !sub_id;
    cb event);
  !sub_id
