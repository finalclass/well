(** Persisted aggregates for HTTP routes, document flow, and service methods. *)

let bucket_count = 12

let bucket_bounds =
  [| 1_000
   ; 5_000
   ; 10_000
   ; 25_000
   ; 50_000
   ; 100_000
   ; 250_000
   ; 500_000
   ; 1_000_000
   ; 2_000_000
   ; 5_000_000 |]

let entry = "(entry)"
let unmatched = "(unmatched)"

let bucket_of_us us =
  let rec go i =
    if i >= Array.length bucket_bounds then bucket_count - 1
    else if us < bucket_bounds.(i) then i
    else go (i + 1)
  in
  go 0

let percentile_us ~p buckets total =
  if total <= 0 then 0
  else
    let need =
      max 1 (int_of_float (ceil (p *. float_of_int total)))
    in
    let rec go i acc =
      if i >= bucket_count then -1
      else
        let acc = acc + buckets.(i) in
        if acc >= need then
          if i >= Array.length bucket_bounds then -1 else bucket_bounds.(i)
        else go (i + 1) acc
    in
    go 0 0

type http_row = {
  class_ : string;
  meth : string;
  route : string;
  count : int;
  mean_us : int;
  p95_us : int;
  c2xx : int;
  c4xx : int;
  c5xx : int;
  cother : int;
}

type flow_row = {
  from_route : string;
  to_route : string;
  count : int;
}

type service_row = {
  service : string;
  rpc : string;
  count : int;
  mean_us : int;
  p95_us : int;
  ok : int;
  err : int;
}

type mute = {
  service : string;
  rpc : string;
  until_unix : float;
}

type agg = {
  mutable count : int;
  mutable sum_us : int;
  mutable c2xx : int;
  mutable c4xx : int;
  mutable c5xx : int;
  mutable cother : int;
  mutable ok : int;
  mutable err : int;
  buckets : int array;
}

let empty_agg () =
  { count = 0
  ; sum_us = 0
  ; c2xx = 0
  ; c4xx = 0
  ; c5xx = 0
  ; cother = 0
  ; ok = 0
  ; err = 0
  ; buckets = Array.make bucket_count 0 }

let add_agg dst src =
  dst.count <- dst.count + src.count;
  dst.sum_us <- dst.sum_us + src.sum_us;
  dst.c2xx <- dst.c2xx + src.c2xx;
  dst.c4xx <- dst.c4xx + src.c4xx;
  dst.c5xx <- dst.c5xx + src.c5xx;
  dst.cother <- dst.cother + src.cother;
  dst.ok <- dst.ok + src.ok;
  dst.err <- dst.err + src.err;
  Array.iteri (fun i n -> dst.buckets.(i) <- dst.buckets.(i) + n) src.buckets

let minute_of now = int_of_float (now /. 60.)

let mu = Mutex.create ()
let http_mem : (int * string * string * string, agg) Hashtbl.t = Hashtbl.create 64
let flow_mem : (int * string * string, agg) Hashtbl.t = Hashtbl.create 32
let service_mem : (int * string * string, agg) Hashtbl.t = Hashtbl.create 64
let mutes : (string * string, float) Hashtbl.t = Hashtbl.create 8
let mutes_loaded = ref false
let last_flush = ref 0.
let flushing = ref false

let exec db sql =
  match Sqlite3.exec db sql with
  | Sqlite3.Rc.OK -> ()
  | rc ->
      failwith
        ("metrics: " ^ Sqlite3.Rc.to_string rc ^ ": " ^ Sqlite3.errmsg db)

let bucket_ddl =
  String.concat ", "
    (List.init bucket_count (fun i -> Printf.sprintf "b%d INTEGER NOT NULL" i))

