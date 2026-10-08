module C = Well.Civil_clock

let require condition message = if not condition then failwith message

let zone =
  match C.resolve "Europe/Warsaw" with
  | Ok zone -> zone
  | Error _ -> failwith "Cannot resolve Warsaw"

let date_text date = Timedesc.Date.Ymd.to_iso8601 date

let () =
  let before = Unix.gettimeofday () in
  let local : C.date_time = C.now ~zone () in
  let after = Unix.gettimeofday () in
  let timestamp = Timedesc.to_timestamp_float_s_single local in
  require (before <= timestamp && timestamp <= after) "now escaped clock bounds" ;
  require
    (Timedesc.Time_zone.equal
       (Timedesc.tz local)
       (zone :> Timedesc.Time_zone.t) )
    "now used a different zone" ;
  require (Timedesc.hour local >= 0 && Timedesc.hour local < 24) "invalid hour" ;
  let before_today = C.now ~zone () |> Timedesc.date |> date_text in
  let today : C.date = C.today ~zone () in
  let after_today = C.now ~zone () |> Timedesc.date |> date_text in
  require
    (date_text today = before_today || date_text today = after_today)
    "today used a different clock or zone" ;
  require (Timedesc.Date.year today >= 0) "invalid year" ;
  require (Timedesc.Date.month today >= 1) "invalid month" ;
  require (Timedesc.Date.day today >= 1) "invalid day" ;
  List.iter
    (fun (name, instant, expected) ->
      let selected =
        match C.resolve name with
        | Ok zone -> zone
        | Error _ -> failwith ("Cannot resolve " ^ name)
      in
      match C.date_of_instant ~zone:selected instant with
      | Ok date -> require (date_text date = expected) (name ^ " " ^ instant)
      | Error _ -> failwith ("Conversion rejected " ^ instant) )
    Civil_clock_cases.Cases.conversions ;
  Printf.printf
    "C06 consumer: clock bounds, public aliases and %d conversions passed\n"
    (List.length Civil_clock_cases.Cases.conversions)
