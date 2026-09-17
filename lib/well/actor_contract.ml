open Actor_types

type schema =
  | Primitive of string
  | Reference of string
  | List of schema
  | Optional of schema
  | Struct of (string * schema) list
  | Variant of (string * schema) list

type actor_meta = {
  version : int;
  accepts : (string * string) list;
  emits : (string * string) list;
  actor_contract_hash : string;
}

type descriptor = {
  format : int;
  modules : string list;
  messages : (string * (schema * string)) list;
  actors : (string * actor_meta) list;
  json : Yojson.Safe.t;
}

module type RAW_ACTOR = sig
  type state
  type inbound
  type outbound
  val state_version : int
  val init : actor_id -> state
  val state_to_wire : state -> Yojson.Safe.t
  val state_of_wire : Yojson.Safe.t -> (state, string) result
  val inbound_of_wire : kind:string -> Yojson.Safe.t -> (inbound, string) result
  val outbound_to_wire : outbound -> string * Yojson.Safe.t
  val handle : context -> state -> inbound ->
    (state * outbound list, failure) result
end

type definition = {
  actor_type : string;
  version : int;
  descriptor : descriptor;
  actor_contract_hash : string;
  accepts : (string * string) list;
  emits : (string * string) list;
  state_version : int;
  raw : (module RAW_ACTOR);
}

type msg_def = {
  module_name : string;
  name : string;
  qualified : string;
  schema : schema;
}

type actor_def = {
  module_name : string;
  name : string;
  version : int;
  accepts : (string * string) list;
  emits : (string * string) list;
}

type catalog = {
  modules : string list;
  messages : msg_def list;
  actors : actor_def list;
  files : (string * string) list;
}

let err ?(path = None) code message = error ~path code message

let rec schema_to_json = function
  | Primitive n -> `Assoc ["kind", `String "primitive"; "name", `String n]
  | Reference n -> `Assoc ["kind", `String "reference"; "name", `String n]
  | List e -> `Assoc ["kind", `String "list"; "element", schema_to_json e]
  | Optional e -> `Assoc ["kind", `String "optional"; "element", schema_to_json e]
  | Struct fields ->
    `Assoc [
      "kind", `String "struct";
      "fields", `List (List.mapi (fun i (name, ty) ->
        `Assoc [
          "name", `String name;
          "type", schema_to_json ty;
          "index", `Int i;
        ]) fields)
    ]
  | Variant ctors ->
    `Assoc [
      "kind", `String "variant";
      "constructors", `List (List.map (fun (name, ty) ->
        `Assoc ["name", `String name; "type", schema_to_json ty]) ctors)
    ]

let rec parse_schema_json json =
  match json with
  | `Assoc _ as obj ->
    (match Actor_json.member "kind" obj with
     | Some (`String "primitive") ->
       (match Actor_json.member "name" obj with
        | Some (`String n) -> Ok (Primitive n)
        | _ -> Error "primitive name")
     | Some (`String "reference") ->
       (match Actor_json.member "name" obj with
        | Some (`String n) -> Ok (Reference n)
        | _ -> Error "reference name")
     | Some (`String "list") ->
       (match Actor_json.member "element" obj with
        | Some e -> Result.map (fun s -> List s) (parse_schema_json e)
        | _ -> Error "list element")
     | Some (`String "optional") ->
       (match Actor_json.member "element" obj with
        | Some e -> Result.map (fun s -> Optional s) (parse_schema_json e)
        | _ -> Error "optional element")
     | Some (`String "struct") ->
       (match Actor_json.member "fields" obj with
        | Some (`List fields) ->
          let rec go acc = function
            | [] -> Ok (Struct (List.rev acc))
            | (`Assoc _ as f) :: rest ->
              (match Actor_json.member "name" f, Actor_json.member "type" f with
               | Some (`String name), Some ty ->
                 (match parse_schema_json ty with
                  | Ok s -> go ((name, s) :: acc) rest
                  | Error e -> Error e)
               | _ -> Error "struct field")
            | _ -> Error "struct field"
          in
          go [] fields
        | _ -> Error "struct fields")
     | Some (`String "variant") ->
       (match Actor_json.member "constructors" obj with
        | Some (`List cs) ->
          let rec go acc = function
            | [] -> Ok (Variant (List.rev acc))
            | (`Assoc _ as c) :: rest ->
              (match Actor_json.member "name" c, Actor_json.member "type" c with
               | Some (`String name), Some ty ->
                 (match parse_schema_json ty with
                  | Ok s -> go ((name, s) :: acc) rest
                  | Error e -> Error e)
               | _ -> Error "variant constructor")
            | _ -> Error "variant constructor"
          in
          go [] cs
        | _ -> Error "variant constructors")
     | _ -> Error "schema kind")
  | _ -> Error "schema object"

let rec resolve_schema messages = function
  | Primitive n -> Primitive n
  | Reference n ->
    (match List.find_opt (fun (q, _) -> q = n) messages with
     | Some (_, (s, _)) -> resolve_schema messages s
     | None -> Reference n)
  | List s -> List (resolve_schema messages s)
  | Optional s -> Optional (resolve_schema messages s)
  | Struct fs -> Struct (List.map (fun (n, s) -> n, resolve_schema messages s) fs)
  | Variant cs -> Variant (List.map (fun (n, s) -> n, resolve_schema messages s) cs)

let rec resolved_json messages seen = function
  | Primitive n -> schema_to_json (Primitive n)
  | List s -> `Assoc ["kind", `String "list"; "element", resolved_json messages seen s]
  | Optional s -> `Assoc ["kind", `String "optional"; "element", resolved_json messages seen s]
  | Struct fs ->
    `Assoc [
      "kind", `String "struct";
      "fields", `List (List.mapi (fun i (name, ty) ->
        `Assoc ["name", `String name; "type", resolved_json messages seen ty; "index", `Int i]) fs)
    ]
  | Variant cs ->
    `Assoc [
      "kind", `String "variant";
      "constructors", `List (List.map (fun (name, ty) ->
        `Assoc ["name", `String name; "type", resolved_json messages seen ty]) cs)
    ]
  | Reference n ->
    if List.mem n seen then `Assoc ["kind", `String "reference"; "name", `String n]
    else
      match List.find_opt (fun (q, _) -> q = n) messages with
      | None -> `Assoc ["kind", `String "reference"; "name", `String n]
      | Some (_, (s, _)) ->
        `Assoc [
          "kind", `String "resolved";
          "name", `String n;
          "schema", resolved_json messages (n :: seen) s
        ]

let schema_hash messages qualified schema =
  let body =
    `Assoc [
      "name", `String qualified;
      "schema", resolved_json messages [] schema;
    ]
  in
  Actor_jcs.hash_json body

