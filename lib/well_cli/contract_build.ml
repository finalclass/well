(* Contract build coordination for Well.

   One [well contract build] reads a source directory, compiles it with the
   public Cyrograf library, generates the target data libraries and the Well
   adapter library, and publishes the complete result atomically behind one
   manifest. Well owns only the composition and the adapters; Cyrograf owns
   the language, the types and the message codecs. *)

module Compiler = Cyrograf_compiler

module Ocaml_profile = struct
  type t = Compiler.ocaml_profile = Native | Js
end

type error = { code : string; message : string; path : string option }

type summary = { modules : string list; artifacts : string list }

type artifact = { path : string; contents : string }

let error ?path ~code message = { code; message; path }

let of_cyrograf_error (e : Cyrograf.Error.t) =
  error ~code:e.code (Cyrograf.Error.to_string e)

(* ── Source access ─────────────────────────────────────────────────── *)

let source_suffixes = [ ".cyrograf"; ".toml" ]

let is_source_file name =
  List.exists (fun suffix -> Filename.check_suffix name suffix) source_suffixes

let read_sources dir =
  if not (Sys.file_exists dir) then
    Error
      (error ~code:"source_missing"
         (Printf.sprintf "source directory '%s' not found" dir))
  else if not (Sys.is_directory dir) then
    Error (error ~code:"source_not_dir" (Printf.sprintf "'%s' is not a directory" dir))
  else
    let names =
      Sys.readdir dir |> Array.to_list
      |> List.filter is_source_file
      |> List.sort String.compare
    in
    if names = [] then
      Error (error ~code:"empty_sources"
               (Printf.sprintf "no .cyrograf or .toml sources in '%s'" dir))
    else
      let sources =
        List.map
          (fun name ->
            let path = Filename.concat dir name in
            let ic = open_in_bin path in
            let n = in_channel_length ic in
            let text = really_input_string ic n in
            close_in ic;
            { Compiler.name = name; text })
          names
      in
      Ok sources

(* ── Path helpers ──────────────────────────────────────────────────── *)

let absolute path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path

let normalize path = String.split_on_char '/' (absolute path)

let normalize_segments path =
  let segs = normalize path in
  List.fold_left
    (fun acc seg ->
      match seg with
      | "" | "." -> acc
      | ".." -> (match acc with [] -> [] | _ :: tl -> tl)
      | s -> acc @ [ s ])
    [] segs

let canonical path = "/" ^ String.concat "/" (normalize_segments path)

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let is_within ~parent child =
  child = parent || starts_with ~prefix:(parent ^ "/") child

let rec mkdir_p dir =
  if dir = "" || dir = "/" || dir = "." then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let rec rm_rf path =
  if Sys.file_exists path then begin
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path
  end

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let text = really_input_string ic n in
  close_in ic;
  text

(* ── Artifact layout ───────────────────────────────────────────────── *)

let native_prefix = "ocaml/"
let js_prefix = "ocaml_js/"

let rebase_prefix ~from ~into path =
  if starts_with ~prefix:from path then
    into ^ String.sub path (String.length from) (String.length path - String.length from)
  else path

let profile_library = function
  | Ocaml_profile.Native -> "contract_data"
  | Ocaml_profile.Js -> "contract_data_browser"

let profile_prefix = function
  | Ocaml_profile.Native -> native_prefix
  | Ocaml_profile.Js -> js_prefix

let generate_ocaml ~profile ~schema =
  match
    Compiler.Generator.generate ~ocaml_profile:profile
      ~ocaml_library:(profile_library profile)
      ~targets:[ Compiler.Ocaml ] ~schema ()
  with
  | Error errors -> Error (List.map of_cyrograf_error errors)
  | Ok artifacts ->
    let from = native_prefix in
    let into = profile_prefix profile in
    Ok
      (List.map
         (fun (a : Compiler.artifact) ->
           { path = rebase_prefix ~from ~into a.path; contents = a.contents })
         artifacts)

let generate_other ~targets ~schema =
  match Compiler.Generator.generate ~targets ~schema () with
  | Error errors -> Error (List.map of_cyrograf_error errors)
  | Ok artifacts ->
    Ok
      (List.map (fun (a : Compiler.artifact) -> { path = a.path; contents = a.contents })
         artifacts)

(* ── Publish ───────────────────────────────────────────────────────── *)

let check_relpath path =
  if not (Filename.is_relative path) then
    Error (error ~path ~code:"absolute_path" "artifact path is absolute")
  else if List.mem ".." (String.split_on_char '/' path) then
    Error (error ~path ~code:"unsafe_path" "artifact path escapes the output directory")
  else Ok ()

