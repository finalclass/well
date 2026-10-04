open Cap_helpers

let page_size = 20

type db_source =
  | App
  | Well_fw

type editing =
  { row_id: string
  ; col: string
  ; value: string }

type model =
  { db_source: db_source
  ; tables: string list
  ; selected_table: string
  ; rows: string list list
  ; columns: string list
  ; total_rows: int
  ; page: int
  ; editing: editing option
  ; sql_input: string
  ; sql_result: string
  ; sql_error: string }

type msg =
  | SwitchDb of string
  | SelectTable of string
  | GoPage of int
  | EditCell of string * string * string
  | SaveCell of string
  | CancelEdit
  | RunSQL of string

let with_db_for source f =
  match source with
  | App ->
      let db = Well.Db.open_db () in
      Fun.protect
        ~finally:(fun () -> ignore (Sqlite3.db_close db))
        (fun () -> f db)
  | Well_fw -> Well.Db.with_well_db f

let get_table_names_app () =
  List.map (fun (t : Well.Db.table) -> t.name) !Well.Db.registered_tables

let get_table_names_well () =
  try
    Well.Db.with_well_db @@ fun db ->
    let stmt =
      Sqlite3.prepare
        db
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE \
         '_well_%' ORDER BY name"
    in
    let results = ref [] in
    while Sqlite3.step stmt = Sqlite3.Rc.ROW do
      results := Sqlite3.column_text stmt 0 :: !results
    done ;
    ignore (Sqlite3.finalize stmt) ;
    List.rev !results
  with
  | _ -> []

let get_table_names source =
  match source with
  | App -> get_table_names_app ()
  | Well_fw -> get_table_names_well ()

let find_pk_app table_name =
  let tables = !Well.Db.registered_tables in
  match
    List.find_opt (fun (t : Well.Db.table) -> t.name = table_name) tables
  with
  | Some tbl -> (
    match List.find_opt (fun (c : Well.Db.column) -> c.primary) tbl.columns with
    | Some c -> Some c.cname
    | None -> None )
  | None -> None

let find_pk_well table_name =
  try
    Well.Db.with_well_db @@ fun db ->
    let sql =
      Printf.sprintf "PRAGMA table_info(%s)" (Well.Db.quote_id table_name)
    in
    let stmt = Sqlite3.prepare db sql in
    let result = ref None in
    while Sqlite3.step stmt = Sqlite3.Rc.ROW do
      let pk =
        match Sqlite3.column stmt 5 with
        | Sqlite3.Data.INT i64 -> Int64.to_int i64 <> 0
        | _ -> false
      in
      if pk
      then
        result :=
          Some
            ( match Sqlite3.column stmt 1 with
            | Sqlite3.Data.TEXT s -> s
            | _ -> "" )
    done ;
    ignore (Sqlite3.finalize stmt) ;
    !result
  with
  | _ -> None

let find_pk source table_name =
  match source with
  | App -> find_pk_app table_name
  | Well_fw -> find_pk_well table_name

let read_rows stmt =
  let ncols = Sqlite3.column_count stmt in
  let cols = List.init ncols (fun i -> Sqlite3.column_name stmt i) in
  let rows = ref [] in
  while Sqlite3.step stmt = Sqlite3.Rc.ROW do
    let row =
      List.init ncols (fun i ->
          match Sqlite3.column stmt i with
          | Sqlite3.Data.NULL -> "NULL"
          | Sqlite3.Data.INT i64 -> Int64.to_string i64
          | Sqlite3.Data.FLOAT f -> string_of_float f
          | Sqlite3.Data.TEXT s -> s
          | Sqlite3.Data.BLOB s -> Printf.sprintf "<blob %d>" (String.length s)
          | _ -> "?" )
    in
    rows := row :: !rows
  done ;
  ignore (Sqlite3.finalize stmt) ;
  (cols, List.rev !rows)

