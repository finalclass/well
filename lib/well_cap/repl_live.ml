(* repl_live.ml — REPL LiveView for Cap admin panel *)
(* In-process expression shell for querying services *)

open Cap_helpers

(* ── Schema types ────────────────────────────────────────────────── *)

type field_info = { fname : string; ftype : string; foptional : bool }

type method_info = {
  params : field_info list;
  returns : field_info list;
  returns_name : string;
}

type schema = (string * (string * method_info) list) list

let build_schema () : schema =
  let json = Well.Service.describe_services () in
  match json with
  | `Assoc services ->
    List.filter_map (fun (sname, methods_json) ->
      if String.length sname > 0 && sname.[0] = '_' then None
      else
      let methods = match methods_json with
        | `Assoc ms ->
          List.map (fun (mname, minfo) ->
            let parse_fields key =
              match minfo with
              | `Assoc a ->
                (match List.assoc_opt key a with
                 | Some (`List fields) ->
                   List.filter_map (fun f ->
                     match f with
                     | `Assoc fl ->
                       let get k = match List.assoc_opt k fl with
                         | Some (`String s) -> s | _ -> "" in
                       let opt = match List.assoc_opt "optional" fl with
                         | Some (`Bool b) -> b | _ -> false in
                       Some { fname = get "name"; ftype = get "type"; foptional = opt }
                     | _ -> None
                   ) fields
                 | _ -> [])
              | _ -> []
            in
            let returns_name = match minfo with
              | `Assoc a ->
                (match List.assoc_opt "returns_name" a with
                 | Some (`String s) -> s | _ -> mname)
              | _ -> mname
            in
            (mname, { params = parse_fields "params";
                      returns = parse_fields "returns";
                      returns_name })
          ) ms
        | _ -> []
      in
      Some (sname, methods)
    ) services
  | _ -> []

let schema_to_json (schema : schema) =
  let services = List.map (fun (sname, methods) ->
    let ms = List.map (fun (mname, minfo) ->
      let params = `List (List.map (fun fi ->
        `Assoc [("name", `String fi.fname); ("type", `String fi.ftype);
                ("optional", `Bool fi.foptional)]
      ) minfo.params) in
      (mname, `Assoc [("params", params)])
    ) methods in
    (sname, `Assoc ms)
  ) schema in
  Yojson.Safe.to_string (`Assoc services)

(* ── Tokenizer ───────────────────────────────────────────────────── *)

type token =
  | TIdent of string
  | TString of string
  | TInt of int
  | TFloat of float
  | TBool of bool
  | TDot
  | TColon
  | TTilde
  | TPipe
  | TLParen
  | TRParen
  | TPlus
  | TMinus
  | TStar
  | TSlash
  | TPercent
  | TEq
  | TLet
  | TEOF

let is_ident_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') || c = '_'

let tokenize input =
  let len = String.length input in
  let pos = ref 0 in
  let tokens = ref [] in
  let peek () = if !pos < len then Some input.[!pos] else None in
  let advance () = incr pos in
  let rec skip_ws () =
    match peek () with
    | Some (' ' | '\t' | '\r' | '\n') -> advance (); skip_ws ()
    | _ -> ()
  in
  let read_string delim =
    advance ();
    let buf = Buffer.create 32 in
    let rec loop () =
      match peek () with
      | None -> Buffer.contents buf
      | Some c when c = delim -> advance (); Buffer.contents buf
      | Some '\\' ->
        advance ();
        (match peek () with
         | Some 'n' -> Buffer.add_char buf '\n'; advance ()
         | Some 't' -> Buffer.add_char buf '\t'; advance ()
         | Some '\\' -> Buffer.add_char buf '\\'; advance ()
         | Some c when c = delim -> Buffer.add_char buf c; advance ()
         | Some c -> Buffer.add_char buf '\\'; Buffer.add_char buf c; advance ()
         | None -> Buffer.add_char buf '\\');
        loop ()
      | Some '{' ->
        advance ();
        let depth = ref 1 in
        let expr_buf = Buffer.create 16 in
        while !depth > 0 do
          match peek () with
          | None -> depth := 0
          | Some '{' -> Buffer.add_char expr_buf '{'; incr depth; advance ()
          | Some '}' -> decr depth; if !depth > 0 then Buffer.add_char expr_buf '}'; advance ()
          | Some c -> Buffer.add_char expr_buf c; advance ()
        done;
        Buffer.add_char buf '\x00';
        Buffer.add_string buf (Buffer.contents expr_buf);
        Buffer.add_char buf '\x00';
        loop ()
      | Some c -> Buffer.add_char buf c; advance (); loop ()
    in
    loop ()
  in
  let read_number () =
    let start = !pos in
    let is_float = ref false in
    while (match peek () with Some c -> (c >= '0' && c <= '9') || c = '.' | _ -> false) do
      if (match peek () with Some '.' -> true | _ -> false) then is_float := true;
      advance ()
    done;
    let s = String.sub input start (!pos - start) in
    if !is_float then TFloat (float_of_string s)
    else TInt (int_of_string s)
  in
  let read_ident () =
    let start = !pos in
    while (match peek () with Some c -> is_ident_char c | _ -> false) do
      advance ()
    done;
    String.sub input start (!pos - start)
  in
  let rec scan () =
    skip_ws ();
    match peek () with
    | None -> tokens := TEOF :: !tokens
    | Some '"' ->
      let s = read_string '"' in
      tokens := TString s :: !tokens; scan ()
    | Some '\'' ->
      let s = read_string '\'' in
      tokens := TString s :: !tokens; scan ()
    | Some '.' -> advance (); tokens := TDot :: !tokens; scan ()
    | Some ':' -> advance (); tokens := TColon :: !tokens; scan ()
    | Some '~' -> advance (); tokens := TTilde :: !tokens; scan ()
    | Some '|' ->
      advance ();
      (match peek () with Some '>' -> advance () | _ -> ());
      tokens := TPipe :: !tokens; scan ()
    | Some '(' -> advance (); tokens := TLParen :: !tokens; scan ()
    | Some ')' -> advance (); tokens := TRParen :: !tokens; scan ()
    | Some '+' -> advance (); tokens := TPlus :: !tokens; scan ()
    | Some '-' ->
      advance ();
      (match peek () with
       | Some c when c >= '0' && c <= '9' ->
         let t = read_number () in
         let t = match t with
           | TInt n -> TInt (-n)
           | TFloat f -> TFloat (-.f)
           | _ -> t
         in
         tokens := t :: !tokens
       | _ -> tokens := TMinus :: !tokens);
      scan ()
    | Some '*' -> advance (); tokens := TStar :: !tokens; scan ()
    | Some '/' -> advance (); tokens := TSlash :: !tokens; scan ()
    | Some '%' -> advance (); tokens := TPercent :: !tokens; scan ()
    | Some '=' -> advance (); tokens := TEq :: !tokens; scan ()
    | Some c when c >= '0' && c <= '9' ->
      tokens := read_number () :: !tokens; scan ()
    | Some c when is_ident_char c || c = '_' ->
      let id = read_ident () in
      let t = match id with
        | "let" -> TLet
        | "true" -> TBool true
        | "false" -> TBool false
        | _ -> TIdent id
      in
      tokens := t :: !tokens; scan ()
    | Some _ -> advance (); scan ()
  in
  scan ();
  List.rev !tokens

(* ── AST ─────────────────────────────────────────────────────────── *)

type expr =
  | ELit of value
  | EVar of string
  | EDot of expr * string
  | ECall of string * string * (string * expr) list
  | EBinOp of binop * expr * expr
  | EPipe of expr * transform
  | ELet of string * expr
  | EInterp of interp_part list
and value =
  | VInt of int
  | VFloat of float
  | VString of string
  | VBool of bool
  | VNull
  | VList of Yojson.Safe.t list
  | VRecord of (string * Yojson.Safe.t) list
and binop = Add | Sub | Mul | Div | Mod
and transform =
  | TrMap of string
  | TrFilter of string * expr
  | TrPick of string list
  | TrCount
  | TrFirst
  | TrSort of string
and interp_part =
  | IPLit of string
  | IPExpr of string

(* ── Parser ──────────────────────────────────────────────────────── *)

type parser_state = { mutable toks : token list }

let parser_peek p = match p.toks with t :: _ -> t | [] -> TEOF
let parser_advance p = match p.toks with _ :: rest -> p.toks <- rest | [] -> ()
let parser_eat p = let t = parser_peek p in parser_advance p; t

let parser_expect_ident p =
  match parser_eat p with
  | TIdent s -> s
  | _ -> failwith "expected identifier"

let rec parse_expr p =
  let left = parse_primary p in
  parse_pipe p left

and parse_pipe p left =
  match parser_peek p with
  | TPipe ->
    parser_advance p;
    let tr = parse_transform p in
    let result = EPipe (left, tr) in
    parse_pipe p result
  | _ -> left

and parse_transform p =
  let name = parser_expect_ident p in
  match name with
  | "map" ->
    (match parser_peek p with
     | TDot -> parser_advance p; TrMap (parser_expect_ident p)
     | _ -> failwith "map expects .field")
  | "filter" ->
    (match parser_peek p with
     | TDot ->
       parser_advance p;
       let field = parser_expect_ident p in
       (match parser_peek p with
        | TColon ->
          parser_advance p;
          let v = parse_atom p in
          TrFilter (field, v)
        | _ -> failwith "filter expects .field:value")
     | _ -> failwith "filter expects .field")
  | "pick" ->
    let fields = ref [] in
    let rec read_fields () =
      match parser_peek p with
      | TDot ->
        parser_advance p;
        fields := parser_expect_ident p :: !fields;
        read_fields ()
      | _ -> ()
    in
    read_fields ();
    if !fields = [] then failwith "pick expects .field1 .field2 ...";
    TrPick (List.rev !fields)
  | "count" -> TrCount
  | "first" -> TrFirst
  | "sort" ->
    (match parser_peek p with
     | TDot -> parser_advance p; TrSort (parser_expect_ident p)
     | _ -> failwith "sort expects .field")
  | _ -> failwith ("unknown transform: " ^ name)

and parse_primary p =
  match parser_peek p with
  | TLet ->
    parser_advance p;
    let name = parser_expect_ident p in
    (match parser_peek p with
     | TEq -> parser_advance p
     | _ -> failwith "expected = after let identifier");
    let e = parse_expr p in
    ELet (name, e)
  | _ -> parse_arith p

and parse_arith p =
  let left = parse_unary p in
  parse_arith_right p left

and parse_arith_right p left =
  match parser_peek p with
  | TPlus -> parser_advance p; let right = parse_unary p in
    parse_arith_right p (EBinOp (Add, left, right))
  | TMinus -> parser_advance p; let right = parse_unary p in
    parse_arith_right p (EBinOp (Sub, left, right))
  | TStar -> parser_advance p; let right = parse_unary p in
    parse_arith_right p (EBinOp (Mul, left, right))
  | TSlash -> parser_advance p; let right = parse_unary p in
    parse_arith_right p (EBinOp (Div, left, right))
  | TPercent -> parser_advance p; let right = parse_unary p in
    parse_arith_right p (EBinOp (Mod, left, right))
  | _ -> left

and parse_unary p =
  match parser_peek p with
  | TMinus ->
    parser_advance p;
    let e = parse_atom p in
    EBinOp (Sub, ELit (VInt 0), e)
  | _ -> parse_postfix p

and parse_postfix p =
  let base = parse_atom p in
  parse_dot_chain p base

and parse_dot_chain p base =
  match parser_peek p with
  | TDot ->
    parser_advance p;
    let field = parser_expect_ident p in
    (match base with
     | EVar service_name ->
       let args = try_parse_args p in
       if args <> [] || is_at_end_or_pipe p then
         ECall (service_name, field, args)
       else
         parse_dot_chain p (EDot (EVar service_name, field))
     | _ -> parse_dot_chain p (EDot (base, field)))
  | _ -> base

and is_at_end_or_pipe p =
  match parser_peek p with
  | TEOF | TPipe -> true
  | _ -> false

and try_parse_args p =
  let has_parens = match parser_peek p with TLParen -> true | _ -> false in
  if has_parens then begin
    parser_advance p;
    let args = parse_named_args p in
    (match parser_peek p with TRParen -> parser_advance p | _ -> ());
    args
  end else
    parse_named_args p

and parse_named_args p =
  let args = ref [] in
  let rec loop () =
    match parser_peek p with
    | TTilde ->
      parser_advance p;
      let name = parser_expect_ident p in
      (match parser_peek p with
       | TColon -> parser_advance p
       | _ -> failwith ("expected : after ~" ^ name));
      let value = parse_arg_value p in
      args := (name, value) :: !args;
      loop ()
    | TIdent name ->
      let saved = p.toks in
      parser_advance p;
      (match parser_peek p with
       | TColon ->
         parser_advance p;
         let value = parse_arg_value p in
         args := (name, value) :: !args;
         loop ()
       | _ ->
         p.toks <- saved;
         ())
    | _ -> ()
  in
  loop ();
  List.rev !args

and parse_arg_value p =
  match parser_peek p with
  | TLParen ->
    parser_advance p;
    let e = parse_arith p in
    (match parser_peek p with TRParen -> parser_advance p | _ -> ());
    e
  | TString _ | TInt _ | TFloat _ | TBool _ ->
    parse_atom p
  | TIdent _ ->
    parse_postfix p
  | TMinus ->
    parse_unary p
  | _ ->
    parse_atom p

and parse_atom p =
  match parser_eat p with
  | TInt n -> ELit (VInt n)
  | TFloat f -> ELit (VFloat f)
  | TBool b -> ELit (VBool b)
  | TString s ->
    if String.contains s '\x00' then
      parse_interpolated_string s
    else
      ELit (VString s)
  | TIdent name -> EVar name
  | TLParen ->
    let e = parse_arith p in
    (match parser_peek p with TRParen -> parser_advance p | _ -> ());
    e
  | t ->
    failwith (Printf.sprintf "unexpected token: %s"
      (match t with
       | TDot -> "." | TColon -> ":" | TTilde -> "~" | TPipe -> "|"
       | TPlus -> "+" | TMinus -> "-" | TStar -> "*" | TSlash -> "/"
       | TPercent -> "%%" | TEq -> "=" | TLet -> "let" | TRParen -> ")"
       | TEOF -> "end of input" | _ -> "?"))

and parse_interpolated_string s =
  let parts = ref [] in
  let len = String.length s in
  let pos = ref 0 in
  while !pos < len do
    match String.index_from_opt s !pos '\x00' with
    | None ->
      parts := IPLit (String.sub s !pos (len - !pos)) :: !parts;
      pos := len
    | Some i ->
      if i > !pos then
        parts := IPLit (String.sub s !pos (i - !pos)) :: !parts;
      let j = match String.index_from_opt s (i + 1) '\x00' with
        | Some j -> j | None -> len in
      let expr_text = String.sub s (i + 1) (j - i - 1) in
      parts := IPExpr expr_text :: !parts;
      pos := j + 1
  done;
  EInterp (List.rev !parts)

let parse input =
  let tokens = tokenize input in
  let p = { toks = tokens } in
  parse_expr p

(* ── Type tracker ────────────────────────────────────────────────── *)

type repl_type =
  | RtString
  | RtInt
  | RtFloat
  | RtBool
  | RtRecord of string * (string * string) list
  | RtList of repl_type
  | RtUnknown

let rec type_name = function
  | RtString -> "string"
  | RtInt -> "int"
  | RtFloat -> "float"
  | RtBool -> "bool"
  | RtRecord (name, _) -> name
  | RtList inner -> type_name inner ^ " list"
  | RtUnknown -> "?"

let method_return_type (minfo : method_info) =
  RtRecord (minfo.returns_name,
    List.map (fun f -> (f.fname, f.ftype)) minfo.returns)

(* ── Evaluator ───────────────────────────────────────────────────── *)

type env = {
  schema : schema;
  vars : (string, Yojson.Safe.t * repl_type) Hashtbl.t;
}

let json_of_value = function
  | VInt n -> `Int n
  | VFloat f -> `Float f
  | VString s -> `String s
  | VBool b -> `Bool b
  | VNull -> `Null
  | VList l -> `List l
  | VRecord fields -> `Assoc fields

let find_method env service_name method_name =
  match List.assoc_opt service_name env.schema with
  | Some methods -> List.assoc_opt method_name methods
  | None -> None

let json_to_record (json : Yojson.Safe.t) (fields : field_info list) =
  match json with
  | `List arr ->
    let pairs = List.mapi (fun i fi ->
      let v = if i < List.length arr then List.nth arr i else `Null in
      (fi.fname, v)
    ) fields in
    `Assoc pairs
  | other -> other

let call_rpc_web service_name rpc_name payload =
  try
    let result = Well.Service.dispatch_by_name
      service_name rpc_name `Null payload in
    Ok result
  with exn -> Error (Printexc.to_string exn)

