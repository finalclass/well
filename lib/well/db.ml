(** Runtime schema registry and automagic SQLite migrations.

    Manages two databases: [app.sqlite] for user tables and [well.sqlite] for
    framework internals. Registered schemas are automatically diffed and migrated
    at connection time (CREATE TABLE / ALTER TABLE ADD COLUMN). *)

(* SQLite identifier quoting — prevents injection via table/column names *)
let quote_id name =
  "\"" ^ String.concat "\"\"" (String.split_on_char '"' name) ^ "\""

let quote_string value =
  "'" ^ String.concat "''" (String.split_on_char '\'' value) ^ "'"

(* ── Schema types ─────────────────────────────────────────────────── *)

(** A column definition in a table schema. *)
type column = {
  cname : string;
  sqlite_type : string;
  primary : bool;
  nullable : bool;
}

(** A table definition with name and column list. *)
type table = {
  name : string;
  columns : column list;
}

(* ── Runtime registry ─────────────────────────────────────────────── *)

(** All tables registered via [\[@@deriving table\]] or {!register_table}. *)
let registered_tables : table list ref = ref []

(** Register a table schema for auto-migration. Called by [\[@@deriving table\]]. *)
let register_table tbl =
  registered_tables := tbl :: !registered_tables

(* ── SQLite introspection ─────────────────────────────────────────── *)

(** Check whether a table exists in the database. *)
let table_exists db table_name =
  let sql =
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name="
    ^ quote_string table_name
  in
  let found = ref false in
  let rc = Sqlite3.exec db sql ~cb:(fun _row _headers -> found := true) in
  match rc with
  | Sqlite3.Rc.OK -> !found
  | rc -> failwith ("Well.Db.table_exists: " ^ Sqlite3.Rc.to_string rc)

