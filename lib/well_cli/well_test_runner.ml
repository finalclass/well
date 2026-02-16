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

let run_test_file ~ci ~update_snapshots ~coverage:_ test_file =
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

let run_parallel ~ci ~update_snapshots ~coverage test_files =
  let n = List.length test_files in
  if n = 0 then 0
  else if n = 1 then begin
    let (_file, code) = run_test_file ~ci ~update_snapshots ~coverage (List.hd test_files) in
    if code <> 0 then 1 else 0
  end else begin
    let pipes = Array.init n (fun _ -> Unix.pipe ()) in
    List.iteri (fun i test_file ->
      match Unix.fork () with
      | 0 ->
          Unix.close (fst pipes.(i));
          let code = snd (run_test_file ~ci ~update_snapshots ~coverage test_file) in
          let oc = Unix.out_channel_of_descr (snd pipes.(i)) in
          Printf.fprintf oc "%s\n%d\n" test_file code;
          close_out oc;
          exit 0
      | _pid ->
          Unix.close (snd pipes.(i))
    ) test_files;
    let results = Array.make n ("", 0) in
    for i = 0 to n - 1 do
      let ic = Unix.in_channel_of_descr (fst pipes.(i)) in
      (try
         let file = input_line ic in
         let code = int_of_string (input_line ic) in
         results.(i) <- (file, code)
       with End_of_file | Failure _ ->
         results.(i) <- ("unknown", 1));
      close_in ic;
      ignore (Unix.wait ())
    done;
    let failed_list = Array.to_list results
      |> List.filter (fun (_, code) -> code <> 0) in
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
  end