let ensure db =
  exec db
    (Printf.sprintf
       {|CREATE TABLE IF NOT EXISTS well_http_minute (
           minute INTEGER NOT NULL,
           class TEXT NOT NULL,
           meth TEXT NOT NULL,
           route TEXT NOT NULL,
           count INTEGER NOT NULL,
           sum_us INTEGER NOT NULL,
           c2xx INTEGER NOT NULL,
           c4xx INTEGER NOT NULL,
           c5xx INTEGER NOT NULL,
           cother INTEGER NOT NULL,
           %s,
           PRIMARY KEY (minute, class, meth, route)
         )|}
       bucket_ddl);
  exec db
    {|CREATE TABLE IF NOT EXISTS well_http_flow_minute (
        minute INTEGER NOT NULL,
        from_route TEXT NOT NULL,
        to_route TEXT NOT NULL,
        count INTEGER NOT NULL,
        PRIMARY KEY (minute, from_route, to_route)
      )|};
  exec db
    (Printf.sprintf
       {|CREATE TABLE IF NOT EXISTS well_service_minute (
           minute INTEGER NOT NULL,
           service TEXT NOT NULL,
           rpc TEXT NOT NULL,
           count INTEGER NOT NULL,
           sum_us INTEGER NOT NULL,
           ok INTEGER NOT NULL,
           err INTEGER NOT NULL,
           %s,
           PRIMARY KEY (minute, service, rpc)
         )|}
       bucket_ddl);
  exec db
    {|CREATE TABLE IF NOT EXISTS well_metric_mute (
        service TEXT NOT NULL,
        rpc TEXT NOT NULL,
        until_unix REAL NOT NULL,
        PRIMARY KEY (service, rpc)
      )|}

let bind_int stmt i n =
  ignore (Sqlite3.bind stmt i (Sqlite3.Data.INT (Int64.of_int n)))

let bind_text stmt i s =
  ignore (Sqlite3.bind stmt i (Sqlite3.Data.TEXT s))

let finish stmt = ignore (Sqlite3.finalize stmt)

let run stmt =
  match Sqlite3.step stmt with
  | Sqlite3.Rc.DONE | Sqlite3.Rc.ROW -> ()
  | rc -> failwith ("metrics step: " ^ Sqlite3.Rc.to_string rc)

let with_stmt db sql f =
  let stmt = Sqlite3.prepare db sql in
  Fun.protect ~finally:(fun () -> finish stmt) (fun () -> f stmt)

let column_int stmt i =
  match Sqlite3.column stmt i with
  | Sqlite3.Data.INT n -> Int64.to_int n
  | Sqlite3.Data.FLOAT f -> int_of_float f
  | Sqlite3.Data.TEXT s -> (try int_of_string s with _ -> 0)
  | _ -> 0

let column_float stmt i =
  match Sqlite3.column stmt i with
  | Sqlite3.Data.FLOAT f -> f
  | Sqlite3.Data.INT n -> Int64.to_float n
  | Sqlite3.Data.TEXT s -> (try float_of_string s with _ -> 0.)
  | _ -> 0.

let column_text stmt i =
  match Sqlite3.column stmt i with
  | Sqlite3.Data.TEXT s -> s
  | _ -> ""

let insert_buckets_sql prefix =
  let cols = String.concat ", " (List.init bucket_count (fun i -> Printf.sprintf "b%d" i)) in
  let marks = String.concat ", " (List.init bucket_count (fun _ -> "?")) in
  let adds =
    String.concat ", "
      (List.init bucket_count (fun i ->
           Printf.sprintf "b%d = %s.b%d + excluded.b%d" i prefix i i))
  in
  (cols, marks, adds)

let http_cols, http_marks, http_adds = insert_buckets_sql "well_http_minute"
let service_cols, service_marks, service_adds = insert_buckets_sql "well_service_minute"

let write_http db minute class_ meth route agg =
  let sql =
    Printf.sprintf
      {|INSERT INTO well_http_minute
          (minute, class, meth, route, count, sum_us, c2xx, c4xx, c5xx, cother, %s)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, %s)
        ON CONFLICT (minute, class, meth, route) DO UPDATE SET
          count = well_http_minute.count + excluded.count,
          sum_us = well_http_minute.sum_us + excluded.sum_us,
          c2xx = well_http_minute.c2xx + excluded.c2xx,
          c4xx = well_http_minute.c4xx + excluded.c4xx,
          c5xx = well_http_minute.c5xx + excluded.c5xx,
          cother = well_http_minute.cother + excluded.cother,
          %s|}
      http_cols http_marks http_adds
  in
  with_stmt db sql (fun stmt ->
      bind_int stmt 1 minute;
      bind_text stmt 2 class_;
      bind_text stmt 3 meth;
      bind_text stmt 4 route;
      bind_int stmt 5 agg.count;
      bind_int stmt 6 agg.sum_us;
      bind_int stmt 7 agg.c2xx;
      bind_int stmt 8 agg.c4xx;
      bind_int stmt 9 agg.c5xx;
      bind_int stmt 10 agg.cother;
      Array.iteri (fun i n -> bind_int stmt (11 + i) n) agg.buckets;
      run stmt)

