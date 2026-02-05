let commands : Command.t list ref = ref []

let register cmd = commands := cmd :: !commands

let sorted_commands () =
  List.sort (fun (a : Command.t) (b : Command.t) -> String.compare a.name b.name) !commands

let print_usage () =
  Printf.printf "well %s — Full-stack OCaml web framework\n\n" Well.version;
  Printf.printf "Usage: well <command> [options]\n\n";
  Printf.printf "Commands:\n";
  List.iter
    (fun (cmd : Command.t) -> Printf.printf "  %-16s %s\n" cmd.name cmd.summary)
    (sorted_commands ());
  Printf.printf "\nRun 'well <command> --help' for more information.\n"

let print_version () =
  Printf.printf "well %s\n" Well.version

let find_command name =
  List.find_opt (fun (cmd : Command.t) -> cmd.name = name) !commands

let run argv =
  let args = Array.to_list argv |> List.tl in
  match args with
  | [] | [ "--help" ] | [ "-h" ] ->
    print_usage ()
  | [ "--version" ] | [ "-v" ] ->
    print_version ()
  | name :: rest -> (
    match find_command name with
    | Some cmd ->
      if rest = [ "--help" ] || rest = [ "-h" ] then (
        Printf.printf "%s — %s\n\n" cmd.name cmd.summary;
        Printf.printf "Usage: well %s\n\n" cmd.usage;
        Printf.printf "%s\n" cmd.description)
      else
        cmd.run rest
    | None ->
      Printf.eprintf "Error: unknown command '%s'\n\n" name;
      print_usage ();
      exit 1)

let () = register Cmd_init.cmd
