(* cmd_test — `well test` command *)

let run args =
  let watch = List.mem "--watch" args || List.mem "-w" args in
  let ci = List.mem "--ci" args in
  let filter =
    let rec find = function
      | "--filter" :: pat :: _ | "-f" :: pat :: _ -> Some pat
      | _ :: rest -> find rest
      | [] -> None
    in
    find args
  in
  (* Build first *)
  let dune = if Sys.file_exists "./vendor/dune" then "./vendor/dune" else "dune" in
  if watch then begin
    let cmd = Printf.sprintf "%s test -w" dune in
    exit (Sys.command cmd)
  end;
  let build_code = Sys.command (dune ^ " build 2>&1") in
  if build_code <> 0 then begin
    Printf.eprintf "\027[31mBuild failed\027[0m\n";
    exit 1
  end;
  (* Find test executables *)
  let test_files = Well_test_runner.find_test_files () in
  let test_files = match filter with
    | None -> test_files
    | Some pattern ->
        let re = Str.regexp pattern in
        List.filter (fun f ->
          try let _ = Str.search_forward re f 0 in true
          with Not_found -> false
        ) test_files
  in
  if test_files = [] then begin
    Printf.printf "\027[33mNo test files found (*_test.ml)\027[0m\n";
    exit 0
  end;
  Printf.printf "\027[1mRunning %d test file(s)...\027[0m\n\n" (List.length test_files);
  let failed = Well_test_runner.run_parallel ~ci test_files in
  exit failed

let cmd : Command.t = {
  name = "test";
  summary = "Run tests";
  usage = "test [--watch] [--filter <pattern>] [--ci]";
  description =
    "Discover and run all *_test.ml test files.\n\
     \n\
     Options:\n\
     \  --watch, -w       Watch for changes and rerun\n\
     \  --filter, -f PAT  Only run tests matching pattern\n\
     \  --ci              CI-friendly output format";
  run;
}
