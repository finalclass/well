(* Actor contract source adapter for Well.

   Cyrograf owns the message language, the type rules and the codecs. This
   module only feeds it: it loads native [.cyrograf] sources unchanged, projects
   the legacy mixed TOML [msg] tables onto the same frontend, extracts the Well
   [actor] metadata, and validates actor declarations against the compiled
   schema. It contains no second type parser and no codec. *)

module Compiler = Cyrograf_compiler
module Schema = Cyrograf.Schema

type error = { code : string; message : string; path : string option }

type actor_decl = {
  module_name : string;
  name : string;
  version : int;
  accepts : (string * string) list;
  emits : (string * string) list;
}

type loaded = {
  schema : Cyrograf.Schema.t;
  actors : actor_decl list;
}

type raw_actor = {
  raw_module : string;
  raw_name : string;
  raw_version : int;
  raw_accepts : (string * string) list;
  raw_emits : (string * string) list;
}

let error ?path ~code message = { code; message; path }

let of_cyrograf (e : Cyrograf.Error.t) =
  let path =
    match e.source with
    | Some source -> Some source.name
    | None -> (match e.path with [] -> None | segment :: _ -> Some segment)
  in
  error ?path ~code:e.code (Cyrograf.Error.to_string e)

let ident_actor name =
  let len = String.length name in
  len >= 1 && len <= 64
  && name.[0] >= 'A' && name.[0] <= 'Z'
  && String.for_all
       (function 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false)
       name

let source_suffixes = [ ".cyrograf"; ".toml" ]

let is_source_file name =
  List.exists (fun suffix -> Filename.check_suffix name suffix) source_suffixes

let is_actor_meta name = Filename.check_suffix name ".actor.toml"

let module_of_file name =
  if is_actor_meta name then
    Filename.remove_extension (Filename.remove_extension name)
  else Filename.remove_extension name

let module_name_of_file name = String.capitalize_ascii (module_of_file name)

let projected_name name = module_name_of_file name ^ ".toml"

let table_pairs = function
  | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs -> pairs
  | _ -> []

let read_file path =
  let ic = open_in_bin path in
  let text = really_input_string ic (in_channel_length ic) in
  close_in ic;
  text

let reserved_actor name =
  String.length name >= 7 && String.sub name 0 7 = "__well."

let parse_actor ~errors ~path ~module_name pairs =
  let push e = errors := e :: !errors in
  let get key =
    match List.assoc_opt key pairs with
    | Some value -> Some value
    | None -> None
  in
  let name =
    match get "name" with
    | Some (Otoml.TomlString n) -> n
    | _ -> ""
  in
  let version =
    match get "version" with
    | Some (Otoml.TomlInteger v) -> v
    | _ -> 0
  in
  if reserved_actor name then
    push (error ~path ~code:"InvalidContract" "reserved actor name");
  if not (ident_actor name) then
    push (error ~path ~code:"InvalidContract" "invalid actor name");
  if version <= 0 then
    push (error ~path ~code:"InvalidContract" "version must be positive");
  let known = [ "name"; "version"; "accepts"; "emits" ] in
  List.iter
    (fun (key, _) ->
      if not (List.mem key known) then
        push (error ~path ~code:"InvalidContract" ("unknown actor key " ^ key)))
    pairs;
  let parse_map key =
    let table =
      match get key with
      | Some (Otoml.TomlTable t | Otoml.TomlInlineTable t) -> t
      | _ -> []
    in
    List.filter_map
      (fun (ctor, value) ->
        let at = path ^ "/actor/" ^ key ^ "/" ^ ctor in
        if not (ident_actor ctor) then begin
          push (error ~path:at ~code:"InvalidContract" "invalid constructor name");
          None
        end
        else
          match value with
          | Otoml.TomlString ty -> Some (ctor, ty)
          | _ ->
            push (error ~path:at ~code:"InvalidContract" "expected type name");
            None)
      table
  in
  let accepts = parse_map "accepts" in
  let emits = parse_map "emits" in
  if accepts = [] then
    push (error ~path ~code:"InvalidContract" "accepts must be non-empty");
  { raw_module = module_name; raw_name = name; raw_version = version;
    raw_accepts = accepts; raw_emits = emits }

