(* Cap_hook — Forward references and log store for Cap admin panel *)
(* Lives in well.core to avoid circular dependency with well_cap *)

(* ── Cap response type ────────────────────────────────────────────── *)

type cap_response =
  | CRHtml of string
  | CRRedirect of string
  | CRJs of string
  | CRJson of string
  | CRStatus of int * string

(* ── Forward refs (wired by well.ml before init) ─────────────────── *)

let _register_cap_get : (string -> (Types.request -> cap_response) -> unit) ref
    =
  ref (fun _ _ -> ())

let _register_cap_post : (string -> (Types.request -> cap_response) -> unit) ref
    =
  ref (fun _ _ -> ())

(* Cap init — filled by well_cap at module load time *)
let _cap_init : (unit -> unit) ref = ref (fun () -> ())

(* ── Start time (set by well_cap init) ──────────────────────────── *)

let start_time = ref 0.0

module Log_buffer = struct
  type entry =
    { id: int
    ; level: string
    ; message: string
    ; timestamp: float
    ; ctx: (string * string) list }

  let max_entries = 4096

  let max_bytes = 4 * 1024 * 1024

  let max_entry_bytes = 16 * 1024

  let max_level_bytes = 64

  let truncation_marker = "[truncated]"

  let marker_bytes = String.length truncation_marker

  let entries : entry option array = Array.make max_entries None

  let first = ref 0

  let retained = ref 0

  let retained_bytes = ref 0

  let retained_cost = ref 0

  let count = ref 0

  let mu = Mutex.create ()

  let with_lock f =
    Mutex.lock mu ;
    Fun.protect ~finally:(fun () -> Mutex.unlock mu) f

  let utf8_prefix_length text limit =
    let length = String.length text in
    let finish = ref (min length (max 0 limit)) in
    if !finish < length
    then
      while !finish > 0 && Char.code text.[!finish] land 0xc0 = 0x80 do
        decr finish
      done ;
    !finish

  let copy_prefix text limit = String.sub text 0 (utf8_prefix_length text limit)

  let bounded_text limit text =
    if String.length text <= limit
    then String.sub text 0 (String.length text)
    else copy_prefix text (limit - marker_bytes) ^ truncation_marker

  let entry_bytes entry =
    List.fold_left
      (fun total (key, value) -> total + String.length key + String.length value)
      (String.length entry.level + String.length entry.message)
      entry.ctx

  let entry_cost entry = entry_bytes entry + 64 + (48 * List.length entry.ctx)

  let copy_context budget ctx =
    let rec loop budget copied = function
      | [] -> (List.rev copied, false)
      | (key, value) :: rest ->
          let cost = String.length key + String.length value + 48 in
          if cost > budget
          then (List.rev copied, true)
          else
            let pair =
              ( String.sub key 0 (String.length key)
              , String.sub value 0 (String.length value) )
            in
            loop (budget - cost) (pair :: copied) rest
    in
    loop budget [] ctx

  let normalize level message ctx =
    let level = bounded_text max_level_bytes level in
    let reserve = if ctx = [] then 0 else marker_bytes in
    let message =
      bounded_text (max_entry_bytes - String.length level - reserve) message
    in
    let budget =
      max_entry_bytes - String.length level - String.length message - reserve
    in
    let ctx, omitted = copy_context budget ctx in
    let message = if omitted then message ^ truncation_marker else message in
    (level, message, ctx)

  let at index = Option.get entries.((!first + index) mod max_entries)

  let evict () =
    let entry = at 0 in
    retained_bytes := !retained_bytes - entry_bytes entry ;
    retained_cost := !retained_cost - entry_cost entry ;
    entries.(!first) <- None ;
    first := (!first + 1) mod max_entries ;
    decr retained

  let push ~level ~message ~timestamp ?(ctx = []) () =
    let level, message, ctx = normalize level message ctx in
    with_lock (fun () ->
        let entry = {id= !count; level; message; timestamp; ctx} in
        let bytes = entry_bytes entry and cost = entry_cost entry in
        while
          !retained > 0
          && ( !retained >= max_entries
             || !retained_bytes + bytes > max_bytes
             || !retained_cost + cost > max_bytes )
        do
          evict ()
        done ;
        entries.((!first + !retained) mod max_entries) <- Some entry ;
        incr retained ;
        incr count ;
        retained_bytes := !retained_bytes + bytes ;
        retained_cost := !retained_cost + cost ;
        entry )

  let stats () = with_lock (fun () -> (!retained, !retained_bytes))

  let range start finish =
    let result = ref [] in
    for index = finish - 1 downto start do
      result := at index :: !result
    done ;
    !result

  let recent n =
    with_lock (fun () -> range (max 0 (!retained - max 0 n)) !retained)

  let recent_filtered
      ~n
      ?(level = "all")
      ?(search = "")
      ?(since = 0.)
      ?(until = 0.)
      () =
    let pattern =
      if search = "" then None else Some (Str.regexp_string_case_fold search)
    in
    let matches entry =
      (level = "all" || entry.level = level)
      && (since <= 0. || entry.timestamp >= since)
      && (until <= 0. || entry.timestamp <= until)
      &&
      match pattern with
      | None -> true
      | Some pattern -> (
        try
          ignore (Str.search_forward pattern entry.message 0) ;
          true
        with
        | Not_found -> false )
    in
    with_lock (fun () ->
        let result = ref [] and found = ref 0 and index = ref (!retained - 1) in
        while !index >= 0 && !found < n do
          let entry = at !index in
          if matches entry
          then begin
            result := entry :: !result ;
            incr found
          end ;
          decr index
        done ;
        !result )

  let around ~target_ts ~n =
    let nearer candidate selected =
      if candidate <= target_ts && selected <= target_ts
      then candidate > selected
      else if candidate >= target_ts && selected >= target_ts
      then candidate < selected
      else abs_float (candidate -. target_ts) < abs_float (selected -. target_ts)
    in
    with_lock (fun () ->
        if !retained = 0 || n <= 0
        then ([], -1)
        else begin
          let nearest = ref 0 in
          for index = 1 to !retained - 1 do
            if nearer (at index).timestamp (at !nearest).timestamp
            then nearest := index
          done ;
          let start = max 0 (!nearest - (n / 2)) in
          (range start (start + min n (!retained - start)), (at !nearest).id)
        end )

  let before ~before_id ~n =
    with_lock (fun () ->
        let finish = ref !retained in
        while !finish > 0 && (at (!finish - 1)).id >= before_id do
          decr finish
        done ;
        range (max 0 (!finish - max 0 n)) !finish )

  let entry_to_json entry =
    Yojson.Safe.to_string
      (`Assoc
         [ ("id", `Int entry.id)
         ; ("level", `String entry.level)
         ; ("message", `String entry.message)
         ; ("timestamp", `Float entry.timestamp)
         ; ("ctx", `Assoc (List.map (fun (k, v) -> (k, `String v)) entry.ctx))
         ] )

  let parse_line line =
    try
      if not (String.starts_with ~prefix:"[well] " line)
      then None
      else
        let rest = String.sub line 7 (String.length line - 7) in
        let utc = rest.[19] = 'Z' in
        let ts_size = if utc then 24 else 23 in
        let ts = String.sub rest 0 ts_size in
        let after =
          String.sub rest (ts_size + 1) (String.length rest - ts_size - 1)
        in
        match String.index_opt after ']' with
        | Some finish when finish > 1 && after.[0] = '[' ->
            let level = String.sub after 1 (finish - 1) in
            let offset = min (String.length after) (finish + 2) in
            let message =
              String.sub after offset (String.length after - offset)
            in
            let convert y mo d h mi s ms =
              match Ptime.of_date_time ((y, mo, d), ((h, mi, s), 0)) with
              | None -> None
              | Some timestamp ->
                  Some
                    ( level
                    , message
                    , Ptime.to_float_s timestamp +. (float_of_int ms /. 1000.)
                    )
            in
            if utc
            then Scanf.sscanf ts "%d-%d-%d %d:%d:%dZ.%d" convert
            else Scanf.sscanf ts "%d-%d-%d %d:%d:%d.%d" convert
        | _ -> None
    with
    | Invalid_argument _
     |Scanf.Scan_failure _
     |Failure _
     |End_of_file ->
        None

  let read_bounded_line channel =
    let buffer = Buffer.create 256 in
    let limit = max_entry_bytes + 128 in
    let truncated = ref false in
    let in_level = ref false in
    let level_bytes = ref 0 in
    let keep character =
      if Buffer.length buffer < limit
      then Buffer.add_char buffer character
      else truncated := true
    in
    let append character =
      if !in_level
      then
        if character = ']'
        then begin
          in_level := false ;
          keep character
        end
        else if !level_bytes <= max_level_bytes
        then begin
          incr level_bytes ;
          keep character
        end
        else truncated := true
      else begin
        let length = Buffer.length buffer in
        if
          character = '['
          && (length = 31 || length = 32)
          && String.starts_with ~prefix:"[well] " (Buffer.contents buffer)
        then in_level := true ;
        keep character
      end
    in
    let rec loop () =
      match input_char channel with
      | '\n' -> Some (Buffer.contents buffer, !truncated)
      | character ->
          append character ;
          loop ()
      | exception End_of_file ->
          if Buffer.length buffer = 0
          then None
          else Some (Buffer.contents buffer, !truncated)
    in
    loop ()

  let load_from_file path =
    if Sys.file_exists path
    then begin
      let channel = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr channel)
        (fun () ->
          let rec loop () =
            match read_bounded_line channel with
            | None -> ()
            | Some (line, truncated) ->
                ( match parse_line line with
                | None -> ()
                | Some (level, message, timestamp) ->
                    let message =
                      if truncated
                      then
                        bounded_text (max_entry_bytes - max_level_bytes) message
                      else message
                    in
                    ignore (push ~level ~message ~timestamp ()) ) ;
                loop ()
          in
          loop () )
    end
end