(** Introspect a table's columns via [PRAGMA table_info]. *)
let get_db_columns db table_name =
  let sql = Printf.sprintf "PRAGMA table_info(%s)" (quote_id table_name) in
  let cols = ref [] in
  let text row index default =
    match row.(index) with
    | Some value -> value
    | None -> default
  in
  let int_flag row index =
    match row.(index) with
    | Some value -> (try int_of_string value <> 0 with Failure _ -> false)
    | None -> false
  in
  let rc =
    Sqlite3.exec db sql ~cb:(fun row _headers ->
      let col_name = text row 1 "" in
      let col_type = text row 2 "TEXT" in
      let notnull = int_flag row 3 in
      let pk = int_flag row 5 in
      cols := { cname = col_name;
                sqlite_type = String.uppercase_ascii col_type;
                primary = pk;
                nullable = not notnull && not pk } :: !cols)
  in
  (match rc with
   | Sqlite3.Rc.OK -> ()
   | rc -> failwith ("Well.Db.get_db_columns: " ^ Sqlite3.Rc.to_string rc));
  List.rev !cols

(* ── SQL generation from schema ───────────────────────────────────── *)

(** Generate a [CREATE TABLE IF NOT EXISTS] statement from a table schema. *)
let create_table_sql tbl =
  let col_strs =
    List.map (fun c ->
      let pk = if c.primary then " PRIMARY KEY" else "" in
      let nn = if c.nullable || c.primary then "" else " NOT NULL" in
      Printf.sprintf "%s %s%s%s" (quote_id c.cname) c.sqlite_type pk nn
    ) tbl.columns
  in
  Printf.sprintf "CREATE TABLE IF NOT EXISTS %s (%s)"
    (quote_id tbl.name) (String.concat ", " col_strs)

(* ── Diff types ───────────────────────────────────────────────────── *)

(** A single schema difference between registered tables and the database. *)
type diff_entry =
  | Create_table of table
  | Add_column of { table : string; column : column }
  | Extra_column of { table : string; column_name : string }
  | Type_mismatch of { table : string; column : string;
                        db_type : string; code_type : string }

(* ── Diff computation ─────────────────────────────────────────────── *)

(** Compute schema differences between registered tables and the database. *)
let diff db =
  List.concat_map (fun tbl ->
    if not (table_exists db tbl.name) then
      [Create_table tbl]
    else begin
      let db_cols = get_db_columns db tbl.name in
      let adds =
        List.filter_map (fun col ->
          if not (List.exists (fun dc -> dc.cname = col.cname) db_cols) then
            Some (Add_column { table = tbl.name; column = col })
          else None
        ) tbl.columns
      in
      let extras =
        List.filter_map (fun dc ->
          if dc.cname <> "id" &&
             not (List.exists (fun c -> c.cname = dc.cname) tbl.columns) then
            Some (Extra_column { table = tbl.name; column_name = dc.cname })
          else None
        ) db_cols
      in
      let mismatches =
        List.filter_map (fun col ->
          match List.find_opt (fun dc -> dc.cname = col.cname) db_cols with
          | Some dc when String.uppercase_ascii dc.sqlite_type <>
                          String.uppercase_ascii col.sqlite_type ->
              Some (Type_mismatch { table = tbl.name; column = col.cname;
                                    db_type = dc.sqlite_type;
                                    code_type = col.sqlite_type })
          | _ -> None
        ) tbl.columns
      in
      adds @ extras @ mismatches
    end
  ) !registered_tables

(* ── Diff to JSON ─────────────────────────────────────────────────── *)

(** Convert a {!diff_entry} to a JSON representation. *)
let diff_entry_to_json = function
  | Create_table tbl ->
      `Assoc [("type", `String "create_table"); ("table", `String tbl.name)]
  | Add_column { table; column } ->
      `Assoc [("type", `String "add_column"); ("table", `String table);
              ("column", `String column.cname);
              ("sqlite_type", `String column.sqlite_type)]
  | Extra_column { table; column_name } ->
      `Assoc [("type", `String "extra_column"); ("table", `String table);
              ("column", `String column_name)]
  | Type_mismatch { table; column; db_type; code_type } ->
      `Assoc [("type", `String "type_mismatch"); ("table", `String table);
              ("column", `String column); ("db_type", `String db_type);
              ("code_type", `String code_type)]

(* ── Auto-migrate ─────────────────────────────────────────────────── *)

(** Apply pending migrations: creates missing tables, adds new columns,
    and warns about schema drift (extra columns or type mismatches). *)
let auto_migrate db =
  List.iter (fun tbl ->
    if not (table_exists db tbl.name) then begin
      let sql = create_table_sql tbl in
      ignore (Sqlite3.exec db sql);
      Log.log "created table %s" tbl.name
    end else begin
      let db_cols = get_db_columns db tbl.name in
      (* ADD COLUMN for new fields *)
      List.iter (fun col ->
        if not (List.exists (fun dc -> dc.cname = col.cname) db_cols) then begin
          let default = match String.uppercase_ascii col.sqlite_type with
            | "INTEGER" -> "0" | "REAL" -> "0.0" | _ -> "''"
          in
          let nn = if col.nullable then "" else " NOT NULL" in
          let sql = Printf.sprintf "ALTER TABLE %s ADD COLUMN %s %s%s DEFAULT %s"
            (quote_id tbl.name) (quote_id col.cname) col.sqlite_type nn default in
          ignore (Sqlite3.exec db sql);
          Log.log "%s: added column %s" tbl.name col.cname
        end
      ) tbl.columns;
      (* WARN about columns in DB but not in code *)
      List.iter (fun dc ->
        if dc.cname <> "id" &&
           not (List.exists (fun c -> c.cname = dc.cname) tbl.columns) then
          Log.log ~level:"warn" "schema drift: %s.%s in db but not in code"
            tbl.name dc.cname
      ) db_cols;
      (* WARN about type mismatches *)
      List.iter (fun col ->
        match List.find_opt (fun dc -> dc.cname = col.cname) db_cols with
        | Some dc when String.uppercase_ascii dc.sqlite_type <>
                        String.uppercase_ascii col.sqlite_type ->
            Log.log ~level:"warn" "schema drift: %s.%s is %s in db but %s in code"
              tbl.name col.cname dc.sqlite_type col.sqlite_type
        | _ -> ()
      ) tbl.columns
    end
  ) !registered_tables

