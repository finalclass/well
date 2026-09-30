open Well_test

let fail msg = raise (Assertion_failed msg)

let examples =
  let rec find = function
    | [] -> failwith "examples dir not found"
    | p :: rest -> if Sys.file_exists (Filename.concat p "Reports.cyrograf") then p else find rest
  in
  find [
    "lib/well/actor/examples";
    "../../lib/well/actor/examples";
    "../../../lib/well/actor/examples";
  ]

let fixture =
  let rec find = function
    | [] -> failwith "baseline fixture not found"
    | p :: rest -> if Sys.file_exists p then p else find rest
  in
  find [
    "test/contract_actor/fixtures/baseline_descriptor.json";
    "../../test/contract_actor/fixtures/baseline_descriptor.json";
    "../../../test/contract_actor/fixtures/baseline_descriptor.json";
  ]

let tmp_dir prefix =
  let p = Filename.temp_file prefix "" in
  Sys.remove p;
  Unix.mkdir p 0o700;
  p

let rec rm_rf p =
  if Sys.file_exists p then
    if Sys.is_directory p then begin
      Array.iter (fun n -> rm_rf (Filename.concat p n)) (Sys.readdir p);
      Unix.rmdir p
    end else Sys.remove p

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let contains s sub =
  let n = String.length sub in
  let rec go i =
    if i + n > String.length s then false
    else if String.sub s i n = sub then true
    else go (i + 1)
  in
  go 0

let build_examples out =
  match Well.Actor.Contract.build ~source_dir:examples ~output_dir:out with
  | Ok () -> ()
  | Error errs ->
    fail (List.map (fun (e : Well.Actor.error) -> e.message) errs |> String.concat "; ")

let () =
  Well_test.default_timeout 60.;
  describe "Contract Actor M10" (fun () ->
    it "descriptor and JCS/SHA-256 hashes match the preserved old generator" (fun () ->
      let out = tmp_dir "contract-actor-desc-" in
      Fun.protect ~finally:(fun () -> rm_rf out) (fun () ->
        build_examples out;
        let generated = read_file (Filename.concat out "descriptor.json") in
        let baseline = read_file fixture in
        expect generated |> to_equal_string baseline;
        let json = Yojson.Safe.from_string generated in
        match json with
        | `Assoc root ->
          expect
            (match List.assoc_opt "format" root with Some (`Int 1) -> true | _ -> false)
          |> to_be_true;
          let actor_names =
            match List.assoc_opt "actors" root with
            | Some (`Assoc pairs) -> List.map fst pairs
            | _ -> []
          in
          expect (List.length actor_names) |> to_equal_int 5;
          expect (List.mem "Reporter" actor_names) |> to_be_true;
          expect (List.mem "SummaryBuilder" actor_names) |> to_be_true
        | _ -> fail "descriptor object"));

    it "message library compiles without well.core while the adapter needs it" (fun () ->
      let out = tmp_dir "contract-actor-libs-" in
      Fun.protect ~finally:(fun () -> rm_rf out) (fun () ->
        build_examples out;
        let data = read_file (Filename.concat out "ocaml_data/dune") in
        expect (contains data "cyrograf") |> to_be_true;
        expect (contains data "yojson") |> to_be_true;
        expect (contains data "well") |> to_be_false;
        let adapter = read_file (Filename.concat out "ocaml/dune") in
        expect (contains adapter "actor_data") |> to_be_true;
        expect (contains adapter "well.core") |> to_be_true;
        expect (contains adapter "actor_contracts") |> to_be_true;
        expect (Sys.file_exists (Filename.concat out "ocaml_data/drut_runtime.ml"))
        |> to_be_true;
        expect (Sys.file_exists (Filename.concat out "ocaml/reporter.ml")) |> to_be_true));
  );
  run ~source_file:__FILE__ () |> exit_with_result