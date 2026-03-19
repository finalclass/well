open Ppxlib

(* ═══════════════════════════════════════════════════════════════════ *)
(*  Schema Registry — populated by [@@deriving table], read by query  *)
(* ═══════════════════════════════════════════════════════════════════ *)

type col_info = {
  col_name : string;
  col_sqlite_type : string;
  col_nullable : bool;
  col_primary : bool;
}

type tbl_info = {
  tbl_name : string;
  tbl_cols : col_info list;
}

let tables : (string, tbl_info) Hashtbl.t = Hashtbl.create 16

let find_column name =
  Hashtbl.fold
    (fun _tname tbl acc ->
      match acc with
      | Some _ -> acc
      | None -> List.find_opt (fun c -> c.col_name = name) tbl.tbl_cols)
    tables None

(* ═══════════════════════════════════════════════════════════════════ *)
(*  Type Mapping                                                      *)
(* ═══════════════════════════════════════════════════════════════════ *)

let rec ocaml_to_sqlite (ct : core_type) : string * bool =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "int"; _ }, []) -> ("INTEGER", false)
  | Ptyp_constr ({ txt = Lident "int64"; _ }, []) -> ("INTEGER", false)
  | Ptyp_constr ({ txt = Lident "float"; _ }, []) -> ("REAL", false)
  | Ptyp_constr ({ txt = Lident "string"; _ }, []) -> ("TEXT", false)
  | Ptyp_constr ({ txt = Lident "bool"; _ }, []) -> ("INTEGER", false)
  | Ptyp_constr ({ txt = Lident "option"; _ }, [inner]) ->
      let t, _ = ocaml_to_sqlite inner in
      (t, true)
  | _ -> ("TEXT", false)

let sqlite_to_ocaml_name = function
  | "INTEGER" | "INT" | "BIGINT" | "SMALLINT" | "TINYINT" | "BOOLEAN" -> "int"
  | "REAL" | "FLOAT" | "DOUBLE" -> "float"
  | "TEXT" | "VARCHAR" | "CHAR" | "CLOB" -> "string"
  | "BLOB" -> "string"
  | _ -> "string"

(* ═══════════════════════════════════════════════════════════════════ *)
(*  SQL Generation                                                    *)
(* ═══════════════════════════════════════════════════════════════════ *)

let create_table_sql info =
  let col_strs =
    List.map
      (fun c ->
        let pk = if c.col_primary then " PRIMARY KEY" else "" in
        let nn =
          if c.col_nullable || c.col_primary then "" else " NOT NULL"
        in
        Printf.sprintf "\"%s\" %s%s%s" c.col_name c.col_sqlite_type pk nn)
      info.tbl_cols
  in
  Printf.sprintf "CREATE TABLE IF NOT EXISTS \"%s\" (%s)" info.tbl_name
    (String.concat ", " col_strs)

(* ═══════════════════════════════════════════════════════════════════ *)
(*  Extract :param names from SQL string                              *)
(*  :param  — required parameter                                      *)
(*  :param? — optional parameter (binds NULL when None)               *)
(*  IN (:param) — list parameter (expands to ?,?,? at runtime)        *)
(* ═══════════════════════════════════════════════════════════════════ *)