(* ── Data directory ───────────────────────────────────────────────── *)

(** Create a one-shot initializer guarded by an [Atomic.t] flag.
    Returns a function [Sqlite3.db -> unit] that executes [f] only once. *)
let once f =
  let done_ = Atomic.make false in
  fun db ->
    if not (Atomic.get done_) then begin
      f db;
      Atomic.set done_ true
    end

(** Reset a one-shot guard (for test teardown). Takes the guard function and
    sets its internal flag to [false]. Not possible with [once] — use
    {!once_resettable} instead if reset is needed. *)

(** Like {!once} but also returns a reset function. *)
let once_resettable f =
  let done_ = Atomic.make false in
  let run db =
    if not (Atomic.get done_) then begin
      f db;
      Atomic.set done_ true
    end
  in
  let reset () = Atomic.set done_ false in
  (run, reset)

(** Directory for SQLite database files. Defaults to ["data"], overridable via config. *)
let data_dir = ref (Config.get_string ~default:"data" "well.db.data_dir")

(** When [true], all databases use in-memory shared-cache URIs. *)
let memory_mode = ref false

(* ── Connection pool ─────────────────────────────────────────────── *)

let _init_conn db =
  ignore (Sqlite3.exec db "PRAGMA journal_mode=WAL");
  ignore (Sqlite3.exec db "PRAGMA synchronous=NORMAL")

type pooled_conn = {
  db : Sqlite3.db;
  mutex : Mutex.t;
}

type pool = {
  conns : pooled_conn array;
  next : int Atomic.t;
  mutex : Mutex.t;
  cond : Condition.t;
  mutable active : int;
  mutable closed : bool;
}

let _memory_uri filename =
  Printf.sprintf "file:%s?mode=memory&cache=shared" filename

let _db_path dir filename =
  let path = Filename.concat dir filename in
  if Filename.is_relative path then
    Filename.concat (Sys.getcwd ()) path
  else
    path

(** Create a round-robin connection pool. Runs auto-migrate on the first connection. *)
let create_pool ?(size = 8) ?(filename = "app.sqlite") () =
  if !memory_mode then begin
    let uri = _memory_uri filename in
    let db = Sqlite3.db_open ~uri:true uri in
    _init_conn db;
    auto_migrate db;
    { conns = [|{ db; mutex = Mutex.create () }|];
      next = Atomic.make 0;
      mutex = Mutex.create ();
      cond = Condition.create ();
      active = 0;
      closed = false }
  end else begin
    let dir = !data_dir in
    (try Unix.mkdir dir 0o755
     with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let path = _db_path dir filename in
    let migrated = Atomic.make false in
    let conns = Array.init size (fun _ ->
      let db = Sqlite3.db_open path in
      _init_conn db;
      if not (Atomic.exchange migrated true) then
        auto_migrate db;
      { db; mutex = Mutex.create () }) in
    { conns;
      next = Atomic.make 0;
      mutex = Mutex.create ();
      cond = Condition.create ();
      active = 0;
      closed = false }
  end

(** Run [f] with exclusive ownership of the next connection from the pool. *)
let with_conn pool f =
  Mutex.lock pool.mutex;
  (try
     if pool.closed then
       invalid_arg "Well.Db.with_conn: pool is closed";
     pool.active <- pool.active + 1;
     Mutex.unlock pool.mutex
   with exn ->
     Mutex.unlock pool.mutex;
     raise exn);
  let idx = Atomic.fetch_and_add pool.next 1 mod Array.length pool.conns in
  let conn = pool.conns.(idx) in
  Mutex.lock conn.mutex;
  Fun.protect
    ~finally:(fun () ->
      Mutex.unlock conn.mutex;
      Mutex.lock pool.mutex;
      pool.active <- pool.active - 1;
      if pool.active = 0 then
        Condition.broadcast pool.cond;
      Mutex.unlock pool.mutex)
    (fun () -> f conn.db)

(** Close all connections in the pool after waiting for leased handles. *)
let close_pool pool =
  Mutex.lock pool.mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock pool.mutex)
    (fun () ->
      if not pool.closed then begin
        pool.closed <- true;
        while pool.active > 0 do
          Condition.wait pool.cond pool.mutex
        done;
        Array.iter
          (fun (conn : pooled_conn) -> ignore (Sqlite3.db_close conn.db))
          pool.conns
      end)

