(* CLI command: well contract build [source_dir] [output_dir] [--targets ...]

   Reads .cyrograf sources (legacy TOML stays a Cyrograf compatibility input),
   compiles them with the public Cyrograf library, generates the data libraries
   and the Well adapter layer, and publishes one complete result behind a
   manifest. The old hand-rolled TOML parser/codegen is no longer on this path.

   The default target set is the Well compatibility set: OCaml (native +
   browser), TypeScript, Go and Dart. [--targets] selects a subset explicitly,
   e.g. a project that only compiles OCaml and TypeScript. *)

let target_of_name = function
  | "ocaml" -> Some Cyrograf_compiler.Ocaml
  | "typescript" -> Some Cyrograf_compiler.Typescript
  | "go" -> Some Cyrograf_compiler.Go
  | "dart" -> Some Cyrograf_compiler.Dart
  | _ -> None

let parse_targets value =
  match
    List.filter_map
      (fun name ->
        match target_of_name (String.trim name) with
        | Some t -> Some t
        | None ->
          Printf.eprintf "Error: unknown target '%s'\n" name;
          exit 1)
      (String.split_on_char ',' value)
  with
  | [] ->
    Printf.eprintf "Error: --targets needs at least one target\n";
    exit 1
  | targets -> targets

let run args =
  let sub, rest =
    match args with
    | sub :: rest -> (sub, rest)
    | [] -> ("", [])
  in
  if sub <> "build" then begin
    Printf.eprintf "Usage: well contract build [source_dir] [output_dir]\n";
    exit 1
  end;
  let rec loop targets positionals = function
    | [] -> (List.rev positionals, targets)
    | "--targets" :: value :: tl -> loop (Some (parse_targets value)) positionals tl
    | arg :: tl
      when String.length arg > 10
           && String.sub arg 0 10 = "--targets=" ->
      loop
        (Some (parse_targets (String.sub arg 10 (String.length arg - 10))))
        positionals tl
    | arg :: _ when String.length arg > 0 && arg.[0] = '-' ->
      Printf.eprintf "Error: unexpected argument '%s'\n" arg;
      exit 1
    | arg :: tl -> loop targets (arg :: positionals) tl
  in
  let positionals, targets = loop None [] rest in
  let source_dir, output_dir =
    match positionals with
    | [] -> ("./lib/contract", "lib/contract_generated")
    | [ dir ] -> (dir, "lib/contract_generated")
    | [ dir; out ] -> (dir, out)
    | _ ->
      Printf.eprintf "Usage: well contract build [source_dir] [output_dir]\n";
      exit 1
  in
  match Contract_build.build ~source_dir ~output_dir ?targets () with
  | Error errors ->
    List.iter
      (fun (e : Contract_build.error) ->
        Printf.eprintf "Error[%s] %s%s\n" e.code e.message
          (match e.path with Some p -> " (" ^ p ^ ")" | None -> ""))
      errors;
    exit 1
  | Ok (summary : Contract_build.summary) ->
    List.iter (fun p -> Printf.printf "  %s\n" p) summary.artifacts;
    Printf.printf "\nGenerated %d module(s) in %s/\n"
      (List.length summary.modules) output_dir

let cmd : Command.t =
  { name = "contract"
  ; summary =
      "Compile .cyrograf contracts and generate data libraries plus Well adapters"
  ; usage = "contract build [source_dir] [output_dir] [--targets ocaml,typescript,go,dart]"
  ; description =
      "Compiles .cyrograf sources with the Cyrograf compiler and generates:\n\
       OCaml native data (contract_data), OCaml browser data\n\
       (contract_data_browser), the Well adapter library (contract) with\n\
       IMPL/make_spec, the browser Proxy library (contract_browser), and the\n\
       TypeScript, Go and Dart clients. The complete result is published once\n\
       behind manifest.json.\n\n\
       Default source directory: ./lib/contract/\n\
       Default output directory: lib/contract_generated/\n\
       Default targets: ocaml, typescript, go, dart"
  ; run
  }