let write_flow db minute from_route to_route count =
  let sql =
    {|INSERT INTO well_http_flow_minute (minute, from_route, to_route, count)
      VALUES (?, ?, ?, ?)
      ON CONFLICT (minute, from_route, to_route) DO UPDATE SET
        count = well_http_flow_minute.count + excluded.count|}
  in
  with_stmt db sql (fun stmt ->
      bind_int stmt 1 minute;
      bind_text stmt 2 from_route;
      bind_text stmt 3 to_route;
      bind_int stmt 4 count;
      run stmt)

let write_service db minute service rpc agg =
  let sql =
    Printf.sprintf
      {|INSERT INTO well_service_minute
          (minute, service, rpc, count, sum_us, ok, err, %s)
        VALUES (?, ?, ?, ?, ?, ?, ?, %s)
        ON CONFLICT (minute, service, rpc) DO UPDATE SET
          count = well_service_minute.count + excluded.count,
          sum_us = well_service_minute.sum_us + excluded.sum_us,
          ok = well_service_minute.ok + excluded.ok,
          err = well_service_minute.err + excluded.err,
          %s|}
      service_cols service_marks service_adds
  in
  with_stmt db sql (fun stmt ->
      bind_int stmt 1 minute;
      bind_text stmt 2 service;
      bind_text stmt 3 rpc;
      bind_int stmt 4 agg.count;
      bind_int stmt 5 agg.sum_us;
      bind_int stmt 6 agg.ok;
      bind_int stmt 7 agg.err;
      Array.iteri (fun i n -> bind_int stmt (8 + i) n) agg.buckets;
      run stmt)

let retain db now_minute =
  let cutoff = now_minute - 1500 in
  List.iter
    (fun sql ->
      with_stmt db sql (fun stmt ->
          bind_int stmt 1 cutoff;
          run stmt))
    [ "DELETE FROM well_http_minute WHERE minute < ?"
    ; "DELETE FROM well_http_flow_minute WHERE minute < ?"
    ; "DELETE FROM well_service_minute WHERE minute < ?" ]

let merge_back http flow service =
  Mutex.lock mu;
  Hashtbl.iter
    (fun k src ->
      let dst =
        match Hashtbl.find_opt http_mem k with
        | Some dst -> dst
        | None ->
            let dst = empty_agg () in
            Hashtbl.add http_mem k dst;
            dst
      in
      add_agg dst src)
    http;
  Hashtbl.iter
    (fun k src ->
      let dst =
        match Hashtbl.find_opt flow_mem k with
        | Some dst -> dst
        | None ->
            let dst = empty_agg () in
            Hashtbl.add flow_mem k dst;
            dst
      in
      add_agg dst src)
    flow;
  Hashtbl.iter
    (fun k src ->
      let dst =
        match Hashtbl.find_opt service_mem k with
        | Some dst -> dst
        | None ->
            let dst = empty_agg () in
            Hashtbl.add service_mem k dst;
            dst
      in
      add_agg dst src)
    service;
  Mutex.unlock mu

let flush_now () =
  let http = Hashtbl.create 16 in
  let flow = Hashtbl.create 16 in
  let service = Hashtbl.create 16 in
  Mutex.lock mu;
  Hashtbl.iter (fun k v -> Hashtbl.add http k v) http_mem;
  Hashtbl.iter (fun k v -> Hashtbl.add flow k v) flow_mem;
  Hashtbl.iter (fun k v -> Hashtbl.add service k v) service_mem;
  Hashtbl.clear http_mem;
  Hashtbl.clear flow_mem;
  Hashtbl.clear service_mem;
  Mutex.unlock mu;
  let pending =
    Hashtbl.length http + Hashtbl.length flow + Hashtbl.length service
  in
  if pending = 0 then ()
  else
    try
      Db.with_well_db (fun db ->
          ensure db;
          Hashtbl.iter
            (fun (minute, class_, meth, route) agg ->
              write_http db minute class_ meth route agg)
            http;
          Hashtbl.iter
            (fun (minute, from_route, to_route) agg ->
              write_flow db minute from_route to_route agg.count)
            flow;
          Hashtbl.iter
            (fun (minute, service_name, rpc) agg ->
              write_service db minute service_name rpc agg)
            service;
          retain db (minute_of (Unix.gettimeofday ())))
    with exn ->
      merge_back http flow service;
      raise exn

