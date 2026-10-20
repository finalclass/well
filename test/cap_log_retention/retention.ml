module B = Well.Cap_hook.Log_buffer

let report = Unix.out_channel_of_descr (Unix.dup Unix.stdout)

let assertions = ref 0

let check name condition =
  incr assertions ;
  if not condition then failwith name

let json value =
  output_string report (Yojson.Safe.to_string value) ;
  output_char report '\n' ;
  flush report

let contains text pattern =
  try
    ignore (Str.search_forward (Str.regexp_string pattern) text 0) ;
    true
  with
  | Not_found -> false

let push ?(level = "info") ?(ctx = []) message =
  B.push ~level ~message ~timestamp:(Unix.gettimeofday ()) ~ctx ()

let check_limits () =
  let count, bytes = B.stats () in
  check "entry limit" (count <= 4096) ;
  check "byte limit" (bytes <= 4 * 1024 * 1024)

let ordered entries =
  let rec loop = function
    | []
     |[_] ->
        true
    | (a : B.entry) :: ((b : B.entry) :: _ as rest) -> a.id < b.id && loop rest
  in
  loop entries

let check_utf8 text =
  let rec loop index =
    if index = String.length text
    then true
    else
      let decoded = String.get_utf_8_uchar text index in
      Uchar.utf_decode_is_valid decoded
      && loop (index + Uchar.utf_decode_length decoded)
  in
  check "valid UTF-8" (loop 0)

let import_file write check_file =
  let path = Filename.temp_file "well-retention-" ".log" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
      let channel = open_out_bin path in
      Fun.protect
        ~finally:(fun () -> close_out channel)
        (fun () -> write channel) ;
      check_file path )

let line message = "[well] 2026-10-20 08:00:00Z.000 [info] " ^ message ^ "\n"

