(* well_test — Jest-like testing framework for OCaml *)

(* === Types === *)

type test_result =
  | Pass
  | Fail of string
  | Skip of string

type test_case = {
  name : string;
  fn : unit -> unit;
  mutable result : test_result option;
  mutable duration_ms : float;
}

type test_suite = {
  name : string;
  mutable tests : test_case list;
  mutable before_each : (unit -> unit) option;
  mutable after_each : (unit -> unit) option;
  mutable before_all : (unit -> unit) option;
  mutable after_all : (unit -> unit) option;
}

type test_state = {
  mutable suites : test_suite list;
  mutable current_suite : test_suite option;
}

(* === Global state === *)

let state = { suites = []; current_suite = None }

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

(* === Describe / It API === *)

let describe name fn =
  let suite =
    {
      name;
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

let it name fn =
  match state.current_suite with
  | None -> failwith "it() must be called inside describe()"
  | Some suite ->
      let test = { name; fn; result = None; duration_ms = 0.0 } in
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
          result = Some (Skip "Skipped");
          duration_ms = 0.0;
        }
      in
      suite.tests <- test :: suite.tests

(* === Runner === *)

let get_time_ms () = Unix.gettimeofday () *. 1000.0

let run_test suite test =
  (match suite.before_each with Some fn -> fn () | None -> ());
  let start_time = get_time_ms () in
  (try
     test.fn ();
     test.result <- Some Pass
   with
  | Assertion_failed msg -> test.result <- Some (Fail msg)
  | exn ->
      test.result <-
        Some
          (Fail
             (Printf.sprintf "Unexpected exception: %s"
                (Printexc.to_string exn))));
  test.duration_ms <- get_time_ms () -. start_time;
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
  if not ci_mode then print_endline (Color.bold suite.name);
  List.iter
    (fun test ->
      match test.result with
      | Some (Skip reason) ->
          if ci_mode then
            Printf.printf "SKIP %s > %s (%s)\n" suite.name test.name reason
          else
            Printf.printf "  %s %s %s\n" (Color.yellow "○")
              (Color.dim test.name)
              (Color.dim (Printf.sprintf "(%s)" reason))
      | _ -> (
          run_test suite test;
          match test.result with
          | Some Pass ->
              if ci_mode then
                Printf.printf "PASS %s > %s (%.2fms)\n" suite.name test.name
                  test.duration_ms
              else
                Printf.printf "  %s %s %s\n" (Color.green "✓") test.name
                  (Color.gray (Printf.sprintf "(%.2fms)" test.duration_ms))
          | Some (Fail msg) ->
              if ci_mode then
                Printf.printf "FAIL %s > %s: %s\n" suite.name test.name msg
              else begin
                Printf.printf "  %s %s\n" (Color.red "✗")
                  (Color.red test.name);
                Printf.printf "    %s\n" (Color.dim msg)
              end
          | Some (Skip _) -> ()
          | None -> ()))
    tests;
  if not ci_mode then print_newline ();
  (match suite.after_all with Some fn -> fn () | None -> ())

type run_result = {
  total : int;
  passed : int;
  failed : int;
  skipped : int;
  duration_ms : float;
}

let run ?(filter = None) ?ci_mode () =
  let ci_mode =
    match ci_mode with
    | Some v -> v
    | None -> (
        match Sys.getenv_opt "CI" with
        | Some _ -> true
        | None -> false)
  in
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
  if ci_mode then
    Printf.printf "\n%d passed, %d failed, %d skipped (%.2fms)\n" !passed
      !failed !skipped duration_ms
  else begin
    print_endline (Color.bold "Summary:");
    if !passed > 0 then
      Printf.printf "  %s %d passed\n" (Color.green "✓") !passed;
    if !failed > 0 then
      Printf.printf "  %s %d failed\n" (Color.red "✗") !failed;
    if !skipped > 0 then
      Printf.printf "  %s %d skipped\n" (Color.yellow "○") !skipped;
    Printf.printf "  %s\n"
      (Color.gray
         (Printf.sprintf "Total: %d tests in %.2fms" !total duration_ms))
  end;
  {
    total = !total;
    passed = !passed;
    failed = !failed;
    skipped = !skipped;
    duration_ms;
  }

let exit_with_result result =
  if result.failed > 0 then exit 1 else exit 0

(* === Diff utility for failed assertions === *)

let show_diff expected actual =
  let expected_lines = String.split_on_char '\n' expected in
  let actual_lines = String.split_on_char '\n' actual in
  print_endline (Color.dim "Expected:");
  List.iter
    (fun line -> Printf.printf "  %s\n" (Color.green ("+ " ^ line)))
    expected_lines;
  print_endline (Color.dim "Actual:");
  List.iter
    (fun line -> Printf.printf "  %s\n" (Color.red ("- " ^ line)))
    actual_lines

(* === Reset state (for testing the test framework) === *)

let reset () =
  state.suites <- [];
  state.current_suite <- None
