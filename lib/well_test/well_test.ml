(* well_test — Jest-like testing framework for OCaml *)

(* === Types === *)

type test_result =
  | Pass
  | Fail of string
  | Skip of string

type test_case = {
  name : string;
  fn : unit -> unit;
  timeout_s : float option;
  mutable result : test_result option;
  mutable duration_ms : float;
}

type test_suite = {
  name : string;
  timeout_s : float option;
  mutable tests : test_case list;
  mutable before_each : (unit -> unit) option;
  mutable after_each : (unit -> unit) option;
  mutable before_all : (unit -> unit) option;
  mutable after_all : (unit -> unit) option;
}

let _default_timeout = ref 5.0

let default_timeout t = _default_timeout := t

exception Test_timeout of float

type test_state = {
  mutable suites : test_suite list;
  mutable current_suite : test_suite option;
  mutable current_test : test_case option;
  mutable snapshot_source_file : string option;
  mutable update_snapshots : bool;
  mutable snapshots : (string * string) list;
  mutable snapshots_used : (string * string) list;
  mutable snapshot_counter : int;
}

(* === Global state === *)

let state =
  {
    suites = [];
    current_suite = None;
    current_test = None;
    snapshot_source_file = None;
    update_snapshots = false;
    snapshots = [];
    snapshots_used = [];
    snapshot_counter = 0;
  }

(* === Terminal colors === *)

module Color = struct
  let green s = "\027[32m" ^ s ^ "\027[0m"
  let red s = "\027[31m" ^ s ^ "\027[0m"
  let yellow s = "\027[33m" ^ s ^ "\027[0m"
  let gray s = "\027[90m" ^ s ^ "\027[0m"
  let bold s = "\027[1m" ^ s ^ "\027[0m"
  let dim s = "\027[2m" ^ s ^ "\027[0m"
end

(* === Exceptions for assertions === *)

exception Assertion_failed of string

(* === Expect API === *)

type 'a expectation = { value : 'a; negated : bool }

let expect value = { value; negated = false }
let not_ exp = { exp with negated = true }

let fail_with exp message =
  let prefix = if exp.negated then "Expected NOT " else "Expected " in
  raise (Assertion_failed (prefix ^ message))

let to_equal_string expected exp =
  let equal = exp.value = expected in
  if (equal && exp.negated) || ((not equal) && not exp.negated) then
    fail_with exp (Printf.sprintf "\"%s\" to equal \"%s\"" exp.value expected)

let to_equal_int expected exp =
  let equal = exp.value = expected in
  if (equal && exp.negated) || ((not equal) && not exp.negated) then
    fail_with exp (Printf.sprintf "%d to equal %d" exp.value expected)

let to_equal_float ?(epsilon = 0.0001) expected exp =
  let equal = abs_float (exp.value -. expected) < epsilon in
  if (equal && exp.negated) || ((not equal) && not exp.negated) then
    fail_with exp (Printf.sprintf "%f to equal %f" exp.value expected)

let to_equal_bool expected exp =
  let equal = exp.value = expected in
  if (equal && exp.negated) || ((not equal) && not exp.negated) then
    fail_with exp (Printf.sprintf "%b to equal %b" exp.value expected)

let to_be_true exp =
  if (exp.value && exp.negated) || ((not exp.value) && not exp.negated) then
    fail_with exp "value to be true"

let to_be_false exp =
  if ((not exp.value) && exp.negated) || (exp.value && not exp.negated) then
    fail_with exp "value to be false"

let to_be_some exp =
  let is_some = match exp.value with Some _ -> true | None -> false in
  if (is_some && exp.negated) || ((not is_some) && not exp.negated) then
    fail_with exp "value to be Some"

let to_be_none exp =
  let is_none = match exp.value with None -> true | Some _ -> false in
  if (is_none && exp.negated) || ((not is_none) && not exp.negated) then
    fail_with exp "value to be None"

let to_be_greater_than threshold exp =
  let greater = exp.value > threshold in
  if (greater && exp.negated) || ((not greater) && not exp.negated) then
    fail_with exp
      (Printf.sprintf "%d to be greater than %d" exp.value threshold)