let maybe_flush () =
  let now = Unix.gettimeofday () in
  Mutex.lock mu;
  let due = now -. !last_flush >= 2. && not !flushing in
  if due then flushing := true;
  Mutex.unlock mu;
  if due then
    Fun.protect
      ~finally:(fun () ->
        Mutex.lock mu;
        flushing := false;
        last_flush := Unix.gettimeofday ();
        Mutex.unlock mu)
      (fun () -> try flush_now () with exn -> Log.log ~level:"error" "metrics flush: %s" (Printexc.to_string exn))

let touch_agg table key f =
  Mutex.lock mu;
  let agg =
    match Hashtbl.find_opt table key with
    | Some agg -> agg
    | None ->
        let agg = empty_agg () in
        Hashtbl.add table key agg;
        agg
  in
  f agg;
  Mutex.unlock mu

let observe_http ~class_ ~meth ~route ~status ~us =
  try
    let us = max 0 us in
    let minute = minute_of (Unix.gettimeofday ()) in
    touch_agg http_mem (minute, class_, meth, route) (fun agg ->
        agg.count <- agg.count + 1;
        agg.sum_us <- agg.sum_us + us;
        agg.buckets.(bucket_of_us us) <- agg.buckets.(bucket_of_us us) + 1;
        if status >= 200 && status < 300 then agg.c2xx <- agg.c2xx + 1
        else if status >= 400 && status < 500 then agg.c4xx <- agg.c4xx + 1
        else if status >= 500 && status < 600 then agg.c5xx <- agg.c5xx + 1
        else agg.cother <- agg.cother + 1);
    maybe_flush ()
  with exn ->
    Log.log ~level:"error" "metrics http: %s" (Printexc.to_string exn)

let observe_flow ~from_route ~to_route =
  try
    let minute = minute_of (Unix.gettimeofday ()) in
    touch_agg flow_mem (minute, from_route, to_route) (fun agg ->
        agg.count <- agg.count + 1);
    maybe_flush ()
  with exn ->
    Log.log ~level:"error" "metrics flow: %s" (Printexc.to_string exn)

let drop_expired_mutes now =
  let expired = ref [] in
  Hashtbl.iter
    (fun key until_unix -> if until_unix <= now then expired := key :: !expired)
    mutes;
  List.iter (Hashtbl.remove mutes) !expired;
  !expired

let load_mutes () =
  if !mutes_loaded then ()
  else
    let rows =
      Db.with_well_db (fun db ->
          ensure db;
          let now = Unix.gettimeofday () in
          with_stmt db "DELETE FROM well_metric_mute WHERE until_unix <= ?" (fun stmt ->
              ignore (Sqlite3.bind stmt 1 (Sqlite3.Data.FLOAT now));
              run stmt);
          let acc = ref [] in
          with_stmt db "SELECT service, rpc, until_unix FROM well_metric_mute" (fun stmt ->
              let rec loop () =
                match Sqlite3.step stmt with
                | Sqlite3.Rc.ROW ->
                    acc :=
                      (column_text stmt 0, column_text stmt 1, column_float stmt 2)
                      :: !acc;
                    loop ()
                | _ -> ()
              in
              loop ());
          !acc)
    in
    Mutex.lock mu;
    if not !mutes_loaded then begin
      List.iter (fun (service, rpc, until_unix) -> Hashtbl.replace mutes (service, rpc) until_unix) rows;
      mutes_loaded := true
    end;
    Mutex.unlock mu

let muted ~service ~rpc =
  try
    load_mutes ();
    let now = Unix.gettimeofday () in
    Mutex.lock mu;
    let expired = drop_expired_mutes now in
    let blocked key =
      match Hashtbl.find_opt mutes key with
      | Some until_unix when until_unix > now -> true
      | _ -> false
    in
    let yes = blocked (service, rpc) || blocked (service, "") in
    Mutex.unlock mu;
    if expired <> [] then
      begin
        try
          Db.with_well_db (fun db ->
              ensure db;
              List.iter
                (fun (service, rpc) ->
                  with_stmt db
                    "DELETE FROM well_metric_mute WHERE service = ? AND rpc = ?"
                    (fun stmt ->
                      bind_text stmt 1 service;
                      bind_text stmt 2 rpc;
                      run stmt))
                expired)
        with _ -> ()
      end;
    yes
  with exn ->
    Log.log ~level:"error" "metrics mute: %s" (Printexc.to_string exn);
    false