let is_ident_char c =
  (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9')
  || c = '_'

type param_kind = Plain | Optional | List

type param = {
  p_name : string;
  p_kind : param_kind;
  p_column_hint : string option;  (* for IN params: the column name from SQL context *)
  p_type_hint : string option;    (* forced type from SQL context: LIMIT/OFFSET → "int" *)
}

let extract_params sql =
  let len = String.length sql in
  let rec scan i acc =
    if i >= len then List.rev acc
    else if sql.[i] = ':' then begin
      let j = ref (i + 1) in
      while !j < len && is_ident_char sql.[!j] do
        incr j
      done;
      if !j > i + 1 then begin
        let name = String.sub sql (i + 1) (!j - i - 1) in
        (* Check for trailing ? → optional *)
        let kind, end_pos =
          if !j < len && sql.[!j] = '?' then (Optional, !j + 1)
          else (Plain, !j)
        in
        if List.exists (fun p -> p.p_name = name) acc then scan end_pos acc
        else scan end_pos ({ p_name = name; p_kind = kind; p_column_hint = None; p_type_hint = None } :: acc)
      end
      else scan (i + 1) acc
    end
    else scan (i + 1) acc
  in
  let params = scan 0 [] in
  (* Detect IN (:param) — upgrade matching params to List kind
     Also capture the column name from "column IN (:param)" for type inference *)
  let in_re = Str.regexp_case_fold
    {|\([a-zA-Z_][a-zA-Z0-9_.]*\)[ \t]+IN[ \t]*([ \t]*:\([a-zA-Z_][a-zA-Z0-9_]*\)[ \t]*)|} in
  let in_params = ref [] in  (* (param_name, column_name) *)
  let s = ref 0 in
  (try while true do
    let _ = Str.search_forward in_re sql !s in
    let col_name = Str.matched_group 1 sql in
    let param_name = Str.matched_group 2 sql in
    (* Strip table prefix: "users.id" → "id" *)
    let col_hint = match String.split_on_char '.' col_name with
      | [_; c] -> c | _ -> col_name in
    in_params := (param_name, col_hint) :: !in_params;
    s := Str.match_end ()
  done with Not_found -> ());
  (* Detect LIMIT/OFFSET :param — force int type *)
  let int_kw_re = Str.regexp_case_fold
    {|\(LIMIT\|OFFSET\)[ \t]+:\([a-zA-Z_][a-zA-Z0-9_]*\)|} in
  let int_params = ref [] in
  let s2 = ref 0 in
  (try while true do
    let _ = Str.search_forward int_kw_re sql !s2 in
    int_params := Str.matched_group 2 sql :: !int_params;
    s2 := Str.match_end ()
  done with Not_found -> ());
  List.map (fun p ->
    let p = match List.assoc_opt p.p_name !in_params with
      | Some col_hint -> { p with p_kind = List; p_column_hint = Some col_hint }
      | None -> p
    in
    if List.mem p.p_name !int_params then { p with p_type_hint = Some "int" }
    else p
  ) params

(* Rewrite SQL for validation: replace IN (:param) with IN (NULL)
   and :param? with NULL for SQLite to accept the query *)
let sql_for_validation sql =
  let s = Str.global_replace
    (Str.regexp_case_fold {|IN[ \t]*([ \t]*:[a-zA-Z_][a-zA-Z0-9_]*[ \t]*)|})
    "IN (NULL)" sql
  in
  (* Replace :param? with NULL *)
  Str.global_replace
    (Str.regexp {|:[a-zA-Z_][a-zA-Z0-9_]*\?|})
    "NULL" s

(* Rewrite SQL: strip ? from :param?, keep :param as-is for plain *)
let sql_for_runtime sql =
  Str.global_replace
    (Str.regexp {|\(:[a-zA-Z_][a-zA-Z0-9_]*\)\?|})
    {|\1|} sql

(* ═══════════════════════════════════════════════════════════════════ *)
(*  Sanitize column names for OCaml identifiers                       *)
(* ═══════════════════════════════════════════════════════════════════ *)

let sanitize_name s =
  let s = String.lowercase_ascii s in
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      if is_ident_char c then Buffer.add_char buf c
      else Buffer.add_char buf '_')
    s;
  let result = Buffer.contents buf in
  if String.length result = 0 then "column"
  else if result.[0] >= '0' && result.[0] <= '9' then "c_" ^ result
  else result

(* ═══════════════════════════════════════════════════════════════════ *)
(*  [@@deriving table]                                                *)
(* ═══════════════════════════════════════════════════════════════════ *)