let to_be_less_than threshold exp =
  let less = exp.value < threshold in
  if (less && exp.negated) || ((not less) && not exp.negated) then
    fail_with exp (Printf.sprintf "%d to be less than %d" exp.value threshold)

let to_be_greater_than_float threshold exp =
  let greater = exp.value > threshold in
  if (greater && exp.negated) || ((not greater) && not exp.negated) then
    fail_with exp
      (Printf.sprintf "%f to be greater than %f" exp.value threshold)

let to_be_less_than_float threshold exp =
  let less = exp.value < threshold in
  if (less && exp.negated) || ((not less) && not exp.negated) then
    fail_with exp
      (Printf.sprintf "%f to be less than %f" exp.value threshold)

let to_contain substring exp =
  let len_sub = String.length substring in
  let len_s = String.length exp.value in
  let contains =
    if len_sub > len_s then false
    else
      let found = ref false in
      for i = 0 to len_s - len_sub do
        if String.sub exp.value i len_sub = substring then found := true
      done;
      !found
  in
  if (contains && exp.negated) || ((not contains) && not exp.negated) then
    fail_with exp
      (Printf.sprintf "\"%s\" to contain \"%s\"" exp.value substring)

let to_match pattern exp =
  let matches =
    try
      let _ = Str.search_forward (Str.regexp pattern) exp.value 0 in
      true
    with Not_found -> false
  in
  if (matches && exp.negated) || ((not matches) && not exp.negated) then
    fail_with exp (Printf.sprintf "\"%s\" to match /%s/" exp.value pattern)

let to_have_length expected_len exp =
  let actual_len = List.length exp.value in
  let equal = actual_len = expected_len in
  if (equal && exp.negated) || ((not equal) && not exp.negated) then
    fail_with exp
      (Printf.sprintf "list to have length %d but got %d" expected_len
         actual_len)

let to_raise exp =
  let raised =
    try
      let _ = exp.value () in
      false
    with _ -> true
  in
  if (raised && exp.negated) || ((not raised) && not exp.negated) then
    fail_with exp "function to raise an exception"

let to_raise_with expected_msg exp =
  let message =
    try
      let _ = exp.value () in
      None
    with
    | Failure msg -> Some msg
    | exn -> Some (Printexc.to_string exn)
  in
  match message with
  | None when not exp.negated ->
      fail_with exp "function to raise an exception"
  | Some msg when exp.negated ->
      fail_with exp
        (Printf.sprintf "function not to raise, but got: %s" msg)
  | Some msg when msg <> expected_msg && not exp.negated ->
      fail_with exp
        (Printf.sprintf "exception message \"%s\" to equal \"%s\"" msg
           expected_msg)
  | _ -> ()

(* === Snapshot testing === *)

let snapshot_path_of source_file =
  let dir = Filename.dirname source_file in
  let snap_dir = Filename.concat dir "__snapshots__" in
  let base = Filename.basename source_file in
  let snap_name =
    (try Filename.chop_extension base with Invalid_argument _ -> base)
    ^ ".snap"
  in
  Filename.concat snap_dir snap_name

let parse_snap_file path =
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    let buf = Buffer.create 4096 in
    let len = in_channel_length ic in
    Buffer.add_channel buf ic len;
    close_in ic;
    let content = Buffer.contents buf in
    let lines = String.split_on_char '\n' content in
    let rec parse acc current_key current_lines = function
      | [] ->
          let acc =
            match current_key with
            | Some key ->
                let body =
                  String.concat "\n" (List.rev current_lines)
                in
                (key, body) :: acc
            | None -> acc
          in
          List.rev acc
      | line :: rest -> (
          if String.length line > 2 && line.[0] = '[' then
            let key =
              String.sub line 1 (String.length line - 2)
            in
            let acc =
              match current_key with
              | Some prev_key ->
                  let body =
                    String.concat "\n" (List.rev current_lines)
                  in
                  (prev_key, body) :: acc
              | None -> acc
            in
            (* Expect <<< on next line *)
            match rest with
            | "<<<" :: rest2 -> parse acc (Some key) [] rest2
            | _ -> parse acc (Some key) [] rest
          else if line = ">>>" then
            let acc =
              match current_key with
              | Some key ->
                  let body =
                    String.concat "\n" (List.rev current_lines)
                  in
                  (key, body) :: acc
              | None -> acc
            in
            parse acc None [] rest
          else
            match current_key with
            | Some _ -> parse acc current_key (line :: current_lines) rest
            | None -> parse acc None current_lines rest)
    in
    parse [] None [] lines

