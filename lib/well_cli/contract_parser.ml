(* Contract TOML parser — two-pass parsing matching dg *)

open Contract_types

(* ── OCaml keyword escaping ───────────────────────────────────────── *)

let ocaml_keywords =
  [ "and"; "as"; "assert"; "asr"; "begin"; "class"; "constraint"; "do";
    "done"; "downto"; "else"; "end"; "exception"; "external"; "false";
    "for"; "fun"; "function"; "functor"; "if"; "in"; "include"; "inherit";
    "initializer"; "land"; "lazy"; "let"; "lor"; "lsl"; "lsr"; "lxor";
    "match"; "method"; "mod"; "module"; "mutable"; "new"; "nonrec";
    "object"; "of"; "open"; "or"; "private"; "rec"; "sig"; "struct";
    "then"; "to"; "true"; "try"; "type"; "val"; "virtual"; "when";
    "while"; "with" ]

let escape_keyword name =
  if List.mem name ocaml_keywords then name ^ "'"
  else name

(* ── Primitive type resolution ────────────────────────────────────── *)

let resolve_prim = function
  | "string" -> Some String
  | "int" -> Some Int
  | "float" -> Some Float
  | "bool" -> Some Bool
  | "void" -> Some Void
  | "date" -> Some Date
  | "record" -> Some Record
  | "ctx" -> Some Ctx
  | _ -> None

(* ── Type resolution ──────────────────────────────────────────────── *)

let resolve_type ~module_name ~available_msgs type_str =
  match resolve_prim type_str with
  | Some p -> Prim p
  | None ->
    if String.contains type_str '.' then
      (* Qualified: "Common.UserCtx" *)
      match String.index_opt type_str '.' with
      | Some i ->
        let mod_name = String.sub type_str 0 i in
        let msg_name = String.sub type_str (i + 1) (String.length type_str - i - 1) in
        Custom { module_name = mod_name; msg_name }
      | None -> Prim String
    else
      (* Unqualified: try "Module.Name" first, then just use as-is *)
      let qualified = module_name ^ "." ^ type_str in
      if List.mem qualified available_msgs then
        Custom { module_name; msg_name = type_str }
      else if List.mem type_str available_msgs then
        (* Bare name that happens to be a module *)
        Custom { module_name = type_str; msg_name = type_str }
      else
        Custom { module_name; msg_name = type_str }

(* ── Parse a type value (string or inline table) ─────────────────── *)

let parse_type_value ~module_name ~available_msgs (value : Otoml.t) =
  match value with
  | TomlString s ->
    (resolve_type ~module_name ~available_msgs s, false)
  | TomlInlineTable pairs | TomlTable pairs ->
    let get_str key =
      match List.assoc_opt key pairs with
      | Some (Otoml.TomlString s) -> Some s
      | _ -> None
    in
    let get_bool key =
      match List.assoc_opt key pairs with
      | Some (Otoml.TomlBoolean b) -> Some b
      | _ -> None
    in
    let optional = Option.value ~default:false (get_bool "optional") in
    let base_type =
      match get_str "type" with
      | Some "list" ->
        let of_type =
          match get_str "of" with
          | Some s -> resolve_type ~module_name ~available_msgs s
          | None -> Prim String
        in
        List of_type
      | Some s -> resolve_type ~module_name ~available_msgs s
      | None -> Prim String
    in
    (base_type, optional)
  | _ -> (Prim String, false)

(* ── Pass 1: Collect available message names ─────────────────────── *)

let module_name_of_file path =
  let base = Filename.basename path in
  let name = Filename.chop_extension base in
  String.capitalize_ascii name

let collect_available_msgs dir =
  let files = Sys.readdir dir |> Array.to_list in
  let toml_files =
    List.filter (fun f -> Filename.check_suffix f ".toml") files
    |> List.map (fun f -> Filename.concat dir f)
  in
  List.concat_map (fun path ->
    let module_name = module_name_of_file path in
    let toml = Otoml.Parser.from_file path in
    match Otoml.find_opt toml Otoml.get_table ["msg"] with
    | Some msg_pairs ->
      List.map (fun (name, _) -> module_name ^ "." ^ name) msg_pairs
    | None -> []
  ) toml_files

(* ── Parse service RPCs ──────────────────────────────────────────── *)

let parse_rpcs toml =
  match Otoml.find_opt toml Otoml.get_table ["service"; "rpc"] with
  | None -> []
  | Some pairs ->
    List.filter_map (fun (name, value) ->
      match value with
      | Otoml.TomlString s ->
        (match String.split_on_char '-' s with
         | [req_part; resp_part] ->
           let req_part = String.trim req_part in
           let resp_part = String.trim resp_part in
           (* Strip leading '>' from resp_part: "Req -> Resp" splits as ["Req "; "> Resp"] *)
           let resp_part =
             if String.length resp_part > 0 && resp_part.[0] = '>' then
               String.trim (String.sub resp_part 1 (String.length resp_part - 1))
             else resp_part
           in
           Some { name = escape_keyword name; request_msg = req_part; response_msg = resp_part }
         | _ -> None)
      | _ -> None
    ) pairs

(* ── Parse messages ──────────────────────────────────────────────── *)

