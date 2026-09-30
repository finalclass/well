(* Actor contract code generation for Well.

   Cyrograf generates the message types and their text [to_drut]/[from_drut]
   conversions into a separate data library. Well generates only the actor
   integration layer on top of those public conversions: the [message_type]
   witness, [Inbound.t]/[Outbound.t], the [IMPL] module type and [make]. There
   is no second type parser and no second message codec here. *)

module Compiler = Cyrograf_compiler
module Schema = Cyrograf.Schema
module Info = Cyrograf_compiler.Info

type error = Actor_compile.error

type artifact = { path : string; contents : string }

let snake_case name =
  let buf = Buffer.create (String.length name + 8) in
  String.iteri
    (fun i c ->
      if c >= 'A' && c <= 'Z' then begin
        if i > 0 then Buffer.add_char buf '_';
        Buffer.add_char buf (Char.lowercase_ascii c)
      end
      else Buffer.add_char buf c)
    name;
  Buffer.contents buf

let ocaml_library_module name = String.capitalize_ascii (snake_case name)

let ocaml_quote s = "\"" ^ String.escaped s ^ "\""

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let rebase ~from ~into path =
  if starts_with ~prefix:from path then
    into ^ String.sub path (String.length from) (String.length path - String.length from)
  else path

let qualified_path (q : string) =
  match String.split_on_char '.' q with
  | [ module_name; message_name ] ->
    Info.qualified_message Compiler.Ocaml ~module_name ~message_name
  | _ -> q

let type_path q = qualified_path q ^ ".t"

let data_ref ~data_module q = data_module ^ "." ^ qualified_path q

let of_cyrograf = Actor_compile.of_cyrograf

let generate_data ~library ~prefix ~schema =
  match
    Compiler.Generator.generate ~ocaml_profile:Compiler.Native
      ~ocaml_library:library ~targets:[ Compiler.Ocaml ] ~schema ()
  with
  | Error errors -> Error (List.map of_cyrograf errors)
  | Ok artifacts ->
    Ok
      (List.map
         (fun (a : Compiler.artifact) ->
           { path = rebase ~from:"ocaml/" ~into:(prefix ^ "/") a.path;
             contents = a.contents })
         artifacts)

let message_ml ~data_module ~descriptor_json ~module_name (msg : Schema.message) =
  let ref_ = data_ref ~data_module (module_name ^ "." ^ msg.name) in
  let qualified = module_name ^ "." ^ msg.name in
  Printf.sprintf
    "module %s = struct\n\
    \  include %s\n\n\
    \  let to_wire (v : t) : Yojson.Safe.t =\n\
    \    match to_drut v with\n\
    \    | Ok text -> Yojson.Safe.from_string text\n\
    \    | Error e -> invalid_arg (\"Well.Actor encode: \" ^ Cyrograf.Error.to_string e)\n\n\
    \  let of_wire (json : Yojson.Safe.t) : (t, string) result =\n\
    \    match from_drut (Yojson.Safe.to_string json) with\n\
    \    | Ok value -> Ok value\n\
    \    | Error e -> Error (Cyrograf.Error.to_string e)\n\n\
    \  let message_type : t Well.Actor.message_type =\n\
    \    let d =\n\
    \      match Well.Actor.Generated.descriptor (Yojson.Safe.from_string %s) with\n\
    \      | Ok d -> d\n\
    \      | Error _ -> invalid_arg \"actor descriptor\"\n\
    \    in\n\
    \    match\n\
    \      Well.Actor.Generated.message_type d ~name:%s ~encode:to_wire\n\
    \        ~decode:of_wire\n\
    \    with\n\
    \    | Ok t -> t\n\
    \    | Error e -> invalid_arg e.message\n\
    end\n"
    msg.name ref_ (ocaml_quote descriptor_json) (ocaml_quote qualified)

let message_mli ~data_module ~module_name (msg : Schema.message) =
  let ref_ = data_ref ~data_module (module_name ^ "." ^ msg.name) in
  Printf.sprintf
    "module %s : sig\n\
    \  include module type of %s\n\
    \  val to_wire : t -> Yojson.Safe.t\n\
    \  val of_wire : Yojson.Safe.t -> (t, string) result\n\
    \  val message_type : t Well.Actor.message_type\n\
    end\n"
    msg.name ref_

