(* well repl — Typed query shell for service introspection *)

(* ── Schema types ────────────────────────────────────────────────── *)

type field_info = { fname : string; ftype : string; foptional : bool }

type method_info = {
  params : field_info list;
  returns : field_info list;
  returns_name : string;
}

type schema = (string * (string * method_info) list) list
(* service_name -> [(method_name, method_info)] *)

(* ── Socket communication ────────────────────────────────────────── *)

let connect_socket path =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_UNIX path);
  fd

let send_recv fd msg =
  let data = msg ^ "\n" in
  ignore (Unix.write_substring fd data 0 (String.length data));
  (* Read response — may come in multiple chunks *)
  let buf = Buffer.create 4096 in
  let tmp = Bytes.create 65536 in
  let rec read_loop () =
    let n = Unix.read fd tmp 0 (Bytes.length tmp) in
    if n > 0 then begin
      Buffer.add_subbytes buf tmp 0 n;
      (* Check if we have a complete line (newline terminated) *)
      let s = Buffer.contents buf in
      if String.contains s '\n' then
        String.trim s
      else
        read_loop ()
    end else
      String.trim (Buffer.contents buf)
  in
  read_loop ()

let fetch_schema fd : schema =
  let req = Yojson.Safe.to_string
    (`Assoc [("service", `String "_system");
             ("rpc", `String "describe");
             ("payload", `Null)]) in
  let resp = send_recv fd req in
  let json = Yojson.Safe.from_string resp in
  match json with
  | `Assoc l ->
    (match List.assoc_opt "result" l with
     | Some (`Assoc services) ->
       List.map (fun (sname, methods_json) ->
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
         (sname, methods)
       ) services
     | _ -> [])
  | _ -> []