let derive_table_impl ~ctxt (_rec_flag, type_decls) name_opt =
  let loc = Expansion_context.Deriver.derived_item_loc ctxt in
  List.concat_map
    (fun (td : type_declaration) ->
      match td.ptype_kind with
      | Ptype_record fields ->
          let type_name = td.ptype_name.txt in
          let table_name =
            match name_opt with Some n -> n | None -> type_name
          in
          let cols =
            List.map
              (fun (ld : label_declaration) ->
                let fname = ld.pld_name.txt in
                let sql_type, nullable = ocaml_to_sqlite ld.pld_type in
                let primary = fname = "id" && sql_type = "INTEGER" in
                {
                  col_name = fname;
                  col_sqlite_type = sql_type;
                  col_nullable = nullable;
                  col_primary = primary;
                })
              fields
          in
          let info = { tbl_name = table_name; tbl_cols = cols } in
          Hashtbl.replace tables table_name info;
          let sql_str = create_table_sql info in
          let pat =
            Ast_builder.Default.pvar ~loc
              (type_name ^ "_create_table_sql")
          in
          (* Generate: let _ = fun (__x : t) -> (__x.f1, __x.f2, ...) *)
          (* This suppresses warning 69 (unused record fields) *)
          let field_use =
            let x_var = Ast_builder.Default.evar ~loc "__well_x" in
            let field_exprs =
              List.map
                (fun (ld : label_declaration) ->
                  Ast_builder.Default.pexp_field ~loc x_var
                    { txt = Lident ld.pld_name.txt; loc })
                fields
            in
            let body =
              match field_exprs with
              | [ e ] -> e
              | es -> Ast_builder.Default.pexp_tuple ~loc es
            in
            let x_pat =
              Ast_builder.Default.ppat_constraint ~loc
                (Ast_builder.Default.ppat_var ~loc
                   { txt = "__well_x"; loc })
                (Ast_builder.Default.ptyp_constr ~loc
                   { txt = Lident type_name; loc }
                   [])
            in
            [%stri let _ = fun [%p x_pat] -> [%e body]]
          in
          (* Generate: let () = Well.Db.register_table { Well.Db.name = "tbl"; columns = [...] } *)
          let register_call =
            let mk_field name =
              { txt = Ldot (Ldot (Lident "Well", "Db"), name); loc }
            in
            let col_exprs =
              List.map (fun c ->
                Ast_builder.Default.pexp_record ~loc [
                  (mk_field "cname", Ast_builder.Default.estring ~loc c.col_name);
                  (mk_field "sqlite_type", Ast_builder.Default.estring ~loc c.col_sqlite_type);
                  (mk_field "primary", Ast_builder.Default.ebool ~loc c.col_primary);
                  (mk_field "nullable", Ast_builder.Default.ebool ~loc c.col_nullable);
                ] None
              ) cols
            in
            let tbl_expr =
              Ast_builder.Default.pexp_record ~loc [
                (mk_field "name", Ast_builder.Default.estring ~loc table_name);
                (mk_field "columns", Ast_builder.Default.elist ~loc col_exprs);
              ] None
            in
            let register_fn =
              Ast_builder.Default.pexp_ident ~loc
                { txt = Ldot (Ldot (Lident "Well", "Db"), "register_table"); loc }
            in
            [%stri let () = [%e Ast_builder.Default.pexp_apply ~loc
              register_fn [(Nolabel, tbl_expr)]]]
          in
          [
            field_use;
            [%stri
              let [%p pat] = [%e Ast_builder.Default.estring ~loc sql_str]];
            register_call;
          ]
      | _ ->
          Location.raise_errorf ~loc
            "[@@deriving table] requires a record type")
    type_decls

let _ =
  Deriving.add "table"
    ~str_type_decl:
      (Deriving.Generator.V2.make
         Deriving.Args.(empty +> arg "name" (estring __))
         derive_table_impl)

(* ═══════════════════════════════════════════════════════════════════ *)
(*  Compile-time SQL validation via in-memory SQLite                  *)
(* ═══════════════════════════════════════════════════════════════════ *)

type typed_param = {
  tp_name : string;
  tp_type : string;  (* ocaml type name *)
  tp_kind : param_kind;
}

type query_result = {
  columns : (string * string) list; (* sanitized_name, ocaml_type_name *)
  params : typed_param list;
}