let write_snap_file path entries =
  let dir = Filename.dirname path in
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
  let oc = open_out path in
  List.iter
    (fun (key, body) ->
      Printf.fprintf oc "[%s]\n<<<\n%s\n>>>\n\n" key body)
    entries;
  close_out oc

(* === Output buffer === *)

let _output_buf = Buffer.create 4096

let _bprintf fmt = Printf.bprintf _output_buf fmt
let _bprint_string s = Buffer.add_string _output_buf s
let _bprint_newline () = Buffer.add_char _output_buf '\n'

(* === Diff utility for failed assertions === *)

let show_diff expected actual =
  let expected_lines = String.split_on_char '\n' expected in
  let actual_lines = String.split_on_char '\n' actual in
  _bprint_string (Color.dim "Expected:");
  _bprint_newline ();
  List.iter
    (fun line -> _bprintf "  %s\n" (Color.green ("+ " ^ line)))
    expected_lines;
  _bprint_string (Color.dim "Actual:");
  _bprint_newline ();
  List.iter
    (fun line -> _bprintf "  %s\n" (Color.red ("- " ^ line)))
    actual_lines

let to_match_snapshot exp =
  let actual = exp.value in
  let suite_name =
    match state.current_suite with
    | Some s -> s.name
    | None -> "unknown"
  in
  let test_name =
    match state.current_test with
    | Some t -> t.name
    | None -> "unknown"
  in
  state.snapshot_counter <- state.snapshot_counter + 1;
  let key =
    if state.snapshot_counter = 1 then
      Printf.sprintf "%s > %s" suite_name test_name
    else
      Printf.sprintf "%s > %s #%d" suite_name test_name
        state.snapshot_counter
  in
  let existing =
    List.assoc_opt key state.snapshots
  in
  match existing with
  | None ->
      (* New snapshot — record it *)
      state.snapshots_used <- (key, actual) :: state.snapshots_used;
      _bprintf "    %s\n"
        (Color.yellow (Printf.sprintf "New snapshot: %s" key))
  | Some expected ->
      if actual = expected then
        state.snapshots_used <- (key, actual) :: state.snapshots_used
      else if state.update_snapshots then begin
        state.snapshots_used <- (key, actual) :: state.snapshots_used;
        _bprintf "    %s\n"
          (Color.yellow (Printf.sprintf "Updated snapshot: %s" key))
      end else begin
        state.snapshots_used <- (key, expected) :: state.snapshots_used;
        show_diff expected actual;
        raise
          (Assertion_failed
             (Printf.sprintf "Snapshot mismatch for \"%s\"" key))
      end

let describe ?timeout name fn =
  let suite =
    {
      name;
      timeout_s = timeout;
      tests = [];
      before_each = None;
      after_each = None;
      before_all = None;
      after_all = None;
    }
  in
  let prev_suite = state.current_suite in
  state.current_suite <- Some suite;
  fn ();
  state.current_suite <- prev_suite;
  state.suites <- suite :: state.suites

let it ?timeout name fn =
  match state.current_suite with
  | None -> failwith "it() must be called inside describe()"
  | Some suite ->
      let test = { name; fn; timeout_s = timeout; result = None; duration_ms = 0.0 } in
      suite.tests <- test :: suite.tests

let test = it

let before_each fn =
  match state.current_suite with
  | None -> failwith "before_each() must be called inside describe()"
  | Some suite -> suite.before_each <- Some fn

let after_each fn =
  match state.current_suite with
  | None -> failwith "after_each() must be called inside describe()"
  | Some suite -> suite.after_each <- Some fn

let before_all fn =
  match state.current_suite with
  | None -> failwith "before_all() must be called inside describe()"
  | Some suite -> suite.before_all <- Some fn

