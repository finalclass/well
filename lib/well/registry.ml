(** Declarative admin registries backed by SQLite.

    This module is intentionally small: it is for low-volatility back-office
    reference tables, not for domain workflows or public APIs. *)

type field_type = String | Text | Int | Bool

type field =
  { name : string
  ; label : string
  ; field_type : field_type
  ; required : bool
  ; unique : bool }

type t =
  { id : string
  ; table : string
  ; title : string
  ; fields : field list
  ; display : string list
  ; soft_delete : bool }

type row = { id : string; values : (string * string) list }

type issue = { field : string; message : string }

type save_result = Saved of string | Invalid of issue list

let is_ident value =
  value <> ""
  && String.for_all
       (function
         | 'a' .. 'z'
          |'A' .. 'Z'
          |'0' .. '9'
          |'_' ->
             true
         | _ -> false )
       value
  &&
  match value.[0] with
  | 'a' .. 'z'
   |'A' .. 'Z'
   |'_' ->
      true
  | _ -> false

let ensure_ident kind value =
  if is_ident value then value
  else invalid_arg (Printf.sprintf "Well.Registry: invalid %s %S" kind value)

let field_type_of_string = function
  | "string" -> String
  | "text" -> Text
  | "int" | "integer" -> Int
  | "bool" | "boolean" -> Bool
  | other -> invalid_arg ("Well.Registry: unsupported field type " ^ other)

let sqlite_type = function
  | String | Text -> "TEXT"
  | Int | Bool -> "INTEGER"

let input_type = function
  | String -> "text"
  | Text -> "textarea"
  | Int -> "number"
  | Bool -> "checkbox"

let toml_string ?default toml path =
  match Toml.get_string toml path with
  | Some value -> value
  | None -> (
    match default with
    | Some value -> value
    | None ->
        invalid_arg
          (Printf.sprintf
             "Well.Registry: missing TOML string %s"
             (String.concat "." path)) )

let toml_bool ?(default = false) toml path =
  Option.value ~default (Toml.get_bool toml path)

let parse_field toml registry_id name =
  let base = ["registry"; registry_id; "fields"; name] in
  let field_type =
    toml_string ~default:"string" toml (base @ ["type"])
    |> field_type_of_string
  in
  { name = ensure_ident "field name" name
  ; label = toml_string ~default:name toml (base @ ["label"])
  ; field_type
  ; required = toml_bool toml (base @ ["required"])
  ; unique = toml_bool toml (base @ ["unique"]) }

let parse_registry toml id =
  let base = ["registry"; id] in
  let fields =
    match Toml.get_table toml (base @ ["fields"]) with
    | Some pairs ->
        pairs
        |> List.filter_map (fun (name, value) ->
             match value with
             | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
                 Some (parse_field toml id name)
             | _ -> None )
    | None ->
        invalid_arg
          (Printf.sprintf "Well.Registry: registry %S has no fields" id)
  in
  let display =
    Option.value
      ~default:(List.map (fun f -> f.name) fields)
      (Toml.get_string_list toml (base @ ["display"]))
  in
  { id = ensure_ident "registry id" id
  ; table =
      ensure_ident
        "table name"
        (toml_string ~default:id toml (base @ ["table"]))
  ; title = toml_string ~default:id toml (base @ ["title"])
  ; fields
  ; display
  ; soft_delete = toml_bool toml (base @ ["soft_delete"]) }

let from_toml toml =
  match Toml.get_table toml ["registry"] with
  | None -> []
  | Some pairs ->
      pairs
      |> List.filter_map (fun (id, value) ->
           match value with
           | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
               Some (parse_registry toml id)
           | _ -> None )

let from_toml_file path = Toml.from_file path |> from_toml