(* ── open_db — single connection (backward compat) ───────────────── *)

(** Open a single database connection with WAL mode and auto-migration. *)
let open_db ?(filename = "app.sqlite") () =
  if !memory_mode then begin
    let uri = _memory_uri filename in
    let db = Sqlite3.db_open ~uri:true uri in
    _init_conn db;
    auto_migrate db;
    db
  end else begin
    let dir = !data_dir in
    (try Unix.mkdir dir 0o755
     with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let path = _db_path dir filename in
    let db = Sqlite3.db_open path in
    _init_conn db;
    auto_migrate db;
    db
  end

(* ── Transactions ────────────────────────────────────────────────── *)

(** Run [f] inside a SQLite transaction. Commits on success, rolls back on exception. *)
let transaction db f =
  ignore (Sqlite3.exec db "BEGIN");
  let committed = ref false in
  Fun.protect
    ~finally:(fun () ->
      if not !committed then
        ignore (Sqlite3.exec db "ROLLBACK"))
    (fun () ->
      let result = f db in
      (match Sqlite3.exec db "COMMIT" with
       | Sqlite3.Rc.OK -> committed := true
       | rc ->
           failwith ("Well.Db.transaction: COMMIT failed: "
                      ^ Sqlite3.Rc.to_string rc));
      result)

(** Like {!transaction} but [f] returns a [result]. Commits on [Ok], rolls back on [Error]. *)
let transaction_result db f =
  ignore (Sqlite3.exec db "BEGIN");
  let committed = ref false in
  Fun.protect
    ~finally:(fun () ->
      if not !committed then
        ignore (Sqlite3.exec db "ROLLBACK"))
    (fun () ->
      match f db with
      | Ok _ as result ->
          (match Sqlite3.exec db "COMMIT" with
           | Sqlite3.Rc.OK -> committed := true
           | rc ->
               failwith ("Well.Db.transaction: COMMIT failed: "
                          ^ Sqlite3.Rc.to_string rc));
          result
      | Error _ as result ->
          result)

(* ── Backup / rollback ────────────────────────────────────────────── *)

(** Create a binary backup of the database file at [path] as [path.bak]. *)
let backup path =
  let bak = path ^ ".bak" in
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let data = Bytes.create len in
  really_input ic data 0 len;
  close_in ic;
  let oc = open_out_bin bak in
  output_bytes oc data;
  close_out oc;
  Log.log "backup created: %s" bak

(* ── Test sandbox ────────────────────────────────────────────────── *)

(** Run [f] with an in-memory database that has all registered tables migrated.
    The connection is closed when [f] returns. *)
let with_test_db f =
  let db = Sqlite3.db_open ":memory:" in
  ignore (Sqlite3.exec db "PRAGMA journal_mode=WAL");
  auto_migrate db;
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close db))
    (fun () -> f db)