let actor_hash name version accepts emits message_hashes =
  let wrap pairs =
    `Assoc (List.map (fun (kind, ty) ->
      let h = List.assoc ty message_hashes in
      kind, `Assoc ["name", `String ty; "schema_hash", `String h]
    ) pairs)
  in
  Actor_jcs.hash_json (`Assoc [
    "name", `String name;
    "version", `Int version;
    "accepts", wrap accepts;
    "emits", wrap emits;
  ])

let primitives = ["string"; "int"; "float"; "bool"; "void"; "date"; "record"]

let rec collect_refs acc = function
  | Primitive _ -> acc
  | Reference n -> n :: acc
  | List s | Optional s -> collect_refs acc s
  | Struct fs -> List.fold_left (fun a (_, s) -> collect_refs a s) acc fs
  | Variant cs -> List.fold_left (fun a (_, s) -> collect_refs a s) acc cs

let rec validate_wire schema json =
  match schema, json with
  | Primitive "string", `String _ -> Ok ()
  | Primitive "date", `String _ -> Ok ()
  | Primitive "bool", `Bool _ -> Ok ()
  | Primitive "void", `Null -> Ok ()
  | Primitive "record", `Assoc _ -> Ok ()
  | Primitive "int", `Int n when int_in_json_range n -> Ok ()
  | Primitive "int", `Intlit s ->
    (try
       let n = Int64.of_string s in
       if n >= json_int_min && n <= json_int_max then Ok ()
       else Error "int out of JSON range"
     with Failure _ -> Error "invalid int")
  | Primitive "float", `Float f when Float.is_finite f -> Ok ()
  | Primitive "float", `Int n -> ignore n; Ok ()
  | Primitive "int", `Float f when Float.is_finite f && f = floor f ->
    let n = Int64.of_float f in
    if n >= json_int_min && n <= json_int_max then Ok () else Error "int out of JSON range"
  | Optional _, `Null -> Ok ()
  | Optional s, v -> validate_wire s v
  | List s, `List xs ->
    let rec go = function
      | [] -> Ok ()
      | x :: rest ->
        (match validate_wire s x with Ok () -> go rest | Error e -> Error e)
    in
    go xs
  | Struct fields, `List xs ->
    if List.length xs <> List.length fields then
      Error "struct arity"
    else
      let rec go fs vs =
        match fs, vs with
        | [], [] -> Ok ()
        | (_, ty) :: frest, v :: vrest ->
          (match validate_wire ty v with Ok () -> go frest vrest | Error e -> Error e)
        | _ -> Error "struct arity"
      in
      go fields xs
  | Variant ctors, `List [`String tag; payload] ->
    (match List.find_opt (fun (n, _) -> n = tag) ctors with
     | None -> Error ("unknown variant " ^ tag)
     | Some (_, ty) -> validate_wire ty payload)
  | Primitive n, _ -> Error ("expected " ^ n)
  | Reference n, _ -> Error ("unresolved " ^ n)
  | _ -> Error "wire mismatch"

let find_message (desc : descriptor) name =
  List.find_opt (fun (q, _) -> q = name) desc.messages

let message_schema (desc : descriptor) name =
  match find_message desc name with
  | Some (_, (s, h)) -> Some (s, h)
  | None -> None

