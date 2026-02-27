(* cmd_release.ml — `well release` command *)

let run args =
  (* Build first *)
  Cmd_build.run args;
  let name = Cmd_build.detect_name () in
  let version = Cmd_build.detect_version () in
  let archive =
    match version with
    | Some v -> Printf.sprintf "%s-v%s.tar.gz" name v
    | None -> Printf.sprintf "%s.tar.gz" name
  in
  (* Create archive *)
  Printf.printf "\nCreating archive...\n%!";
  let rc =
    Sys.command
      (Printf.sprintf "tar czf %s -C %s ."
         (Filename.quote archive)
         (Filename.quote Cmd_build.release_dir))
  in
  if rc <> 0 then (
    Printf.eprintf "Error: failed to create archive\n";
    exit 1);
  (* Show size *)
  let ic =
    Unix.open_process_in
      (Printf.sprintf "du -h %s | cut -f1" (Filename.quote archive))
  in
  let size =
    (try String.trim (input_line ic) with End_of_file -> "?")
  in
  ignore (Unix.close_process_in ic);
  Printf.printf "\n\027[32mRelease: %s (%s)\027[0m\n" archive size;
  Printf.printf "\nDeploy:\n";
  Printf.printf "  scp %s server:/srv/%s/\n" archive name;
  Printf.printf "  ssh server 'cd /srv/%s && tar xzf %s && ./bin/%s'\n" name
    archive name;
  Printf.printf "\nArchive contains bin/ and static/ only. data/ is not touched.\n"

let cmd : Command.t =
  {
    name = "release";
    summary = "Create deployable archive";
    usage = "release";
    description =
      "Build and package a deployable .tar.gz archive.\n\
       Runs `well build` first, then creates a compressed archive.\n\n\
       Output: <name>-v<version>.tar.gz (or <name>.tar.gz if no version)";
    run;
  }