let columns registry =
  let base =
    { Db.cname = "id"; sqlite_type = "TEXT"; primary = true; nullable = false }
    :: (registry.fields
       |> List.map (fun f ->
            { Db.cname = f.name
            ; sqlite_type = sqlite_type f.field_type
            ; primary = false
            ; nullable = not f.required } ))
  in
  if registry.soft_delete
  then
    base
    @ [ { Db.cname = "is_archived"
        ; sqlite_type = "INTEGER"
        ; primary = false
        ; nullable = false } ]
  else base

let register_table (registry : t) =
  Db.register_table {name = registry.table; columns = columns registry}

let register_tables registries = List.iter register_table registries

let pool =
  lazy
    (Db.create_pool
       ~filename:(Config.get_string ~default:"app.sqlite" "well.registry.db")
       () )

let with_db f = Db.with_conn (Lazy.force pool) f

let make_id (registry : t) =
  Printf.sprintf
    "%s_%s"
    registry.id
    (Digestif.SHA1.(digest_string (string_of_float (Unix.gettimeofday ())) |> to_hex)
     |> fun s -> String.sub s 0 12)

let sql_select_columns (registry : t) =
  "id" :: List.map (fun f -> f.name) registry.fields
  |> List.map Db.quote_id
  |> String.concat ", "

let param_of_field field value =
  let open Db in
  match field.field_type with
  | String | Text -> Text value
  | Int -> (
      try Int (int_of_string value) with Failure _ -> Null )
  | Bool ->
      Int (if value = "on" || value = "true" || value = "1" then 1 else 0)

let value_of_row field (row : Db.row) index =
  match field.field_type with
  | String | Text -> Option.value ~default:"" (row.text_opt index)
  | Int -> (
      match row.int_opt index with
      | Some value -> string_of_int value
      | None -> "" )
  | Bool -> (
      match row.bool_opt index with
      | Some true -> "true"
      | _ -> "" )

let row_mapper registry (row : Db.row) =
  let values =
    registry.fields
    |> List.mapi (fun index field ->
         (field.name, value_of_row field row (index + 1)) )
  in
  {id = row.text 0; values}

let ensure_indexes db registry =
  registry.fields
  |> List.iter (fun field ->
       if field.unique
       then
         let sql =
           Printf.sprintf
             "CREATE UNIQUE INDEX IF NOT EXISTS %s ON %s (%s)"
             (Db.quote_id ("idx_" ^ registry.table ^ "_" ^ field.name ^ "_unique"))
             (Db.quote_id registry.table)
             (Db.quote_id field.name)
         in
         ignore (Sqlite3.exec db sql) )

let list_rows ?(include_archived = false) (registry : t) =
  with_db @@ fun db ->
  ensure_indexes db registry ;
  let where =
    if registry.soft_delete && not include_archived
    then " WHERE is_archived = 0"
    else ""
  in
  let order_field =
    match registry.display with
    | name :: _ when List.exists (fun f -> f.name = name) registry.fields ->
        name
    | _ -> (
        match registry.fields with
        | f :: _ -> f.name
        | [] -> "id" )
  in
  let sql =
    Printf.sprintf
      "SELECT %s FROM %s%s ORDER BY %s"
      (sql_select_columns registry)
      (Db.quote_id registry.table)
      where
      (Db.quote_id order_field)
  in
  Db.query db sql [] (row_mapper registry)

let find_row (registry : t) id =
  with_db @@ fun db ->
  ensure_indexes db registry ;
  let sql =
    Printf.sprintf
      "SELECT %s FROM %s WHERE id = ?%s"
      (sql_select_columns registry)
      (Db.quote_id registry.table)
      (if registry.soft_delete then " AND is_archived = 0" else "")
  in
  Db.query_one db sql [Db.Text id] (row_mapper registry)