let parse_msgs ~module_name ~available_msgs toml =
  match Otoml.find_opt toml Otoml.get_table ["msg"] with
  | None -> []
  | Some msg_pairs ->
    List.map (fun (msg_name, msg_val) ->
      let kind =
        (* Check for struct *)
        let struct_pairs =
          match msg_val with
          | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs ->
            (match List.assoc_opt "struct" pairs with
             | Some (Otoml.TomlTable sp | Otoml.TomlInlineTable sp) -> Some sp
             | _ -> None)
          | _ -> None
        in
        let variant_pairs =
          match msg_val with
          | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs ->
            (match List.assoc_opt "variant" pairs with
             | Some (Otoml.TomlTable vp | Otoml.TomlInlineTable vp) -> Some vp
             | _ -> None)
          | _ -> None
        in
        match struct_pairs with
        | Some pairs ->
          Struct (List.map (fun (field_name, field_val) ->
            let type_info, optional =
              parse_type_value ~module_name ~available_msgs field_val
            in
            { name = escape_keyword field_name;
              type_info;
              optional }
          ) pairs)
        | None ->
          match variant_pairs with
          | Some pairs ->
            Variant (List.map (fun (ctor_name, ctor_val) ->
              let payload, _ =
                parse_type_value ~module_name ~available_msgs ctor_val
              in
              { name = ctor_name; payload }
            ) pairs)
          | None -> Struct []
      in
      { name = msg_name; kind }
    ) msg_pairs

(* ── Topological sort (Kahn's algorithm) ─────────────────────────── *)

let msg_deps ~module_name (msg : msg) =
  let rec collect_type_deps acc = function
    | Prim _ -> acc
    | Custom { module_name = m; msg_name } when m = module_name ->
      msg_name :: acc
    | Custom _ -> acc
    | List inner -> collect_type_deps acc inner
    | Optional inner -> collect_type_deps acc inner
  in
  match msg.kind with
  | Struct props ->
    List.fold_left (fun acc p -> collect_type_deps acc p.type_info) [] props
  | Variant ctors ->
    List.fold_left (fun acc c -> collect_type_deps acc c.payload) [] ctors

let topo_sort ~module_name (msgs : msg list) =
  let names = List.map (fun (m : msg) -> m.name) msgs in
  let msg_by_name = List.map (fun (m : msg) -> (m.name, m)) msgs in
  (* Build adjacency: deps of each msg *)
  let deps_map =
    List.map (fun m ->
      let deps = msg_deps ~module_name m
        |> List.filter (fun d -> List.mem d names)
      in
      (m.name, deps)
    ) msgs
  in
  (* Kahn's algorithm *)
  let in_degree = Hashtbl.create 16 in
  List.iter (fun name -> Hashtbl.replace in_degree name 0) names;
  List.iter (fun (name, deps) ->
    List.iter (fun dep ->
      let cur = try Hashtbl.find in_degree name with Not_found -> 0 in
      Hashtbl.replace in_degree name (cur + 1);
      ignore dep
    ) deps
  ) deps_map;
  (* Actually: in_degree[x] = number of deps x has (things x depends on) *)
  (* Reset and recount properly *)
  List.iter (fun name -> Hashtbl.replace in_degree name 0) names;
  List.iter (fun (_name, deps) ->
    (* _name depends on deps — so _name needs all deps first *)
    ignore _name;
    ignore deps
  ) deps_map;
  (* For topo sort: if A depends on B, B must come first.
     in_degree[A] = count of things A depends on *)
  List.iter (fun name -> Hashtbl.replace in_degree name 0) names;
  List.iter (fun (name, deps) ->
    Hashtbl.replace in_degree name (List.length deps)
  ) deps_map;
  let queue = Queue.create () in
  List.iter (fun name ->
    if Hashtbl.find in_degree name = 0 then Queue.add name queue
  ) names;
  let result = ref [] in
  while not (Queue.is_empty queue) do
    let name = Queue.pop queue in
    result := name :: !result;
    (* For each msg that depends on `name`, decrement its in_degree *)
    List.iter (fun (other, deps) ->
      if List.mem name deps then begin
        let d = Hashtbl.find in_degree other - 1 in
        Hashtbl.replace in_degree other d;
        if d = 0 then Queue.add other queue
      end
    ) deps_map
  done;
  let sorted_names = List.rev !result in
  (* If cycle, append remaining *)
  let remaining = List.filter (fun n -> not (List.mem n sorted_names)) names in
  let all_names = sorted_names @ remaining in
  List.filter_map (fun name -> List.assoc_opt name msg_by_name) all_names

(* ── Parse a single file ─────────────────────────────────────────── *)

let parse_file ~available_msgs path =
  let module_name = module_name_of_file path in
  let toml = Otoml.Parser.from_file path in
  let rpcs = parse_rpcs toml in
  let service = if rpcs = [] then None else Some { rpcs } in
  let msgs = parse_msgs ~module_name ~available_msgs toml in
  let msgs = topo_sort ~module_name msgs in
  { name = module_name; service; msgs }

(* ── Public API ──────────────────────────────────────────────────── *)

let parse_all dir =
  let available_msgs = collect_available_msgs dir in
  let files = Sys.readdir dir |> Array.to_list in
  let toml_files =
    List.filter (fun f -> Filename.check_suffix f ".toml") files
    |> List.sort String.compare
    |> List.map (fun f -> Filename.concat dir f)
  in
  List.map (parse_file ~available_msgs) toml_files