let load_toml ~errors path text =
  match Otoml.Parser.from_string_result text with
  | Error message ->
    errors := error ~path ~code:"InvalidContract" message :: !errors;
    (None, [])
  | Ok (Otoml.TomlTable pairs) ->
    let module_name = module_name_of_file (Filename.basename path) in
    let kept = ref [] in
    let actors = ref [] in
    let push e = errors := e :: !errors in
    List.iter
      (fun (key, value) ->
        match key with
        | "msg" -> kept := (key, value) :: !kept
        | "actor" ->
          (match value with
           | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
             actors :=
               parse_actor ~errors ~path ~module_name (table_pairs value)
               :: !actors
           | _ ->
             push (error ~path ~code:"InvalidContract" "actor must be a table"))
        | "service" ->
          push
            (error ~path ~code:"InvalidContract"
               "service.rpc is not allowed in Actor contracts")
        | other ->
          push
            (error ~path ~code:"InvalidContract"
               ("unknown top-level key " ^ other)))
      pairs;
    let projected = Otoml.TomlTable (List.rev !kept) in
    (Some (projected_name path, Otoml.Printer.to_string projected),
     List.rev !actors)
  | Ok _ ->
    errors :=
      error ~path ~code:"InvalidContract" "the TOML root must be a table" :: !errors;
    (None, [])

let resolve_decl ~errors ~available (raw : raw_actor) =
  let resolve ~at ty =
    let qualified =
      if String.contains ty '.' then ty else raw.raw_module ^ "." ^ ty
    in
    if List.mem qualified available then qualified
    else begin
      errors :=
        error ~path:at ~code:"InvalidContract" ("unknown type " ^ ty) :: !errors;
      qualified
    end
  in
  let map key =
    List.map
      (fun (ctor, ty) -> (ctor, resolve ~at:(raw.raw_module ^ "/actor/" ^ key ^ "/" ^ ctor) ty))
  in
  { module_name = raw.raw_module; name = raw.raw_name; version = raw.raw_version;
    accepts = map "accepts" raw.raw_accepts;
    emits = map "emits" raw.raw_emits }

let load ~source_dir =
  if not (Sys.file_exists source_dir) then
    Error [ error ~code:"InvalidContract" ("source directory '" ^ source_dir ^ "' not found") ]
  else if not (Sys.is_directory source_dir) then
    Error [ error ~code:"InvalidContract" (source_dir ^ " is not a directory") ]
  else
    let names =
      Sys.readdir source_dir |> Array.to_list |> List.filter is_source_file
      |> List.sort String.compare
    in
    if names = [] then
      Error [ error ~code:"InvalidContract" ("no .cyrograf or .toml sources in " ^ source_dir) ]
    else begin
      let errors = ref [] in
      let sources = ref [] in
      let raw_actors = ref [] in
      List.iter
        (fun name ->
          let path = Filename.concat source_dir name in
          let text = read_file path in
          if Filename.check_suffix name ".cyrograf" then
            sources := { Compiler.name; text } :: !sources
          else
            let source, actors = load_toml ~errors path text in
            (match source with
             | Some (name, text) -> sources := { Compiler.name; text } :: !sources
             | None -> ());
            raw_actors := List.rev_append actors !raw_actors)
        names;
      match Compiler.compile ~sources:(List.rev !sources) with
      | Error cyrograf_errors ->
        Error
          (List.map of_cyrograf cyrograf_errors
           @ List.rev !errors)
      | Ok schema ->
        List.iter
          (fun (m : Schema.module_) ->
            if m.methods <> [] then
              errors :=
                error ~path:m.name ~code:"InvalidContract"
                  "service.rpc is not allowed in Actor contracts"
                :: !errors)
          schema.modules;
        let available =
          List.concat_map
            (fun (m : Schema.module_) ->
              List.map
                (fun (msg : Schema.message) -> m.name ^ "." ^ msg.name)
                m.messages)
            schema.modules
        in
        let actors =
          List.map (resolve_decl ~errors ~available) (List.rev !raw_actors)
        in
        let seen = Hashtbl.create 8 in
        List.iter
          (fun (a : actor_decl) ->
            if Hashtbl.mem seen a.name then
              errors :=
                error ~code:"InvalidContract" ("duplicate actor " ^ a.name)
                :: !errors
            else Hashtbl.add seen a.name ())
          actors;
        if !errors <> [] then Error (List.rev !errors)
        else Ok { schema; actors }
    end