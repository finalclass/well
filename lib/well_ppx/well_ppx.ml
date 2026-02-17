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
        Printf.sprintf "%s %s%s%s" c.col_name c.col_sqlite_type pk nn)
      info.tbl_cols
  in
  Printf.sprintf "CREATE TABLE IF NOT EXISTS %s (%s)" info.tbl_name
    (String.concat ", " col_strs)

(* ═══════════════════════════════════════════════════════════════════ *)
(*  Extract :param names from SQL string                              *)
(* ═══════════════════════════════════════════════════════════════════ *)

let is_ident_char c =
  (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9')
  || c = '_'

let extract_params sql =
  let len = String.length sql in
  let rec scan i acc =
    if i >= len then List.rev acc
    else if sql.[i] = ':' then begin
      let j = ref (i + 1) in
      while !j < len && is_ident_char sql.[!j] do
        incr j
      done;
      if !j > i + 1 then
        let name = String.sub sql (i + 1) (!j - i - 1) in
        if List.mem name acc then scan !j acc else scan !j (name :: acc)
      else scan (i + 1) acc
    end
    else scan (i + 1) acc
  in
  scan 0 []

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

type query_result = {
  columns : (string * string) list; (* sanitized_name, ocaml_type_name *)
  params : (string * string) list; (* param_name, ocaml_type_name *)
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
  (* Prepare the query — SQLite validates it *)
  let stmt =
    try Sqlite3.prepare db sql
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
  (* Extract parameters from SQL *)
  let param_names = extract_params sql in
  let params =
    List.map
      (fun name ->
        let ocaml_type =
          match find_column name with
          | Some col -> sqlite_to_ocaml_name col.col_sqlite_type
          | None -> "string"
        in
        (name, ocaml_type))
      param_names
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

let gen_param_bind ~loc idx (param_name, type_name) =
  let idx_e = Ast_builder.Default.eint ~loc (idx + 1) in
  let param_e = Ast_builder.Default.evar ~loc param_name in
  let data_e =
    match type_name with
    | "int" -> [%expr Sqlite3.Data.INT (Int64.of_int [%e param_e])]
    | "float" -> [%expr Sqlite3.Data.FLOAT [%e param_e]]
    | _ -> [%expr Sqlite3.Data.TEXT [%e param_e]]
  in
  [%expr ignore (Sqlite3.bind stmt [%e idx_e] [%e data_e])]

let capitalize s =
  if String.length s = 0 then s
  else
    String.make 1 (Char.uppercase_ascii s.[0])
    ^ String.sub s 1 (String.length s - 1)

(* ═══════════════════════════════════════════════════════════════════ *)
(*  Generate module for let%query                                     *)
(* ═══════════════════════════════════════════════════════════════════ *)

let gen_query_module ~loc name sql =
  let info = validate_sql ~loc sql in
  let module_name = capitalize name in
  let sql_e = Ast_builder.Default.estring ~loc sql in
  if info.columns = [] then begin
    (* Non-SELECT (INSERT/UPDATE/DELETE) → exec returning unit *)
    let bind_exprs =
      List.mapi (fun i p -> gen_param_bind ~loc i p) info.params
    in
    let exec_body =
      let stmts =
        List.fold_right
          (fun e acc -> [%expr [%e e]; [%e acc]])
          bind_exprs
          [%expr
            ignore (Sqlite3.step stmt);
            ignore (Sqlite3.finalize stmt)]
      in
      [%expr
        let stmt = Sqlite3.prepare db [%e sql_e] in
        [%e stmts]]
    in
    let exec_fun =
      List.fold_right
        (fun (pname, _ptype) body ->
          Ast_builder.Default.pexp_fun ~loc (Labelled pname) None
            (Ast_builder.Default.ppat_var ~loc { txt = pname; loc })
            body)
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
    let bind_exprs =
      List.mapi (fun i p -> gen_param_bind ~loc i p) info.params
    in
    let query_body =
      let loop_and_collect =
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
      let with_binds =
        List.fold_right
          (fun e acc -> [%expr [%e e]; [%e acc]])
          bind_exprs loop_and_collect
      in
      [%expr
        let stmt = Sqlite3.prepare db [%e sql_e] in
        [%e with_binds]]
    in
    let query_fun =
      List.fold_right
        (fun (pname, _ptype) body ->
          Ast_builder.Default.pexp_fun ~loc (Labelled pname) None
            (Ast_builder.Default.ppat_var ~loc { txt = pname; loc })
            body)
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