let count_table source table_name =
  try
    with_db_for source @@ fun db ->
    let sql =
      Printf.sprintf "SELECT COUNT(*) FROM %s" (Well.Db.quote_id table_name)
    in
    let stmt = Sqlite3.prepare db sql in
    let n =
      if Sqlite3.step stmt = Sqlite3.Rc.ROW
      then
        match Sqlite3.column stmt 0 with
        | Sqlite3.Data.INT i64 -> Int64.to_int i64
        | _ -> 0
      else 0
    in
    ignore (Sqlite3.finalize stmt) ;
    n
  with
  | _ -> 0

let query_table_page source table_name page =
  try
    with_db_for source @@ fun db ->
    let offset = page * page_size in
    let sql =
      Printf.sprintf
        "SELECT * FROM %s LIMIT %d OFFSET %d"
        (Well.Db.quote_id table_name)
        page_size
        offset
    in
    let stmt = Sqlite3.prepare db sql in
    let cols, rows = read_rows stmt in
    (cols, rows, "")
  with
  | exn -> ([], [], Printexc.to_string exn)

let update_cell source table_name pk_col row_id col_name new_value =
  try
    with_db_for source @@ fun db ->
    let sql =
      Printf.sprintf
        "UPDATE %s SET %s = ? WHERE %s = ?"
        (Well.Db.quote_id table_name)
        (Well.Db.quote_id col_name)
        (Well.Db.quote_id pk_col)
    in
    let stmt = Sqlite3.prepare db sql in
    let value_data =
      if new_value = "NULL"
      then Sqlite3.Data.NULL
      else Sqlite3.Data.TEXT new_value
    in
    ignore (Sqlite3.bind stmt 1 value_data) ;
    ignore (Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT row_id)) ;
    let result = Sqlite3.step stmt in
    let error =
      if result = Sqlite3.Rc.DONE then None else Some (Sqlite3.errmsg db)
    in
    ignore (Sqlite3.finalize stmt) ;
    error
  with
  | exn -> Some (Printexc.to_string exn)

let run_sql source sql_str =
  try
    with_db_for source @@ fun db ->
    let stmt = Sqlite3.prepare db sql_str in
    let ncols = Sqlite3.column_count stmt in
    if ncols = 0
    then begin
      ignore (Sqlite3.step stmt) ;
      ignore (Sqlite3.finalize stmt) ;
      let changes = Sqlite3.changes db in
      ([], [], "", Printf.sprintf "OK — %d row(s) affected" changes)
    end
    else begin
      let cols, rows = read_rows stmt in
      (cols, rows, "", "")
    end
  with
  | exn -> ([], [], Printexc.to_string exn, "")

let init _req _props =
  let db_source = App in
  let tables = get_table_names db_source in
  let selected_table =
    match tables with
    | t :: _ -> t
    | [] -> ""
  in
  let columns, rows, _err =
    if selected_table <> ""
    then query_table_page db_source selected_table 0
    else ([], [], "")
  in
  let total_rows =
    if selected_table <> "" then count_table db_source selected_table else 0
  in
  ( { db_source
    ; tables
    ; selected_table
    ; rows
    ; columns
    ; total_rows
    ; page= 0
    ; editing= None
    ; sql_input= ""
    ; sql_result= ""
    ; sql_error= "" }
  , [] )

let reload_current model =
  let columns, rows, err =
    query_table_page model.db_source model.selected_table model.page
  in
  let total_rows = count_table model.db_source model.selected_table in
  {model with columns; rows; total_rows; sql_error= err; editing= None}