let observe_service ~service ~rpc ~us ~ok =
  try
    if muted ~service ~rpc then ()
    else
      let us = max 0 us in
      let minute = minute_of (Unix.gettimeofday ()) in
      touch_agg service_mem (minute, service, rpc) (fun agg ->
          agg.count <- agg.count + 1;
          agg.sum_us <- agg.sum_us + us;
          agg.buckets.(bucket_of_us us) <- agg.buckets.(bucket_of_us us) + 1;
          if ok then agg.ok <- agg.ok + 1 else agg.err <- agg.err + 1);
      maybe_flush ()
  with exn ->
    Log.log ~level:"error" "metrics service: %s" (Printexc.to_string exn)

let read_buckets stmt first =
  Array.init bucket_count (fun i -> column_int stmt (first + i))

let row_times count sum_us buckets =
  let mean = if count > 0 then sum_us / count else 0 in
  let p95 = percentile_us ~p:0.95 buckets count in
  (mean, p95)

let http_summary ~minutes =
  flush_now ();
  let from_minute = minute_of (Unix.gettimeofday ()) - minutes + 1 in
  Db.with_well_db (fun db ->
      ensure db;
      let sums =
        String.concat ", "
          (List.init bucket_count (fun i -> Printf.sprintf "SUM(b%d)" i))
      in
      let sql =
        Printf.sprintf
          {|SELECT class, meth, route, SUM(count), SUM(sum_us),
                   SUM(c2xx), SUM(c4xx), SUM(c5xx), SUM(cother), %s
            FROM well_http_minute
            WHERE minute >= ?
            GROUP BY class, meth, route|}
          sums
      in
      let acc : http_row list ref = ref [] in
      with_stmt db sql (fun stmt ->
          bind_int stmt 1 from_minute;
          let rec loop () =
            match Sqlite3.step stmt with
            | Sqlite3.Rc.ROW ->
                let count = column_int stmt 3 in
                let buckets = read_buckets stmt 9 in
                let mean, p95 = row_times count (column_int stmt 4) buckets in
                acc :=
                  { class_ = column_text stmt 0
                  ; meth = column_text stmt 1
                  ; route = column_text stmt 2
                  ; count
                  ; mean_us = mean
                  ; p95_us = p95
                  ; c2xx = column_int stmt 5
                  ; c4xx = column_int stmt 6
                  ; c5xx = column_int stmt 7
                  ; cother = column_int stmt 8 }
                  :: !acc;
                loop ()
            | _ -> ()
          in
          loop ());
      List.sort
        (fun (a : http_row) (b : http_row) ->
          match compare b.count a.count with
          | 0 -> compare (a.meth, a.route) (b.meth, b.route)
          | n -> n)
        !acc)

let flow_summary ~minutes =
  flush_now ();
  let from_minute = minute_of (Unix.gettimeofday ()) - minutes + 1 in
  Db.with_well_db (fun db ->
      ensure db;
      let acc : flow_row list ref = ref [] in
      with_stmt db
        {|SELECT from_route, to_route, SUM(count)
          FROM well_http_flow_minute
          WHERE minute >= ?
          GROUP BY from_route, to_route|}
        (fun stmt ->
          bind_int stmt 1 from_minute;
          let rec loop () =
            match Sqlite3.step stmt with
            | Sqlite3.Rc.ROW ->
                acc :=
                  { from_route = column_text stmt 0
                  ; to_route = column_text stmt 1
                  ; count = column_int stmt 2 }
                  :: !acc;
                loop ()
            | _ -> ()
          in
          loop ());
      List.sort
        (fun (a : flow_row) (b : flow_row) ->
          match compare b.count a.count with
          | 0 -> compare (a.from_route, a.to_route) (b.from_route, b.to_route)
          | n -> n)
        !acc)

