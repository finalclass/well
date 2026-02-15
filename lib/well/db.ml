(* Db — Runtime schema registry and automagic migrations *)

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
  let sql = Printf.sprintf
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='%s'" table_name in
  let stmt = Sqlite3.prepare db sql in
  let found = Sqlite3.step stmt = Sqlite3.Rc.ROW in
  ignore (Sqlite3.finalize stmt);
  found

let get_db_columns db table_name =
  let sql = Printf.sprintf "PRAGMA table_info(%s)" table_name in
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
      Printf.sprintf "%s %s%s%s" c.cname c.sqlite_type pk nn
    ) tbl.columns
  in
  Printf.sprintf "CREATE TABLE IF NOT EXISTS %s (%s)"
    tbl.name (String.concat ", " col_strs)

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
      Printf.printf "[well] created table %s\n%!" tbl.name
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
            tbl.name col.cname col.sqlite_type nn default in
          ignore (Sqlite3.exec db sql);
          Printf.printf "[well] %s: added column %s\n%!" tbl.name col.cname
        end
      ) tbl.columns;
      (* WARN about columns in DB but not in code *)
      List.iter (fun dc ->
        if dc.cname <> "id" &&
           not (List.exists (fun c -> c.cname = dc.cname) tbl.columns) then
          Printf.eprintf "[well] schema drift: %s.%s in db but not in code\n%!"
            tbl.name dc.cname
      ) db_cols;
      (* WARN about type mismatches *)
      List.iter (fun col ->
        match List.find_opt (fun dc -> dc.cname = col.cname) db_cols with
        | Some dc when String.uppercase_ascii dc.sqlite_type <>
                        String.uppercase_ascii col.sqlite_type ->
            Printf.eprintf "[well] schema drift: %s.%s is %s in db but %s in code\n%!"
              tbl.name col.cname dc.sqlite_type col.sqlite_type
        | _ -> ()
      ) tbl.columns
    end
  ) !registered_tables

(* ── open_db — replaces manual init ───────────────────────────────── *)

let open_db path =
  (try Unix.mkdir "data" 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let db = Sqlite3.db_open path in
  ignore (Sqlite3.exec db "PRAGMA journal_mode=WAL");
  ignore (Sqlite3.exec db "PRAGMA synchronous=NORMAL");
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
  Printf.printf "[well] backup created: %s\n%!" bak

(* ── Test sandbox ────────────────────────────────────────────────── *)

let with_test_db f =
  let db = Sqlite3.db_open ":memory:" in
  ignore (Sqlite3.exec db "PRAGMA journal_mode=WAL");
  auto_migrate db;
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close db))
    (fun () -> f db)

(* ── Backup / rollback ────────────────────────────────────────────── *)

let rollback path =
  let bak = path ^ ".bak" in
  if Sys.file_exists bak then begin
    Unix.rename path (path ^ ".tmp");
    Unix.rename bak path;
    Unix.rename (path ^ ".tmp") bak;
    Printf.printf "[well] rolled back %s from backup\n%!" path
  end else
    Printf.eprintf "[well] no backup found: %s\n%!" bak
