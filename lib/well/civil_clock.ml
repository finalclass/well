type zone = Timedesc.Time_zone.t

type date = Timedesc.Date.t

type date_time = Timedesc.t

type error =
  | Invalid_zone of string
  | Invalid_date of string
  | Invalid_instant of string

let resolve input =
  let name = String.trim input in
  if name = "UTC" || List.mem name Timedesc.Time_zone.available_time_zones
  then
    match Timedesc.Time_zone.make name with
    | Some zone -> Ok zone
    | None -> Error (Invalid_zone input)
  else Error (Invalid_zone input)

let now ~zone () = Timedesc.now ~tz_of_date_time:zone ()

let today ~zone () = Timedesc.date (now ~zone ())

let digits_at text start count =
  let rec loop index =
    index = start + count
    || (text.[index] >= '0' && text.[index] <= '9' && loop (index + 1))
  in
  loop start

let number_at text start = int_of_string (String.sub text start 2)

let ymd_format text =
  String.length text >= 10
  && text.[4] = '-'
  && text.[7] = '-'
  && digits_at text 0 4
  && digits_at text 5 2
  && digits_at text 8 2

let valid_offset text start =
  if String.length text - start = 1
  then text.[start] = 'Z'
  else
    (text.[start] = '+' || text.[start] = '-')
    && text.[start + 3] = ':'
    && digits_at text (start + 1) 2
    && digits_at text (start + 4) 2
    && number_at text (start + 1) < 24
    && number_at text (start + 4) < 60
    && String.sub text start 6 <> "-00:00"

let instant_format text =
  let length = String.length text in
  if length < 20
  then false
  else
    let offset_start =
      if text.[length - 1] = 'Z' then length - 1 else length - 6
    in
    let fraction_valid =
      offset_start = 19
      || offset_start >= 21
         && offset_start <= 29
         && text.[19] = '.'
         && digits_at text 20 (offset_start - 20)
    in
    ymd_format text
    && text.[10] = 'T'
    && text.[13] = ':'
    && text.[16] = ':'
    && digits_at text 11 2
    && digits_at text 14 2
    && digits_at text 17 2
    && number_at text 11 < 24
    && number_at text 14 < 60
    && number_at text 17 < 60
    && fraction_valid
    && valid_offset text offset_start

let date_of_ymd input =
  let text = String.trim input in
  if String.length text <> 10 || not (ymd_format text)
  then Error (Invalid_date input)
  else
    match Timedesc.Date.Ymd.of_iso8601 text with
    | Ok date -> Ok date
    | Error _ -> Error (Invalid_date input)

let date_of_instant ~zone input =
  let text = String.trim input in
  let invalid = Error (Invalid_instant input) in
  if not (instant_format text)
  then invalid
  else
    match Timedesc.of_iso8601 text with
    | Error _ -> invalid
    | Ok instant -> (
      match Timedesc.to_timestamp instant with
      | `Ambiguous _ -> invalid
      | `Single timestamp -> (
        try
          match Timedesc.of_timestamp ~tz_of_date_time:zone timestamp with
          | None -> invalid
          | Some local -> Ok (Timedesc.date local)
        with
        | Timedesc.Date.Ymd.Error_exn (`Invalid_year _) -> invalid ) )