let service_summary ~minutes =
  flush_now ();
  let from_minute = minute_of (Unix.gettimeofday ()) - minutes + 1 in
  Db.with_well_db (fun db ->
      ensure db;
      let sums =
        String.concat ", "
          (List.init bucket_count (fun i -> Printf.sprintf "SUM(b%d)" i))
      in
      let sql =
        Printf.sprintf
          {|SELECT service, rpc, SUM(count), SUM(sum_us), SUM(ok), SUM(err), %s
            FROM well_service_minute
            WHERE minute >= ?
            GROUP BY service, rpc|}
          sums
      in
      let acc : service_row list ref = ref [] in
      with_stmt db sql (fun stmt ->
          bind_int stmt 1 from_minute;
          let rec loop () =
            match Sqlite3.step stmt with
            | Sqlite3.Rc.ROW ->
                let count = column_int stmt 2 in
                let buckets = read_buckets stmt 6 in
                let mean, p95 = row_times count (column_int stmt 3) buckets in
                acc :=
                  { service = column_text stmt 0
                  ; rpc = column_text stmt 1
                  ; count
                  ; mean_us = mean
                  ; p95_us = p95
                  ; ok = column_int stmt 4
                  ; err = column_int stmt 5 }
                  :: !acc;
                loop ()
            | _ -> ()
          in
          loop ());
      List.sort
        (fun (a : service_row) (b : service_row) ->
          match compare (a.service, a.rpc) (b.service, b.rpc) with
          | 0 -> 0
          | n -> n)
        !acc)

let active_mutes () =
  load_mutes ();
  let now = Unix.gettimeofday () in
  Mutex.lock mu;
  let expired = drop_expired_mutes now in
  let acc = ref [] in
  Hashtbl.iter
    (fun (service, rpc) until_unix ->
      if until_unix > now then acc := { service; rpc; until_unix } :: !acc)
    mutes;
  Mutex.unlock mu;
  if expired <> [] then
    begin
      try
        Db.with_well_db (fun db ->
            List.iter
              (fun (service, rpc) ->
                with_stmt db
                  "DELETE FROM well_metric_mute WHERE service = ? AND rpc = ?"
                  (fun stmt ->
                    bind_text stmt 1 service;
                    bind_text stmt 2 rpc;
                    run stmt))
              expired)
      with _ -> ()
    end;
  List.sort (fun a b -> compare (a.service, a.rpc) (b.service, b.rpc)) !acc

let mute ~service ~rpc ~until_unix =
  Db.with_well_db (fun db ->
      ensure db;
      with_stmt db
        {|INSERT INTO well_metric_mute (service, rpc, until_unix)
          VALUES (?, ?, ?)
          ON CONFLICT (service, rpc) DO UPDATE SET until_unix = excluded.until_unix|}
        (fun stmt ->
          bind_text stmt 1 service;
          bind_text stmt 2 rpc;
          ignore (Sqlite3.bind stmt 3 (Sqlite3.Data.FLOAT until_unix));
          run stmt));
  Mutex.lock mu;
  Hashtbl.replace mutes (service, rpc) until_unix;
  mutes_loaded := true;
  Mutex.unlock mu

let unmute ~service ~rpc =
  Db.with_well_db (fun db ->
      ensure db;
      with_stmt db "DELETE FROM well_metric_mute WHERE service = ? AND rpc = ?"
        (fun stmt ->
          bind_text stmt 1 service;
          bind_text stmt 2 rpc;
          run stmt));
  Mutex.lock mu;
  Hashtbl.remove mutes (service, rpc);
  mutes_loaded := true;
  Mutex.unlock mu

let _forget_cache () =
  Mutex.lock mu;
  Hashtbl.clear mutes;
  mutes_loaded := false;
  Mutex.unlock mu

let _reset () =
  Mutex.lock mu;
  Hashtbl.clear http_mem;
  Hashtbl.clear flow_mem;
  Hashtbl.clear service_mem;
  Hashtbl.clear mutes;
  mutes_loaded := false;
  last_flush := 0.;
  flushing := false;
  Mutex.unlock mu;
  Db.with_well_db (fun db ->
      ensure db;
      exec db "DELETE FROM well_http_minute";
      exec db "DELETE FROM well_http_flow_minute";
      exec db "DELETE FROM well_service_minute";
      exec db "DELETE FROM well_metric_mute")