let publish ~source_dir ~output_dir ~rel_paths ~write =
  let output_abs = canonical output_dir in
  let source_abs = canonical source_dir in
  if is_within ~parent:source_abs output_abs then
    Error
      (error ~code:"output_in_sources" ~path:output_dir
         (Printf.sprintf
            "output '%s' is inside the source directory '%s'; choose a path \
             outside the sources" output_dir source_dir))
  else
    let bad =
      List.find_map
        (fun p -> match check_relpath p with Error e -> Some e | Ok () -> None)
        rel_paths
    in
    match bad with
    | Some e -> Error e
    | None ->
      let exists = Sys.file_exists output_dir in
      let foreign =
        exists && Sys.is_directory output_dir
        && Array.length (Sys.readdir output_dir) > 0
        && not (Sys.file_exists (Filename.concat output_dir "manifest.json"))
      in
      if foreign then
        Error
          (error ~code:"foreign_output" ~path:output_dir
             (Printf.sprintf
                "'%s' is not empty and has no manifest; refusing to take ownership"
                output_dir))
      else begin
        let staging = output_dir ^ ".w2-staging" in
        let previous = output_dir ^ ".w2-previous" in
        rm_rf staging;
        rm_rf previous;
        mkdir_p (Filename.dirname output_dir);
        (try
           mkdir_p staging;
           write staging;
           (if Sys.file_exists output_dir then
              Unix.rename output_dir previous);
           Unix.rename staging output_dir;
           rm_rf previous;
           Ok ()
         with exn ->
           (try rm_rf staging with _ -> ());
           (if (not (Sys.file_exists output_dir)) && Sys.file_exists previous then
              try Unix.rename previous output_dir with _ -> ());
           Error
             (error ~code:"publish_failed" ~path:output_dir
                (Printexc.to_string exn)))
      end

(* ── Build ─────────────────────────────────────────────────────────── *)

let default_targets = [ Compiler.Ocaml; Compiler.Typescript; Compiler.Go; Compiler.Dart ]

let default_profiles = [ Ocaml_profile.Native; Ocaml_profile.Js ]

let dedupe paths =
  let seen = Hashtbl.create 32 in
  List.filter
    (fun p ->
      if Hashtbl.mem seen p then false
      else begin
        Hashtbl.add seen p ();
        true
      end)
    paths

let build ~source_dir ~output_dir ?targets ?ocaml_profiles () =
  let targets = Option.value ~default:default_targets targets in
  let ocaml_profiles = Option.value ~default:default_profiles ocaml_profiles in
  match read_sources source_dir with
  | Error e -> Error [ e ]
  | Ok sources ->
    (match Compiler.compile ~sources with
     | Error errors -> Error (List.map of_cyrograf_error errors)
     | Ok schema ->
       let modules = List.map (fun (m : Cyrograf.Schema.module_) -> m.name) schema.modules in
       let ocaml_target = List.mem Compiler.Ocaml targets in
       let other_targets = List.filter (fun t -> t <> Compiler.Ocaml) targets in
       (match Compiler.validate ~targets ~schema with
        | Error errors -> Error (List.map of_cyrograf_error errors)
        | Ok () ->
          let gather = ref [] in
          let failure = ref None in
          if other_targets <> [] then
            (match generate_other ~targets:other_targets ~schema with
             | Ok arts -> gather := !gather @ arts
             | Error errs -> failure := Some errs);
          if !failure = None && ocaml_target then
            List.iter
              (fun profile ->
                match !failure with
                | Some _ -> ()
                | None ->
                  (match generate_ocaml ~profile ~schema with
                   | Ok arts -> gather := !gather @ arts
                   | Error errs -> failure := Some errs))
              ocaml_profiles;
          if !failure = None && ocaml_target then
            gather :=
              !gather
              @ List.map
                  (fun (a : Contract_adapters.artifact) ->
                    { path = a.path; contents = a.contents })
                  (Contract_adapters.generate ~library:"Contract_data" ~schema);
          if
            !failure = None && ocaml_target
            && List.mem Ocaml_profile.Js ocaml_profiles
          then
            gather :=
              !gather
              @ List.map
                  (fun (a : Contract_adapters.artifact) ->
                    { path = a.path; contents = a.contents })
                  (Contract_adapters.generate_browser ~schema);
          if !failure = None && other_targets <> [] then
            gather :=
              !gather
              @ List.map
                  (fun (a : Contract_adapters.artifact) ->
                    { path = a.path; contents = a.contents })
                  (Contract_adapters.generate_clients
                     ~go_module:"generated_contracts" ~targets:other_targets
                     ~schema);
          (match !failure with
           | Some errs -> Error errs
           | None ->
             let schema_path = "schema.json" in
             let arts =
               { path = schema_path;
                 contents = Compiler.Descriptor.schema_json schema }
               :: !gather
             in
             let paths = List.map (fun (a : artifact) -> a.path) arts |> dedupe in
             (match
                publish ~source_dir ~output_dir ~rel_paths:paths ~write:(fun staging ->
                  List.iter
                    (fun (a : artifact) -> write_file (Filename.concat staging a.path) a.contents)
                    arts;
                  write_file (Filename.concat staging "manifest.json")
                    (Compiler.Descriptor.manifest_json paths))
              with
              | Error e -> Error [ e ]
              | Ok () ->
                Ok { modules; artifacts = "manifest.json" :: paths }))))