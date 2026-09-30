(* W2 harness: drive Contract_build over a fixture source directory. *)

let () =
  let source_dir = Sys.argv.(1) in
  let output_dir = Sys.argv.(2) in
  match Well_cli.Contract_build.build ~source_dir ~output_dir () with
  | Error errors ->
    List.iter
      (fun (e : Well_cli.Contract_build.error) ->
        Printf.eprintf "error[%s] %s%s\n" e.code e.message
          (match e.path with Some p -> " (" ^ p ^ ")" | None -> ""))
      errors;
    exit 1
  | Ok (summary : Well_cli.Contract_build.summary) ->
    Printf.printf "modules: %s\n" (String.concat ", " summary.modules);
    List.iter (fun p -> Printf.printf "  %s\n" p) summary.artifacts