let actor_ml ~descriptor_json (a : Actor_compile.actor_decl) =
  let buf = Buffer.create 1024 in
  let p fmt = Printf.bprintf buf fmt in
  p "module Inbound = struct\n";
  p "  type t =\n";
  List.iter (fun (kind, ty) -> p "    | %s of %s\n" kind (type_path ty)) a.accepts;
  p "  let of_wire ~kind json =\n    match kind with\n";
  List.iter
    (fun (kind, ty) ->
      p "    | %s ->\n      (match %s.of_wire json with\n"
        (ocaml_quote kind) (qualified_path ty);
      p "       | Ok v -> Ok (%s v)\n       | Error e -> Error e)\n" kind)
    a.accepts;
  p "    | _ -> Error (\"unknown inbound \" ^ kind)\n";
  p "end\n\n";
  p "module Outbound = struct\n";
  p "  type t =\n";
  (match a.emits with
   | [] -> p "    | Unused of unit\n"
   | emits -> List.iter (fun (kind, ty) -> p "    | %s of %s\n" kind (type_path ty)) emits);
  p "  let to_wire = function\n";
  (match a.emits with
   | [] -> p "    | Unused () -> (\"Unused\", `Null)\n"
   | emits ->
     List.iter
       (fun (kind, ty) ->
         p "    | %s v -> (%s, %s.to_wire v)\n" kind (ocaml_quote kind) (qualified_path ty))
       emits);
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
  p "  let d =\n";
  p "    match Well.Actor.Generated.descriptor (Yojson.Safe.from_string %s) with\n"
    (ocaml_quote descriptor_json);
  p "    | Ok d -> d\n";
  p "    | Error _ -> invalid_arg %s\n" (ocaml_quote (a.name ^ ".make: descriptor"));
  p "  in\n";
  p "  let raw =\n";
  p "    (module struct\n";
  p "      type state = I.state\n";
  p "      type inbound = Inbound.t\n";
  p "      type outbound = Outbound.t\n";
  p "      let state_version = I.state_version\n";
  p "      let init = I.init\n";
  p "      let state_to_wire = I.state_to_wire\n";
  p "      let state_of_wire = I.state_of_wire\n";
  p "      let inbound_of_wire = Inbound.of_wire\n";
  p "      let outbound_to_wire = Outbound.to_wire\n";
  p "      let handle = I.handle\n";
  p "    end : Well.Actor.Generated.RAW_ACTOR)\n";
  p "  in\n";
  p "  match Well.Actor.Generated.define d ~actor_type:%s raw with\n"
    (ocaml_quote a.name);
  p "  | Ok def -> def\n";
  p "  | Error _ -> invalid_arg %s\n" (ocaml_quote (a.name ^ ".make"));
  Buffer.contents buf

let actor_mli (a : Actor_compile.actor_decl) =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in
  p "module Inbound : sig\n  type t =\n";
  List.iter (fun (kind, ty) -> p "    | %s of %s\n" kind (type_path ty)) a.accepts;
  p "end\n";
  p "module Outbound : sig\n  type t =\n";
  (match a.emits with
   | [] -> p "    | Unused of unit\n"
   | emits -> List.iter (fun (kind, ty) -> p "    | %s of %s\n" kind (type_path ty)) emits);
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

let generate_adapters ~data_library ~adapter_prefix ~descriptor_json ~actors
    (schema : Schema.t) =
  let data_module = ocaml_library_module data_library in
  let artifacts = ref [] in
  List.iter
    (fun (m : Schema.module_) ->
      let ml = Buffer.create 2048 in
      let mli = Buffer.create 1024 in
      List.iter
        (fun (msg : Schema.message) ->
          Buffer.add_string ml (message_ml ~data_module ~descriptor_json ~module_name:m.name msg);
          Buffer.add_char ml '\n';
          Buffer.add_string mli (message_mli ~data_module ~module_name:m.name msg);
          Buffer.add_char mli '\n')
        m.messages;
      List.iter
        (fun (a : Actor_compile.actor_decl) ->
          if a.module_name = m.name then begin
            Buffer.add_string ml (actor_ml ~descriptor_json a);
            Buffer.add_string mli (actor_mli a)
          end)
        actors;
      let file = snake_case m.name in
      artifacts :=
        { path = adapter_prefix ^ "/" ^ file ^ ".ml"; contents = Buffer.contents ml }
        :: !artifacts;
      artifacts :=
        { path = adapter_prefix ^ "/" ^ file ^ ".mli"; contents = Buffer.contents mli }
        :: !artifacts)
    schema.modules;
  let modules =
    schema.modules |> List.map (fun (m : Schema.module_) -> snake_case m.name)
    |> List.sort String.compare |> String.concat " "
  in
  let dune =
    Printf.sprintf
      "(library\n (name actor_contracts)\n (wrapped false)\n (libraries %s \
       well.core yojson cyrograf)\n (modules %s))\n"
      data_library modules
  in
  artifacts :=
    { path = adapter_prefix ^ "/dune"; contents = dune } :: !artifacts;
  List.rev !artifacts

let generate ~data_library ~data_prefix ~adapter_prefix ~schema ~actors
    ~descriptor_json () =
  match generate_data ~library:data_library ~prefix:data_prefix ~schema with
  | Error errors -> Error errors
  | Ok data ->
    let adapters =
      generate_adapters ~data_library ~adapter_prefix ~descriptor_json ~actors schema
    in
    Ok (data @ adapters)