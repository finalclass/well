(* Meta-tests: testing the Well_test framework itself *)

(* We use a fresh Well_test state per suite via reset() and capture results *)

let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then incr pass
  else begin
    incr fail;
    Printf.eprintf "META-FAIL: %s\n%!" name
  end

let () =
  (* ── describe / it ─────────────────────────────────────────────── *)
  Well_test.reset ();
  Well_test.describe "Suite A" (fun () ->
    Well_test.it "passes" (fun () ->
      Well_test.expect 1 |> Well_test.to_equal_int 1
    );
    Well_test.it "also passes" (fun () ->
      Well_test.expect "hi" |> Well_test.to_equal_string "hi"
    );
  );
  let result = Well_test.run () in
  check "describe/it: total = 2" (result.total = 2);
  check "describe/it: passed = 2" (result.passed = 2);
  check "describe/it: failed = 0" (result.failed = 0);

  (* ── failing test ──────────────────────────────────────────────── *)
  Well_test.reset ();
  Well_test.describe "Failures" (fun () ->
    Well_test.it "will fail" (fun () ->
      Well_test.expect 1 |> Well_test.to_equal_int 2
    );
  );
  let result = Well_test.run () in
  check "failure: total = 1" (result.total = 1);
  check "failure: failed = 1" (result.failed = 1);

  (* ── skip ──────────────────────────────────────────────────────── *)
  Well_test.reset ();
  Well_test.describe "Skips" (fun () ->
    Well_test.skip "not ready" (fun () ->
      failwith "should not run"
    );
    Well_test.it "runs" (fun () ->
      Well_test.expect true |> Well_test.to_be_true
    );
  );
  let result = Well_test.run () in
  check "skip: total = 2" (result.total = 2);
  check "skip: skipped = 1" (result.skipped = 1);
  check "skip: passed = 1" (result.passed = 1);

  (* ── matchers ──────────────────────────────────────────────────── *)
  Well_test.reset ();
  Well_test.describe "Matchers" (fun () ->
    Well_test.it "to_equal_string" (fun () ->
      Well_test.expect "hello" |> Well_test.to_equal_string "hello"
    );
    Well_test.it "to_equal_int" (fun () ->
      Well_test.expect 42 |> Well_test.to_equal_int 42
    );
    Well_test.it "to_equal_float" (fun () ->
      Well_test.expect 3.14 |> Well_test.to_equal_float 3.14
    );
    Well_test.it "to_be_true" (fun () ->
      Well_test.expect true |> Well_test.to_be_true
    );
    Well_test.it "to_be_false" (fun () ->
      Well_test.expect false |> Well_test.to_be_false
    );
    Well_test.it "to_be_some" (fun () ->
      Well_test.expect (Some 1) |> Well_test.to_be_some
    );
    Well_test.it "to_be_none" (fun () ->
      Well_test.expect None |> Well_test.to_be_none
    );
    Well_test.it "to_be_greater_than" (fun () ->
      Well_test.expect 10 |> Well_test.to_be_greater_than 5
    );
    Well_test.it "to_be_less_than" (fun () ->
      Well_test.expect 3 |> Well_test.to_be_less_than 5
    );
    Well_test.it "to_contain" (fun () ->
      Well_test.expect "hello world" |> Well_test.to_contain "world"
    );
    Well_test.it "to_match" (fun () ->
      Well_test.expect "abc123" |> Well_test.to_match "[a-z]+[0-9]+"
    );
    Well_test.it "to_have_length" (fun () ->
      Well_test.expect [1; 2; 3] |> Well_test.to_have_length 3
    );
    Well_test.it "to_raise" (fun () ->
      Well_test.expect (fun () -> failwith "boom") |> Well_test.to_raise
    );
    Well_test.it "to_raise_with" (fun () ->
      Well_test.expect (fun () -> failwith "specific") |> Well_test.to_raise_with "specific"
    );
  );
  let result = Well_test.run () in
  check "matchers: all 14 pass" (result.passed = 14);
  check "matchers: 0 failed" (result.failed = 0);

  (* ── negation ──────────────────────────────────────────────────── *)
  Well_test.reset ();
  Well_test.describe "Negation" (fun () ->
    Well_test.it "not to_equal_int" (fun () ->
      Well_test.expect 1 |> Well_test.not_ |> Well_test.to_equal_int 2
    );
    Well_test.it "not to_be_true" (fun () ->
      Well_test.expect false |> Well_test.not_ |> Well_test.to_be_true
    );
    Well_test.it "not to_contain" (fun () ->
      Well_test.expect "hello" |> Well_test.not_ |> Well_test.to_contain "xyz"
    );
  );
  let result = Well_test.run () in
  check "negation: all 3 pass" (result.passed = 3);

  (* ── before_each / after_each ──────────────────────────────────── *)
  Well_test.reset ();
  let counter = ref 0 in
  Well_test.describe "Hooks" (fun () ->
    Well_test.before_each (fun () -> counter := !counter + 10);
    Well_test.after_each (fun () -> counter := !counter - 1);
    Well_test.it "first" (fun () ->
      (* before_each ran: counter should be 10 *)
      Well_test.expect !counter |> Well_test.to_equal_int 10
    );
    (* after_each ran: counter = 9 *)
    Well_test.it "second" (fun () ->
      (* before_each ran again: counter = 9 + 10 = 19 *)
      Well_test.expect !counter |> Well_test.to_equal_int 19
    );
  );
  let result = Well_test.run () in
  check "hooks: 2 passed" (result.passed = 2);
  check "hooks: counter correct" (!counter = 18); (* after_each ran after second: 19-1=18 *)

  (* ── nested describe ───────────────────────────────────────────── *)
  Well_test.reset ();
  Well_test.describe "Outer" (fun () ->
    Well_test.describe "Inner" (fun () ->
      Well_test.it "nested test" (fun () ->
        Well_test.expect true |> Well_test.to_be_true
      );
    );
    Well_test.it "outer test" (fun () ->
      Well_test.expect true |> Well_test.to_be_true
    );
  );
  let result = Well_test.run () in
  check "nested: total = 2" (result.total = 2);
  check "nested: passed = 2" (result.passed = 2);

  (* ── run_result fields ─────────────────────────────────────────── *)
  Well_test.reset ();
  Well_test.describe "Timing" (fun () ->
    Well_test.it "fast" (fun () ->
      Well_test.expect true |> Well_test.to_be_true
    );
  );
  let result = Well_test.run () in
  check "timing: duration >= 0" (result.duration_ms >= 0.0);

  (* ── Summary ───────────────────────────────────────────────────── *)
  Printf.printf "\nWell_test meta-tests: %d passed, %d failed\n%!" !pass !fail;
  if !fail > 0 then exit 1