(** Swap the database at [path] with its [.bak] backup (atomic rename). *)
let rollback path =
  let bak = path ^ ".bak" in
  if Sys.file_exists bak then begin
    Unix.rename path (path ^ ".tmp");
    Unix.rename bak path;
    Unix.rename (path ^ ".tmp") bak;
    Log.log "rolled back %s from backup" path
  end else
    Log.log ~level:"error" "no backup found: %s" bak

(* ── well.sqlite — shared framework database ─────────────────────── *)

(* Simple round-robin pool for well.sqlite.
   No Eio dependency — works both inside and outside Eio runtime.
   Each callback gets exclusive use of its selected connection. *)

let _well_size = 4
let _well_conns : pooled_conn array option ref = ref None
let _well_next = Atomic.make 0
let _well_mu = Mutex.create () (* only for lazy init + shutdown *)
let _well_cond = Condition.create ()
let _well_active = ref 0
let _well_closing = ref false

let _make_well_conns () =
  if !memory_mode then begin
    let uri = _memory_uri "well.sqlite" in
    let db = Sqlite3.db_open ~uri:true uri in
    _init_conn db;
    [|{ db; mutex = Mutex.create () }|]
  end else begin
    let dir = !data_dir in
    (try Unix.mkdir dir 0o755
     with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let path = _db_path dir "well.sqlite" in
    Array.init _well_size (fun _ ->
      let db = Sqlite3.db_open path in
      _init_conn db;
      { db; mutex = Mutex.create () })
  end

let _ensure_well_conns () =
  match !_well_conns with
  | Some c -> c
  | None ->
    Mutex.lock _well_mu;
    Fun.protect ~finally:(fun () -> Mutex.unlock _well_mu) (fun () ->
      match !_well_conns with
      | Some c -> c (* double-check after lock *)
      | None ->
        let conns = _make_well_conns () in
        _well_conns := Some conns;
        conns)

(** Run [f] with a connection to the framework database ([well.sqlite]).
    Lazily initializes a round-robin pool on first call and leases the selected
    connection exclusively. *)
let with_well_db f =
  Mutex.lock _well_mu;
  let conn =
    (try
       while !_well_closing do
         Condition.wait _well_cond _well_mu
       done;
       let conns =
         match !_well_conns with
         | Some conns -> conns
         | None ->
           let conns = _make_well_conns () in
           _well_conns := Some conns;
           conns
       in
       _well_active := !_well_active + 1;
       let idx = Atomic.fetch_and_add _well_next 1 mod Array.length conns in
       let conn = conns.(idx) in
       Mutex.unlock _well_mu;
       conn
     with exn ->
       Mutex.unlock _well_mu;
       raise exn)
  in
  Mutex.lock conn.mutex;
  Fun.protect
    ~finally:(fun () ->
      Mutex.unlock conn.mutex;
      Mutex.lock _well_mu;
      _well_active := !_well_active - 1;
      if !_well_active = 0 then
        Condition.broadcast _well_cond;
      Mutex.unlock _well_mu)
    (fun () -> f conn.db)

(* ── Query helpers ────────────────────────────────────────────────── *)

(** Bind parameter for parameterized SQL queries. *)
type param =
  | Null
  | Int of int
  | Float of float
  | Text of string
  | Blob of string

let _bind_params stmt params =
  List.iteri (fun i p ->
    let d = match p with
      | Null -> Sqlite3.Data.NULL
      | Int n -> Sqlite3.Data.INT (Int64.of_int n)
      | Float f -> Sqlite3.Data.FLOAT f
      | Text s -> Sqlite3.Data.TEXT s
      | Blob s -> Sqlite3.Data.BLOB s
    in
    ignore (Sqlite3.bind stmt (i + 1) d)
  ) params

let _col_to_yojson stmt i : Yojson.Safe.t =
  match Sqlite3.column stmt i with
  | Sqlite3.Data.NULL | Sqlite3.Data.NONE -> `Null
  | Sqlite3.Data.INT n -> `Int (Int64.to_int n)
  | Sqlite3.Data.FLOAT f -> `Float f
  | Sqlite3.Data.TEXT s -> `String s
  | Sqlite3.Data.BLOB s -> `String s

(** Typed accessors for reading column values from a result row. *)
type row = {
  int : int -> int;
  float : int -> float;
  text : int -> string;
  bool : int -> bool;
  int_opt : int -> int option;
  float_opt : int -> float option;
  text_opt : int -> string option;
  bool_opt : int -> bool option;
}

let _make_row stmt =
  let _float i =
    match Sqlite3.column stmt i with
    | Sqlite3.Data.FLOAT f -> f | Sqlite3.Data.INT n -> Int64.to_float n | _ -> 0.0
  in
  { int = (fun i -> Sqlite3.column_int stmt i);
    float = _float;
    text = (fun i -> Sqlite3.column_text stmt i);
    bool = (fun i -> Sqlite3.column_int stmt i <> 0);
    int_opt = (fun i -> match Sqlite3.column stmt i with Sqlite3.Data.NULL -> None | _ -> Some (Sqlite3.column_int stmt i));
    float_opt = (fun i -> match Sqlite3.column stmt i with Sqlite3.Data.NULL -> None | _ -> Some (_float i));
    text_opt = (fun i -> match Sqlite3.column stmt i with Sqlite3.Data.NULL -> None | _ -> Some (Sqlite3.column_text stmt i));
    bool_opt = (fun i -> match Sqlite3.column stmt i with Sqlite3.Data.NULL -> None | _ -> Some (Sqlite3.column_int stmt i <> 0));
  }

(** Execute a SELECT query and map each row with [f]. Returns results in order. *)
let query db sql params f =
  let stmt = Sqlite3.prepare db sql in
  _bind_params stmt params;
  let r = _make_row stmt in
  let results = ref [] in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
    while Sqlite3.step stmt = Sqlite3.Rc.ROW do
      results := f r :: !results
    done;
    List.rev !results)

(** Like {!query} but returns only the first row, or [None]. *)
let query_one db sql params f =
  let stmt = Sqlite3.prepare db sql in
  _bind_params stmt params;
  let r = _make_row stmt in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Some (f r)
    | _ -> None)

(** Execute a non-SELECT statement (INSERT, UPDATE, DELETE). Returns the number of changed rows. *)
let exec db sql params =
  let stmt = Sqlite3.prepare db sql in
  _bind_params stmt params;
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
    match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE -> Sqlite3.changes db
    | rc -> failwith ("Well.Db.exec: " ^ Sqlite3.Rc.to_string rc))

(** Execute a SELECT and return rows as [Yojson.Safe.t] association lists. *)
let fetch_yojson db sql params =
  let stmt = Sqlite3.prepare db sql in
  _bind_params stmt params;
  let ncols = Sqlite3.column_count stmt in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
    let results = ref [] in
    while Sqlite3.step stmt = Sqlite3.Rc.ROW do
      let names = Array.init ncols (fun i -> Sqlite3.column_name stmt i) in
      let assoc = Array.to_list (Array.mapi (fun i name ->
        (name, _col_to_yojson stmt i)) names) in
      results := `Assoc assoc :: !results
    done;
    List.rev !results)

(** Close all connections in the framework database pool. Safe to call multiple times. *)
let close_well_db () =
  Mutex.lock _well_mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock _well_mu) (fun () ->
    match !_well_conns with
    | Some conns ->
      _well_closing := true;
      while !_well_active > 0 do
        Condition.wait _well_cond _well_mu
      done;
      _well_conns := None;
      Array.iter (fun (conn : pooled_conn) -> ignore (Sqlite3.db_close conn.db)) conns;
      _well_closing := false;
      Condition.broadcast _well_cond
    | None ->
      while !_well_active > 0 do
        Condition.wait _well_cond _well_mu
      done;
      _well_closing := false;
      Condition.broadcast _well_cond)
