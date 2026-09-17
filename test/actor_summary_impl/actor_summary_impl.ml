module Impl : Summary_builder.IMPL = struct
  type state = unit
  let state_version = 1
  let init _ = ()
  let state_to_wire () = `Null
  let state_of_wire _ = Ok ()
  let handle _ctx () = function
    | Summary_builder.Inbound.Build batch ->
      let text =
        batch.items
        |> List.map (fun (r : Reports.Report.t) -> r.text)
        |> String.concat " "
      in
      Ok ((), [Summary_builder.Outbound.Built (Reports.Summary.make ~text ())])
end

let definition = Summary_builder.make (module Impl)
