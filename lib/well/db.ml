(* Db — Runtime schema registry and automagic migrations *)

(* SQLite identifier quoting — prevents injection via table/column names *)
let quote_id name =
  "\"" ^ String.concat "\"\"" (String.split_on_char '"' name) ^ "\""

(* ── Schema types ─────────────────────────────────────────────────── *)

type column = {
  cname : string;
  sqlite_type : string;
  primary : bool;
  nullable : bool;
}

type table = {
  name : string;
  columns : column list;
}

(* ── Runtime registry ─────────────────────────────────────────────── *)

let registered_tables : table list ref = ref []

let register_table tbl =
  registered_tables := tbl :: !registered_tables

(* ── SQLite introspection ─────────────────────────────────────────── *)

let table_exists db table_name =
  let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?" in
  let stmt = Sqlite3.prepare db sql in
  ignore (Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT table_name));
  let found = Sqlite3.step stmt = Sqlite3.Rc.ROW in
  ignore (Sqlite3.finalize stmt);
  found

let get_db_columns db table_name =
  let sql = Printf.sprintf "PRAGMA table_info(%s)" (quote_id table_name) in
  let stmt = Sqlite3.prepare db sql in
  let cols = ref [] in
  let rec loop () =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
        let col_name = match Sqlite3.column stmt 1 with
          | Sqlite3.Data.TEXT s -> s | _ -> "" in
        let col_type = match Sqlite3.column stmt 2 with
          | Sqlite3.Data.TEXT s -> s | _ -> "TEXT" in
        let notnull = match Sqlite3.column stmt 3 with
          | Sqlite3.Data.INT i -> Int64.to_int i <> 0 | _ -> false in
        let pk = match Sqlite3.column stmt 5 with
          | Sqlite3.Data.INT i -> Int64.to_int i <> 0 | _ -> false in
        cols := { cname = col_name;
                  sqlite_type = String.uppercase_ascii col_type;
                  primary = pk;
                  nullable = not notnull && not pk } :: !cols;
        loop ()
    | _ -> ()
  in
  loop ();
  ignore (Sqlite3.finalize stmt);
  List.rev !cols

(* ── SQL generation from schema ───────────────────────────────────── *)

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

type diff_entry =
  | Create_table of table
  | Add_column of { table : string; column : column }
  | Extra_column of { table : string; column_name : string }
  | Type_mismatch of { table : string; column : string;
                        db_type : string; code_type : string }

(* ── Diff computation ─────────────────────────────────────────────── *)

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

let data_dir = ref "data"

(* ── Connection pool ─────────────────────────────────────────────── *)

let _init_conn db =
  ignore (Sqlite3.exec db "PRAGMA journal_mode=WAL");
  ignore (Sqlite3.exec db "PRAGMA synchronous=NORMAL")

type pool = {
  conns : Sqlite3.db array;
  next : int Atomic.t;
}

let create_pool ?(size = 8) ?(filename = "app.sqlite") () =
  let dir = !data_dir in
  (try Unix.mkdir dir 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir filename in
  let migrated = Atomic.make false in
  let conns = Array.init size (fun _ ->
    let db = Sqlite3.db_open path in
    _init_conn db;
    if not (Atomic.exchange migrated true) then
      auto_migrate db;
    db) in
  { conns; next = Atomic.make 0 }

let with_conn pool f =
  let idx = Atomic.fetch_and_add pool.next 1 mod Array.length pool.conns in
  f pool.conns.(idx)

let close_pool pool =
  Array.iter (fun db -> ignore (Sqlite3.db_close db)) pool.conns

(* ── open_db — single connection (backward compat) ───────────────── *)

let open_db ?(filename = "app.sqlite") () =
  let dir = !data_dir in
  (try Unix.mkdir dir 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir filename in
  let db = Sqlite3.db_open path in
  _init_conn db;
  auto_migrate db;
  db

(* ── Transactions ────────────────────────────────────────────────── *)

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

let with_test_db f =
  let db = Sqlite3.db_open ":memory:" in
  ignore (Sqlite3.exec db "PRAGMA journal_mode=WAL");
  auto_migrate db;
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close db))
    (fun () -> f db)

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
   Each fiber/thread gets its own connection via round-robin — no locking needed. *)

let _well_size = 4
let _well_conns : Sqlite3.db array option ref = ref None
let _well_next = Atomic.make 0
let _well_mu = Mutex.create () (* only for lazy init + shutdown *)

let _ensure_well_conns () =
  match !_well_conns with
  | Some c -> c
  | None ->
    Mutex.lock _well_mu;
    Fun.protect ~finally:(fun () -> Mutex.unlock _well_mu) (fun () ->
      match !_well_conns with
      | Some c -> c (* double-check after lock *)
      | None ->
        let dir = !data_dir in
        (try Unix.mkdir dir 0o755
         with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
        let path = Filename.concat dir "well.sqlite" in
        let conns = Array.init _well_size (fun _ ->
          let db = Sqlite3.db_open path in
          _init_conn db;
          db) in
        _well_conns := Some conns;
        conns)

let with_well_db f =
  let conns = _ensure_well_conns () in
  let idx = Atomic.fetch_and_add _well_next 1 mod _well_size in
  f conns.(idx)

(* ── Query helpers ────────────────────────────────────────────────── *)

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

let query_one db sql params f =
  let stmt = Sqlite3.prepare db sql in
  _bind_params stmt params;
  let r = _make_row stmt in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Some (f r)
    | _ -> None)

let exec db sql params =
  let stmt = Sqlite3.prepare db sql in
  _bind_params stmt params;
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
    match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE -> Sqlite3.changes db
    | rc -> failwith ("Well.Db.exec: " ^ Sqlite3.Rc.to_string rc))

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

let close_well_db () =
  Mutex.lock _well_mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock _well_mu) (fun () ->
    match !_well_conns with
    | Some conns ->
      Array.iter (fun db -> ignore (Sqlite3.db_close db)) conns;
      _well_conns := None
    | None -> ())