let read_input_path (desc : descriptor) ~payload_type payload path =
  match message_schema desc payload_type with
  | None -> Error (err "InvalidAddress" ("unknown type " ^ payload_type))
  | Some (schema, _) ->
    let rec go schema json = function
      | [] ->
        (match json with
         | `String s when s <> "" -> Ok s
         | `String _ -> Error (err "InvalidAddress" "empty actor id")
         | _ -> Error (err "InvalidAddress" "input_path is not a string"))
      | key :: rest ->
        (match schema with
         | Struct fields ->
           let rec idx i = function
             | [] -> None
             | (n, ty) :: _ when n = key -> Some (i, ty)
             | _ :: xs -> idx (i + 1) xs
           in
           (match json, idx 0 fields with
            | `List arr, Some (i, ty) ->
              (match ty with
               | List _ | Optional _ | Variant _ ->
                 Error (err "InvalidAddress" "input_path through list/optional/variant")
               | _ ->
                 (try go ty (List.nth arr i) rest
                  with Failure _ | Invalid_argument _ ->
                    Error (err "InvalidAddress" "input_path missing field")))
            | _ -> Error (err "InvalidAddress" "input_path expected struct array"))
         | List _ | Optional _ | Variant _ ->
           Error (err "InvalidAddress" "input_path through list/optional/variant")
         | _ -> Error (err "InvalidAddress" "input_path not a struct"))
    in
    go schema payload path

(* ── TOML catalog ─────────────────────────────────────────────────── *)

let module_name_of_file path =
  Filename.basename path |> Filename.chop_extension |> String.capitalize_ascii

let toml_files dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".toml")
  |> List.sort String.compare
  |> List.map (fun f -> Filename.concat dir f)

let get_table toml path =
  match Otoml.find_opt toml Otoml.get_table path with
  | Some pairs -> Some pairs
  | None -> None

let rec parse_type ~module_name ~available value =
  match value with
  | Otoml.TomlString s ->
    if List.mem s primitives then Ok (Primitive s)
    else if String.contains s '.' then
      if qualified_type s && List.mem s available then Ok (Reference s)
      else Error ("unknown type " ^ s)
    else
      let q = module_name ^ "." ^ s in
      if ident_actor s && List.mem q available then Ok (Reference q)
      else Error ("unknown type " ^ s)
  | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs ->
    let get_str k =
      match List.assoc_opt k pairs with
      | Some (Otoml.TomlString s) -> Some s
      | _ -> None
    in
    let get_bool k =
      match List.assoc_opt k pairs with
      | Some (Otoml.TomlBoolean b) -> Some b
      | _ -> None
    in
    let optional = Option.value ~default:false (get_bool "optional") in
    let keys = List.map fst pairs in
    let allowed = ["type"; "of"; "optional"] in
    if List.exists (fun k -> not (List.mem k allowed)) keys then
      Error "unknown type table key"
    else
      (match get_str "type" with
       | Some "list" ->
         (match get_str "of" with
          | None -> Error "list requires of"
          | Some of_ ->
            parse_type ~module_name ~available (Otoml.TomlString of_)
            |> Result.map (fun s -> if optional then Optional (List s) else List s))
       | Some "optional" ->
         (match get_str "of" with
          | None -> Error "optional requires of"
          | Some of_ ->
            parse_type ~module_name ~available (Otoml.TomlString of_)
            |> Result.map (fun s -> Optional s))
       | Some s ->
         parse_type ~module_name ~available (Otoml.TomlString s)
         |> Result.map (fun t -> if optional then Optional t else t)
       | None -> Error "type table missing type")
  | _ -> Error "invalid type value"

let parse_catalog source_dir =
  let files = toml_files source_dir in
  if files = [] then Error [err "InvalidContract" "no TOML files"]
  else
    let errors = ref [] in
    let push e = errors := e :: !errors in
    let parsed =
      List.filter_map (fun path ->
        match Otoml.Parser.from_file_result path with
        | Error msg ->
          push (err ~path:(Some path) "InvalidContract" msg);
          None
        | Ok toml -> Some (path, toml)
      ) files
    in
    List.iter (fun (path, toml) ->
      match get_table toml ["service"; "rpc"] with
      | Some _ ->
        push (err ~path:(Some path) "InvalidContract" "service.rpc is not allowed in Actor contracts")
      | None -> ()
    ) parsed;
    let available =
      List.concat_map (fun (path, toml) ->
        let module_name = module_name_of_file path in
        match get_table toml ["msg"] with
        | None -> []
        | Some pairs -> List.map (fun (n, _) -> module_name ^ "." ^ n) pairs
      ) parsed
    in
    let modules_rev = ref [] in
    let messages_rev = ref [] in
    let actors_rev = ref [] in
    let seen_modules = Hashtbl.create 8 in
    List.iter (fun (path, toml) ->
      let module_name = module_name_of_file path in
      let norm = ocaml_module_name module_name in
      if Hashtbl.mem seen_modules norm then
        push (err ~path:(Some path) "InvalidContract" ("module name collision " ^ module_name))
      else Hashtbl.add seen_modules norm ();
      modules_rev := module_name :: !modules_rev;
      (match get_table toml ["msg"] with
       | None -> ()
       | Some pairs ->
         List.iter (fun (msg_name, msg_val) ->
           if not (ident_actor msg_name) then
             push (err ~path:(Some (path ^ "/msg/" ^ msg_name)) "InvalidContract" "invalid message name")
           else
             let struct_pairs, variant_pairs =
               match msg_val with
               | Otoml.TomlTable ps | Otoml.TomlInlineTable ps ->
                 let st =
                   match List.assoc_opt "struct" ps with
                   | Some (Otoml.TomlTable s | Otoml.TomlInlineTable s) -> Some s
                   | _ -> None
                 in
                 let vr =
                   match List.assoc_opt "variant" ps with
                   | Some (Otoml.TomlTable s | Otoml.TomlInlineTable s) -> Some s
                   | _ -> None
                 in
                 let extra = List.filter (fun (k, _) -> k <> "struct" && k <> "variant") ps in
                 if extra <> [] then
                   push (err ~path:(Some (path ^ "/msg/" ^ msg_name)) "InvalidContract" "unknown message key");
                 (st, vr)
               | _ -> (None, None)
             in
             match struct_pairs, variant_pairs with
             | Some _, Some _ ->
               push (err ~path:(Some (path ^ "/msg/" ^ msg_name)) "InvalidContract" "struct and variant together")
             | Some fields, None ->
               let rec go acc = function
                 | [] ->
                   messages_rev := {
                     module_name; name = msg_name;
                     qualified = module_name ^ "." ^ msg_name;
                     schema = Struct (List.rev acc);
                   } :: !messages_rev
                 | (fname, fval) :: rest ->
                   if not (ident_field fname) then
                     push (err ~path:(Some (path ^ "/msg/" ^ msg_name ^ "/" ^ fname)) "InvalidContract" "invalid field name")
                   else
                     match parse_type ~module_name ~available fval with
                     | Error msg ->
                       push (err ~path:(Some (path ^ "/msg/" ^ msg_name ^ "/" ^ fname)) "InvalidContract" msg)
                     | Ok ty -> go ((fname, ty) :: acc) rest
               in
               go [] fields
             | None, Some ctors ->
               let rec go acc = function
                 | [] ->
                   messages_rev := {
                     module_name; name = msg_name;
                     qualified = module_name ^ "." ^ msg_name;
                     schema = Variant (List.rev acc);
                   } :: !messages_rev
                 | (cname, cval) :: rest ->
                   if not (ident_actor cname) then
                     push (err ~path:(Some (path ^ "/msg/" ^ msg_name ^ "/" ^ cname)) "InvalidContract" "invalid constructor")
                   else
                     match parse_type ~module_name ~available cval with
                     | Error msg ->
                       push (err ~path:(Some (path ^ "/msg/" ^ msg_name ^ "/" ^ cname)) "InvalidContract" msg)
                     | Ok ty -> go ((cname, ty) :: acc) rest
               in
               go [] ctors
             | None, None ->
               push (err ~path:(Some (path ^ "/msg/" ^ msg_name)) "InvalidContract" "message must be struct or variant")
         ) pairs);
      match get_table toml ["actor"] with
      | None -> ()
      | Some pairs ->
        let name =
          match List.assoc_opt "name" pairs with
          | Some (Otoml.TomlString n) -> n
          | _ -> ""
        in
        let version =
          match List.assoc_opt "version" pairs with
          | Some (Otoml.TomlInteger v) -> v
          | _ -> 0
        in
        if String.length name >= 7 && String.sub name 0 7 = "__well." then
          push (err ~path:(Some path) "InvalidContract" "reserved actor name");
        if not (ident_actor name) then
          push (err ~path:(Some path) "InvalidContract" "invalid actor name");
        if version <= 0 then
          push (err ~path:(Some path) "InvalidContract" "version must be positive");
        let table_of key =
          match List.assoc_opt key pairs with
          | Some (Otoml.TomlTable t | Otoml.TomlInlineTable t) -> t
          | _ -> []
        in
        let parse_map key =
          let t = table_of key in
          List.filter_map (fun (k, v) ->
            if not (ident_actor k) then begin
              push (err ~path:(Some (path ^ "/actor/" ^ key ^ "/" ^ k)) "InvalidContract" "invalid constructor name");
              None
            end else
              match v with
              | Otoml.TomlString ty ->
                let q =
                  if String.contains ty '.' then ty else module_name ^ "." ^ ty
                in
                if not (List.mem q available) then begin
                  push (err ~path:(Some (path ^ "/actor/" ^ key ^ "/" ^ k)) "InvalidContract" ("unknown type " ^ ty));
                  None
                end else Some (k, q)
              | _ ->
                push (err ~path:(Some (path ^ "/actor/" ^ key ^ "/" ^ k)) "InvalidContract" "expected type name");
                None
          ) t
        in
        let accepts = parse_map "accepts" in
        let emits = parse_map "emits" in
        if accepts = [] then
          push (err ~path:(Some path) "InvalidContract" "accepts must be non-empty");
        let known = ["name"; "version"; "accepts"; "emits"] in
        List.iter (fun (k, _) ->
          if not (List.mem k known) then
            push (err ~path:(Some path) "InvalidContract" ("unknown actor key " ^ k))
        ) pairs;
        actors_rev := {
          module_name; name; version; accepts; emits;
        } :: !actors_rev
    ) parsed;
    let messages = List.rev !messages_rev in
    let qnames = List.map (fun m -> m.qualified) messages in
    let dup =
      let seen = Hashtbl.create 16 in
      List.filter (fun q ->
        if Hashtbl.mem seen q then true else (Hashtbl.add seen q (); false)
      ) qnames
    in
    List.iter (fun q -> push (err "InvalidContract" ("duplicate type " ^ q))) dup;
    let by_q = List.map (fun m -> m.qualified, m.schema) messages in
    List.iter (fun m ->
      List.iter (fun r ->
        if not (List.mem_assoc r by_q) then
          push (err "InvalidContract" ("unknown reference " ^ r ^ " in " ^ m.qualified))
      ) (collect_refs [] m.schema)
    ) messages;
    let rec cycle_from start path schema =
      match schema with
      | Reference n ->
        if n = start && path <> [] then true
        else if List.mem n path then false
        else
          (match List.assoc_opt n by_q with
           | None -> false
           | Some s -> cycle_from start (n :: path) s)
      | List s | Optional s -> cycle_from start path s
      | Struct fs -> List.exists (fun (_, s) -> cycle_from start path s) fs
      | Variant cs -> List.exists (fun (_, s) -> cycle_from start path s) cs
      | Primitive _ -> false
    in
    List.iter (fun m ->
      if cycle_from m.qualified [] m.schema then
        push (err "InvalidContract" ("cyclic type " ^ m.qualified))
    ) messages;
    let actor_names = Hashtbl.create 8 in
    List.iter (fun (a : actor_def) ->
      if Hashtbl.mem actor_names a.name then
        push (err "InvalidContract" ("duplicate actor " ^ a.name))
      else Hashtbl.add actor_names a.name ()
    ) (List.rev !actors_rev);
    if !errors <> [] then Error (List.rev !errors)
    else
      Ok {
        modules = List.rev !modules_rev;
        messages;
        actors = List.rev !actors_rev;
        files = List.map (fun path -> path, module_name_of_file path) files;
      }

let descriptor_of_catalog (cat : catalog) =
  let msg_pairs_unhashed =
    List.map (fun (m : msg_def) -> m.qualified, m.schema) cat.messages
  in
  let hashed =
    List.map (fun (m : msg_def) ->
      let h = schema_hash (List.map (fun (q, s) -> q, (s, "")) msg_pairs_unhashed) m.qualified m.schema in
      m.qualified, (m.schema, h)
    ) cat.messages
  in
  let message_hashes = List.map (fun (q, (_, h)) -> q, h) hashed in
  let actors =
    List.map (fun (a : actor_def) ->
      let h = actor_hash a.name a.version a.accepts a.emits message_hashes in
      a.name, ({ version = a.version; accepts = a.accepts; emits = a.emits; actor_contract_hash = h } : actor_meta)
    ) cat.actors
  in
  let messages_json =
    `Assoc (List.map (fun (q, (s, h)) ->
      q, `Assoc ["schema", schema_to_json s; "schema_hash", `String h]
    ) hashed)
  in
  let actors_json =
    `Assoc (List.map (fun ((name, meta) : string * actor_meta) ->
      name, `Assoc [
        "version", `Int meta.version;
        "accepts", `Assoc (List.map (fun (k, v) -> k, `String v) meta.accepts);
        "emits", `Assoc (List.map (fun (k, v) -> k, `String v) meta.emits);
        "actor_contract_hash", `String meta.actor_contract_hash;
      ]
    ) actors)
  in
  let json =
    `Assoc [
      "format", `Int 1;
      "modules", `List (List.map (fun m -> `String m) cat.modules);
      "messages", messages_json;
      "actors", actors_json;
    ]
  in
  { format = 1; modules = cat.modules; messages = hashed; actors; json }

