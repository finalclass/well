let copy src dst =
  let ic = open_in_bin src in
  let oc = open_out_bin dst in
  let rec loop () =
    let buf = Bytes.create 4096 in
    let n = input ic buf 0 4096 in
    if n = 0 then () else (output oc buf 0 n; loop ())
  in
  loop ();
  close_in ic;
  close_out oc

let rec rm_rf p =
  if Sys.file_exists p then
    if Sys.is_directory p then begin
      Array.iter (fun n -> rm_rf (Filename.concat p n)) (Sys.readdir p);
      Unix.rmdir p
    end else Sys.remove p

let () =
  let src = Sys.argv.(1) in
  let dest = Sys.argv.(2) in
  let out = Filename.concat dest "actor_gen_out" in
  rm_rf out;
  match Well.Actor.Contract.build ~source_dir:src ~output_dir:out with
  | Error errs ->
    List.iter (fun (e : Well.Actor.error) ->
      Printf.eprintf "%s: %s\n" e.code e.message) errs;
    exit 1
  | Ok () ->
    let ocaml = Filename.concat out "ocaml" in
    Array.iter (fun name ->
      if Filename.check_suffix name ".ml" || Filename.check_suffix name ".mli" then
        copy (Filename.concat ocaml name) (Filename.concat dest name)
    ) (Sys.readdir ocaml)
