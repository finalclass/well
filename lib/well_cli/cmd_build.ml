(* cmd_build.ml — `well build` command *)

let release_dir = "_release"
let binary_path = "_build/default/bin/main.exe"

let read_dune_project () =
  if not (Sys.file_exists "dune-project") then (
    Printf.eprintf "Error: no dune-project found\n";
    exit 1);
  let ic = open_in "dune-project" in
  let content = really_input_string ic (in_channel_length ic) in
  close_in ic;
  content

let detect_name () =
  let content = read_dune_project () in
  (* Find top-level (package — at start of file or start of line,
     not inline like (pin ... (package (name well))) *)
  let rec find_package pos =
    let i = Str.search_forward (Str.regexp_string "(package") content pos in
    if i = 0 || content.[i - 1] = '\n' then i
    else find_package (i + 1)
  in
  try
    let pos = find_package 0 in
    ignore
      (Str.search_forward
         (Str.regexp {|(name \([a-z0-9_]+\))|})
         content pos);
    Str.matched_group 1 content
  with Not_found -> Filename.basename (Sys.getcwd ())

let detect_version () =
  let content = read_dune_project () in
  try
    ignore
      (Str.search_forward
         (Str.regexp {|(version \([^ )]+\))|})
         content 0);
    Some (Str.matched_group 1 content)
  with Not_found -> None

let has_tool name =
  Sys.command (Printf.sprintf "which %s >/dev/null 2>&1" name) = 0

let discover_libs binary =
  let ic =
    Unix.open_process_in
      (Printf.sprintf "ldd %s 2>/dev/null" (Filename.quote binary))
  in
  let libs = ref [] in
  (try
     while true do
       let line = String.trim (input_line ic) in
       if
         String.length line > 0
         && (not (String.starts_with ~prefix:"linux-vdso" line))
         && not (String.ends_with ~suffix:"not found" line)
       then begin
         let path =
           match
             (try
                Some
                  (Str.search_forward (Str.regexp_string "=> ") line 0 + 3)
              with Not_found -> None)
           with
           | Some pos ->
             let rest =
               String.trim
                 (String.sub line pos (String.length line - pos))
             in
             (match String.index_opt rest ' ' with
             | Some i -> String.sub rest 0 i
             | None -> rest)
           | None ->
             (match String.index_opt line ' ' with
             | Some i -> String.sub line 0 i
             | None -> line)
         in
         if
           String.length path > 0
           && path.[0] = '/'
           && Sys.file_exists path
         then libs := path :: !libs
       end
     done
   with End_of_file -> ());
  ignore (Unix.close_process_in ic);
  List.rev !libs

let get_interpreter binary =
  let ic =
    Unix.open_process_in
      (Printf.sprintf "patchelf --print-interpreter %s 2>/dev/null"
         (Filename.quote binary))
  in
  let result =
    try Some (String.trim (input_line ic)) with End_of_file -> None
  in
  ignore (Unix.close_process_in ic);
  result

let rec ensure_dir path =
  if path = "" || path = "." then ()
  else if Sys.file_exists path then (
    if not (Sys.is_directory path) then (
      Printf.eprintf "Error: %s exists and is not a directory\n" path;
      exit 1))
  else (
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o755)

let copy_file ~src ~dst =
  ensure_dir (Filename.dirname dst);
  let ic = open_in_bin src in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let oc = open_out_bin dst in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () ->
          let buffer = Bytes.create 65536 in
          let rec loop () =
            match input ic buffer 0 (Bytes.length buffer) with
            | 0 -> ()
            | n ->
                output oc buffer 0 n;
                loop ()
          in
          loop ()))

let copy_registry_specs ~src ~dst =
  if not (Sys.file_exists src) then false
  else (
    if Sys.file_exists dst then
      ignore
        (Sys.command
           (Printf.sprintf "rm -rf %s" (Filename.quote dst)));
    let copied = ref false in
    let rec walk rel =
      let dir = if rel = "" then src else Filename.concat src rel in
      Sys.readdir dir
      |> Array.iter (fun name ->
           let src_path = Filename.concat dir name in
           let rel_path =
             if rel = "" then name else Filename.concat rel name
           in
           match (Unix.lstat src_path).Unix.st_kind with
           | Unix.S_DIR -> walk rel_path
           | Unix.S_REG when String.ends_with ~suffix:".toml" name ->
               copy_file
                 ~src:src_path
                 ~dst:(Filename.concat dst rel_path);
               copied := true
           | _ -> ())
    in
    walk "";
    !copied)

