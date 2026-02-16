let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then incr pass
  else begin
    incr fail;
    Printf.eprintf "FAIL: %s\n%!" name
  end

let () =
  let open Well.Form in

  (* ── get ────────────────────────────────────────────────────────── *)
  let data = [("title", "hello"); ("body", "world"); ("age", "42")] in

  let t = get data "title" in
  check "get existing field" (t.value = Some "hello");

  let t = get data "missing" in
  check "get missing field returns empty string" (t.value = Some "");

  (* ── required ───────────────────────────────────────────────────── *)
  let t = get data "title" |> required in
  check "required passes on non-empty" (t.value = Some "hello");
  check "required passes — no errors" (t.errors = []);

  let t = get data "missing" |> required in
  check "required fails on empty" (t.value = None);
  check "required error field" (List.assoc "missing" t.errors = "required");

  (* ── trim ───────────────────────────────────────────────────────── *)
  let data2 = [("name", "  bob  ")] in
  let t = get data2 "name" |> trim in
  check "trim removes whitespace" (t.value = Some "bob");

  let t = get data2 "name" |> trim |> required in
  check "trim then required — passes" (t.value = Some "bob");

  (* ── min_length ─────────────────────────────────────────────────── *)
  let t = get data "title" |> min_length 3 in
  check "min_length passes" (t.value = Some "hello");

  let t = get data "title" |> min_length 10 in
  check "min_length fails" (t.value = None);
  check "min_length error" (List.assoc "title" t.errors = "min 10 characters");

  (* ── max_length ─────────────────────────────────────────────────── *)
  let t = get data "title" |> max_length 10 in
  check "max_length passes" (t.value = Some "hello");

  let t = get data "title" |> max_length 3 in
  check "max_length fails" (t.value = None);
  check "max_length error" (List.assoc "title" t.errors = "max 3 characters");

  (* ── format_ ────────────────────────────────────────────────────── *)
  let email_data = [("email", "a@b.com")] in
  let t = get email_data "email" |> format_ ".*@.*\\..*" in
  check "format_ passes" (t.value = Some "a@b.com");

  let t = get data "title" |> format_ "[0-9]+" in
  check "format_ fails" (t.value = None);
  check "format_ error" (List.assoc "title" t.errors = "invalid format");

  (* ── number ─────────────────────────────────────────────────────── *)
  let t = get data "age" |> number in
  check "number parses int" (t.value = Some 42);

  let t = get data "title" |> number in
  check "number fails on non-numeric" (t.value = None);
  check "number error" (List.assoc "title" t.errors = "must be a number");

  (* ── decimal ────────────────────────────────────────────────────── *)
  let data3 = [("price", "9.99")] in
  let t = get data3 "price" |> decimal in
  check "decimal parses float" (t.value = Some 9.99);

  let t = get data "title" |> decimal in
  check "decimal fails on non-numeric" (t.value = None);

  (* ── custom ─────────────────────────────────────────────────────── *)
  let t = get data "title" |> custom (fun v ->
    if String.length v > 2 then None else Some "too short") in
  check "custom passes" (t.value = Some "hello");

  let t = get data "title" |> custom (fun _ -> Some "nope") in
  check "custom fails" (t.value = None);
  check "custom error" (List.assoc "title" t.errors = "nope");

  (* ── pipeline short-circuits ────────────────────────────────────── *)
  let t = get data "missing" |> required |> min_length 3 |> max_length 100 in
  check "short-circuit: only first error" (List.length t.errors = 1);
  check "short-circuit: required error" (List.assoc "missing" t.errors = "required");

  (* ── let+ / and+ ───────────────────────────────────────────────── *)
  let result =
    (let+ title = get data "title" |> required |> max_length 100
     and+ body  = get data "body"  |> required in
     (title, body))
    |> validate
  in
  check "let+/and+ Ok" (result = Ok ("hello", "world"));

  let bad_data = [("title", ""); ("body", "")] in
  let result =
    (let+ title = get bad_data "title" |> required
     and+ body  = get bad_data "body"  |> required in
     (title, body))
    |> validate
  in
  (match result with
   | Error errors ->
       check "let+/and+ collects all errors" (List.length errors = 2);
       check "let+/and+ has title error" (List.mem ("title", "required") errors);
       check "let+/and+ has body error" (List.mem ("body", "required") errors)
   | Ok _ ->
       check "let+/and+ should be Error" false);

  (* ── mixed types with number ────────────────────────────────────── *)
  let result =
    (let+ title = get data "title" |> required
     and+ age   = get data "age"   |> number in
     (title, age))
    |> validate
  in
  check "mixed types Ok" (result = Ok ("hello", 42));

  (* ── Summary ────────────────────────────────────────────────────── *)
  Printf.printf "Form tests: %d passed, %d failed\n%!" !pass !fail;
  if !fail > 0 then exit 1
