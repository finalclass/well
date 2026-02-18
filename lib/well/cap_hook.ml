(* Cap_hook — Forward references and log store for Cap admin panel *)
(* Lives in well.core to avoid circular dependency with well_cap *)

(* ── Cap response type ────────────────────────────────────────────── *)

type cap_response =
  | CRHtml of string
  | CRRedirect of string
  | CRJs of string
  | CRJson of string

(* ── Forward refs (wired by well.ml before init) ─────────────────── *)

let _register_cap_get :
  (string -> (Types.request -> cap_response) -> unit) ref =
  ref (fun _ _ -> ())

let _register_cap_post :
  (string -> (Types.request -> cap_response) -> unit) ref =
  ref (fun _ _ -> ())

(* Cap init — filled by well_cap at module load time *)
let _cap_init : (unit -> unit) ref = ref (fun () -> ())

(* ── Cap password ────────────────────────────────────────────────── *)

let cap_password = ref ""

(* ── Log store (growable array) ──────────────────────────────────── *)

module Log_buffer = struct
  type entry = {
    id : int;
    level : string;
    message : string;
    timestamp : float;
  }

  let _dummy = { id = 0; level = ""; message = ""; timestamp = 0.0 }
  let _arr = ref (Array.make 4096 _dummy)
  let count = ref 0
  let mu = Mutex.create ()

  let _ensure_capacity () =
    let len = Array.length !_arr in
    if !count >= len then begin
      let new_arr = Array.make (len * 2) _dummy in
      Array.blit !_arr 0 new_arr 0 !count;
      _arr := new_arr
    end

  let push ~level ~message ~timestamp =
    Mutex.lock mu;
    _ensure_capacity ();
    let id = !count in
    let entry = { id; level; message; timestamp } in
    (!_arr).(id) <- entry;
    incr count;
    Mutex.unlock mu;
    entry

  let recent n =
    Mutex.lock mu;
    let n = min n !count in
    let start = !count - n in
    let result = ref [] in
    for i = !count - 1 downto start do
      result := (!_arr).(i) :: !result
    done;
    Mutex.unlock mu;
    !result

  let before ~before_id ~n =
    Mutex.lock mu;
    let end_idx = min before_id !count in
    let start_idx = max 0 (end_idx - n) in
    let result = ref [] in
    for i = end_idx - 1 downto start_idx do
      result := (!_arr).(i) :: !result
    done;
    Mutex.unlock mu;
    !result

  let entry_to_json (e : entry) =
    Printf.sprintf
      {|{"id":%d,"level":"%s","message":"%s","timestamp":%f}|}
      e.id (String.escaped e.level) (String.escaped e.message) e.timestamp

  (* Parse a log line: [well] YYYY-MM-DD HH:MM:SS.mmm [LEVEL] MESSAGE *)
  let parse_line line =
    let len = String.length line in
    if len > 7 && String.sub line 0 7 = "[well] " then begin
      let rest = String.sub line 7 (len - 7) in
      if String.length rest >= 25 then begin
        let ts_str = String.sub rest 0 23 in
        let after_ts = String.sub rest 24 (String.length rest - 24) in
        match String.index_opt after_ts ']' with
        | Some i when i > 1 && after_ts.[0] = '[' ->
            let level = String.sub after_ts 1 (i - 1) in
            let msg =
              if String.length after_ts > i + 2 then
                String.sub after_ts (i + 2) (String.length after_ts - i - 2)
              else ""
            in
            (try
              Scanf.sscanf ts_str "%d-%d-%d %d:%d:%d.%d"
                (fun y mo d h mi s ms ->
                  let tm = { Unix.tm_sec = s; tm_min = mi; tm_hour = h;
                             tm_mday = d; tm_mon = mo - 1; tm_year = y - 1900;
                             tm_wday = 0; tm_yday = 0; tm_isdst = false } in
                  let (t, _) = Unix.mktime tm in
                  Some (level, msg, t +. (float_of_int ms /. 1000.0)))
            with _ -> None)
        | _ -> None
      end else None
    end else None

  let load_from_file path =
    if Sys.file_exists path then begin
      let ic = open_in path in
      Mutex.lock mu;
      (try while true do
        let line = input_line ic in
        match parse_line line with
        | Some (level, msg, ts) ->
            _ensure_capacity ();
            let id = !count in
            (!_arr).(id) <- { id; level; message = msg; timestamp = ts };
            incr count
        | None -> ()
      done with End_of_file -> ());
      Mutex.unlock mu;
      close_in_noerr ic
    end
end
