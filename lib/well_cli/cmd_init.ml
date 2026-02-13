let valid_name name =
  String.length name > 0
  && name.[0] >= 'a'
  && name.[0] <= 'z'
  && String.to_seq name
     |> Seq.for_all (fun c ->
            (c >= 'a' && c <= 'z')
            || (c >= '0' && c <= '9')
            || c = '_')

let ignorable_entries =
  [ "."; ".."; ".git"; ".gitignore"; ".gitkeep"; ".DS_Store" ]

let dir_is_empty_enough path =
  let entries = Sys.readdir path |> Array.to_list in
  List.for_all (fun e -> List.mem e ignorable_entries) entries

let mkdir_p path =
  let parts = String.split_on_char '/' path in
  let _ =
    List.fold_left
      (fun acc part ->
        let dir = if acc = "" then part else acc ^ "/" ^ part in
        if dir <> "" && not (Sys.file_exists dir) then Sys.mkdir dir 0o755;
        dir)
      "" parts
  in
  ()

let write_file path content =
  let dir = Filename.dirname path in
  if not (Sys.file_exists dir) then mkdir_p dir;
  let oc = open_out path in
  output_string oc content;
  close_out oc

let run args =
  let target =
    match args with
    | [ t ] -> t
    | [] ->
      Printf.eprintf "Error: missing project name\n";
      Printf.eprintf "Usage: well init <name>\n";
      exit 1
    | _ ->
      Printf.eprintf "Error: too many arguments\n";
      Printf.eprintf "Usage: well init <name>\n";
      exit 1
  in
  let init_in_current_dir = target = "." in
  let name, base_dir =
    if init_in_current_dir then (
      let cwd = Sys.getcwd () in
      let name = Filename.basename cwd in
      if not (valid_name name) then (
        Printf.eprintf
          "Error: current directory name '%s' is not a valid project name\n"
          name;
        Printf.eprintf
          "Project names must start with a lowercase letter and contain only \
           a-z, 0-9, _\n";
        exit 1);
      if not (dir_is_empty_enough cwd) then (
        Printf.eprintf "Error: current directory is not empty\n";
        Printf.eprintf
          "Use 'well init <name>' to create a new directory, or empty this \
           directory first\n";
        exit 1);
      (name, "."))
    else (
      if not (valid_name target) then (
        Printf.eprintf "Error: '%s' is not a valid project name\n" target;
        Printf.eprintf
          "Project names must start with a lowercase letter and contain only \
           a-z, 0-9, _\n";
        exit 1);
      if Sys.file_exists target then (
        Printf.eprintf "Error: directory '%s' already exists\n" target;
        exit 1);
      (target, target))
  in
  let files = Template.project_files name in
  List.iter
    (fun (file : Template.file) ->
      let full_path =
        if base_dir = "." then file.path else base_dir ^ "/" ^ file.path
      in
      write_file full_path file.content)
    files;
  Printf.printf "\n";
  (* Run dune pkg lock + dune build inside the project dir *)
  let run_in_dir cmd_str =
    let full_cmd =
      if base_dir = "." then cmd_str
      else Printf.sprintf "cd %s && %s" base_dir cmd_str
    in
    Sys.command full_cmd
  in
  Printf.printf "Resolving dependencies...\n%!";
  let lock_rc = run_in_dir "dune pkg lock > /dev/null 2>&1" in
  if lock_rc <> 0 then (
    Printf.eprintf "Warning: 'dune pkg lock' failed (exit %d)\n" lock_rc;
    Printf.eprintf "Run it manually to see details.\n%!")
  else (
    Printf.printf "Building (this may take a minute)...\n%!";
    let build_rc = run_in_dir "dune build > /dev/null 2>&1" in
    if build_rc <> 0 then (
      Printf.eprintf "Warning: 'dune build' failed (exit %d)\n" build_rc;
      Printf.eprintf "Run 'dune build' manually to see details.\n%!")
    else
      Printf.printf "Done!\n%!");
  Printf.printf "\n";
  if init_in_current_dir then
    Printf.printf "Initialized well project: %s (in current directory)\n\n" name
  else (
    Printf.printf "Created new well project: %s\n\n" name;
    Printf.printf "  cd %s\n" name);
  Printf.printf "  dune exec bin/main.exe\n";
  Printf.printf "\nHappy hacking!\n"

let cmd : Command.t =
  {
    name = "init";
    summary = "Create a new well project";
    usage = "init <name>";
    description =
      "Create a new well project with the given name.\n\
       The name must start with a lowercase letter and contain only a-z, 0-9, \
       _.\n\n\
       Examples:\n\
      \  well init my_app        Create project in new directory ./my_app/\n\
      \  well init .             Initialize project in current directory";
    run;
  }