let run _args =
  let name = detect_name () in
  let dune =
    if Sys.file_exists "./vendor/dune" then "./vendor/dune" else "dune"
  in
  (* 1. Build *)
  Printf.printf "Building %s...\n%!" name;
  let rc = Sys.command (Printf.sprintf "%s build" dune) in
  if rc <> 0 then (
    Printf.eprintf "\027[31mBuild failed\027[0m\n";
    exit 1);
  if not (Sys.file_exists binary_path) then (
    Printf.eprintf "Error: binary not found at %s\n" binary_path;
    exit 1);
  if not (has_tool "patchelf") then (
    Printf.eprintf
      "Error: patchelf not found\n\
       Install: pacman -S patchelf / apt install patchelf\n";
    exit 1);
  (* 2. Prepare release directory *)
  if Sys.file_exists release_dir then
    ignore
      (Sys.command
         (Printf.sprintf "rm -rf %s" (Filename.quote release_dir)));
  ignore
    (Sys.command
       (Printf.sprintf "mkdir -p %s/bin/lib" release_dir));
  (* 3. Copy binary *)
  let target = Printf.sprintf "%s/bin/%s" release_dir name in
  ignore
    (Sys.command
       (Printf.sprintf "cp %s %s && chmod 755 %s"
          (Filename.quote binary_path)
          (Filename.quote target)
          (Filename.quote target)));
  (* 4. Bundle shared libraries *)
  Printf.printf "Bundling libraries...\n%!";
  let libs = discover_libs binary_path in
  let lib_dir = release_dir ^ "/bin/lib" in
  List.iter
    (fun path ->
      ignore
        (Sys.command
           (Printf.sprintf "cp %s %s/" (Filename.quote path)
              (Filename.quote lib_dir))))
    libs;
  Printf.printf "  %d libraries bundled\n%!" (List.length libs);
  (* 5. Patchelf — relocatable interpreter + rpath *)
  Printf.printf "Patching binary...\n%!";
  let interp_name =
    match get_interpreter binary_path with
    | Some path -> Filename.basename path
    | None -> "ld-linux-x86-64.so.2"
  in
  let rc =
    Sys.command
      (Printf.sprintf
         "patchelf --set-interpreter bin/lib/%s --set-rpath '$ORIGIN/lib' %s"
         interp_name (Filename.quote target))
  in
  if rc <> 0 then
    Printf.eprintf "\027[33mWarning: patchelf failed (exit %d)\027[0m\n" rc;
  (* 6. Copy static assets *)
  if Sys.file_exists "static" then (
    Printf.printf "Copying static assets...\n%!";
    ignore
      (Sys.command
         (Printf.sprintf "cp -r static %s/" (Filename.quote release_dir))));
  (* 7. Copy framework-known runtime specs *)
  let has_registry_specs =
    copy_registry_specs ~src:"lib/registry" ~dst:(release_dir ^ "/lib/registry")
  in
  (* 8. Summary *)
  Printf.printf "\n\027[32mBuild ready: %s/\027[0m\n" release_dir;
  Printf.printf "  bin/%-14s relocatable binary\n" name;
  Printf.printf "  bin/lib/           bundled .so\n";
  if Sys.file_exists "static" then
    Printf.printf "  static/            assets\n";
  if has_registry_specs then
    Printf.printf "  lib/registry/      Registry Forms TOML specs\n";
  Printf.printf "\nRun: cd %s && ./bin/%s\n" release_dir name

let cmd : Command.t =
  {
    name = "build";
    summary = "Production build with bundled libraries";
    usage = "build";
    description =
      "Build a relocatable binary with bundled shared libraries.\n\
       Uses patchelf to make the binary portable across Linux x86_64.\n\n\
       Creates _release/ directory:\n\
      \  bin/<name>       Relocatable binary\n\
      \  bin/lib/         Bundled .so libraries\n\
      \  static/          Static assets (if present)\n\
      \  lib/registry/    Registry Forms TOML specs (if present)\n\n\
       Run: cd _release && ./bin/<name>\n\n\
       Note: data/ is NOT included — the server keeps its own databases.";
    run;
  }
