(* W4 server: a real Well text-Drut service and a legacy Actor, reachable
   through the unix socket and the HTTP route. The wide Int fields let the
   socket test prove that a raw fractional Int never reaches the handler. *)

let port =
  match Sys.getenv_opt "W4_PORT" with
  | Some p -> (try int_of_string p with _ -> 8479)
  | None -> 8479

module Impl = struct
  let reserve ctx (req : Contract_data.Orders.ReserveRequest.t) =
    if req.quantity <= 0 then
      Contract_data.Orders.ReserveResponse.Rejected
        (Contract_data.Orders.Problem.make ~code:"bad"
           ~message:"non-positive" ())
    else
      Contract_data.Orders.ReserveResponse.Reserved
        (Contract_data.Orders.Reservation.make ~id:req.owner_id
           ~item:
             (Contract_data.Common.Thing.make
                ~id:("ctx:" ^ Option.value ctx.Well.user_id ~default:"none")
                ())
           ~count:req.quantity ())

  let echo _ctx (thing : Contract_data.Common.Thing.t) = thing

  let numbers _ctx (numbers : Contract_data.Common.Numbers.t) =
    if numbers.small = -1 then failwith "numbers boom";
    numbers

  let empty _ctx (empty : Contract_data.Common.Empty.t) = empty
end

let legacy =
  { Well.Service.name = "LegacyEcho";
    handler =
      (fun rpc _ctx payload ->
        match rpc with
        | "ping" -> `Assoc [ ("pong", payload) ]
        | _ -> `Null);
    set_ref = ignore;
    rpcs =
      [ { Well.Service.rname = "ping"; params = []; returns = []; returns_name = "void" } ] }

let () =
  Well.Service.register_drut (Orders.make_spec (module Impl));
  Well.Service.expose "Orders";
  Well.Actor.register legacy;
  Well.use Well.csrf;
  Well.run ~port ()