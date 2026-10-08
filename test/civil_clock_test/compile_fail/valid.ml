let zone =
  match Well.Civil_clock.resolve "UTC" with
  | Ok zone -> zone
  | Error _ -> failwith "Cannot resolve UTC"

let raw_zone : Timedesc.Time_zone.t = (zone :> Timedesc.Time_zone.t)

let local : Well.Civil_clock.date_time = Well.Civil_clock.now ~zone ()

let date : Well.Civil_clock.date = Timedesc.date local
