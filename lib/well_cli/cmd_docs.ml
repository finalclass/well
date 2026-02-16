(* cmd_docs — `well docs` command *)

(* Extract project name from dune-project *)
let find_project_name () =
  if not (Sys.file_exists "dune-project") then
    "my_app"
  else begin
    let ic = open_in "dune-project" in
    let name = ref "my_app" in
    let in_package = ref false in
    (try while true do
       let line = input_line ic in
       let trimmed = String.trim line in
       (* Track (package stanza *)
       if String.length trimmed >= 8 && String.sub trimmed 0 8 = "(package" then
         in_package := true;
       (* (name ...) inside (package ...) is the project name *)
       if !in_package
          && String.length trimmed > 7
          && String.sub trimmed 0 6 = "(name " then begin
         let rest = String.sub trimmed 6 (String.length trimmed - 6) in
         let rest = String.trim rest in
         let n = match String.index_opt rest ')' with
           | Some i -> String.sub rest 0 i
           | None -> rest
         in
         name := String.trim n;
         in_package := false
       end
     done with End_of_file -> ());
    close_in ic;
    !name
  end

(* Discover .ml and .mlx source files in lib/ *)
let discover_sources () =
  let files = ref [] in
  let rec walk dir =
    if Sys.file_exists dir && Sys.is_directory dir then begin
      let entries = Sys.readdir dir in
      Array.sort String.compare entries;
      Array.iter (fun entry ->
        let path = Filename.concat dir entry in
        if Sys.is_directory path then
          walk path
        else if Filename.check_suffix entry ".ml"
             || Filename.check_suffix entry ".mlx" then
          files := path :: !files
      ) entries
    end
  in
  walk "lib";
  List.rev !files

let run args =
  let output_dir = ref "_docs" in
  let open_browser = ref false in
  let rec parse = function
    | "--output" :: dir :: rest ->
      output_dir := dir;
      parse rest
    | "-o" :: dir :: rest ->
      output_dir := dir;
      parse rest
    | "--open" :: rest ->
      open_browser := true;
      parse rest
    | _ :: rest -> parse rest
    | [] -> ()
  in
  parse args;

  let project_name = find_project_name () in
  let sources = discover_sources () in

  if sources = [] then begin
    Printf.printf "\027[33mNo source files found in lib/\027[0m\n";
    exit 0
  end;

  Printf.printf "Generating docs for \027[1m%s\027[0m...\n" project_name;

  (* Parse all source files *)
  let modules = List.filter_map (fun path ->
    try
      let m = Doc_parser.parse_file path in
      Some m
    with _ ->
      Printf.eprintf "\027[33mWarning: could not parse %s\027[0m\n" path;
      None
  ) sources in

  (* Generate HTML *)
  let count = Doc_html.generate ~project_name ~output_dir:!output_dir ~modules in

  Printf.printf "\027[32mGenerated docs for %d modules → %s/\027[0m\n" count !output_dir;
  Printf.printf "  Open: %s/index.html\n" !output_dir;

  if !open_browser then begin
    let abs_path = Filename.concat (Sys.getcwd ()) (Filename.concat !output_dir "index.html") in
    let cmd = Printf.sprintf "xdg-open %s 2>/dev/null || open %s 2>/dev/null" abs_path abs_path in
    ignore (Sys.command cmd)
  end

let cmd : Command.t = {
  name = "docs";
  summary = "Generate documentation";
  usage = "docs [--output <dir>] [--open]";
  description =
    "Generate static HTML documentation from source files.\n\
     Parses (** ... *) doc comments, routes, LiveViews, and models.\n\
     \n\
     Options:\n\
     \  --output, -o DIR    Output directory (default: _docs/)\n\
     \  --open              Open in browser after generating";
  run;
}