let validate_sql ~loc sql =
  let db = Sqlite3.db_open ":memory:" in
  (* Create all registered tables in the in-memory DB *)
  Hashtbl.iter
    (fun _name info ->
      let ddl = create_table_sql info in
      match Sqlite3.exec db ddl with
      | Sqlite3.Rc.OK -> ()
      | rc ->
          ignore (Sqlite3.db_close db);
          Location.raise_errorf ~loc
            "well.ppx internal: failed to create table %s: %s"
            info.tbl_name (Sqlite3.Rc.to_string rc))
    tables;
  (* Validate with rewritten SQL (IN (:x) → IN (NULL), :x? → NULL) *)
  let validation_sql = sql_for_validation sql in
  let stmt =
    try Sqlite3.prepare db validation_sql
    with Sqlite3.Error msg ->
      ignore (Sqlite3.db_close db);
      Location.raise_errorf ~loc "SQL error: %s\n  in: %s" msg sql
  in
  (* Extract result columns *)
  let col_count = Sqlite3.column_count stmt in
  let columns =
    List.init col_count (fun i ->
        let raw_name = Sqlite3.column_name stmt i in
        let name = sanitize_name raw_name in
        let ocaml_type =
          match Sqlite3.column_decltype stmt i with
          | Some dt -> sqlite_to_ocaml_name dt
          | None -> (
              match find_column raw_name with
              | Some col -> sqlite_to_ocaml_name col.col_sqlite_type
              | None -> "string")
        in
        (name, ocaml_type))
  in
  (* Extract parameters from original SQL *)
  let raw_params = extract_params sql in
  let params =
    List.map
      (fun p ->
        let ocaml_type =
          (* Explicit type hint from SQL context (LIMIT/OFFSET → int) *)
          match p.p_type_hint with
          | Some t -> t
          | None ->
          match find_column p.p_name with
          | Some col -> sqlite_to_ocaml_name col.col_sqlite_type
          | None ->
            (* For IN params, try the column hint (e.g. "id" from "id IN (:ids)") *)
            match p.p_column_hint with
            | Some hint -> (match find_column hint with
              | Some col -> sqlite_to_ocaml_name col.col_sqlite_type
              | None -> "string")
            | None -> "string"
        in
        { tp_name = p.p_name; tp_type = ocaml_type; tp_kind = p.p_kind })
      raw_params
  in
  ignore (Sqlite3.finalize stmt);
  ignore (Sqlite3.db_close db);
  { columns; params }

(* ═══════════════════════════════════════════════════════════════════ *)
(*  Code generation helpers                                           *)
(* ═══════════════════════════════════════════════════════════════════ *)

let gen_col_extract ~loc idx (_col_name, type_name) =
  let stmt_e = Ast_builder.Default.evar ~loc "stmt" in
  let idx_e = Ast_builder.Default.eint ~loc idx in
  let col_e = [%expr Sqlite3.column [%e stmt_e] [%e idx_e]] in
  match type_name with
  | "int" ->
      [%expr
        match [%e col_e] with
        | Sqlite3.Data.INT i -> Int64.to_int i
        | Sqlite3.Data.FLOAT f -> int_of_float f
        | _ -> 0]
  | "float" ->
      [%expr
        match [%e col_e] with
        | Sqlite3.Data.FLOAT f -> f
        | Sqlite3.Data.INT i -> Int64.to_float i
        | _ -> 0.0]
  | _ ->
      [%expr
        match [%e col_e] with
        | Sqlite3.Data.TEXT s -> s
        | Sqlite3.Data.BLOB s -> s
        | Sqlite3.Data.INT i -> Int64.to_string i
        | Sqlite3.Data.FLOAT f -> string_of_float f
        | _ -> ""]

let gen_data_expr ~loc type_name value_e =
  match type_name with
  | "int" -> [%expr Sqlite3.Data.INT (Int64.of_int [%e value_e])]
  | "float" -> [%expr Sqlite3.Data.FLOAT [%e value_e]]
  | _ -> [%expr Sqlite3.Data.TEXT [%e value_e]]

let gen_param_bind ~loc idx tp =
  let param_e = Ast_builder.Default.evar ~loc tp.tp_name in
  match tp.tp_kind with
  | Plain ->
    let idx_e = Ast_builder.Default.eint ~loc (idx + 1) in
    let data_e = gen_data_expr ~loc tp.tp_type param_e in
    [%expr ignore (Sqlite3.bind stmt [%e idx_e] [%e data_e])]
  | Optional ->
    let idx_e = Ast_builder.Default.eint ~loc (idx + 1) in
    [%expr ignore (Sqlite3.bind stmt [%e idx_e]
      (match [%e param_e] with
       | None -> Sqlite3.Data.NULL
       | Some _v -> [%e gen_data_expr ~loc tp.tp_type (Ast_builder.Default.evar ~loc "_v")]))]
  | List ->
    (* List params use dynamic binding — handled separately *)
    [%expr ignore [%e param_e]]  (* placeholder, not actually used *)