let rec eval env expr : Yojson.Safe.t * repl_type =
  match expr with
  | ELit v -> (json_of_value v, lit_type v)
  | EVar name ->
    (match Hashtbl.find_opt env.vars name with
     | Some (v, t) -> (v, t)
     | None -> failwith ("undefined variable: " ^ name))
  | EDot (e, field) ->
    let v, t = eval env e in
    let result = match v with
      | `Assoc fields ->
        (match List.assoc_opt field fields with
         | Some v -> v
         | None -> failwith (Printf.sprintf "field '%s' not found" field))
      | _ -> failwith "cannot access field on non-record"
    in
    let rt = match t with
      | RtRecord (_, fields) ->
        (match List.assoc_opt field fields with
         | Some "int" -> RtInt
         | Some "float" -> RtFloat
         | Some "bool" -> RtBool
         | Some "string" | Some "date" -> RtString
         | Some s ->
           if String.length s > 5 && String.sub s (String.length s - 5) 5 = " list"
           then RtList RtUnknown
           else RtUnknown
         | None -> RtUnknown)
      | _ -> RtUnknown
    in
    (result, rt)
  | ECall (service, method_name, args) ->
    let minfo = match find_method env service method_name with
      | Some m -> m
      | None -> failwith (Printf.sprintf "%s.%s: not found" service method_name)
    in
    let payload = `List (List.map (fun (fi : field_info) ->
      match List.assoc_opt fi.fname args with
      | Some arg_expr ->
        let v, _ = eval env arg_expr in
        v
      | None ->
        if fi.foptional then `Null
        else failwith (Printf.sprintf "%s.%s: missing required param '%s'"
          service method_name fi.fname)
    ) minfo.params) in
    (match call_rpc_web service method_name payload with
     | Ok result ->
       let decoded = json_to_record result minfo.returns in
       (decoded, method_return_type minfo)
     | Error e -> failwith e)
  | EBinOp (op, left, right) ->
    let lv, lt = eval env left in
    let rv, _rt = eval env right in
    eval_binop op lv rv lt
  | EPipe (e, tr) ->
    let v, t = eval env e in
    eval_transform env v t tr
  | ELet (name, e) ->
    let v, t = eval env e in
    Hashtbl.replace env.vars name (v, t);
    (v, t)
  | EInterp parts ->
    let buf = Buffer.create 64 in
    List.iter (fun part ->
      match part with
      | IPLit s -> Buffer.add_string buf s
      | IPExpr text ->
        let e = parse text in
        let v, _ = eval env e in
        Buffer.add_string buf (json_value_to_string v)
    ) parts;
    (`String (Buffer.contents buf), RtString)

and lit_type = function
  | VInt _ -> RtInt
  | VFloat _ -> RtFloat
  | VString _ -> RtString
  | VBool _ -> RtBool
  | VNull -> RtUnknown
  | VList _ -> RtList RtUnknown
  | VRecord _ -> RtRecord ("?", [])

and eval_binop op lv rv lt =
  match op, lv, rv with
  | Add, `Int a, `Int b -> (`Int (a + b), RtInt)
  | Sub, `Int a, `Int b -> (`Int (a - b), RtInt)
  | Mul, `Int a, `Int b -> (`Int (a * b), RtInt)
  | Div, `Int a, `Int b -> (`Int (a / b), RtInt)
  | Mod, `Int a, `Int b -> (`Int (a mod b), RtInt)
  | Add, `Float a, `Float b -> (`Float (a +. b), RtFloat)
  | Sub, `Float a, `Float b -> (`Float (a -. b), RtFloat)
  | Mul, `Float a, `Float b -> (`Float (a *. b), RtFloat)
  | Div, `Float a, `Float b -> (`Float (a /. b), RtFloat)
  | Add, `Int a, `Float b -> (`Float (float_of_int a +. b), RtFloat)
  | Add, `Float a, `Int b -> (`Float (a +. float_of_int b), RtFloat)
  | Add, `String a, `String b -> (`String (a ^ b), RtString)
  | Add, `String a, v -> (`String (a ^ json_value_to_string v), RtString)
  | Add, v, `String b -> (`String (json_value_to_string v ^ b), RtString)
  | _ -> failwith (Printf.sprintf "cannot apply %s to %s"
    (match op with Add -> "+" | Sub -> "-" | Mul -> "*" | Div -> "/" | Mod -> "%%")
    (type_name lt))

