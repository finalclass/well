(* CLI command: well contract build [contract_dir] [output_dir] *)

let write_file path content =
  let dir = Filename.dirname path in
  if not (Sys.file_exists dir) then
    Cmd_init.mkdir_p dir;
  let oc = open_out path in
  output_string oc content;
  close_out oc

let run args =
  let sub, rest =
    match args with
    | sub :: rest -> (sub, rest)
    | [] -> ("", [])
  in
  if sub <> "build" then begin
    Printf.eprintf "Usage: well contract build [contract_dir] [output_dir]\n";
    exit 1
  end;
  let contract_dir, output_dir =
    match rest with
    | [] -> ("./lib/contract", "lib/contract/build")
    | [dir] -> (dir, "lib/contract/build")
    | [dir; out] -> (dir, out)
    | _ ->
      Printf.eprintf "Usage: well contract build [contract_dir] [output_dir]\n";
      exit 1
  in
  if not (Sys.file_exists contract_dir) then begin
    Printf.eprintf "Error: contract directory '%s' not found\n" contract_dir;
    exit 1
  end;
  let modules = Contract_parser.parse_all contract_dir in
  if modules = [] then begin
    Printf.printf "No contract files found in %s\n" contract_dir;
    exit 0
  end;
  let ocaml_dir = Filename.concat output_dir "ocaml" in
  let ts_dir = Filename.concat output_dir "ts" in
  (* Generate OCaml .ml files *)
  List.iter (fun (cm : Contract_types.contract_module) ->
    let filename = Contract_codegen.snake_case cm.name ^ ".ml" in
    let path = Filename.concat ocaml_dir filename in
    let content = Contract_codegen.generate_module cm in
    write_file path content;
    let msg_count = List.length cm.msgs in
    let rpc_count =
      match cm.service with
      | Some s -> List.length s.rpcs
      | None -> 0
    in
    Printf.printf "  %s (%d msgs, %d rpcs)\n" path msg_count rpc_count
  ) modules;
  (* Generate OCaml dune file only if it doesn't exist *)
  let dune_path = Filename.concat ocaml_dir "dune" in
  if not (Sys.file_exists dune_path) then begin
    let dune_content = Contract_codegen.generate_dune modules ~output_dir:ocaml_dir in
    write_file dune_path dune_content;
    Printf.printf "  %s\n" dune_path
  end;
  (* Generate TypeScript files — silently skip if dir creation fails *)
  (try
     List.iter (fun (cm : Contract_types.contract_module) ->
       let filename = cm.name ^ ".ts" in
       let path = Filename.concat ts_dir filename in
       let content = Contract_codegen.generate_ts_module cm in
       write_file path content;
       Printf.printf "  %s\n" path
     ) modules;
     (* rpc.ts *)
     let rpc_path = Filename.concat ts_dir "rpc.ts" in
     let rpc_content = Contract_codegen.generate_ts_rpc () in
     write_file rpc_path rpc_content;
     Printf.printf "  %s\n" rpc_path
   with _ -> ());
  (* Generate Go files — silently skip if dir creation fails *)
  let go_dir = Filename.concat output_dir "go" in
  (try
     List.iter (fun (cm : Contract_types.contract_module) ->
       let pkg_dir = Filename.concat go_dir (String.lowercase_ascii cm.name) in
       let filename = String.lowercase_ascii cm.name ^ ".go" in
       let path = Filename.concat pkg_dir filename in
       let go_module_path = "contract" in
       let content = Contract_codegen.generate_go_module ~go_module_path cm in
       write_file path content;
       Printf.printf "  %s\n" path
     ) modules
   with _ -> ());
  (* Generate Dart files — silently skip if dir creation fails *)
  let dart_dir = Filename.concat output_dir "dart" in
  (try
     List.iter (fun (cm : Contract_types.contract_module) ->
       let filename = cm.name ^ ".dart" in
       let path = Filename.concat dart_dir filename in
       let content = Contract_codegen.generate_dart_module cm in
       write_file path content;
       Printf.printf "  %s\n" path
     ) modules
   with _ -> ());
  Printf.printf "\nGenerated %d contract module(s) in %s/\n"
    (List.length modules) output_dir

let cmd : Command.t =
  { name = "contract"
  ; summary = "Generate OCaml, TypeScript, Go, and Dart from TOML contracts"
  ; usage = "contract build [contract_dir] [output_dir]"
  ; description =
      "Parses TOML contract files and generates code in four languages:\n\
       OCaml, TypeScript, Go, and Dart.\n\n\
       Default contract directory: ./lib/contract/\n\
       Default output directory: lib/contract/build/\n\
       Output: build/ocaml/*.ml, build/ts/*.ts, build/go/*/*.go, build/dart/*.dart\n\
       Dune file is generated only if it doesn't already exist."
  ; run
  }