let validate (registry : t) ?id values =
  let by_name name = Option.value ~default:"" (List.assoc_opt name values) in
  with_db @@ fun db ->
  ensure_indexes db registry ;
  registry.fields
  |> List.concat_map (fun field ->
       let value = by_name field.name |> String.trim in
       let required_issue =
         if field.required && value = ""
         then [{field = field.name; message = "required"}]
         else []
       in
       let int_issue =
         match field.field_type with
         | Int when value <> "" -> (
             try
               ignore (int_of_string value) ;
               []
             with Failure _ ->
               [{field = field.name; message = "must be a number"}] )
         | _ -> []
       in
       let unique_issue =
         if field.unique && value <> ""
         then
           let sql =
             Printf.sprintf
               "SELECT id FROM %s WHERE %s = ?%s LIMIT 1"
               (Db.quote_id registry.table)
               (Db.quote_id field.name)
               (match id with
               | Some _ -> " AND id <> ?"
               | None -> "")
           in
           let params =
             Db.Text value
             ::
             match id with
             | Some current_id -> [Db.Text current_id]
             | None -> []
           in
           match Db.query_one db sql params (fun row -> row.text 0) with
           | Some _ -> [{field = field.name; message = "must be unique"}]
           | None -> []
         else []
       in
       required_issue @ int_issue @ unique_issue )

let save (registry : t) ?id values =
  match validate registry ?id values with
  | issues when issues <> [] -> Invalid issues
  | _ ->
      with_db @@ fun db ->
      ensure_indexes db registry ;
      let id = Option.value ~default:(make_id registry) id in
      let field_names = List.map (fun f -> f.name) registry.fields in
      let field_values =
        registry.fields
        |> List.map (fun field ->
             let value = Option.value ~default:"" (List.assoc_opt field.name values) in
             param_of_field field value )
      in
      ( match find_row registry id with
      | Some _ ->
          let assignments =
            field_names
            |> List.map (fun name -> Db.quote_id name ^ " = ?")
            |> String.concat ", "
          in
          let sql =
            Printf.sprintf
              "UPDATE %s SET %s WHERE id = ?"
              (Db.quote_id registry.table)
              assignments
          in
          ignore (Db.exec db sql (field_values @ [Db.Text id]))
      | None ->
          let all_names =
            "id" :: field_names @ if registry.soft_delete then ["is_archived"] else []
          in
          let placeholders =
            List.map (fun _ -> "?") all_names |> String.concat ", "
          in
          let params =
            [Db.Text id]
            @ field_values
            @ if registry.soft_delete then [Db.Int 0] else []
          in
          let sql =
            Printf.sprintf
              "INSERT INTO %s (%s) VALUES (%s)"
              (Db.quote_id registry.table)
              (all_names |> List.map Db.quote_id |> String.concat ", ")
              placeholders
          in
          ignore (Db.exec db sql params) ) ;
      Saved id

let archive (registry : t) id =
  if registry.soft_delete
  then
    with_db @@ fun db ->
    let sql =
      Printf.sprintf
        "UPDATE %s SET is_archived = 1 WHERE id = ?"
        (Db.quote_id registry.table)
    in
    ignore (Db.exec db sql [Db.Text id])

let esc = Html.escape_html

let form_params body =
  String.split_on_char '&' body
  |> List.filter_map (fun pair ->
       match String.index_opt pair '=' with
       | None ->
           if pair = "" then None else Some (Url.decode pair, "")
       | Some index ->
           let key = String.sub pair 0 index in
           let value =
             String.sub pair (index + 1) (String.length pair - index - 1)
           in
           Some (Url.decode key, Url.decode value) )

let form_value (req : Types.request) key = List.assoc_opt key (form_params req.body)

