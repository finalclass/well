(* Log — unified logging to stdout + file *)

let _file : out_channel option ref = ref None
let _enabled = ref true

let init () =
  if !_enabled && !_file = None then begin
    let oc = open_out_gen
      [Open_append; Open_creat; Open_wronly] 0o644 "well.log" in
    _file := Some oc
  end

let close () =
  match !_file with
  | Some oc -> close_out_noerr oc; _file := None
  | None -> ()

let timestamp () =
  let t = Unix.gettimeofday () in
  let tm = Unix.localtime t in
  let ms = int_of_float ((t -. floor t) *. 1000.0) in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d.%03d"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec ms

let write_line level msg =
  let line = Printf.sprintf "[well] %s [%s] %s" (timestamp ()) level msg in
  print_string line; print_char '\n'; flush stdout;
  match !_file with
  | Some oc ->
      output_string oc line;
      output_char oc '\n';
      flush oc
  | None -> ()

let log ?(level = "info") fmt =
  Printf.ksprintf (write_line level) fmt
