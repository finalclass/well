(** Log -- unified structured logging to stdout and file with automatic rotation. *)

let _file : out_channel option ref = ref None
let _enabled = ref true
let _buffer : Buffer.t option ref = ref None

(* Hook: called with (timestamp, level, message, ctx) on every log line *)
let _hook : (float -> string -> string -> (string * string) list -> unit) option ref = ref None

(* Rotation config *)
let _max_log_size = ref (10 * 1024 * 1024)  (* 10 MB *)
let _max_log_files = ref 5
let _lines_since_check = ref 0
let _check_interval = 100  (* check size every N lines *)
let _log_path = "well.log"

let rotate () =
  (match !_file with
   | Some oc -> close_out_noerr oc; _file := None
   | None -> ());
  (* Shift existing rotated files: .4->.5 (delete), .3->.4, .2->.3, .1->.2 *)
  for i = !_max_log_files - 1 downto 1 do
    let src = Printf.sprintf "%s.%d" _log_path i in
    let dst = Printf.sprintf "%s.%d" _log_path (i + 1) in
    if i + 1 >= !_max_log_files then
      (try Sys.remove dst with Sys_error _ -> ());
    (try Sys.rename src dst with Sys_error _ -> ())
  done;
  (* Rename current log to .1 *)
  (try Sys.rename _log_path (Printf.sprintf "%s.1" _log_path)
   with Sys_error _ -> ());
  (* Open fresh log file *)
  let oc = open_out_gen
    [Open_append; Open_creat; Open_wronly] 0o644 _log_path in
  _file := Some oc

let maybe_rotate () =
  incr _lines_since_check;
  if !_lines_since_check >= _check_interval then begin
    _lines_since_check := 0;
    try
      let st = Unix.stat _log_path in
      if st.Unix.st_size > !_max_log_size then rotate ()
    with Unix.Unix_error _ -> ()
  end

(** Initialize the log file (opens well.log for appending). *)
let init () =
  if !_enabled && !_file = None then begin
    let oc = open_out_gen
      [Open_append; Open_creat; Open_wronly] 0o644 _log_path in
    _file := Some oc
  end

(** Close the log file handle. *)
let close () =
  match !_file with
  | Some oc -> close_out_noerr oc; _file := None
  | None -> ()

let format_ts t =
  let tm = Unix.gmtime t in
  let ms = int_of_float ((t -. floor t) *. 1000.0) in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02dZ.%03d"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec ms

let write_line ?(ctx=[]) level msg =
  let t = Unix.gettimeofday () in
  let ctx_str =
    if ctx = [] then ""
    else " " ^ String.concat " " (List.map (fun (k, v) -> k ^ "=" ^ v) ctx)
  in
  let line = Printf.sprintf "[well] %s [%s]%s %s" (format_ts t) level ctx_str msg in
  (match !_buffer with
   | Some buf -> Buffer.add_string buf line; Buffer.add_char buf '\n'
   | None -> print_string line; print_char '\n'; flush stdout);
  (match !_file with
   | Some oc ->
       output_string oc line;
       output_char oc '\n';
       flush oc;
       maybe_rotate ()
   | None -> ());
  (match !_hook with
   | Some f -> (try f t level msg ctx with _ -> ())
   | None -> ())

(** Log a formatted message at the given level with optional key-value context. *)
let log ?(level = "info") ?(ctx=[]) fmt =
  Printf.ksprintf (write_line ~ctx level) fmt

(** Start buffering log output (used in tests to prevent interleaving). *)
let start_buffering () =
  _buffer := Some (Buffer.create 4096)

(** Flush the log buffer and return its contents as a string. *)
let flush_buffer () =
  match !_buffer with
  | Some buf ->
    let s = Buffer.contents buf in
    _buffer := None;
    s
  | None -> ""