let update _req model msg =
  match msg with
  | SwitchDb s ->
      let db_source = if s = "well" then Well_fw else App in
      let tables = get_table_names db_source in
      let selected_table =
        match tables with
        | t :: _ -> t
        | [] -> ""
      in
      let columns, rows, err =
        if selected_table <> ""
        then query_table_page db_source selected_table 0
        else ([], [], "")
      in
      let total_rows =
        if selected_table <> "" then count_table db_source selected_table else 0
      in
      { db_source
      ; tables
      ; selected_table
      ; columns
      ; rows
      ; total_rows
      ; page= 0
      ; editing= None
      ; sql_error= err
      ; sql_result= ""
      ; sql_input= "" }
  | SelectTable name ->
      let columns, rows, err = query_table_page model.db_source name 0 in
      let total_rows = count_table model.db_source name in
      { model with
        selected_table= name
      ; columns
      ; rows
      ; total_rows
      ; page= 0
      ; editing= None
      ; sql_error= err }
  | GoPage p ->
      let columns, rows, err =
        query_table_page model.db_source model.selected_table p
      in
      {model with columns; rows; page= p; editing= None; sql_error= err}
  | EditCell (row_id, col, value) ->
      {model with editing= Some {row_id; col; value}}
  | CancelEdit -> {model with editing= None}
  | SaveCell new_value -> (
    match (model.editing, find_pk model.db_source model.selected_table) with
    | Some ed, Some pk_col -> (
      match
        update_cell
          model.db_source
          model.selected_table
          pk_col
          ed.row_id
          ed.col
          new_value
      with
      | None -> reload_current model
      | Some err -> {model with sql_error= err; editing= None} )
    | _ -> {model with editing= None} )
  | RunSQL sql_str ->
      let cols, rows, err, result = run_sql model.db_source sql_str in
      if err <> ""
      then {model with sql_error= err; sql_result= ""}
      else if result <> ""
      then
        { model with
          sql_result= result
        ; sql_error= ""
        ; columns= cols
        ; rows
        ; total_rows= List.length rows
        ; page= 0 }
      else
        { model with
          columns= cols
        ; rows
        ; total_rows= List.length rows
        ; page= 0
        ; sql_error= ""
        ; sql_result= "" }

let page_url model extra =
  let source = if model.db_source = Well_fw then "well" else "app" in
  let base =
    [ ("source", source)
    ; ("table", model.selected_table)
    ; ("page", string_of_int model.page) ]
  in
  url
    "/_cap/db"
    (extra @ List.filter (fun (k, _) -> not (List.mem_assoc k extra)) base)