let after_all fn =
  match state.current_suite with
  | None -> failwith "after_all() must be called inside describe()"
  | Some suite -> suite.after_all <- Some fn

let skip name _fn =
  match state.current_suite with
  | None -> failwith "skip() must be called inside describe()"
  | Some suite ->
      let test =
        {
          name;
          fn = (fun () -> ());
          timeout_s = None;
          result = Some (Skip "Skipped");
          duration_ms = 0.0;
        }
      in
      suite.tests <- test :: suite.tests

(* === Runner === *)

let get_time_ms () = Unix.gettimeofday () *. 1000.0

let run_with_timeout timeout_s fn =
  let alarm_secs = max 1 (int_of_float (ceil timeout_s)) in
  let old_handler = Sys.signal Sys.sigalrm
    (Sys.Signal_handle (fun _ -> raise (Test_timeout timeout_s))) in
  ignore (Unix.alarm alarm_secs);
  (try
     fn ();
     ignore (Unix.alarm 0);
     Sys.set_signal Sys.sigalrm old_handler
   with exn ->
     ignore (Unix.alarm 0);
     Sys.set_signal Sys.sigalrm old_handler;
     raise exn)

let run_test suite test =
  state.current_test <- Some test;
  state.snapshot_counter <- 0;
  (match suite.before_each with Some fn -> fn () | None -> ());
  let timeout_s =
    match test.timeout_s with
    | Some t -> t
    | None ->
      match suite.timeout_s with
      | Some t -> t
      | None -> !_default_timeout
  in
  let start_time = get_time_ms () in
  (try
     run_with_timeout timeout_s test.fn;
     test.result <- Some Pass
   with
  | Assertion_failed msg -> test.result <- Some (Fail msg)
  | Test_timeout t ->
      test.result <-
        Some (Fail (Printf.sprintf "Timeout: test exceeded %.1fs limit" t))
  | exn ->
      test.result <-
        Some
          (Fail
             (Printf.sprintf "Unexpected exception: %s"
                (Printexc.to_string exn))));
  test.duration_ms <- get_time_ms () -. start_time;
  state.current_test <- None;
  (match suite.after_each with Some fn -> fn () | None -> ())

let run_suite ~(filter : string option) ~ci_mode (suite : test_suite) =
  (match suite.before_all with Some fn -> fn () | None -> ());
  let tests = List.rev suite.tests in
  let tests =
    match filter with
    | None -> tests
    | Some pattern ->
        let re = Str.regexp pattern in
        List.filter
          (fun (t : test_case) ->
            try
              let _ = Str.search_forward re t.name 0 in
              true
            with Not_found -> false)
          tests
  in
  if not ci_mode then begin _bprint_string (Color.bold suite.name); _bprint_newline () end;
  List.iter
    (fun test ->
      match test.result with
      | Some (Skip reason) ->
          if ci_mode then
            _bprintf "SKIP %s > %s (%s)\n" suite.name test.name reason
          else
            _bprintf "  %s %s %s\n" (Color.yellow "○")
              (Color.dim test.name)
              (Color.dim (Printf.sprintf "(%s)" reason))
      | _ -> (
          run_test suite test;
          match test.result with
          | Some Pass ->
              if ci_mode then
                _bprintf "PASS %s > %s (%.2fms)\n" suite.name test.name
                  test.duration_ms
              else
                _bprintf "  %s %s %s\n" (Color.green "✓") test.name
                  (Color.gray (Printf.sprintf "(%.2fms)" test.duration_ms))
          | Some (Fail msg) ->
              if ci_mode then
                _bprintf "FAIL %s > %s: %s\n" suite.name test.name msg
              else begin
                _bprintf "  %s %s\n" (Color.red "✗")
                  (Color.red test.name);
                _bprintf "    %s\n" (Color.dim msg)
              end
          | Some (Skip _) -> ()
          | None -> ()))
    tests;
  if not ci_mode then _bprint_newline ();
  (match suite.after_all with Some fn -> fn () | None -> ())

type run_result = {
  total : int;
  passed : int;
  failed : int;
  skipped : int;
  duration_ms : float;
}

