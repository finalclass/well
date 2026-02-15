(* well db — database commands *)

let connect_socket path =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_UNIX path);
  fd

let send_recv fd msg =
  let data = msg ^ "\n" in
  ignore (Unix.write_substring fd data 0 (String.length data));
  let buf = Bytes.create 65536 in
  let n = Unix.read fd buf 0 (Bytes.length buf) in
  let resp = Bytes.sub_string buf 0 n in
  String.trim resp

let diff_cmd () =
  let sock_path = "data/well.sock" in
  if not (Sys.file_exists sock_path) then begin
    Printf.eprintf "Error: %s not found — is the app running?\n%!" sock_path;
    exit 1
  end;
  let fd = connect_socket sock_path in
  let req = Yojson.Safe.to_string
    (`Assoc [("service", `String "_system");
             ("rpc", `String "db_diff");
             ("payload", `Null)]) in
  let resp = send_recv fd req in
  Unix.close fd;
  let json = Yojson.Safe.from_string resp in
  match json with
  | `Assoc l ->
      (match List.assoc_opt "result" l with
       | Some (`List []) ->
           Printf.printf "Schema is up to date — no changes needed.\n%!"
       | Some (`List entries) ->
           List.iter (fun entry ->
             match entry with
             | `Assoc e ->
                 let get k = match List.assoc_opt k e with
                   | Some (`String s) -> s | _ -> "?" in
                 (match get "type" with
                  | "create_table" ->
                      Printf.printf "+ CREATE TABLE %s\n%!" (get "table")
                  | "add_column" ->
                      Printf.printf "+ ALTER TABLE %s ADD COLUMN %s %s\n%!"
                        (get "table") (get "column") (get "sqlite_type")
                  | "extra_column" ->
                      Printf.printf "! %s.%s exists in db but not in code\n%!"
                        (get "table") (get "column")
                  | "type_mismatch" ->
                      Printf.printf "! %s.%s type mismatch: db=%s code=%s\n%!"
                        (get "table") (get "column") (get "db_type") (get "code_type")
                  | t -> Printf.printf "? %s\n%!" t)
             | _ -> ()
           ) entries
       | Some other ->
           Printf.printf "%s\n%!" (Yojson.Safe.pretty_to_string other)
       | None ->
           Printf.eprintf "Error: %s\n%!" resp)
  | _ -> Printf.eprintf "Error: %s\n%!" resp

let rollback_cmd args =
  let path = match args with
    | p :: _ -> p
    | [] -> "data/app.sqlite"
  in
  Well.Db.rollback path

let run args =
  match args with
  | ["diff"] -> diff_cmd ()
  | ["rollback"] -> rollback_cmd []
  | "rollback" :: rest -> rollback_cmd rest
  | _ ->
      Printf.eprintf "Usage: well db <subcommand>\n\n";
      Printf.eprintf "Subcommands:\n";
      Printf.eprintf "  diff       Show pending schema changes (requires running app)\n";
      Printf.eprintf "  rollback   Restore database from .bak file\n";
      exit 1

let cmd : Command.t = {
  name = "db";
  summary = "Database tools (diff, rollback)";
  usage = "db <subcommand>";
  description = "Manage database schema.\n\n\
    Subcommands:\n  \
    diff       Show pending schema changes (connects to running app via socket)\n  \
    rollback   Restore database from .bak backup file";
  run;
}
