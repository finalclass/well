let use_date (date : Well.Civil_clock.date) = date

let reject_date_time (date_time : Well.Civil_clock.date_time) =
  use_date date_time
