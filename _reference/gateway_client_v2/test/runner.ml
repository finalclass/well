(* Test runner with autodiscovery, parallel execution, and watch mode *)

let find_test_files ?(dir=".") () =
  let rec walk acc path =
    if Sys.is_directory path then begin
      let entries = Sys.readdir path in
      Array.fold_left (fun acc entry ->
        let full_path = Filename.concat path entry in
        (* Skip hidden dirs and _build *)
        if String.length entry > 0 && entry.[0] = '.' then acc
        else if entry = "_build" || entry = "_opam" || entry = "node_modules" then acc
        else walk acc full_path
      ) acc entries
    end else begin
      (* Check if filename matches *_test.ml pattern *)
      let basename = Filename.basename path in
      if Str.string_match (Str.regexp ".*_test\\.ml$") basename 0 then
        path :: acc
      else
        acc
    end
  in
  walk [] dir

let get_test_executable test_file =
  (* Convert lib/foo_test.ml to _build/default/lib/foo_test.exe *)
  let without_ext = Filename.chop_extension test_file in
  "_build/default/" ^ without_ext ^ ".exe"

let run_test_file ?(ci_mode=false) test_file =
  let exe = get_test_executable test_file in
  let cmd = if ci_mode then exe ^ " --ci" else exe in
  let code = Sys.command cmd in
  (test_file, code)

let run_tests_sequential ?(ci_mode=false) test_files =
  List.map (run_test_file ~ci_mode) test_files

let run_tests_parallel ?(ci_mode=false) test_files =
  (* Simple parallel execution using Unix.fork *)
  let n = List.length test_files in
  if n = 0 then [] else
  let results = Array.make n ("", 0) in

  (* Create pipes for communication *)
  let pipes = Array.init n (fun _ -> Unix.pipe ()) in

  List.iteri (fun i test_file ->
    match Unix.fork () with
    | 0 ->
      (* Child process *)
      Unix.close (fst pipes.(i));
      let code = snd (run_test_file ~ci_mode test_file) in
      let oc = Unix.out_channel_of_descr (snd pipes.(i)) in
      Printf.fprintf oc "%s\n%d\n" test_file code;
      close_out oc;
      exit 0
    | _pid ->
      Unix.close (snd pipes.(i))
  ) test_files;

  (* Parent: collect results *)
  for i = 0 to n - 1 do
    let ic = Unix.in_channel_of_descr (fst pipes.(i)) in
    let file = input_line ic in
    let code = int_of_string (input_line ic) in
    close_in ic;
    results.(i) <- (file, code);
    (* Wait for child *)
    ignore (Unix.wait ())
  done;

  Array.to_list results

let print_summary results =
  let total = List.length results in
  let passed = List.filter (fun (_, code) -> code = 0) results |> List.length in
  let failed = total - passed in

  print_newline ();
  if failed = 0 then
    Printf.printf "\027[32m%d test file(s) passed\027[0m\n" passed
  else begin
    Printf.printf "\027[31m%d test file(s) failed:\027[0m\n" failed;
    List.iter (fun (file, code) ->
      if code <> 0 then
        Printf.printf "  \027[31m✗\027[0m %s (exit code %d)\n" file code
    ) results
  end;
  failed

let watch_mode ?(filter=None) ?(ci_mode=false) () =
  Printf.printf "\027[1mWatching for changes...\027[0m (Ctrl+C to stop)\n%!";
  let last_run = ref 0.0 in
  let debounce_ms = 500.0 in

  (* Initial run *)
  let test_files = find_test_files () in
  let test_files = match filter with
    | None -> test_files
    | Some pattern ->
      let re = Str.regexp pattern in
      List.filter (fun f ->
        try let _ = Str.search_forward re f 0 in true
        with Not_found -> false
      ) test_files
  in

  (* Build first *)
  ignore (Sys.command "dune build");
  let results = run_tests_parallel ~ci_mode test_files in
  ignore (print_summary results);

  (* Watch loop *)
  while true do
    Unix.sleepf 0.5;
    let current_time = Unix.gettimeofday () *. 1000.0 in

    (* Check for modified files *)
    let files = find_test_files () in
    let any_modified = List.exists (fun file ->
      let stat = Unix.stat file in
      stat.Unix.st_mtime *. 1000.0 > !last_run
    ) files in

    if any_modified && current_time -. !last_run > debounce_ms then begin
      last_run := current_time;
      print_endline "\n\027[2mRerunning tests...\027[0m";
      ignore (Sys.command "dune build");
      let test_files = find_test_files () in
      let test_files = match filter with
        | None -> test_files
        | Some pattern ->
          let re = Str.regexp pattern in
          List.filter (fun f ->
            try let _ = Str.search_forward re f 0 in true
            with Not_found -> false
          ) test_files
      in
      let results = run_tests_parallel ~ci_mode test_files in
      ignore (print_summary results)
    end
  done

let run ?(filter=None) ?(parallel=true) ?(ci_mode=false) ?(watch=false) () =
  if watch then
    (* watch_mode never returns - runs infinite loop *)
    (watch_mode ~filter ~ci_mode (); 0) [@warning "-21"]
  else begin
    (* Build first *)
    let build_code = Sys.command "dune build" in
    if build_code <> 0 then begin
      Printf.eprintf "\027[31mBuild failed\027[0m\n";
      1
    end else begin
      let test_files = find_test_files () in
      let test_files = match filter with
        | None -> test_files
        | Some pattern ->
          let re = Str.regexp pattern in
          List.filter (fun f ->
            try let _ = Str.search_forward re f 0 in true
            with Not_found -> false
          ) test_files
      in

      if List.length test_files = 0 then begin
        print_endline "\027[33mNo test files found (*_test.ml)\027[0m";
        0
      end else begin
        print_endline (Printf.sprintf "\027[1mRunning %d test file(s)...\027[0m\n" (List.length test_files));
        let results =
          if parallel then run_tests_parallel ~ci_mode test_files
          else run_tests_sequential ~ci_mode test_files
        in
        print_summary results
      end
    end
  end
