(* well_test_runner — Autodiscovery and parallel test execution *)

let find_test_files ?(dir = ".") () =
  let rec walk acc path =
    if Sys.is_directory path then begin
      let entries = Sys.readdir path in
      Array.fold_left (fun acc entry ->
        let full_path = Filename.concat path entry in
        if String.length entry > 0 && entry.[0] = '.' then acc
        else if entry = "_build" || entry = "_opam" || entry = "node_modules"
                || entry = "vendor" || entry = "_reference" then acc
        else walk acc full_path
      ) acc entries
    end else begin
      let basename = Filename.basename path in
      if Str.string_match (Str.regexp ".*_test\\.ml$") basename 0 then
        path :: acc
      else
        acc
    end
  in
  List.sort String.compare (walk [] dir)

let get_test_executable test_file =
  let without_ext = Filename.chop_extension test_file in
  "_build/default/" ^ without_ext ^ ".exe"

let run_test_file ~ci ~update_snapshots test_file =
  let exe = get_test_executable test_file in
  if not (Sys.file_exists exe) then begin
    Printf.eprintf "\027[33m  ○ %s (no executable — add (test ...) to dune)\027[0m\n" test_file;
    (test_file, 0)
  end else begin
    let env_prefix =
      if update_snapshots then "WELL_UPDATE_SNAPSHOTS=1 "
      else ""
    in
    let ci_flag = if ci then " --ci" else "" in
    let cmd = Printf.sprintf "%s%s%s" env_prefix exe ci_flag in
    let code = Sys.command cmd in
    (test_file, code)
  end

let print_results results =
  let n = List.length results in
  let failed_list =
    results |> List.filter (fun (_, code) -> code <> 0)
  in
  let failed = List.length failed_list in
  let passed = n - failed in
  print_newline ();
  if failed = 0 then
    Printf.printf "\027[32m✓ %d test file(s) passed\027[0m\n" passed
  else begin
    Printf.printf "\027[31m✗ %d of %d test file(s) failed:\027[0m\n" failed n;
    List.iter (fun (file, code) ->
      Printf.printf "  \027[31m✗\027[0m %s (exit %d)\n" file code
    ) failed_list
  end;
  failed

let read_result ic =
  try
    let file = input_line ic in
    let code = int_of_string (input_line ic) in
    (file, code)
  with End_of_file | Failure _ ->
    ("unknown", 1)

let spawn_test ~ci ~update_snapshots index test_file =
  let read_fd, write_fd = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
      Unix.close read_fd;
      let code = snd (run_test_file ~ci ~update_snapshots test_file) in
      let oc = Unix.out_channel_of_descr write_fd in
      Printf.fprintf oc "%s\n%d\n" test_file code;
      close_out oc;
      exit 0
  | pid ->
      Unix.close write_fd;
      let ic = Unix.in_channel_of_descr read_fd in
      (pid, index, ic)

let run_parallel ~ci ~update_snapshots ~jobs test_files =
  let n = List.length test_files in
  if n = 0 then 0
  else if jobs <= 1 then begin
    List.map (run_test_file ~ci ~update_snapshots) test_files
    |> print_results
  end else begin
    let max_jobs = min jobs n in
    let results = Array.make n ("", 0) in
    let files = Array.of_list test_files in
    let running = ref [] in
    let next = ref 0 in
    let spawn_next () =
      if !next < n then begin
        let index = !next in
        incr next;
        running := spawn_test ~ci ~update_snapshots index files.(index) :: !running
      end
    in
    for _ = 1 to max_jobs do
      spawn_next ()
    done;
    while !running <> [] do
      let pid, _status = Unix.wait () in
      match List.partition (fun (p, _, _) -> p = pid) !running with
      | [(_, index, ic)], rest ->
          results.(index) <- read_result ic;
          close_in ic;
          running := rest;
          spawn_next ()
      | _ ->
          ()
    done;
    Array.to_list results |> print_results
  end