and eval_transform env v t tr =
  match tr with
  | TrMap field ->
    (match v with
     | `List items ->
       let mapped = List.map (fun item ->
         match item with
         | `Assoc fields ->
           (match List.assoc_opt field fields with
            | Some v -> v | None -> `Null)
         | _ -> `Null
       ) items in
       (`List mapped, RtList RtUnknown)
     | `Assoc fields ->
       let items = match List.assoc_opt "items" fields with
         | Some (`List l) -> l | _ -> [] in
       let mapped = List.map (fun item ->
         match item with
         | `Assoc fs -> (match List.assoc_opt field fs with Some v -> v | None -> `Null)
         | _ -> `Null
       ) items in
       (`List mapped, RtList RtUnknown)
     | _ -> failwith "map: expected list")
  | TrFilter (field, pred_expr) ->
    let pred_val, _ = eval env pred_expr in
    (match v with
     | `List items ->
       let filtered = List.filter (fun item ->
         match item with
         | `Assoc fields ->
           (match List.assoc_opt field fields with
            | Some fv -> fv = pred_val
            | None -> false)
         | _ -> false
       ) items in
       (`List filtered, t)
     | _ -> failwith "filter: expected list")
  | TrPick fields ->
    (match v with
     | `List items ->
       let picked = List.map (fun item ->
         match item with
         | `Assoc all_fields ->
           `Assoc (List.filter_map (fun f ->
             match List.assoc_opt f all_fields with
             | Some v -> Some (f, v) | None -> None
           ) fields)
         | other -> other
       ) items in
       (`List picked, RtList RtUnknown)
     | `Assoc all_fields ->
       let picked = List.filter_map (fun f ->
         match List.assoc_opt f all_fields with
         | Some v -> Some (f, v) | None -> None
       ) fields in
       (`Assoc picked, RtUnknown)
     | _ -> failwith "pick: expected list or record")
  | TrCount ->
    (match v with
     | `List items -> (`Int (List.length items), RtInt)
     | _ -> failwith "count: expected list")
  | TrFirst ->
    (match v with
     | `List (x :: _) -> (x, RtUnknown)
     | `List [] -> (`Null, RtUnknown)
     | _ -> failwith "first: expected list")
  | TrSort field ->
    (match v with
     | `List items ->
       let sorted = List.sort (fun a b ->
         let va = match a with `Assoc fs -> List.assoc_opt field fs | _ -> None in
         let vb = match b with `Assoc fs -> List.assoc_opt field fs | _ -> None in
         match va, vb with
         | Some (`String a), Some (`String b) -> String.compare a b
         | Some (`Int a), Some (`Int b) -> compare a b
         | _ -> 0
       ) items in
       (`List sorted, t)
     | _ -> failwith "sort: expected list")

and json_value_to_string = function
  | `String s -> s
  | `Int n -> string_of_int n
  | `Float f -> Printf.sprintf "%g" f
  | `Bool b -> string_of_bool b
  | `Null -> "null"
  | other -> Yojson.Safe.to_string other

(* ── HTML Pretty Printer ────────────────────────────────────────── *)

let rec pretty_json_html ?(indent=0) (v : Yojson.Safe.t) =
  match v with
  | `Null -> {|<span class="j-null">null</span>|}
  | `Bool b -> Printf.sprintf {|<span class="j-bool">%s</span>|} (string_of_bool b)
  | `Int n -> Printf.sprintf {|<span class="j-num">%d</span>|} n
  | `Intlit s -> Printf.sprintf {|<span class="j-num">%s</span>|} (esc s)
  | `Float f -> Printf.sprintf {|<span class="j-num">%g</span>|} f
  | `String s -> Printf.sprintf {|<span class="j-str">"%s"</span>|} (esc s)
  | `List [] -> "[]"
  | `List items ->
    let pad = String.make ((indent + 1) * 2) ' ' in
    let pad_close = String.make (indent * 2) ' ' in
    let inner = List.map (fun item ->
      pad ^ pretty_json_html ~indent:(indent + 1) item
    ) items in
    "[\n" ^ String.concat ",\n" inner ^ "\n" ^ pad_close ^ "]"
  | `Assoc [] -> "{}"
  | `Assoc fields ->
    let pad = String.make ((indent + 1) * 2) ' ' in
    let pad_close = String.make (indent * 2) ' ' in
    let inner = List.map (fun (k, v) ->
      Printf.sprintf "%s<span class=\"j-key\">%s</span>: %s"
        pad (esc k) (pretty_json_html ~indent:(indent + 1) v)
    ) fields in
    "{\n" ^ String.concat ",\n" inner ^ "\n" ^ pad_close ^ "}"

(* ── LiveView ────────────────────────────────────────────────────── *)

type entry = { input : string; output : string; type_str : string; is_error : bool }

type model = {
  history : entry list;
  vars : (string, Yojson.Safe.t * repl_type) Hashtbl.t;
  schema : schema;
  schema_json : string;
  show_help : bool;
}

type msg = Eval of string | Clear | ToggleHelp

let persistence = Well.LiveView.Ephemeral

let init _req _props =
  let schema = build_schema () in
  let schema_json = schema_to_json schema in
  ({ history = []; vars = Hashtbl.create 16; schema; schema_json; show_help = false }, [])

let update _req model msg =
  match msg with
  | Eval expr_str ->
    let trimmed = String.trim expr_str in
    if trimmed = "" then model
    else begin
      let env = { schema = model.schema; vars = model.vars } in
      try
        let expr = parse trimmed in
        let v, t = eval env expr in
        let output = pretty_json_html v in
        let type_str = type_name t in
        let entry = { input = trimmed; output; type_str; is_error = false } in
        { model with history = model.history @ [entry] }
      with
      | Failure msg_str ->
        let entry = { input = trimmed; output = esc msg_str; type_str = ""; is_error = true } in
        { model with history = model.history @ [entry] }
      | exn ->
        let entry = { input = trimmed; output = esc (Printexc.to_string exn);
                       type_str = ""; is_error = true } in
        { model with history = model.history @ [entry] }
    end
  | Clear -> { model with history = [] }
  | ToggleHelp -> { model with show_help = not model.show_help }

let handle_params _req model = model
let temporary_assigns model = model

let view model =
  let var_names = Hashtbl.fold (fun k _ acc -> k :: acc) model.vars [] in
  let vars_json = Yojson.Safe.to_string
    (`List (List.map (fun s -> `String s) var_names)) in
  let history_html =
    if model.history = [] then
      {|<div class="empty-state" style="padding:32px"><div class="icon">&#9002;</div><p>Type an expression below to query services</p></div>|}
    else
      String.concat "" (List.map (fun e ->
        let prompt_html = Printf.sprintf
          {|<div class="repl-entry-input"><span class="repl-prompt-sym">&gt;</span> %s</div>|}
          (esc e.input) in
        let output_html =
          if e.is_error then
            Printf.sprintf {|<div class="repl-entry-output repl-error">error: %s</div>|} e.output
          else
            Printf.sprintf
              {|<div class="repl-entry-type">: %s</div><pre class="repl-entry-output">%s</pre>|}
              (esc e.type_str) e.output
        in
        Printf.sprintf {|<div class="repl-entry">%s%s</div>|} prompt_html output_html
      ) model.history)
  in
  let help_html = if model.show_help then
    {|<div class="repl-help">
      <div class="repl-help-title">Syntax Guide</div>
      <pre class="repl-help-pre">Service.method param:value     Call a service method
let x = Service.method()       Bind result to variable
x.field                        Access record field
expr | map .field              Extract field from list
expr | filter .field:value     Filter by field value
expr | pick .f1 .f2            Select fields
expr | count                   Count items
expr | first                   First item
expr | sort .field             Sort by field
"hello {x.name}"              String interpolation
(2 + 3) * 4                   Arithmetic</pre>
      <div class="repl-help-keys">Tab: autocomplete &middot; Up/Down: history &middot; Ctrl+L: clear</div>
    </div>|}
  else ""
  in
  `Html (Printf.sprintf
    {|<div class="repl-wrap" data-lv-hook="ReplTerminal">
      <div data-lv="repl-head"><div class="repl-toolbar">
        <button class="btn btn-sm" data-lv-click="%s">%s guide</button>
        <button class="btn btn-sm" data-lv-click="%s">clear</button>
      </div>%s</div>
      <div class="repl-output-area" data-lv="repl-out">%s</div>
      <form data-lv-submit="eval" class="repl-input-line">
        <span class="repl-prompt">well&gt;</span>
        <input name="expr" type="text" class="repl-input-field"
               autocomplete="off" spellcheck="false" autofocus
               placeholder="Tasks.list | count" />
        <span class="repl-hint"></span>
      </form>
      <div class="repl-completions" style="display:none"></div>
      <div data-lv="repl-data" style="display:none"
           data-schema="%s" data-vars="%s"></div>
    </div>|}
    (esc {|["ToggleHelp"]|}) (if model.show_help then "hide" else "show")
    (esc {|["Clear"]|})
    help_html history_html
    (esc model.schema_json) (esc vars_json))

let model_to_yojson _m = `Null
let model_of_yojson _j = Error "ephemeral"

let msg_of_yojson j =
  match j with
  | `List [`String "eval"; `Assoc kvs] ->
    let expr = match List.assoc_opt "expr" kvs with
      | Some (`String s) -> s | _ -> "" in
    Ok (Eval expr)
  | `List [`String "Clear"] -> Ok Clear
  | `List [`String "ToggleHelp"] -> Ok ToggleHelp
  | _ -> Error "unknown msg"