let page title body =
  Printf.sprintf
    {|<!doctype html><html><head><meta charset="utf-8"><title>%s</title><style>
body{font-family:system-ui,sans-serif;margin:32px;background:#f8fafc;color:#0f172a}
a{color:#2563eb;text-decoration:none} table{width:100%%;border-collapse:collapse;background:white}
th,td{border-bottom:1px solid #e2e8f0;padding:10px;text-align:left}
.bar{display:flex;justify-content:space-between;align-items:center;margin-bottom:18px}
.card{background:white;border:1px solid #e2e8f0;border-radius:8px;padding:18px;max-width:760px}
.field{display:flex;flex-direction:column;gap:6px;margin-bottom:14px}
label{font-weight:700;color:#475569} input,textarea{border:1px solid #cbd5e1;border-radius:6px;padding:10px;font:inherit}
textarea{min-height:120px}.actions{display:flex;gap:10px;justify-content:flex-end}.btn{border:0;border-radius:6px;padding:10px 14px;font-weight:700;cursor:pointer}.primary{background:#2563eb;color:white}.muted{background:#e2e8f0;color:#334155}.error{color:#b91c1c;font-size:13px}
</style></head><body>%s</body></html>|}
    (esc title)
    body

let issue_for issues field =
  issues
  |> List.find_opt (fun issue -> issue.field = field.name)
  |> Option.map (fun issue -> issue.message)

let render_form (registry : t) ?row ?(issues = []) base_path =
  let action =
    match row with
    | Some row -> Printf.sprintf "%s/%s/%s" base_path registry.id row.id
    | None -> Printf.sprintf "%s/%s/new" base_path registry.id
  in
  let value name =
    match row with
    | Some row -> Option.value ~default:"" (List.assoc_opt name row.values)
    | None -> ""
  in
  let fields_html =
    registry.fields
    |> List.map (fun field ->
         let value = value field.name in
         let error =
           match issue_for issues field with
           | Some msg -> Printf.sprintf {|<div class="error">%s</div>|} (esc msg)
           | None -> ""
         in
         let control =
           match input_type field.field_type with
           | "textarea" ->
               Printf.sprintf
                 {|<textarea id="%s" name="%s">%s</textarea>|}
                 (esc field.name)
                 (esc field.name)
                 (esc value)
           | "checkbox" ->
               Printf.sprintf
                 {|<input id="%s" name="%s" type="checkbox" %s>|}
                 (esc field.name)
                 (esc field.name)
                 (if value = "true" then "checked" else "")
           | typ ->
               Printf.sprintf
                 {|<input id="%s" name="%s" type="%s" value="%s">|}
                 (esc field.name)
                 (esc field.name)
                 typ
                 (esc value)
         in
         Printf.sprintf
           {|<div class="field"><label for="%s">%s</label>%s%s</div>|}
           (esc field.name)
           (esc field.label)
           control
           error )
    |> String.concat "\n"
  in
  page
    registry.title
    (Printf.sprintf
       {|<div class="bar"><h1>%s</h1><a href="%s/%s">Back</a></div><form class="card" method="post" action="%s">%s<div class="actions"><a class="btn muted" href="%s/%s">Cancel</a><button class="btn primary" type="submit">Save</button></div></form>|}
       (esc registry.title)
       (esc base_path)
       (esc registry.id)
       (esc action)
       fields_html
       (esc base_path)
       (esc registry.id))

let render_list (registry : t) rows base_path =
  let display =
    registry.display
    |> List.filter (fun name -> List.exists (fun f -> f.name = name) registry.fields)
  in
  let headers =
    display
    |> List.map (fun name ->
         let label =
           registry.fields
           |> List.find (fun f -> f.name = name)
           |> fun f -> f.label
         in
         "<th>" ^ esc label ^ "</th>" )
    |> String.concat ""
  in
  let row_html row =
    let cells =
      display
      |> List.map (fun name ->
           "<td>" ^ esc (Option.value ~default:"" (List.assoc_opt name row.values)) ^ "</td>" )
      |> String.concat ""
    in
    Printf.sprintf
      {|<tr>%s<td><a href="%s/%s/%s">Edit</a></td></tr>|}
      cells
      (esc base_path)
      (esc registry.id)
      (esc row.id)
  in
  page
    registry.title
    (Printf.sprintf
       {|<div class="bar"><h1>%s</h1><a class="btn primary" href="%s/%s/new">New</a></div><table><thead><tr>%s<th></th></tr></thead><tbody>%s</tbody></table>|}
       (esc registry.title)
       (esc base_path)
       (esc registry.id)
       headers
       (rows |> List.map row_html |> String.concat "\n"))

let route_config_by_id (registries : t list) id =
  List.find_opt (fun (r : t) -> r.id = id) registries

let register_routes ?(base_path = "/_registry") ?layout registries =
  let wrap title body =
    match layout with
    | Some f -> f ~title ~body
    | None -> body
  in
  Router.get (base_path ^ "/:registry") (fun req ->
      match route_config_by_id registries (Types.param req "registry" |> Option.value ~default:"") with
      | None -> Types.text "Registry not found" |> Types.status 404
      | Some registry ->
          let rows = list_rows registry in
          Types.html (wrap registry.title (render_list registry rows base_path)) ) ;
  Router.get (base_path ^ "/:registry/new") (fun req ->
      match route_config_by_id registries (Types.param req "registry" |> Option.value ~default:"") with
      | None -> Types.text "Registry not found" |> Types.status 404
      | Some registry ->
          Types.html (wrap registry.title (render_form registry base_path)) ) ;
  Router.post (base_path ^ "/:registry/new") (fun req ->
      match route_config_by_id registries (Types.param req "registry" |> Option.value ~default:"") with
      | None -> Types.text "Registry not found" |> Types.status 404
      | Some registry -> (
          let values =
            registry.fields
            |> List.map (fun field ->
                 (field.name, Option.value ~default:"" (form_value req field.name)) )
          in
          match save registry values with
          | Saved id -> Types.redirect (Printf.sprintf "%s/%s/%s" base_path registry.id id)
          | Invalid issues ->
              Types.html
                (wrap registry.title (render_form registry ~issues base_path)) ) ) ;
  Router.get (base_path ^ "/:registry/:row_id") (fun req ->
      match route_config_by_id registries (Types.param req "registry" |> Option.value ~default:"") with
      | None -> Types.text "Registry not found" |> Types.status 404
      | Some registry -> (
          let row_id = Types.param req "row_id" |> Option.value ~default:"" in
          match find_row registry row_id with
          | None -> Types.text "Row not found" |> Types.status 404
          | Some row ->
              Types.html (wrap registry.title (render_form registry ~row base_path)) ) ) ;
  Router.post (base_path ^ "/:registry/:row_id") (fun req ->
      match route_config_by_id registries (Types.param req "registry" |> Option.value ~default:"") with
      | None -> Types.text "Registry not found" |> Types.status 404
      | Some registry -> (
          let row_id = Types.param req "row_id" |> Option.value ~default:"" in
          let values =
            registry.fields
            |> List.map (fun field ->
                 (field.name, Option.value ~default:"" (form_value req field.name)) )
          in
          match save registry ~id:row_id values with
          | Saved id -> Types.redirect (Printf.sprintf "%s/%s/%s" base_path registry.id id)
          | Invalid issues ->
              let row = {id = row_id; values} in
              Types.html
                (wrap registry.title (render_form registry ~row ~issues base_path)) ) ) ;
  Router.post (base_path ^ "/:registry/:row_id/archive") (fun req ->
      match route_config_by_id registries (Types.param req "registry" |> Option.value ~default:"") with
      | None -> Types.text "Registry not found" |> Types.status 404
      | Some registry ->
          let row_id = Types.param req "row_id" |> Option.value ~default:"" in
          archive registry row_id ;
          Types.redirect (Printf.sprintf "%s/%s" base_path registry.id) )

let setup ?(base_path = "/_registry") ?layout registries =
  register_tables registries ;
  register_routes ~base_path ?layout registries

let setup_from_toml_file ?base_path ?layout path =
  from_toml_file path |> setup ?base_path ?layout