let capitalize s =
  if String.length s = 0 then s
  else
    String.make 1 (Char.uppercase_ascii s.[0])
    ^ String.sub s 1 (String.length s - 1)

(* ═══════════════════════════════════════════════════════════════════ *)
(*  Generate module for let%query                                     *)
(* ═══════════════════════════════════════════════════════════════════ *)

let has_list_params params = List.exists (fun tp -> tp.tp_kind = List) params

(* Generate the function parameter type for a typed_param *)
let gen_param_type ~loc tp =
  let base_type = Ast_builder.Default.ptyp_constr ~loc
    { txt = Lident tp.tp_type; loc } [] in
  match tp.tp_kind with
  | Plain -> base_type
  | Optional ->
    Ast_builder.Default.ptyp_constr ~loc { txt = Lident "option"; loc } [base_type]
  | List ->
    Ast_builder.Default.ptyp_constr ~loc { txt = Lident "list"; loc } [base_type]

(* Generate body that prepares SQL, binds params, and executes.
   For queries with list params, SQL is rewritten at runtime.
   All params are converted to positional ? and bound in SQL appearance order. *)
let gen_body_with_binds ~loc sql info tail_expr =
  let runtime_sql = sql_for_runtime sql in
  let sql_e = Ast_builder.Default.estring ~loc runtime_sql in
  if has_list_params info.params then begin
    (* Dynamic SQL: replace ALL named params with positional ?,
       and IN (:param) with IN (?,?,?) — bind in order of appearance *)
    let list_params = List.filter (fun tp -> tp.tp_kind = List) info.params in
    (* Step 1: rewrite IN (:param) → IN (:param) placeholder (expand at runtime) *)
    let sql_rewrite =
      List.fold_left (fun acc tp ->
        let param_e = Ast_builder.Default.evar ~loc tp.tp_name in
        let pattern_str = Ast_builder.Default.estring ~loc
          (Printf.sprintf "IN (:%s)" tp.tp_name) in
        [%expr
          let _n = List.length [%e param_e] in
          let _placeholders =
            if _n = 0 then "IN (SELECT NULL WHERE 0)"
            else "IN (" ^ String.concat "," (List.init _n (fun _ -> "?")) ^ ")"
          in
          Str.global_replace (Str.regexp_case_fold [%e pattern_str]) _placeholders [%e acc]]
      ) [%expr _sql] list_params
    in
    (* Step 2: replace remaining named params with ? *)
    let non_list = List.filter (fun tp -> tp.tp_kind <> List) info.params in
    let sql_rewrite2 =
      List.fold_left (fun acc tp ->
        let pattern_str = Ast_builder.Default.estring ~loc
          (Printf.sprintf ":%s" tp.tp_name) in
        [%expr Str.global_replace (Str.regexp [%e pattern_str]) "?" [%e acc]]
      ) sql_rewrite non_list
    in
    (* Step 3: bind in SQL appearance order using _offset counter *)
    let bind_exprs = List.map (fun tp ->
      let param_e = Ast_builder.Default.evar ~loc tp.tp_name in
      match tp.tp_kind with
      | List ->
        let bind_one = match tp.tp_type with
          | "int" -> [%expr fun _i v -> ignore (Sqlite3.bind stmt _i (Sqlite3.Data.INT (Int64.of_int v)))]
          | "float" -> [%expr fun _i v -> ignore (Sqlite3.bind stmt _i (Sqlite3.Data.FLOAT v))]
          | _ -> [%expr fun _i v -> ignore (Sqlite3.bind stmt _i (Sqlite3.Data.TEXT v))]
        in
        [%expr
          let _bind_one = [%e bind_one] in
          List.iteri (fun _j v -> _bind_one (!_off + _j + 1) v) [%e param_e];
          _off := !_off + List.length [%e param_e]]
      | Optional ->
        [%expr
          _off := !_off + 1;
          ignore (Sqlite3.bind stmt !_off
            (match [%e param_e] with
             | None -> Sqlite3.Data.NULL
             | Some _v -> [%e gen_data_expr ~loc tp.tp_type (Ast_builder.Default.evar ~loc "_v")]))]
      | Plain ->
        let data_e = gen_data_expr ~loc tp.tp_type param_e in
        [%expr _off := !_off + 1; ignore (Sqlite3.bind stmt !_off [%e data_e])]
    ) info.params in
    let all_binds =
      List.fold_right (fun e acc -> [%expr [%e e]; [%e acc]])
        bind_exprs tail_expr
    in
    [%expr
      let _sql = [%e sql_e] in
      let _sql = [%e sql_rewrite2] in
      let stmt = Sqlite3.prepare db _sql in
      let _off = ref 0 in
      [%e all_binds]]
  end else begin
    (* Simple case: no list params, static SQL *)
    let bind_exprs =
      List.mapi (fun i p -> gen_param_bind ~loc i p) info.params
    in
    let with_binds =
      List.fold_right
        (fun e acc -> [%expr [%e e]; [%e acc]])
        bind_exprs tail_expr
    in
    [%expr
      let stmt = Sqlite3.prepare db [%e sql_e] in
      [%e with_binds]]
  end