let functional () =
  check "initially empty" (B.recent 200 = []) ;
  check "empty nearest" (B.around ~target_ts:0. ~n:200 = ([], -1)) ;
  let first = push "first" in
  let last = ref first in
  for i = 1 to 12500 do
    last :=
      B.push
        ~level:(if i mod 2 = 0 then "warn" else "info")
        ~message:(Printf.sprintf "retained %d" i)
        ~timestamp:(float_of_int i)
        ()
  done ;
  let entries = B.recent max_int in
  check "count saturation" (List.length entries = 4096) ;
  check "newest suffix" ((List.hd entries).id = !last.id - 4095) ;
  check "old page empty" (B.before ~before_id:first.id ~n:200 = []) ;
  check "evicted search empty" (B.recent_filtered ~n:200 ~search:"first" () = []) ;
  check "negative recent" (B.recent (-1) = []) ;
  check "zero around" (B.around ~target_ts:0. ~n:0 = ([], -1)) ;
  check "chronological IDs" (ordered entries) ;
  let _, old_id = B.around ~target_ts:(-1.) ~n:10 in
  let _, new_id = B.around ~target_ts:max_float ~n:10 in
  check "clamp old time" (old_id = (List.hd entries).id) ;
  check "clamp new time" (new_id = !last.id) ;
  let filtered =
    B.recent_filtered
      ~n:200
      ~level:"warn"
      ~search:"RETAINED"
      ~since:12000.
      ~until:12400.
      ()
  in
  check "filters nonempty" (filtered <> []) ;
  check
    "combined filters"
    (List.for_all
       (fun (e : B.entry) ->
         e.level = "warn" && e.timestamp >= 12000. && e.timestamp <= 12400. )
       filtered ) ;
  let page = B.before ~before_id:!last.id ~n:200 in
  check
    "pagination excludes cursor"
    (List.length page = 200 && (List.hd (List.rev page)).id = !last.id - 1) ;
  for _ = 1 to 400 do
    ignore (push (String.make 16300 'b'))
  done ;
  check_limits () ;
  check "byte saturation before entry limit" (fst (B.stats ()) < 4096) ;
  let utf8 = String.concat "" (List.init 10000 (fun _ -> "Zażółć")) in
  let entry = push ~level:(String.make 1000 'l') ~ctx:[("one", "two")] utf8 in
  check "level bounded" (String.length entry.level <= 64) ;
  check "entry bounded" (B.entry_bytes entry <= 16384) ;
  check "truncation visible" (contains entry.message "[truncated]") ;
  check_utf8 entry.message ;
  let entry =
    push
      ~ctx:[("ok", "yes"); ("too-big", String.make 100000 'v'); ("later", "no")]
      "priority"
  in
  check "context prefix only" (entry.ctx = [("ok", "yes")]) ;
  check "omitted context marked" (contains entry.message "[truncated]") ;
  let entry = push ~ctx:[(String.make 100000 'k', "value")] "key" in
  check
    "large key bounded"
    (entry.ctx = [] && contains entry.message "[truncated]") ;
  let entry =
    push ~ctx:(List.init 100000 (fun _ -> ("", ""))) "empty context"
  in
  check "empty pairs bounded" (List.length entry.ctx < 1000) ;
  check "empty pairs marked" (contains entry.message "[truncated]") ;
  let weak = Weak.create 1 in
  let () =
    let original = String.make (1024 * 1024) 'x' in
    Weak.set weak 0 (Some original) ;
    ignore (push original)
  in
  Gc.full_major () ;
  check "large original released" (not (Weak.check weak 0)) ;
  import_file
    (fun channel ->
      for i = 1 to 20000 do
        output_string channel (line (Printf.sprintf "import %d" i))
      done ;
      output_string channel "invalid line\n" ;
      output_string channel "[well] 2026-10-20 08:00:00Z.000 [warn] " ;
      let chunk = String.make 16384 'x' in
      for _ = 1 to 2048 do
        output_string channel chunk
      done ;
      output_string channel "\n" ;
      output_string channel (line "after malformed and huge line") ;
      output_string
        channel
        ( "[well] 2026-10-20 08:00:00Z.000 ["
        ^ String.make 100000 'l'
        ^ "] huge-level-msg\n" ) ;
      output_string
        channel
        "[well] 2026-10-20 08:00:00.000 [info] legacy timestamp" )
    (fun path ->
      B.load_from_file path ;
      check_limits () ;
      check
        "import suffix"
        ( (List.hd (B.recent_filtered ~n:1 ~search:"after malformed" ())).message
        = "after malformed and huge line" ) ;
      check
        "legacy import"
        (B.recent_filtered ~n:1 ~search:"legacy timestamp" () <> []) ;
      let long_level =
        List.hd (B.recent_filtered ~n:1 ~search:"huge-level-msg" ())
      in
      check "long imported level bounded" (String.length long_level.level <= 64) ;
      check
        "long imported level marked"
        (contains long_level.level "[truncated]") ;
      let huge = List.hd (B.recent_filtered ~n:1 ~level:"warn" ()) in
      check "long import marked" (contains huge.message "[truncated]") ;
      check "long import bounded" (B.entry_bytes huge <= 16384) ;
      let time = Unix.gmtime huge.timestamp in
      check "UTC import" (time.Unix.tm_hour = 8) ;
      ignore (push "after import") ;
      check
        "append after import"
        ((List.hd (B.recent 1)).message = "after import") ) ;
  let finished = Atomic.make false in
  let writer offset =
    Domain.spawn (fun () ->
        for i = 1 to 10000 do
          ignore
            (B.push
               ~level:"info"
               ~message:(string_of_int (offset + i))
               ~timestamp:(float_of_int i)
               () )
        done )
  in
  let a = writer 0 and b = writer 10000 in
  let reader =
    Domain.spawn (fun () ->
        let rec loop reads =
          let entries = B.recent 40 in
          if not (ordered entries) then failwith "concurrent chronological IDs" ;
          ignore (B.recent_filtered ~n:40 ~search:"1" ()) ;
          ignore (B.before ~before_id:max_int ~n:40) ;
          ignore (B.around ~target_ts:5000. ~n:40) ;
          if Atomic.get finished then reads else loop (reads + 1)
        in
        loop 0 )
  in
  Domain.join a ;
  Domain.join b ;
  Atomic.set finished true ;
  check "concurrent reader completed" (Domain.join reader > 0) ;
  check_limits () ;
  check "final IDs ordered" (ordered (B.recent max_int)) ;
  json
    (`Assoc [("case", `String "functional"); ("assertions", `Int !assertions)])

let silence_logger () =
  let null = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  Unix.dup2 null Unix.stdout ;
  Unix.close null ;
  Well.Log._file := Some (open_out_bin "/dev/null") ;
  Well.Log._hook :=
    Some
      (fun timestamp level message ctx ->
        ignore (B.push ~level ~message ~timestamp ~ctx ()) )

let live_bytes () =
  Gc.full_major () ;
  (Gc.stat ()).live_words * (Sys.word_size / 8)

let memory mode =
  silence_logger () ;
  let emit i =
    let size = if mode = "large" then 18000 else 128 in
    let ctx =
      if mode = "context"
      then
        List.init 40 (fun j -> (string_of_int j, Printf.sprintf "value-%08d" i))
      else [("request_id", Printf.sprintf "%08d" i)]
    in
    Well.Log.log ~level:"debug" ~ctx "%08d %s" i (String.make size 'x')
  in
  let run_batch offset =
    for i = 1 to 100000 do
      emit (offset + i)
    done
  in
  let run_import path _ = B.load_from_file path in
  let run_batches batch =
    batch 0 ;
    let baseline = live_bytes () in
    let baseline_rss = Well.Telemetry.rss_kb () * 1024 in
    for phase = 0 to 10 do
      if phase > 0 then batch (phase * 100000) ;
      let live = live_bytes () in
      let rss = Well.Telemetry.rss_kb () * 1024 in
      let count, bytes = B.stats () in
      json
        (`Assoc
           [ ("case", `String mode)
           ; ("phase", `Int phase)
           ; ("emitted", `Int ((phase + 1) * 100000))
           ; ("entries", `Int count)
           ; ("bytes", `Int bytes)
           ; ("live_bytes", `Int live)
           ; ("rss_bytes", `Int rss) ] ) ;
      check_limits () ;
      check "live heap plateau" (live <= baseline + (1024 * 1024)) ;
      check "RSS plateau" (rss <= baseline_rss + (16 * 1024 * 1024))
    done
  in
  if mode = "import"
  then
    import_file
      (fun channel ->
        for i = 1 to 100000 do
          output_string
            channel
            (line (Printf.sprintf "import %08d %s" i (String.make 128 'x')))
        done )
      (fun path -> run_batches (run_import path))
  else run_batches run_batch

let raw_output () =
  let path = Filename.temp_file "well-retention-raw-" ".log" in
  let stdout_path = Filename.temp_file "well-retention-stdout-" ".log" in
  Fun.protect
    ~finally:(fun () ->
      Sys.remove path ;
      Sys.remove stdout_path )
    (fun () ->
      let stdout_fd = Unix.openfile stdout_path [Unix.O_WRONLY] 0 in
      Unix.dup2 stdout_fd Unix.stdout ;
      Unix.close stdout_fd ;
      let channel = open_out_bin path in
      Well.Log._file := Some channel ;
      Well.Log._hook :=
        Some
          (fun timestamp level message ctx ->
            ignore (B.push ~level ~message ~timestamp ~ctx ()) ) ;
      let original = "begin-" ^ String.make 100000 'x' ^ "-end" in
      Well.Log.log
        ~ctx:[("key", String.make 20000 'v' ^ "context-end")]
        "%s"
        original ;
      close_out channel ;
      Well.Log._file := None ;
      let read path =
        let ic = open_in_bin path in
        Fun.protect
          ~finally:(fun () -> close_in ic)
          (fun () -> really_input_string ic (in_channel_length ic))
      in
      List.iter
        (fun path ->
          let text = read path in
          check "raw full message" (contains text original) ;
          check "raw full context" (contains text "context-end") )
        [path; stdout_path] ;
      check "preview bounded" (B.entry_bytes (List.hd (B.recent 1)) <= 16384) ) ;
  json (`Assoc [("case", `String "raw"); ("assertions", `Int !assertions)])

let () =
  match if Array.length Sys.argv > 1 then Sys.argv.(1) else "functional" with
  | "functional" -> functional ()
  | "raw" -> raw_output ()
  | mode -> memory mode