let descriptor_to_json (d : descriptor) = d.json

let parse_descriptor json =
  match json with
  | `Assoc _ as obj ->
    let format = match Actor_json.member "format" obj with Some (`Int 1) -> Ok 1 | _ -> Error (err "InvalidContract" "format") in
    let modules =
      match Actor_json.member "modules" obj with
      | Some (`List xs) ->
        List.fold_left (fun acc x ->
          match acc, x with
          | Ok xs, `String m -> Ok (xs @ [m])
          | Error e, _ -> Error e
          | _ -> Error (err "InvalidContract" "modules")) (Ok []) xs
      | _ -> Error (err "InvalidContract" "modules")
    in
    let messages =
      match Actor_json.member "messages" obj with
      | Some (`Assoc pairs) ->
        let rec go acc = function
          | [] -> Ok (List.rev acc)
          | (name, (`Assoc _ as body)) :: rest ->
            (match Actor_json.member "schema" body, Actor_json.member "schema_hash" body with
             | Some schema_json, Some (`String h) ->
               (match parse_schema_json schema_json with
                | Ok s -> go ((name, (s, h)) :: acc) rest
                | Error e -> Error (err "InvalidContract" e))
             | _ -> Error (err "InvalidContract" ("message " ^ name)))
          | _ -> Error (err "InvalidContract" "messages")
        in
        go [] pairs
      | _ -> Error (err "InvalidContract" "messages")
    in
    let actors =
      match Actor_json.member "actors" obj with
      | Some (`Assoc pairs) ->
        let rec go acc = function
          | [] -> Ok (List.rev acc)
          | (name, (`Assoc _ as body)) :: rest ->
            let version = match Actor_json.member "version" body with Some (`Int v) -> v | _ -> 0 in
            let map key =
              match Actor_json.member key body with
              | Some (`Assoc xs) ->
                List.filter_map (function (k, `String v) -> Some (k, v) | _ -> None) xs
              | _ -> []
            in
            let h = match Actor_json.member "actor_contract_hash" body with Some (`String s) -> s | _ -> "" in
            if version <= 0 || h = "" then Error (err "InvalidContract" ("actor " ^ name))
            else
              go ((name, { version; accepts = map "accepts"; emits = map "emits"; actor_contract_hash = h }) :: acc) rest
          | _ -> Error (err "InvalidContract" "actors")
        in
        go [] pairs
      | _ -> Error (err "InvalidContract" "actors")
    in
    (match format, modules, messages, actors with
     | Ok format, Ok modules, Ok messages, Ok actors ->
       let recomputed =
         List.map (fun (q, (s, _)) ->
           q, (s, schema_hash messages q s)
         ) messages
       in
       let bad =
         List.exists2 (fun (_, (_, a)) (_, (_, b)) -> a <> b) messages recomputed
       in
       if bad then Error [err "InvalidContract" "schema_hash mismatch"]
       else
         let json = `Assoc [
           "format", `Int format;
           "modules", `List (List.map (fun m -> `String m) modules);
           "messages", (match Actor_json.member "messages" obj with Some v -> v | None -> `Assoc []);
           "actors", (match Actor_json.member "actors" obj with Some v -> v | None -> `Assoc []);
         ] in
         Ok { format; modules; messages = recomputed; actors; json }
     | Error e, _, _, _ | _, Error e, _, _ | _, _, Error e, _ | _, _, _, Error e -> Error [e])
  | _ -> Error [err "InvalidContract" "descriptor must be an object"]

let lookup_actor (desc : descriptor) name = List.assoc_opt name desc.actors

let message_type (desc : descriptor) ~name ~encode ~decode =
  match find_message desc name with
  | None -> Error (err "InvalidInput" ("unknown message " ^ name))
  | Some (_, (schema, schema_hash)) ->
    let schema = resolve_schema desc.messages schema in
    let encode v =
      let json = encode v in
      match validate_wire schema json with
      | Ok () -> json
      | Error _ -> invalid_arg "Well.Actor.encode: codec produced invalid wire"
    in
    let decode json =
      match validate_wire schema json with
      | Error msg -> Error (err "InvalidInput" msg)
      | Ok () ->
        match decode json with
        | Ok v -> Ok v
        | Error msg -> Error (err "InvalidInput" msg)
    in
    Ok { name; schema_hash; encode; decode }

let define desc ~actor_type (raw : (module RAW_ACTOR)) =
  match lookup_actor desc actor_type with
  | None -> Error [err "InvalidContract" ("unknown actor type " ^ actor_type)]
  | Some meta ->
    let module R = (val raw) in
    if R.state_version <= 0 then
      Error [err "InvalidContract" "state_version must be positive"]
    else
      Ok {
        actor_type;
        version = meta.version;
        descriptor = desc;
        actor_contract_hash = meta.actor_contract_hash;
        accepts = meta.accepts;
        emits = meta.emits;
        state_version = R.state_version;
        raw;
      }

(* ── Codegen ──────────────────────────────────────────────────────── *)

let rec type_to_ocaml local = function
  | Primitive "string" | Primitive "date" -> "string"
  | Primitive "int" -> "int"
  | Primitive "float" -> "float"
  | Primitive "bool" -> "bool"
  | Primitive "void" -> "unit"
  | Primitive "record" -> "Yojson.Safe.t"
  | Primitive n -> n
  | Reference q ->
    (match String.split_on_char '.' q with
     | [m; t] when m = local -> t ^ ".t"
     | [m; t] -> ocaml_module_name m ^ "." ^ t ^ ".t"
     | _ -> q ^ ".t")
  | List s -> type_to_ocaml local s ^ " list"
  | Optional s -> type_to_ocaml local s ^ " option"
  | Struct _ -> "Yojson.Safe.t"
  | Variant _ -> "Yojson.Safe.t"

let rec to_wire_expr local expr = function
  | Primitive "string" | Primitive "date" -> Printf.sprintf "`String %s" expr
  | Primitive "int" -> Printf.sprintf "`Int %s" expr
  | Primitive "float" -> Printf.sprintf "`Float %s" expr
  | Primitive "bool" -> Printf.sprintf "`Bool %s" expr
  | Primitive "void" -> "`Null"
  | Primitive "record" -> Printf.sprintf "(%s :> Yojson.Safe.t)" expr
  | Reference q ->
    (match String.split_on_char '.' q with
     | [m; t] when m = local -> Printf.sprintf "%s.to_wire %s" t expr
     | [m; t] -> Printf.sprintf "%s.%s.to_wire %s" (ocaml_module_name m) t expr
     | _ -> Printf.sprintf "to_wire %s" expr)
  | List s ->
    Printf.sprintf "`List (List.map (fun item -> %s) %s)" (to_wire_expr local "item" s) expr
  | Optional s ->
    Printf.sprintf "(match %s with None -> `Null | Some x -> %s)" expr (to_wire_expr local "x" s)
  | _ -> expr

let rec of_wire_expr local expr = function
  | Primitive "string" | Primitive "date" ->
    Printf.sprintf "(match %s with `String s -> Ok s | _ -> Error \"expected string\")" expr
  | Primitive "int" ->
    Printf.sprintf
      "(match %s with `Int n when n >= -9007199254740991 && n <= 9007199254740991 -> Ok n | _ -> Error \"expected int\")"
      expr
  | Primitive "float" ->
    Printf.sprintf
      "(match %s with `Float f when Float.is_finite f -> Ok f | `Int n -> Ok (float_of_int n) | _ -> Error \"expected float\")"
      expr
  | Primitive "bool" ->
    Printf.sprintf "(match %s with `Bool b -> Ok b | _ -> Error \"expected bool\")" expr
  | Primitive "void" ->
    Printf.sprintf "(match %s with `Null -> Ok () | _ -> Error \"expected null\")" expr
  | Primitive "record" ->
    Printf.sprintf "(match %s with `Assoc _ as o -> Ok o | _ -> Error \"expected object\")" expr
  | Reference q ->
    (match String.split_on_char '.' q with
     | [m; t] when m = local -> Printf.sprintf "%s.of_wire %s" t expr
     | [m; t] -> Printf.sprintf "%s.%s.of_wire %s" (ocaml_module_name m) t expr
     | _ -> Printf.sprintf "of_wire %s" expr)
  | List s ->
    Printf.sprintf
      "(match %s with `List items -> let rec go acc = function [] -> Ok (List.rev acc) | item :: rest -> (match %s with Ok v -> go (v :: acc) rest | Error e -> Error e) in go [] items | _ -> Error \"expected list\")"
      expr (of_wire_expr local "item" s)
  | Optional s ->
    Printf.sprintf
      "(match %s with `Null -> Ok None | x -> (match %s with Ok v -> Ok (Some v) | Error e -> Error e))"
      expr (of_wire_expr local "x" s)
  | _ -> Printf.sprintf "Error \"unsupported\""

let ocaml_quote s = "\"" ^ String.escaped s ^ "\""

let descriptor_loader desc_json qualified =
  Printf.sprintf
    "let message_type =\n    let d = match Well.Actor.Generated.descriptor (Yojson.Safe.from_string %s) with\n      | Ok d -> d\n      | Error _ -> invalid_arg \"actor descriptor\"\n    in\n    match Well.Actor.Generated.message_type d ~name:%s ~encode:to_wire ~decode:of_wire with\n    | Ok t -> t\n    | Error e -> invalid_arg e.message\n"
    (ocaml_quote desc_json) (ocaml_quote qualified)

let generate_struct local msg_name fields desc_json =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in
  let fields = List.map (fun (n, ty) -> escape_keyword n, ty) fields in
  p "module %s = struct\n" msg_name;
  (match fields with
   | [] ->
     p "  type t = unit\n\n";
     p "  let make () = ()\n\n";
     p "  let to_wire (_ : t) : Yojson.Safe.t = `List []\n\n";
     p "  let of_wire (wire : Yojson.Safe.t) : (t, string) result =\n";
     p "    match wire with `List [] -> Ok () | _ -> Error \"expected empty array\"\n\n"
   | _ ->
     p "  type t = {\n";
     List.iter (fun (esc, ty) -> p "    %s : %s;\n" esc (type_to_ocaml local ty)) fields;
     p "  }\n\n";
     p "  let make";
     List.iter (fun (esc, _) -> p " ~%s" esc) fields;
     p " () = {";
     List.iteri (fun i (esc, _) -> if i > 0 then p "; "; p "%s" esc) fields;
     p " }\n\n";
     p "  let to_wire (v : t) : Yojson.Safe.t =\n    `List [\n";
     List.iter (fun (esc, ty) -> p "      %s;\n" (to_wire_expr local ("v." ^ esc) ty)) fields;
     p "    ]\n\n";
     p "  let of_wire (wire : Yojson.Safe.t) : (t, string) result =\n";
     p "    match wire with\n";
     p "    | `List arr when List.length arr = %d ->\n" (List.length fields);
     p "      let a = Array.of_list arr in\n";
     let rec nest i =
       if i = List.length fields then begin
         p "      Ok {";
         List.iteri (fun j (esc, _) -> if j > 0 then p "; "; p "%s" esc) fields;
         p "}\n";
         List.iter (fun _ -> p "      )\n") fields
       end else
         let (esc, ty) = List.nth fields i in
         p "      (match %s with\n" (of_wire_expr local (Printf.sprintf "a.(%d)" i) ty);
         p "       | Error e -> Error e\n";
         p "       | Ok %s ->\n" esc;
         nest (i + 1)
     in
     nest 0;
     p "    | _ -> Error \"%s: expected array\"\n\n" msg_name);
  p "  %s" (descriptor_loader desc_json (local ^ "." ^ msg_name));
  p "end\n";
  Buffer.contents buf


let generate_variant local msg_name ctors desc_json =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in
  p "module %s = struct\n" msg_name;
  p "  type t =\n";
  List.iter (fun (name, ty) ->
    match ty with
    | Primitive "void" -> p "    | %s\n" name
    | _ -> p "    | %s of %s\n" name (type_to_ocaml local ty)
  ) ctors;
  p "\n";
  p "  let to_wire (v : t) : Yojson.Safe.t =\n    match v with\n";
  List.iter (fun (name, ty) ->
    match ty with
    | Primitive "void" -> p "    | %s -> `List [`String %s; `Null]\n" name (ocaml_quote name)
    | _ ->
      p "    | %s payload -> `List [`String %s; %s]\n"
        name (ocaml_quote name) (to_wire_expr local "payload" ty)
  ) ctors;
  p "\n";
  p "  let of_wire (wire : Yojson.Safe.t) : (t, string) result =\n    match wire with\n";
  List.iter (fun (name, ty) ->
    match ty with
    | Primitive "void" ->
      p "    | `List [`String %s; `Null] | `List [`String %s] -> Ok %s\n"
        (ocaml_quote name) (ocaml_quote name) name
    | _ ->
      p "    | `List [`String %s; payload] ->\n      (match %s with Ok v -> Ok (%s v) | Error e -> Error e)\n"
        (ocaml_quote name) (of_wire_expr local "payload" ty) name
  ) ctors;
  p "    | _ -> Error \"%s: unexpected variant\"\n\n" msg_name;
  p "  %s" (descriptor_loader desc_json (local ^ "." ^ msg_name));
  p "end\n";
  Buffer.contents buf

let generate_msg local (m : msg_def) desc_json =
  match m.schema with
  | Struct fields -> generate_struct local m.name fields desc_json
  | Variant ctors -> generate_variant local m.name ctors desc_json
  | _ -> ""

let generate_actor local (a : actor_def) desc_json =
  let buf = Buffer.create 1024 in
  let p fmt = Printf.bprintf buf fmt in
  let q ty =
    match String.split_on_char '.' ty with
    | [m; t] when m = local -> t ^ ".t"
    | [m; t] -> ocaml_module_name m ^ "." ^ t ^ ".t"
    | _ -> ty
  in
  let qmod ty =
    match String.split_on_char '.' ty with
    | [m; t] when m = local -> t
    | [m; t] -> ocaml_module_name m ^ "." ^ t
    | _ -> ty
  in
  p "module Inbound = struct\n";
  p "  type t =\n";
  List.iter (fun (k, ty) -> p "    | %s of %s\n" k (q ty)) a.accepts;
  p "  let of_wire ~kind json =\n    match kind with\n";
  List.iter (fun (k, ty) ->
    p "    | %s -> (match %s.of_wire json with Ok v -> Ok (%s v) | Error e -> Error e)\n"
      (ocaml_quote k) (qmod ty) k
  ) a.accepts;
  p "    | _ -> Error (\"unknown inbound \" ^ kind)\n";
  p "end\n\n";
  p "module Outbound = struct\n";
  p "  type t =\n";
  (match a.emits with
   | [] -> p "    | Unused of unit\n"
   | emits -> List.iter (fun (k, ty) -> p "    | %s of %s\n" k (q ty)) emits);
  p "  let to_wire = function\n";
  (match a.emits with
   | [] -> p "    | Unused () -> (\"Unused\", `Null)\n"
   | emits ->
     List.iter (fun (k, ty) ->
       p "    | %s v -> (%s, %s.to_wire v)\n" k (ocaml_quote k) (qmod ty)
     ) emits);
  p "end\n\n";
  p "type inbound = Inbound.t\n";
  p "type outbound = Outbound.t\n\n";
  p "module type IMPL = sig\n";
  p "  type state\n";
  p "  val state_version : int\n";
  p "  val init : Well.Actor.actor_id -> state\n";
  p "  val state_to_wire : state -> Yojson.Safe.t\n";
  p "  val state_of_wire : Yojson.Safe.t -> (state, string) result\n";
  p "  val handle : Well.Actor.context -> state -> inbound ->\n";
  p "    (state * outbound list, Well.Actor.failure) result\n";
  p "end\n\n";
  p "let make (module I : IMPL) =\n";
  p "  let d = match Well.Actor.Generated.descriptor (Yojson.Safe.from_string %s) with\n"
    (ocaml_quote desc_json);
  p "    | Ok d -> d\n";
  p "    | Error _ -> invalid_arg %s\n" (ocaml_quote (a.name ^ ".make: descriptor"));
  p "  in\n";
  p "  let raw = (module struct\n";
  p "    type state = I.state\n";
  p "    type inbound = Inbound.t\n";
  p "    type outbound = Outbound.t\n";
  p "    let state_version = I.state_version\n";
  p "    let init = I.init\n";
  p "    let state_to_wire = I.state_to_wire\n";
  p "    let state_of_wire = I.state_of_wire\n";
  p "    let inbound_of_wire = Inbound.of_wire\n";
  p "    let outbound_to_wire = Outbound.to_wire\n";
  p "    let handle = I.handle\n";
  p "  end : Well.Actor.Generated.RAW_ACTOR) in\n";
  p "  match Well.Actor.Generated.define d ~actor_type:%s raw with\n" (ocaml_quote a.name);
  p "  | Ok def -> def\n";
  p "  | Error _ -> invalid_arg %s\n" (ocaml_quote (a.name ^ ".make"));
  Buffer.contents buf

let generate_struct_mli local msg_name fields =
  let buf = Buffer.create 256 in
  let p fmt = Printf.bprintf buf fmt in
  p "module %s : sig\n" msg_name;
  (match fields with
   | [] -> p "  type t = unit\n  val make : unit -> t\n"
   | _ ->
     p "  type t = {\n";
     List.iter (fun (n, ty) ->
       p "    %s : %s;\n" (escape_keyword n) (type_to_ocaml local ty)
     ) fields;
     p "  }\n";
     p "  val make :";
     List.iter (fun (n, ty) ->
       p " %s:%s ->" (escape_keyword n) (type_to_ocaml local ty)
     ) fields;
     p " unit -> t\n");
  p "  val to_wire : t -> Yojson.Safe.t\n";
  p "  val of_wire : Yojson.Safe.t -> (t, string) result\n";
  p "  val message_type : t Well.Actor.message_type\n";
  p "end\n";
  Buffer.contents buf

let generate_variant_mli local msg_name ctors =
  let buf = Buffer.create 256 in
  let p fmt = Printf.bprintf buf fmt in
  p "module %s : sig\n" msg_name;
  p "  type t =\n";
  List.iter (fun (name, ty) ->
    match ty with
    | Primitive "void" -> p "    | %s\n" name
    | _ -> p "    | %s of %s\n" name (type_to_ocaml local ty)
  ) ctors;
  p "  val to_wire : t -> Yojson.Safe.t\n";
  p "  val of_wire : Yojson.Safe.t -> (t, string) result\n";
  p "  val message_type : t Well.Actor.message_type\n";
  p "end\n";
  Buffer.contents buf

let generate_actor_mli local (a : actor_def) =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in
  let q ty =
    match String.split_on_char '.' ty with
    | [m; t] when m = local -> t ^ ".t"
    | [m; t] -> ocaml_module_name m ^ "." ^ t ^ ".t"
    | _ -> ty
  in
  p "module Inbound : sig\n  type t =\n";
  List.iter (fun (k, ty) -> p "    | %s of %s\n" k (q ty)) a.accepts;
  p "end\n";
  p "module Outbound : sig\n  type t =\n";
  (match a.emits with
   | [] -> p "    | Unused of unit\n"
   | emits -> List.iter (fun (k, ty) -> p "    | %s of %s\n" k (q ty)) emits);
  p "end\n";
  p "type inbound = Inbound.t\n";
  p "type outbound = Outbound.t\n";
  p "module type IMPL = sig\n";
  p "  type state\n";
  p "  val state_version : int\n";
  p "  val init : Well.Actor.actor_id -> state\n";
  p "  val state_to_wire : state -> Yojson.Safe.t\n";
  p "  val state_of_wire : Yojson.Safe.t -> (state, string) result\n";
  p "  val handle : Well.Actor.context -> state -> inbound ->\n";
  p "    (state * outbound list, Well.Actor.failure) result\n";
  p "end\n";
  p "val make : (module IMPL) -> Well.Actor.definition\n";
  Buffer.contents buf

let local_messages cat module_name =
  List.filter (fun (m : msg_def) -> m.module_name = module_name) cat.messages

let topo_local cat module_name =
  let msgs = local_messages cat module_name in
  let qset = List.map (fun m -> m.qualified) msgs in
  let deps m =
    collect_refs [] m.schema |> List.filter (fun r -> List.mem r qset)
  in
  let remaining = ref msgs in
  let ordered = ref [] in
  while !remaining <> [] do
    let ready, blocked =
      List.partition (fun m ->
        List.for_all (fun d ->
          List.exists (fun (o : msg_def) -> o.qualified = d) !ordered
        ) (deps m)
      ) !remaining
    in
    if ready = [] then (ordered := !remaining @ !ordered; remaining := [])
    else (ordered := !ordered @ ready; remaining := blocked)
  done;
  !ordered

let generate_ml cat desc module_name =
  let desc_json = Yojson.Safe.to_string desc.json in
  let buf = Buffer.create 2048 in
  List.iter (fun m ->
    Buffer.add_string buf (generate_msg module_name m desc_json);
    Buffer.add_char buf '\n'
  ) (topo_local cat module_name);
  List.iter (fun (a : actor_def) ->
    if a.module_name = module_name then
      Buffer.add_string buf (generate_actor module_name a desc_json)
  ) cat.actors;
  Buffer.contents buf

let generate_mli cat module_name =
  let buf = Buffer.create 1024 in
  List.iter (fun (m : msg_def) ->
    match m.schema with
    | Struct fields -> Buffer.add_string buf (generate_struct_mli module_name m.name fields)
    | Variant ctors -> Buffer.add_string buf (generate_variant_mli module_name m.name ctors)
    | _ -> ()
  ) (topo_local cat module_name);
  List.iter (fun (a : actor_def) ->
    if a.module_name = module_name then
      Buffer.add_string buf (generate_actor_mli module_name a)
  ) cat.actors;
  Buffer.contents buf

let snake_file module_name = snake_case module_name ^ ".ml"
let snake_mli module_name = snake_case module_name ^ ".mli"

let generate_dune cat =
  let mods =
    cat.modules
    |> List.map snake_case
    |> List.sort String.compare
    |> String.concat " "
  in
  Printf.sprintf
    "(library\n (name actor_contracts)\n (wrapped false)\n (libraries well.core yojson)\n (modules %s))\n"
    mods

let manifest_name = ".well-actor-manifest.json"

let file_sha path =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let s = really_input_string ic len in
  close_in ic;
  Actor_jcs.sha256_hex s

let write_file path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

let mkdir_p path =
  let rec go p =
    if p = "/" || p = "." || Sys.file_exists p then ()
    else (go (Filename.dirname p); Unix.mkdir p 0o755)
  in
  try go path with Unix.Unix_error (Unix.EEXIST, _, _) -> ()

let rm_rf path =
  let rec go p =
    if Sys.file_exists p then
      if Sys.is_directory p then begin
        Array.iter (fun n -> go (Filename.concat p n)) (Sys.readdir p);
        Unix.rmdir p
      end else Sys.remove p
  in
  go path

let list_rel root =
  let acc = ref [] in
  let rec go prefix dir =
    Array.iter (fun name ->
      let rel = if prefix = "" then name else prefix ^ "/" ^ name in
      let full = Filename.concat dir name in
      if Sys.is_directory full then go rel full
      else acc := rel :: !acc
    ) (Sys.readdir dir)
  in
  if Sys.file_exists root && Sys.is_directory root then go "" root;
  List.sort String.compare !acc

let read_manifest dir =
  let p = Filename.concat dir manifest_name in
  if not (Sys.file_exists p) then None
  else
    match Actor_json.parse_file p with
    | Error _ -> None
    | Ok (`Assoc _ as obj) ->
      (match Actor_json.member "files" obj with
       | Some (`Assoc pairs) ->
         Some (List.filter_map (function (k, `String h) -> Some (k, h) | _ -> None) pairs)
       | _ -> None)
    | Ok _ -> None

let check_output_dir output_dir =
  if not (Sys.file_exists output_dir) then Ok ()
  else if not (Sys.is_directory output_dir) then
    Error [err "InvalidContract" "output_dir is not a directory"]
  else
    let on_disk = list_rel output_dir in
    if on_disk = [] then Ok ()
    else
      match read_manifest output_dir with
      | None ->
        Error [err "InvalidContract" "output_dir is not an Actor contract directory"]
      | Some files ->
        let expected = List.sort String.compare (List.map fst files @ [manifest_name]) in
        let on_disk = List.sort String.compare on_disk in
        if expected <> on_disk then
          Error [err "InvalidContract" "output_dir contains foreign files"]
        else Ok ()

let build ~source_dir ~output_dir =
  if source_dir = output_dir then
    Error [err "InvalidContract" "output_dir must be distinct from source_dir"]
  else
    match parse_catalog source_dir with
    | Error e -> Error e
    | Ok cat ->
      match check_output_dir output_dir with
      | Error e -> Error e
      | Ok () ->
        let desc = descriptor_of_catalog cat in
        let parent = Filename.dirname output_dir in
        let tmp = Filename.concat parent (Filename.basename output_dir ^ ".generating") in
        rm_rf tmp;
        mkdir_p (Filename.concat tmp "ocaml");
        let written = ref [] in
        List.iter (fun module_name ->
          let ml_name = "ocaml/" ^ snake_file module_name in
          let mli_name = "ocaml/" ^ snake_mli module_name in
          let ml = generate_ml cat desc module_name in
          let mli = generate_mli cat module_name in
          write_file (Filename.concat tmp ml_name) ml;
          write_file (Filename.concat tmp mli_name) mli;
          written := ml_name :: mli_name :: !written
        ) cat.modules;
        let dune = generate_dune cat in
        write_file (Filename.concat tmp "ocaml/dune") dune;
        written := "ocaml/dune" :: !written;
        let desc_s = Yojson.Safe.to_string desc.json ^ "\n" in
        write_file (Filename.concat tmp "descriptor.json") desc_s;
        written := "descriptor.json" :: !written;
        let files =
          List.map (fun rel ->
            rel, file_sha (Filename.concat tmp rel)
          ) (List.sort String.compare !written)
        in
        let manifest =
          Yojson.Safe.to_string (`Assoc [
            "format", `Int 1;
            "files", `Assoc (List.map (fun (n, h) -> n, `String h) files);
          ]) ^ "\n"
        in
        write_file (Filename.concat tmp manifest_name) manifest;
        let old = output_dir ^ ".old" in
        (try
           if Sys.file_exists output_dir then begin
             rm_rf old;
             Unix.rename output_dir old
           end;
           Unix.rename tmp output_dir;
           rm_rf old;
           Ok ()
         with exn ->
           (try if Sys.file_exists old && not (Sys.file_exists output_dir) then
              Unix.rename old output_dir with _ -> ());
           Error [err "InvalidContract" ("replace failed: " ^ Printexc.to_string exn)])

let validate_payload (desc : descriptor) ~payload_type json =
  match find_message desc payload_type with
  | None -> Error (err "InvalidInput" ("unknown type " ^ payload_type))
  | Some (_, (schema, hash)) ->
    let schema = resolve_schema desc.messages schema in
    match validate_wire schema json with
    | Ok () -> Ok hash
    | Error m -> Error (err "InvalidInput" m)

let catalog_json registered =
  let modules = Hashtbl.create 8 in
  let messages = Hashtbl.create 16 in
  let actors : (string, actor_meta) Hashtbl.t = Hashtbl.create 8 in
  List.iter (fun (d : definition) ->
    List.iter (fun m -> Hashtbl.replace modules m ()) d.descriptor.modules;
    List.iter (fun (q, (s, h)) ->
      match Hashtbl.find_opt messages q with
      | Some (_, h') when h' <> h -> ()
      | _ -> Hashtbl.replace messages q (s, h)
    ) d.descriptor.messages;
    Hashtbl.replace actors d.actor_type ({
      version = d.version;
      accepts = d.accepts;
      emits = d.emits;
      actor_contract_hash = d.actor_contract_hash;
    } : actor_meta)
  ) registered;
  let module_names =
    List.sort String.compare (Hashtbl.fold (fun k () acc -> k :: acc) modules [])
  in
  let messages_json =
    `Assoc (Hashtbl.fold (fun q (s, h) acc ->
      (q, `Assoc ["schema", schema_to_json s; "schema_hash", `String h]) :: acc
    ) messages [] |> List.sort compare)
  in
  let actors_json =
    `Assoc (Hashtbl.fold (fun name (meta : actor_meta) acc ->
      (name, `Assoc [
        "version", `Int meta.version;
        "accepts", `Assoc (List.map (fun (k, v) -> k, `String v) meta.accepts);
        "emits", `Assoc (List.map (fun (k, v) -> k, `String v) meta.emits);
        "actor_contract_hash", `String meta.actor_contract_hash;
      ]) :: acc
    ) actors [] |> List.sort compare)
  in
  `Assoc [
    "format", `Int 1;
    "modules", `List (List.map (fun m -> `String m) module_names);
    "messages", messages_json;
    "actors", actors_json;
  ]

let join_batch_schema (desc : descriptor) ~item_type ~batch_type =
  match find_message desc batch_type, find_message desc item_type with
  | Some (_, (Struct ["items", List item], _)), Some (_, (item_schema, _)) ->
    let resolved_item = resolve_schema desc.messages item_schema in
    let resolved_listed = resolve_schema desc.messages item in
    if resolved_item = resolved_listed || item = Reference item_type || item = item_schema
    then Ok ()
    else Error "batch items type mismatch"
  | Some (_, (Struct fields, _)), _ ->
    if List.length fields = 1 && fst (List.hd fields) = "items" then
      Error "batch items must be a list of item_type"
    else Error "batch_type must be a record with exactly field items"
  | _ -> Error "unknown item_type or batch_type"
