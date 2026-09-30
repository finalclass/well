(* W2 acceptance for build composition and publication semantics.

   Covers M01 (same schema/Drut layout for TOML and native sources) and M08
   (output ownership, foreign files, unsafe output path, previous result kept
   on a failed build). *)

let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then incr pass
  else begin incr fail; Printf.printf "FAIL %s\n" name end

let read path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun n -> rm_rf (Filename.concat path n));
      Unix.rmdir path
    end
    else Sys.remove path

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" then ()
  else if Sys.file_exists dir then ()
  else begin mkdir_p (Filename.dirname dir); (try Unix.mkdir dir 0o755 with _ -> ()) end

let write path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

let build source output =
  Well_cli.Contract_build.build ~source_dir:source ~output_dir:output ()

let error_codes = function
  | Ok _ -> []
  | Error errs -> List.map (fun (e : Well_cli.Contract_build.error) -> e.code) errs

let () =
  let root = if Array.length Sys.argv > 1 then Sys.argv.(1)
    else Filename.concat (Sys.getcwd ()) "test/contract_build" in
  let native = Filename.concat root "fixtures/native" in
  let toml = Filename.concat root "fixtures/toml" in
  let work = Filename.concat (Filename.get_temp_dir_name ()) "well-w2-publish" in
  rm_rf work;
  mkdir_p work;
  (* A. clean native build *)
  let out = Filename.concat work "out" in
  (match build native out with
   | Ok _ -> check "native build Ok" true
   | Error _ -> check "native build Ok" false);
  check "manifest written" (Sys.file_exists (Filename.concat out "manifest.json"));
  let schema_native = read (Filename.concat out "schema.json") in
  (* B. rebuild replaces a previous own result *)
  (match build native out with
   | Ok _ -> check "rebuild Ok" true
   | Error _ -> check "rebuild Ok" false);
  (* C. foreign directory without manifest blocks *)
  let foreign = Filename.concat work "foreign" in
  write (Filename.concat foreign "stray.txt") "keep me";
  check "foreign output blocked"
    (List.mem "foreign_output" (error_codes (build native foreign)));
  check "foreign file untouched"
    (Sys.file_exists (Filename.concat foreign "stray.txt"));
  (* D. output inside the source directory is rejected *)
  check "output in sources rejected"
    (List.mem "output_in_sources"
       (error_codes (build native (Filename.concat native "generated"))));
  (* E. TOML and native sources give the same schema layout (M01) *)
  let out_toml = Filename.concat work "out_toml" in
  (match build toml out_toml with
   | Ok _ -> check "toml build Ok" true
   | Error _ -> check "toml build Ok" false);
  check "TOML and native schemas identical (M01)"
    (schema_native = read (Filename.concat out_toml "schema.json"));
  (* F. a failed build leaves the previous result in place *)
  let bad_src = Filename.concat work "bad" in
  write (Filename.concat bad_src "Broken.cyrograf") "struct Broken { x: Int";
  let before = read (Filename.concat out "schema.json") in
  let _ = build bad_src out in
  check "previous result kept after failed build (M08)"
    (Sys.file_exists (Filename.concat out "manifest.json")
     && read (Filename.concat out "schema.json") = before);
  rm_rf work;
  Printf.printf "contract_build_test: %d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1