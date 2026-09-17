module Impl : Reporter.IMPL = struct
  type state = int
  let state_version = 1
  let init _ = 0
  let state_to_wire n = `Int n
  let state_of_wire = function
    | `Int n when n >= 0 -> Ok n
    | _ -> Error "invalid reporter state"
  let handle ctx state = function
    | Reporter.Inbound.Generate request ->
      let report = Reports.Report.make ~source:ctx.Well.Actor.self.id ~text:request.subject () in
      Ok (state + 1, [Reporter.Outbound.Produced report])
end

let definition = Reporter.make (module Impl)