let gen_query_module ~loc name sql =
  let info = validate_sql ~loc sql in
  let module_name = capitalize name in
  let runtime_sql = sql_for_runtime sql in
  let sql_e = Ast_builder.Default.estring ~loc runtime_sql in
  if info.columns = [] then begin
    (* Non-SELECT (INSERT/UPDATE/DELETE) → exec returning unit *)
    let exec_body = gen_body_with_binds ~loc sql info
      [%expr
        ignore (Sqlite3.step stmt);
        ignore (Sqlite3.finalize stmt)]
    in
    let exec_fun =
      List.fold_right
        (fun tp body ->
          let pat = Ast_builder.Default.ppat_constraint ~loc
            (Ast_builder.Default.ppat_var ~loc { txt = tp.tp_name; loc })
            (gen_param_type ~loc tp) in
          Ast_builder.Default.pexp_fun ~loc (Labelled tp.tp_name) None pat body)
        info.params exec_body
    in
    let exec_with_db =
      [%expr fun (db : Sqlite3.db) -> [%e exec_fun]]
    in
    let mod_items =
      [
        [%stri [@@@warning "-32"]];
        [%stri let sql = [%e sql_e]];
        [%stri let exec = [%e exec_with_db]];
      ]
    in
    {
      pstr_desc =
        Pstr_module
          {
            pmb_name = { txt = Some module_name; loc };
            pmb_expr =
              {
                pmod_desc = Pmod_structure mod_items;
                pmod_loc = loc;
                pmod_attributes = [];
              };
            pmb_attributes = [];
            pmb_loc = loc;
          };
      pstr_loc = loc;
    }
  end
  else begin
    (* SELECT → query returning row list *)
    let row_fields =
      List.map
        (fun (col_name, type_name) ->
          Ast_builder.Default.label_declaration ~loc
            ~name:{ txt = col_name; loc }
            ~mutable_:Immutable
            ~type_:
              (Ast_builder.Default.ptyp_constr ~loc
                 { txt = Lident type_name; loc }
                 []))
        info.columns
    in
    let row_td =
      Ast_builder.Default.type_declaration ~loc ~name:{ txt = "row"; loc }
        ~params:[] ~cstrs:[] ~kind:(Ptype_record row_fields)
        ~private_:Public ~manifest:None
    in
    let type_stri =
      { pstr_desc = Pstr_type (Recursive, [row_td]); pstr_loc = loc }
    in
    (* Row construction expression *)
    let row_fields_expr =
      List.mapi
        (fun i (col_name, type_name) ->
          ( { txt = Lident col_name; loc },
            gen_col_extract ~loc i (col_name, type_name) ))
        info.columns
    in
    let row_expr =
      Ast_builder.Default.pexp_record ~loc row_fields_expr None
    in
    (* Parameter bindings + collect loop *)
    let query_body = gen_body_with_binds ~loc sql info
      [%expr
        let results = ref [] in
        let rec loop () =
          match Sqlite3.step stmt with
          | Sqlite3.Rc.ROW ->
              results := [%e row_expr] :: !results;
              loop ()
          | _ -> ()
        in
        loop ();
        ignore (Sqlite3.finalize stmt);
        List.rev !results]
    in
    let query_fun =
      List.fold_right
        (fun tp body ->
          let pat = Ast_builder.Default.ppat_constraint ~loc
            (Ast_builder.Default.ppat_var ~loc { txt = tp.tp_name; loc })
            (gen_param_type ~loc tp) in
          Ast_builder.Default.pexp_fun ~loc (Labelled tp.tp_name) None pat body)
        info.params query_body
    in
    let query_with_db =
      [%expr fun (db : Sqlite3.db) -> [%e query_fun]]
    in
    let mod_items =
      [
        [%stri [@@@warning "-32"]];
        type_stri;
        [%stri let sql = [%e sql_e]];
        [%stri let query = [%e query_with_db]];
      ]
    in
    {
      pstr_desc =
        Pstr_module
          {
            pmb_name = { txt = Some module_name; loc };
            pmb_expr =
              {
                pmod_desc = Pmod_structure mod_items;
                pmod_loc = loc;
                pmod_attributes = [];
              };
            pmb_attributes = [];
            pmb_loc = loc;
          };
      pstr_loc = loc;
    }
  end

