(* W3 server: a real Well text-Drut HTTP server with session and CSRF
   middleware. It hands the browser and the network clients one service whose
   messages cross module boundaries and carry wide integers. *)

let port =
  match Sys.getenv_opt "W3_PORT" with
  | Some p -> (try int_of_string p with _ -> 8478)
  | None -> 8478

module Impl = struct
  let reserve _ctx (req : Contract_data.Orders.ReserveRequest.t) =
    if req.quantity <= 0 then
      Contract_data.Orders.ReserveResponse.Rejected
        (Contract_data.Orders.Problem.make ~code:"bad"
           ~message:"non-positive" ())
    else
      Contract_data.Orders.ReserveResponse.Reserved
        (Contract_data.Orders.Reservation.make ~id:req.owner_id
           ~item:
             (Contract_data.Common.Thing.make ~id:req.thing.id
                ?label:req.thing.label ())
           ~count:req.quantity ())

  let echo _ctx (thing : Contract_data.Common.Thing.t) = thing

  let numbers _ctx (numbers : Contract_data.Common.Numbers.t) = numbers

  let empty _ctx (empty : Contract_data.Common.Empty.t) = empty
end

let () =
  Well.Service.register_drut (Orders.make_spec (module Impl));
  Well.Service.expose "Orders";
  Well.use Well.csrf;
  Well.get "/csrf-token" (fun req ->
      Well.json (`Assoc [ ("token", `String (Well.csrf_token req)) ]));
  Well.run ~port ()