let view req model =
  let pk_col =
    if model.sql_input <> ""
    then None
    else find_pk model.db_source model.selected_table
  in
  let pk_idx =
    match pk_col with
    | Some pk -> List.find_index (fun c -> c = pk) model.columns
    | None -> None
  in
  let is_app = model.db_source = App in
  let db_selector =
    Printf.sprintf
      {|<div class="tab-bar" style="margin-bottom:12px">
        <a class="%s" href="%s">app</a>
        <a class="%s" href="%s">well</a>
      </div>|}
      (if is_app then " active" else "")
      (esc (url "/_cap/db" [("source", "app")]))
      (if not is_app then " active" else "")
      (esc (url "/_cap/db" [("source", "well")]))
  in
  let table_tabs =
    if model.tables = []
    then {|<div class="empty-state"><p>No tables registered</p></div>|}
    else
      let tabs =
        String.concat
          ""
          (List.map
             (fun t ->
               let cls = if t = model.selected_table then " active" else "" in
               Printf.sprintf
                 {|<a class="%s" href="%s">%s</a>|}
                 cls
                 (esc (page_url model [("table", t); ("page", "0")]))
                 (esc t) )
             model.tables )
      in
      Printf.sprintf {|<div class="tab-bar">%s</div>|} tabs
  in
  let data_html =
    if model.columns = []
    then {|<div class="empty-state"><p>No data</p></div>|}
    else
      let thead =
        String.concat
          ""
          (List.map
             (fun c -> Printf.sprintf "<th>%s</th>" (esc c))
             model.columns )
      in
      let tbody =
        String.concat
          ""
          (List.map
             (fun row ->
               let row_id =
                 match pk_idx with
                 | Some i -> List.nth row i
                 | None -> ""
               in
               let cells =
                 String.concat
                   ""
                   (List.mapi
                      (fun i v ->
                        let col_name = List.nth model.columns i in
                        let is_pk =
                          match pk_idx with
                          | Some pi -> i = pi
                          | None -> false
                        in
                        let is_editing =
                          match model.editing with
                          | Some ed -> ed.row_id = row_id && ed.col = col_name
                          | None -> false
                        in
                        if is_editing
                        then
                          Printf.sprintf
                            {|<td><form method="post" action="%s" style="display:flex;gap:4px">%s
                    <input name="value" class="input" style="font-size:12px;padding:2px 6px;width:100%%" value="%s" autofocus />
                    <button type="submit" class="btn btn-accent btn-sm" style="padding:2px 8px;font-size:11px">&#10003;</button>
                    <a class="btn btn-sm" style="padding:2px 8px;font-size:11px" href="%s">&#10005;</a>
                  </form></td>|}
                            (esc (page_url model []))
                            ( csrf req
                            ^ hidden "action" "save_cell"
                            ^ hidden "row" row_id
                            ^ hidden "column" col_name )
                            (esc v)
                            (esc (page_url model []))
                        else if is_pk || pk_col = None
                        then Printf.sprintf "<td>%s</td>" (esc v)
                        else
                          Printf.sprintf
                            {|<td><a style="display:block;color:inherit" href="%s">%s</a></td>|}
                            (esc
                               (page_url
                                  model
                                  [("row", row_id); ("column", col_name)] ) )
                            (esc v) )
                      row )
               in
               Printf.sprintf "<tr>%s</tr>" cells )
             model.rows )
      in
      let total_pages = (model.total_rows + page_size - 1) / page_size in
      let pagination =
        if total_pages <= 1
        then ""
        else
          let prev_btn =
            if model.page > 0
            then
              Printf.sprintf
                {|<a class="btn btn-sm" href="%s">&laquo; Prev</a>|}
                (esc
                   (page_url model [("page", string_of_int (model.page - 1))]) )
            else {|<button class="btn btn-sm" disabled>&laquo; Prev</button>|}
          in
          let next_btn =
            if model.page < total_pages - 1
            then
              Printf.sprintf
                {|<a class="btn btn-sm" href="%s">Next &raquo;</a>|}
                (esc
                   (page_url model [("page", string_of_int (model.page + 1))]) )
            else {|<button class="btn btn-sm" disabled>Next &raquo;</button>|}
          in
          let first_row = (model.page * page_size) + 1 in
          let last_row =
            min (first_row + List.length model.rows - 1) model.total_rows
          in
          Printf.sprintf
            {|<div style="display:flex;align-items:center;justify-content:space-between;margin-top:10px;font-size:12px;color:var(--text-secondary)">
              <span>%d–%d of %d</span>
              <div style="display:flex;gap:6px">%s%s</div>
            </div>|}
            first_row
            last_row
            model.total_rows
            prev_btn
            next_btn
      in
      Printf.sprintf
        {|<div style="overflow-x:auto"><table class="data-table"><thead><tr>%s</tr></thead><tbody>%s</tbody></table></div>%s|}
        thead
        tbody
        pagination
  in
  let err_html =
    if model.sql_error <> ""
    then
      Printf.sprintf
        {|<div class="login-error" style="margin-top:8px">%s</div>|}
        (esc model.sql_error)
    else if model.sql_result <> ""
    then
      Printf.sprintf
        {|<div style="margin-top:8px;color:var(--green);font-family:var(--mono);font-size:12px">%s</div>|}
        (esc model.sql_result)
    else ""
  in

  html_raw
    (Printf.sprintf
       {|<div>
      <div class="card">
        <div class="card-title">Database</div>
        <div>%s</div>
        <div class="card-title" style="margin-top:12px">Tables</div>
        <div>%s</div>
        <div class="mt-3">%s</div>
      </div>
      <div class="card">
        <div class="card-title">SQL REPL</div>
        <form method="post" action="%s">%s
          <div class="sql-editor">
            <textarea name="sql" class="input" placeholder="SELECT * FROM ..." rows="3">%s</textarea>
          </div>
          <button type="submit" class="btn btn-accent btn-sm">Execute</button>
        </form>
        <div>%s</div>
      </div>
    </div>|}
       db_selector
       table_tabs
       data_html
       (esc (page_url model []))
       (csrf req ^ hidden "action" "run_sql")
       (esc model.sql_input)
       err_html )
