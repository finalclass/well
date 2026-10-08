open Well_test
module C = Well.Civil_clock
module Cases = Civil_clock_cases.Cases

let require_zone name =
  match C.resolve name with
  | Ok zone -> zone
  | Error _ -> failwith ("Could not resolve " ^ name)

let date_text = function
  | Ok date -> Timedesc.Date.Ymd.to_iso8601 date
  | Error _ -> failwith "Expected a valid civil date"

let verify_conversion (name, instant, expected) =
  C.date_of_instant ~zone:(require_zone name) instant |> date_text
  |> fun actual ->
  if actual <> expected
  then failwith (Printf.sprintf "%s %s: %s <> %s" name instant actual expected)

let () =
  describe "Well.Civil_clock" (fun () ->
      it "C01 resolves named IANA zones and explicit UTC" (fun () ->
          List.iter
            (fun name ->
              let zone = require_zone name in
              expect (Timedesc.Time_zone.name (zone :> Timedesc.Time_zone.t))
              |> to_equal_string (String.trim name) )
            [ "Europe/Warsaw"
            ; "America/New_York"
            ; "Asia/Kathmandu"
            ; "UTC"
            ; "Etc/GMT-2"
            ; " \tEurope/Warsaw\n" ] ) ;
      it
        "C01 preserves invalid input and leaves fallback to the caller"
        (fun () ->
          List.iter
            (fun input ->
              expect (C.resolve input = Error (C.Invalid_zone input))
              |> to_be_true )
            ["Mars/Olympus"; ""; " \t"; "europe/warsaw"; "+02:00"; "UTC+2"] ;
          ignore (require_zone "UTC") ) ;
      List.iter
        (fun ((name, instant, _) as case) ->
          it
            ("C02/C03 converts " ^ name ^ " " ^ instant)
            (fun () -> verify_conversion case) )
        Cases.conversions ;
      it
        "C02 keeps zones independent across interleaved calls and domains"
        (fun () ->
          let verify () =
            for _ = 1 to 20 do
              List.iter verify_conversion Cases.conversions
            done
          in
          let other = Domain.spawn verify in
          Fun.protect ~finally:(fun () -> Domain.join other) verify ) ;
      it
        "C04 preserves complete Gregorian civil dates without a zone"
        (fun () ->
          List.iter
            (fun input ->
              let date = C.date_of_ymd input |> date_text in
              expect date |> to_equal_string (String.trim input) )
            [ "2024-02-29"
            ; "2026-01-16"
            ; "0000-01-01"
            ; "9999-12-31"
            ; " \t2026-01-16\n" ] ) ;
      List.iter
        (fun input ->
          it
            ("C04 rejects date " ^ String.escaped input)
            (fun () ->
              expect (C.date_of_ymd input = Error (C.Invalid_date input))
              |> to_be_true ) )
        Cases.invalid_dates ;
      List.iter
        (fun input ->
          it
            ("C05 rejects instant " ^ String.escaped input)
            (fun () ->
              expect
                ( C.date_of_instant ~zone:(require_zone "Europe/Warsaw") input
                = Error (C.Invalid_instant input) )
              |> to_be_true ) )
        Cases.invalid_instants ;
      it
        "C05 accepts whitespace, zero offsets and supported fractions"
        (fun () ->
          let zone = require_zone "Europe/Warsaw" in
          List.iter
            (fun input ->
              expect (C.date_of_instant ~zone input |> date_text)
              |> to_equal_string "2026-01-16" )
            [ " \t2026-01-15T23:30:00Z\n"
            ; "2026-01-15T23:30:00+00:00"
            ; "2026-01-15T23:30:00.1Z"
            ; "2026-01-15T23:30:00.123456789+00:00" ] ) ;
      it "C05 reports conversions outside the civil date range" (fun () ->
          List.iter
            (fun (name, input) ->
              expect
                ( C.date_of_instant ~zone:(require_zone name) input
                = Error (C.Invalid_instant input) )
              |> to_be_true )
            [ ("Europe/Warsaw", "9999-12-31T23:30:00Z")
            ; ("UTC", "0000-01-01T00:30:00+01:00") ] ) ) ;
  run ~source_file:__FILE__ () |> exit_with_result