(* ═══════════════════════════════════════════════════════════════════ *)
(*  let%query extension                                               *)
(* ═══════════════════════════════════════════════════════════════════ *)

let query_expand ~ctxt payload =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  match payload with
  | [
      {
        pstr_desc =
          Pstr_value
            ( Nonrecursive,
              [
                {
                  pvb_pat = { ppat_desc = Ppat_var { txt = name; _ }; _ };
                  pvb_expr =
                    {
                      pexp_desc = Pexp_constant (Pconst_string (sql, _, _));
                      _;
                    };
                  _;
                };
              ] );
        _;
      };
    ] ->
      gen_query_module ~loc name sql
  | _ ->
      Location.raise_errorf ~loc
        "Expected: let%%query name = \"SQL string\""

let query_extension =
  Extension.V3.declare "query" Extension.Context.structure_item
    Ast_pattern.(pstr __)
    query_expand

(* ═══════════════════════════════════════════════════════════════════ *)
(*  [@@deriving topic]                                                *)
(* ═══════════════════════════════════════════════════════════════════ *)

let derive_topic_impl ~ctxt (_rec_flag, type_decls) name_opt =
  let loc = Expansion_context.Deriver.derived_item_loc ctxt in
  List.concat_map
    (fun (td : type_declaration) ->
      let type_name = td.ptype_name.txt in
      let channel_name =
        match name_opt with Some n -> n | None -> type_name
      in
      let to_yojson_fn =
        Ast_builder.Default.evar ~loc (type_name ^ "_to_yojson")
      in
      let of_yojson_fn =
        Ast_builder.Default.evar ~loc (type_name ^ "_of_yojson")
      in
      let channel_str = Ast_builder.Default.estring ~loc channel_name in
      let topic_ctor =
        Ast_builder.Default.pexp_ident ~loc
          { txt = Ldot (Lident "Well", "topic"); loc }
      in
      let pat = Ast_builder.Default.pvar ~loc type_name in
      [
        [%stri
          let [%p pat] =
            [%e Ast_builder.Default.pexp_apply ~loc topic_ctor
              [ (Nolabel, channel_str);
                (Nolabel, to_yojson_fn);
                (Nolabel, of_yojson_fn) ]]];
      ])
    type_decls

let _ =
  Deriving.add "topic"
    ~str_type_decl:
      (Deriving.Generator.V2.make
         Deriving.Args.(empty +> arg "name" (estring __))
         derive_topic_impl)

let () =
  Driver.register_transformation "well_ppx"
    ~rules:[ Ppxlib.Context_free.Rule.extension query_extension ]
