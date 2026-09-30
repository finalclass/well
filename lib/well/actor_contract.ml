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

let map_compile_error (e : Well_contract.Actor_compile.error) =
  match e.path with
  | Some path -> err ~path:(Some path) e.code e.message
  | None -> err e.code e.message

let rec schema_of_cyrograf (t : Cyrograf.Schema.type_) =
  match t with
  | Cyrograf.Schema.Primitive p -> Primitive (Cyrograf.Schema.primitive_name p)
  | Cyrograf.Schema.Reference q -> Reference (Cyrograf.Schema.qualified_name q)
  | Cyrograf.Schema.List e -> List (schema_of_cyrograf e)
  | Cyrograf.Schema.Optional e -> Optional (schema_of_cyrograf e)

let catalog_of_loaded (loaded : Well_contract.Actor_compile.loaded) =
  let modules =
    List.map (fun (m : Cyrograf.Schema.module_) -> m.name) loaded.schema.modules
  in
  let messages =
    List.concat_map
      (fun (m : Cyrograf.Schema.module_) ->
        List.map
          (fun (msg : Cyrograf.Schema.message) ->
            let schema =
              match msg.kind with
              | Cyrograf.Schema.Struct fields ->
                Struct
                  (List.map
                     (fun (f : Cyrograf.Schema.field) -> f.name, schema_of_cyrograf f.type_)
                     fields)
              | Cyrograf.Schema.Variant constructors ->
                Variant
                  (List.map
                     (fun (c : Cyrograf.Schema.constructor) ->
                       c.name, schema_of_cyrograf c.payload)
                     constructors)
            in
            { module_name = m.name; name = msg.name;
              qualified = m.name ^ "." ^ msg.name; schema })
          m.messages)
      loaded.schema.modules
  in
  let actors =
    List.map
      (fun (a : Well_contract.Actor_compile.actor_decl) ->
        { module_name = a.module_name; name = a.name; version = a.version;
          accepts = a.accepts; emits = a.emits })
      loaded.actors
  in
  { modules; messages; actors; files = [] }

let build ~source_dir ~output_dir =
  if source_dir = output_dir then
    Error [err "InvalidContract" "output_dir must be distinct from source_dir"]
  else
    match Well_contract.Actor_compile.load ~source_dir with
    | Error errors -> Error (List.map map_compile_error errors)
    | Ok loaded ->
      let desc = descriptor_of_catalog (catalog_of_loaded loaded) in
      (match
         Well_contract.Actor_codegen.generate ~data_library:"actor_data"
           ~data_prefix:"ocaml_data" ~adapter_prefix:"ocaml"
           ~schema:loaded.schema ~actors:loaded.actors
           ~descriptor_json:(Yojson.Safe.to_string desc.json) ()
       with
       | Error errors -> Error (List.map map_compile_error errors)
       | Ok artifacts ->
         (match check_output_dir output_dir with
          | Error e -> Error e
          | Ok () ->
            let parent = Filename.dirname output_dir in
            let tmp = Filename.concat parent (Filename.basename output_dir ^ ".generating") in
            rm_rf tmp;
            mkdir_p tmp;
            List.iter
              (fun (a : Well_contract.Actor_codegen.artifact) ->
                let target = Filename.concat tmp a.path in
                mkdir_p (Filename.dirname target);
                write_file target a.contents)
              artifacts;
            let desc_s = Yojson.Safe.to_string desc.json ^ "\n" in
            write_file (Filename.concat tmp "descriptor.json") desc_s;
            let written =
              "descriptor.json"
              :: List.map (fun (a : Well_contract.Actor_codegen.artifact) -> a.path) artifacts
            in
            let files =
              List.map
                (fun rel -> rel, file_sha (Filename.concat tmp rel))
                (List.sort String.compare written)
            in
            let manifest =
              Yojson.Safe.to_string
                (`Assoc [
                   "format", `Int 1;
                   "files", `Assoc (List.map (fun (n, h) -> n, `String h) files);
                 ])
              ^ "\n"
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
               (try
                  if Sys.file_exists old && not (Sys.file_exists output_dir) then
                    Unix.rename old output_dir
                with _ -> ());
               Error
                 [err "InvalidContract" ("replace failed: " ^ Printexc.to_string exn)])))

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
