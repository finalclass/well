module Impl = struct
  let reserve _ctx (_req : Contract_data.Orders.ReserveRequest.t) =
    Contract_data.Orders.ReserveResponse.Unavailable

  let echo ctx (_req : Contract_data.Common.Thing.t) =
    let user =
      Well.Session.get ~session_id:ctx.Well.session_id ~key:"user_id"
    in
    Contract_data.Common.Thing.make
      ~id:(Option.value ~default:"anonymous" ctx.user_id)
      ?label:user
      ()

  let numbers _ctx request = request

  let empty _ctx request = request
end

let () =
  Well.api_token_auth
    ~verify:(fun token ->
      if token = "alice" || token = "bob"
      then Some {Well.user_id= token; session_data= []}
      else None )
    () ;
  Well.Service.register_drut (Orders.make_spec (module Impl)) ;
  Well.Service.expose "Orders" ;
  Well.use Well.csrf ;
  Well.get "/csrf-token" (fun _ -> Well.json (`Assoc [("ready", `Bool true)])) ;
  Well.run ~port:(int_of_string (Sys.getenv "W3_PORT")) ()