let call_rpc fd service_name rpc_name payload =
  let req = Yojson.Safe.to_string
    (`Assoc [("service", `String service_name);
             ("rpc", `String rpc_name);
             ("payload", payload)]) in
  let resp = send_recv fd req in
  let json = Yojson.Safe.from_string resp in
  match json with
  | `Assoc l ->
    (match List.assoc_opt "error" l with
     | Some (`String e) -> Error e
     | _ ->
       match List.assoc_opt "result" l with
       | Some r -> Ok r
       | None -> Ok json)
  | _ -> Ok json

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
    advance (); (* skip opening quote *)
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
        (* Read interpolation expression *)
        let depth = ref 1 in
        let expr_buf = Buffer.create 16 in
        while !depth > 0 do
          match peek () with
          | None -> depth := 0
          | Some '{' -> Buffer.add_char expr_buf '{'; incr depth; advance ()
          | Some '}' -> decr depth; if !depth > 0 then Buffer.add_char expr_buf '}'; advance ()
          | Some c -> Buffer.add_char expr_buf c; advance ()
        done;
        (* Marker for interpolation: \x00EXPR\x00 *)
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
      (* |> is alias for | *)
      (match peek () with Some '>' -> advance () | _ -> ());
      tokens := TPipe :: !tokens; scan ()
    | Some '(' -> advance (); tokens := TLParen :: !tokens; scan ()
    | Some ')' -> advance (); tokens := TRParen :: !tokens; scan ()
    | Some '+' -> advance (); tokens := TPlus :: !tokens; scan ()
    | Some '-' ->
      advance ();
      (* Check if it's a negative number *)
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
    | Some c ->
      advance ();
      Printf.eprintf "warning: unexpected character '%c'\n%!" c;
      scan ()
  in
  scan ();
  List.rev !tokens

(* ── AST ─────────────────────────────────────────────────────────── *)

type expr =
  | ELit of value
  | EVar of string
  | EDot of expr * string
  | ECall of string * string * (string * expr) list  (* service, method, named args *)
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
  | IPExpr of string  (* raw expression text to re-parse *)

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
    (* Check if this is a service call: Ident.ident followed by args *)
    (match base with
     | EVar service_name ->
       (* Could be Service.method — check if args follow *)
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
  (* Check if we have parenthesized args: (key:val, ...) *)
  let has_parens = match parser_peek p with TLParen -> true | _ -> false in
  if has_parens then begin
    parser_advance p; (* skip ( *)
    let args = parse_named_args p in
    (match parser_peek p with TRParen -> parser_advance p | _ -> ());
    args
  end else
    parse_named_args p

and parse_named_args p =
  let args = ref [] in
  let rec loop () =
    (* Accept ~label:value or label:value *)
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
      (* Peek ahead for colon *)
      let saved = p.toks in
      parser_advance p;
      (match parser_peek p with
       | TColon ->
         parser_advance p;
         let value = parse_arg_value p in
         args := (name, value) :: !args;
         loop ()
       | _ ->
         (* Not a named arg — restore *)
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
    (* Check for interpolation markers *)
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
    failwith (Printf.sprintf "unexpected token in expression: %s"
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
  | RtRecord of string * (string * string) list  (* type_name, [(field, type_str)] *)
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
  fd : Unix.file_descr;
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

let value_to_string = function
  | VInt n -> string_of_int n
  | VFloat f -> Printf.sprintf "%g" f
  | VString s -> s
  | VBool b -> string_of_bool b
  | VNull -> "null"
  | VList _ -> "<list>"
  | VRecord _ -> "<record>"

let find_service env name =
  List.assoc_opt name env.schema

let find_method env service_name method_name =
  match find_service env service_name with
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
    (* Build positional wire array from named args *)
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
    (match call_rpc env.fd service method_name payload with
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
  (* String concat with + *)
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

(* ── Pretty printer ──────────────────────────────────────────────── *)

let ansi_gray s = "\x1b[90m" ^ s ^ "\x1b[0m"
let ansi_green s = "\x1b[32m" ^ s ^ "\x1b[0m"
let ansi_cyan s = "\x1b[36m" ^ s ^ "\x1b[0m"
let ansi_yellow s = "\x1b[33m" ^ s ^ "\x1b[0m"

let rec pretty_json ?(indent=0) (v : Yojson.Safe.t) =
  match v with
  | `Null -> ansi_gray "null"
  | `Bool b -> ansi_yellow (string_of_bool b)
  | `Int n -> ansi_cyan (string_of_int n)
  | `Intlit s -> ansi_cyan s
  | `Float f -> ansi_cyan (Printf.sprintf "%g" f)
  | `String s -> ansi_green (Printf.sprintf "\"%s\"" s)
  | `List [] -> "[]"
  | `List items ->
    let pad = String.make ((indent + 1) * 2) ' ' in
    let pad_close = String.make (indent * 2) ' ' in
    let inner = List.map (fun item ->
      pad ^ pretty_json ~indent:(indent + 1) item
    ) items in
    "[\n" ^ String.concat ",\n" inner ^ "\n" ^ pad_close ^ "]"
  | `Assoc [] -> "{}"
  | `Assoc fields ->
    let pad = String.make ((indent + 1) * 2) ' ' in
    let pad_close = String.make (indent * 2) ' ' in
    let inner = List.map (fun (k, v) ->
      pad ^ ansi_gray k ^ ": " ^ pretty_json ~indent:(indent + 1) v
    ) fields in
    "{\n" ^ String.concat ",\n" inner ^ "\n" ^ pad_close ^ "}"

let print_result (v : Yojson.Safe.t) t =
  Printf.printf "%s %s\n" (ansi_gray "-- :") (ansi_gray (type_name t));
  Printf.printf "%s\n" (pretty_json v)

(* ── Readline ────────────────────────────────────────────────────── *)

type line_state = {
  mutable buf : bytes;
  mutable len : int;
  mutable pos : int;
  mutable cap : int;
}

let ls_create () =
  { buf = Bytes.create 256; len = 0; pos = 0; cap = 256 }

let ls_ensure_cap ls n =
  if ls.len + n > ls.cap then begin
    let new_cap = max (ls.cap * 2) (ls.len + n) in
    let new_buf = Bytes.create new_cap in
    Bytes.blit ls.buf 0 new_buf 0 ls.len;
    ls.buf <- new_buf;
    ls.cap <- new_cap
  end

let ls_insert ls c =
  ls_ensure_cap ls 1;
  if ls.pos < ls.len then
    Bytes.blit ls.buf ls.pos ls.buf (ls.pos + 1) (ls.len - ls.pos);
  Bytes.set ls.buf ls.pos c;
  ls.pos <- ls.pos + 1;
  ls.len <- ls.len + 1

let ls_delete_back ls =
  if ls.pos > 0 then begin
    if ls.pos < ls.len then
      Bytes.blit ls.buf ls.pos ls.buf (ls.pos - 1) (ls.len - ls.pos);
    ls.pos <- ls.pos - 1;
    ls.len <- ls.len - 1
  end

let ls_delete_forward ls =
  if ls.pos < ls.len then begin
    if ls.pos + 1 < ls.len then
      Bytes.blit ls.buf (ls.pos + 1) ls.buf ls.pos (ls.len - ls.pos - 1);
    ls.len <- ls.len - 1
  end

let ls_contents ls = Bytes.sub_string ls.buf 0 ls.len

let read_byte fd =
  let buf = Bytes.create 1 in
  let n = Unix.read fd buf 0 1 in
  if n = 0 then None else Some (Bytes.get buf 0)

type key =
  | Char of char
  | Up | Down | Left | Right
  | Home | End | Delete
  | Tab | Enter | Backspace
  | CtrlC | CtrlD | CtrlA | CtrlE | CtrlK | CtrlL | CtrlW
  | Unknown

let read_key fd =
  match read_byte fd with
  | None -> CtrlD
  | Some '\x1b' ->
    (match read_byte fd with
     | Some '[' ->
       (match read_byte fd with
        | Some 'A' -> Up
        | Some 'B' -> Down
        | Some 'C' -> Right
        | Some 'D' -> Left
        | Some 'H' -> Home
        | Some 'F' -> End
        | Some '3' -> ignore (read_byte fd); Delete
        | Some '1' -> ignore (read_byte fd); Home
        | Some '4' -> ignore (read_byte fd); End
        | _ -> Unknown)
     | _ -> Unknown)
  | Some '\t' -> Tab
  | Some '\r' | Some '\n' -> Enter
  | Some '\x7f' | Some '\x08' -> Backspace
  | Some '\x03' -> CtrlC
  | Some '\x04' -> CtrlD
  | Some '\x01' -> CtrlA
  | Some '\x05' -> CtrlE
  | Some '\x0b' -> CtrlK
  | Some '\x0c' -> CtrlL
  | Some '\x17' -> CtrlW
  | Some c -> Char c

type completion_fn = string -> int -> (string list * int)
(* input, cursor_pos -> (completions, replacement_start) *)

type hint_fn = string -> string option

let render_line prompt ls (hint : hint_fn) =
  let line = ls_contents ls in
  let hint_str = match hint line with Some h -> h | None -> "" in
  Printf.printf "\r\x1b[2K%s%s%s" prompt line (ansi_gray hint_str);
  (* Position cursor correctly *)
  let target = String.length prompt + ls.pos in
  let total = String.length prompt + ls.len + String.length hint_str in
  if target < total then
    Printf.printf "\r\x1b[%dC" target;
  flush stdout

let readline ~prompt ~(complete : completion_fn) ~(hint : hint_fn)
    ~(history : string list ref) () =
  let fd = Unix.stdin in
  let old_attr = Unix.tcgetattr fd in
  let raw = { old_attr with
    Unix.c_icanon = false; c_echo = false; c_isig = false;
    c_ixon = false; c_icrnl = false;
    c_vmin = 1; c_vtime = 0 } in
  Unix.tcsetattr fd Unix.TCSAFLUSH raw;
  let ls = ls_create () in
  let hist_idx = ref (List.length !history) in
  let hist_saved = ref "" in
  let result = ref None in
  let running = ref true in
  render_line prompt ls hint;
  while !running do
    match read_key fd with
    | CtrlC ->
      result := None; running := false
    | CtrlD ->
      if ls.len = 0 then (result := None; running := false)
      else ls_delete_forward ls
    | Enter ->
      let line = ls_contents ls in
      Printf.printf "\n%!";
      if line <> "" then
        history := !history @ [line];
      result := Some line;
      running := false
    | Backspace -> ls_delete_back ls; render_line prompt ls hint
    | Delete -> ls_delete_forward ls; render_line prompt ls hint
    | Left -> if ls.pos > 0 then (ls.pos <- ls.pos - 1; render_line prompt ls hint)
    | Right -> if ls.pos < ls.len then (ls.pos <- ls.pos + 1; render_line prompt ls hint)
    | Home | CtrlA -> ls.pos <- 0; render_line prompt ls hint
    | End | CtrlE -> ls.pos <- ls.len; render_line prompt ls hint
    | CtrlK ->
      ls.len <- ls.pos; render_line prompt ls hint
    | CtrlW ->
      (* Delete word backwards *)
      let p = ref ls.pos in
      while !p > 0 && Bytes.get ls.buf (!p - 1) = ' ' do decr p done;
      while !p > 0 && Bytes.get ls.buf (!p - 1) <> ' ' do decr p done;
      let removed = ls.pos - !p in
      if ls.pos < ls.len then
        Bytes.blit ls.buf ls.pos ls.buf !p (ls.len - ls.pos);
      ls.len <- ls.len - removed;
      ls.pos <- !p;
      render_line prompt ls hint
    | CtrlL ->
      Printf.printf "\x1b[2J\x1b[H%!";
      render_line prompt ls hint
    | Up ->
      if !hist_idx > 0 then begin
        if !hist_idx = List.length !history then
          hist_saved := ls_contents ls;
        hist_idx := !hist_idx - 1;
        let line = List.nth !history !hist_idx in
        ls.len <- 0; ls.pos <- 0;
        String.iter (fun c -> ls_insert ls c) line;
        render_line prompt ls hint
      end
    | Down ->
      if !hist_idx < List.length !history then begin
        hist_idx := !hist_idx + 1;
        let line =
          if !hist_idx = List.length !history then !hist_saved
          else List.nth !history !hist_idx
        in
        ls.len <- 0; ls.pos <- 0;
        String.iter (fun c -> ls_insert ls c) line;
        render_line prompt ls hint
      end
    | Tab ->
      let line = ls_contents ls in
      let completions, start = complete line ls.pos in
      (match completions with
       | [] -> ()  (* no completions *)
       | [single] ->
         (* Replace from start to pos with single completion *)
         let prefix_len = ls.pos - start in
         for _ = 1 to prefix_len do ls_delete_back ls done;
         String.iter (fun c -> ls_insert ls c) single;
         render_line prompt ls hint
       | multiple ->
         (* Show all completions *)
         Printf.printf "\n";
         List.iter (fun c -> Printf.printf "  %s" (ansi_cyan c)) multiple;
         Printf.printf "\n%!";
         (* Find common prefix *)
         let common = match multiple with
           | [] -> ""
           | first :: rest ->
             let len = ref (String.length first) in
             List.iter (fun s ->
               len := min !len (String.length s);
               for i = 0 to !len - 1 do
                 if first.[i] <> s.[i] then len := min !len i
               done
             ) rest;
             String.sub first 0 !len
         in
         let prefix_len = ls.pos - start in
         if String.length common > prefix_len then begin
           for _ = 1 to prefix_len do ls_delete_back ls done;
           String.iter (fun c -> ls_insert ls c) common
         end;
         render_line prompt ls hint)
    | Char c ->
      ls_insert ls c; render_line prompt ls hint
    | Unknown -> ()
  done;
  Unix.tcsetattr fd Unix.TCSAFLUSH old_attr;
  !result

(* ── Completion engine ───────────────────────────────────────────── *)

let build_completer schema env : completion_fn =
  fun input pos ->
    let before = String.sub input 0 pos in
    (* Find the word being typed *)
    let word_start = ref pos in
    while !word_start > 0 &&
          (let c = before.[!word_start - 1] in
           is_ident_char c || c = '.') do
      decr word_start
    done;
    let word = String.sub before !word_start (pos - !word_start) in

    (* Check if we're after ~: param completion *)
    let is_param_context =
      !word_start > 0 && (before.[!word_start - 1] = '~' || before.[!word_start - 1] = ':')
    in

    if is_param_context then
      ([], pos)
    else
      match String.index_opt word '.' with
      | Some dot_pos ->
        let prefix = String.sub word 0 dot_pos in
        let suffix = String.sub word (dot_pos + 1) (String.length word - dot_pos - 1) in
        (* Check if prefix is a service name *)
        (match List.assoc_opt prefix schema with
         | Some methods ->
           let matching = List.filter_map (fun (mname, _) ->
             if String.length mname >= String.length suffix &&
                String.sub mname 0 (String.length suffix) = suffix
             then Some (prefix ^ "." ^ mname)
             else None
           ) methods in
           (matching, !word_start)
         | None ->
           (* Maybe it's a variable — complete fields *)
           (match Hashtbl.find_opt env.vars prefix with
            | Some (_, RtRecord (_, fields)) ->
              let matching = List.filter_map (fun (fname, _) ->
                if String.length fname >= String.length suffix &&
                   String.sub fname 0 (String.length suffix) = suffix
                then Some (prefix ^ "." ^ fname)
                else None
              ) fields in
              (matching, !word_start)
            | _ -> ([], pos)))
      | None ->
        (* Complete service names, variable names, keywords *)
        let service_names = List.filter_map (fun (sname, _) ->
          if String.length sname >= String.length word &&
             String.sub sname 0 (String.length word) = word
          then Some sname
          else None
        ) schema in
        let var_names = Hashtbl.fold (fun name _ acc ->
          if String.length name >= String.length word &&
             String.sub name 0 (String.length word) = word
          then name :: acc else acc
        ) env.vars [] in
        let keywords = List.filter (fun kw ->
          String.length kw >= String.length word &&
          String.sub kw 0 (String.length word) = word
        ) ["let"; "map"; "filter"; "pick"; "count"; "first"; "sort"] in
        let all = service_names @ var_names @ keywords in
        (List.sort_uniq String.compare all, !word_start)

(* ── Hint engine ─────────────────────────────────────────────────── *)

let build_hint schema : hint_fn =
  fun input ->
    let trimmed = String.trim input in
    (* Match Service.method pattern at end *)
    let len = String.length trimmed in
    if len = 0 then None
    else
      (* Check if we just typed Service.method — show params *)
      match String.rindex_opt trimmed '.' with
      | None ->
        (* Maybe just service name — show .methods *)
        (match List.assoc_opt trimmed schema with
         | Some methods ->
           let names = List.map (fun (n, _) -> "." ^ n) methods in
           Some ("  " ^ String.concat " " names)
         | None -> None)
      | Some dot_pos ->
        let service = String.sub trimmed 0 dot_pos in
        let rest = String.sub trimmed (dot_pos + 1) (len - dot_pos - 1) in
        (* Strip any already-typed args *)
        let method_name = match String.index_opt rest ' ' with
          | Some sp -> String.sub rest 0 sp
          | None -> rest
        in
        (match List.assoc_opt service schema with
         | Some methods ->
           (match List.assoc_opt method_name methods with
            | Some minfo ->
              if minfo.params = [] then
                Some " (no params)"
              else begin
                (* Only show params not yet typed *)
                let typed_params = ref [] in
                let parts = String.split_on_char ' ' trimmed in
                List.iter (fun part ->
                  match String.index_opt part ':' with
                  | Some cp ->
                    let pname = String.sub part 0 cp in
                    let pname = if String.length pname > 0 && pname.[0] = '~'
                      then String.sub pname 1 (String.length pname - 1)
                      else pname in
                    typed_params := pname :: !typed_params
                  | None -> ()
                ) parts;
                let remaining = List.filter (fun (fi : field_info) ->
                  not (List.mem fi.fname !typed_params)
                ) minfo.params in
                if remaining = [] then None
                else
                  let hint = String.concat " " (List.map (fun fi ->
                    if fi.foptional then
                      Printf.sprintf "?%s:%s" fi.fname fi.ftype
                    else
                      Printf.sprintf "%s:%s" fi.fname fi.ftype
                  ) remaining) in
                  Some ("  " ^ hint)
              end
            | None -> None)
         | None -> None)

(* ── Entry point ─────────────────────────────────────────────────── *)

let run_repl fd schema =
  let env = { fd; schema; vars = Hashtbl.create 16 } in
  let history = ref [] in
  let complete = build_completer schema env in
  let hint = build_hint schema in
  let prompt = "\x1b[1mwell>\x1b[0m " in
  Printf.printf "Connected. %d service(s): %s\n%!"
    (List.length schema)
    (String.concat ", " (List.map fst schema));
  Printf.printf "Tab for completion, Ctrl-D to exit.\n%!";
  let running = ref true in
  while !running do
    match readline ~prompt ~complete ~hint ~history () with
    | None -> running := false; Printf.printf "\n"
    | Some "" -> ()
    | Some line ->
      (try
        let expr = parse line in
        let v, t = eval env expr in
        print_result v t
      with
      | Failure msg -> Printf.eprintf "\x1b[31merror:\x1b[0m %s\n%!" msg
      | exn -> Printf.eprintf "\x1b[31merror:\x1b[0m %s\n%!" (Printexc.to_string exn))
  done

let run_eval fd schema expressions =
  let env = { fd; schema; vars = Hashtbl.create 16 } in
  List.iter (fun line ->
    try
      let expr = parse line in
      let v, t = eval env expr in
      print_result v t
    with
    | Failure msg ->
      Printf.eprintf "\x1b[31merror:\x1b[0m %s\n%!" msg;
      exit 1
    | exn ->
      Printf.eprintf "\x1b[31merror:\x1b[0m %s\n%!" (Printexc.to_string exn);
      exit 1
  ) expressions

let run args =
  let sock_path = ref "data/well.sock" in
  let expressions = ref [] in
  let rec parse_args = function
    | [] -> ()
    | "-s" :: path :: rest -> sock_path := path; parse_args rest
    | "--socket" :: path :: rest -> sock_path := path; parse_args rest
    | "-e" :: expr :: rest -> expressions := expr :: !expressions; parse_args rest
    | "--eval" :: expr :: rest -> expressions := expr :: !expressions; parse_args rest
    | unknown :: _ ->
      Printf.eprintf "Unknown option: %s\n%!" unknown;
      exit 1
  in
  parse_args args;
  if not (Sys.file_exists !sock_path) then begin
    Printf.eprintf "Error: %s not found — is the app running?\n%!" !sock_path;
    exit 1
  end;
  let fd = connect_socket !sock_path in
  let schema = fetch_schema fd in
  if schema = [] then begin
    Printf.eprintf "Warning: no services found. Is the app running with registered services?\n%!";
  end;
  if !expressions <> [] then
    run_eval fd schema (List.rev !expressions)
  else
    run_repl fd schema;
  Unix.close fd

let cmd : Command.t = {
  name = "repl";
  summary = "Interactive service query shell";
  usage = "repl [-s socket_path] [-e expression]";
  description =
    "Connect to a running well application and query services interactively.\n\n\
     Options:\n  \
     -s, --socket PATH    Unix socket path (default: data/well.sock)\n  \
     -e, --eval EXPR      Evaluate expression and exit (repeatable)\n\n\
     Syntax:\n  \
     Service.method param:value          Call a service method\n  \
     Service.method(param:value)         Same, with parentheses\n  \
     Service.method ~param:value         Same, OCaml-style\n  \
     let x = Service.method param:value  Bind result to variable\n  \
     x.field                             Access record field\n  \
     expr | map .field                   Transform pipeline\n  \
     expr | filter .field:value          Filter pipeline\n  \
     expr | count                        Count items\n  \
     expr | first                        First item\n  \
     \"hello {x.name}\"                    String interpolation\n  \
     (2 + 3) * 4                         Arithmetic";
  run;
}