let run ?(filter = None) ?ci_mode ?source_file () =
  let ci_mode =
    match ci_mode with
    | Some v -> v
    | None -> (
        match Sys.getenv_opt "CI" with
        | Some _ -> true
        | None -> false)
  in
  (* Snapshot setup *)
  state.update_snapshots <-
    (match Sys.getenv_opt "WELL_UPDATE_SNAPSHOTS" with
    | Some "1" -> true
    | _ -> false);
  state.snapshot_source_file <- source_file;
  (match source_file with
  | Some f ->
      let snap_path = snapshot_path_of f in
      state.snapshots <- parse_snap_file snap_path
  | None -> state.snapshots <- []);
  state.snapshots_used <- [];
  (* Capture stdout during test execution to prevent log interleaving *)
  let saved_stdout = Unix.dup Unix.stdout in
  let (pipe_r, pipe_w) = Unix.pipe () in
  Unix.dup2 pipe_w Unix.stdout;
  Unix.close pipe_w;
  let start_time = get_time_ms () in
  let suites = List.rev state.suites in
  List.iter (fun s -> run_suite ~filter ~ci_mode s) suites;
  let total = ref 0 in
  let passed = ref 0 in
  let failed = ref 0 in
  let skipped = ref 0 in
  List.iter
    (fun suite ->
      List.iter
        (fun test ->
          incr total;
          match test.result with
          | Some Pass -> incr passed
          | Some (Fail _) -> incr failed
          | Some (Skip _) -> incr skipped
          | None -> ())
        suite.tests)
    suites;
  let duration_ms = get_time_ms () -. start_time in
  (* Write snapshots if any were collected *)
  (match source_file with
  | Some f when state.snapshots_used <> [] ->
      let snap_path = snapshot_path_of f in
      write_snap_file snap_path (List.rev state.snapshots_used)
  | _ -> ());
  (* Summary *)
  if ci_mode then
    _bprintf "\n%d passed, %d failed, %d skipped (%.2fms)\n" !passed
      !failed !skipped duration_ms
  else begin
    _bprintf "Summary: %s passed, %s failed\n"
      (Color.green (string_of_int !passed))
      (if !failed > 0 then Color.red (string_of_int !failed)
       else string_of_int !failed);
    if !skipped > 0 then
      _bprintf "  %s %d skipped\n" (Color.yellow "○") !skipped;
  end;
  (* Restore stdout and collect captured output (e.g. Well.Log lines) *)
  flush stdout;
  Unix.dup2 saved_stdout Unix.stdout;
  Unix.close saved_stdout;
  let captured_ic = Unix.in_channel_of_descr pipe_r in
  let captured_buf = Buffer.create 1024 in
  (try while true do
    Buffer.add_char captured_buf (input_char captured_ic)
  done with End_of_file -> ());
  close_in captured_ic;
  let captured = Buffer.contents captured_buf in
  if captured <> "" then begin
    _bprint_string captured;
    if captured.[String.length captured - 1] <> '\n' then _bprint_newline ()
  end;
  (* Flush entire buffer atomically *)
  let binary_name = Filename.basename Sys.executable_name in
  let binary_name =
    try Filename.chop_extension binary_name
    with Invalid_argument _ -> binary_name
  in
  let header = Printf.sprintf "── %s (%.1fs) %s\n"
    binary_name (duration_ms /. 1000.0)
    (String.make (max 0 (60 - String.length binary_name - 12)) '-') in
  let output = header ^ Buffer.contents _output_buf in
  output_string stdout output;
  flush stdout;
  {
    total = !total;
    passed = !passed;
    failed = !failed;
    skipped = !skipped;
    duration_ms;
  }

let exit_with_result result =
  if result.failed > 0 then exit 1 else exit 0

(* === Reset state (for testing the test framework) === *)

let reset () =
  state.suites <- [];
  state.current_suite <- None;
  state.current_test <- None;
  state.snapshot_source_file <- None;
  state.update_snapshots <- false;
  state.snapshots <- [];
  state.snapshots_used <- [];
  state.snapshot_counter <- 0;
  Buffer.clear _output_buf
