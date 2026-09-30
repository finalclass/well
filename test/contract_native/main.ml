(* W2 outside-repo consumer: compiles the generated contract data library and
   the generated Well adapters, then exercises the text-Drut path locally and
   over HTTP. It links only the published public names (well.core, cyrograf)
   and never the old JSON codec. *)

let port = 8477

module Impl = struct
  let calls = ref 0
  let explode = ref false

  let reserve ctx (req : Contract_data.Orders.ReserveRequest.t) =
    incr calls;
    if !explode then failwith "boom";
    if req.quantity <= 0 then
      Contract_data.Orders.ReserveResponse.Rejected
        (Contract_data.Orders.Problem.make
           ~code:(Option.value ctx.Well.user_id ~default:"anon")
           ~message:"non-positive" ())
    else
      Contract_data.Orders.ReserveResponse.Reserved
        (Contract_data.Orders.Reservation.make ~id:req.owner_id
           ~item:
             (Contract_data.Common.Thing.make
                ~id:
                  (Printf.sprintf "ctx:%s"
                     (Option.value ctx.Well.user_id ~default:"none"))
                ())
           ())
end

let register_service () =
  Well.Service.register_drut
    (Orders.make_spec (module Impl));
  Well.Service.expose "Orders"

let test_ctx =
  { Well.session_id = "sess"; request_id = "req"; user_id = Some "u-9";
    user_name = None; locale = "pl"; session_data = [] }

let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then begin incr pass; Printf.printf "ok   %s\n" name end
  else begin incr fail; Printf.printf "FAIL %s\n" name end

let show = function
  | Ok s -> "Ok " ^ s
  | Error _ -> "Error"

let local_tests () =
  Impl.calls := 0;
  let spec = Orders.make_spec (module Impl) in
  Well.Service.register_drut spec;
  Well.Service.expose "Orders";
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Well.Service.start_all ~sw;
  let ctx_wire = Well.rpc_ctx_to_wire test_ctx in
  (* 1. local call through the generated convenience wrapper *)
  let req =
    Contract_data.Orders.ReserveRequest.make ~owner_id:"owner-7" ~quantity:2 ()
  in
  (match Orders.reserve ~ctx:test_ctx req with
   | Ok text ->
     check "local Drut text"
       (text = {|["Reserved",["owner-7",["ctx:u-9",null]]]|})
   | Error _ -> check "local Drut text" false);
  check "local handler ran once" (!Impl.calls = 1);
  (* 2. bad request is rejected before the implementation *)
  let before = !Impl.calls in
  (match
     Well.Service.dispatch_drut_by_name "Orders" "reserve" ctx_wire
       {|["owner-7","x",null]|}
   with
   | Error (Well.Service.Drut_request_error _) ->
     check "bad request -> Drut_request_error" true
   | _ -> check "bad request -> Drut_request_error" false);
  check "bad request never reached handler" (!Impl.calls = before);
  (* 3. domain refusal is a normal Drut answer, not a conversion error *)
  let zero =
    Contract_data.Orders.ReserveRequest.make ~owner_id:"owner-7" ~quantity:0 ()
  in
  (match Orders.reserve ~ctx:test_ctx zero with
   | Ok text ->
     check "domain variant is Ok Drut"
       (text = {|["Rejected",["u-9","non-positive"]]|})
   | Error _ -> check "domain variant is Ok Drut" false);
  (* 4. handler exception is its own layer *)
  Impl.explode := true;
  (match Orders.reserve ~ctx:test_ctx req with
   | Error (Well.Service.Drut_handler_error _) ->
     check "handler exception -> Drut_handler_error" true
   | _ -> check "handler exception -> Drut_handler_error" false);
  Impl.explode := false;
  (* 5. unknown method is a dispatch error *)
  (match
     Well.Service.dispatch_drut_by_name "Orders" "nope" ctx_wire "[]"
   with
   | Error (Well.Service.Drut_dispatch_error _) ->
     check "unknown method -> Drut_dispatch_error" true
   | _ -> check "unknown method -> Drut_dispatch_error" false);
  ignore (show (Orders.reserve ~ctx:test_ctx req))

let http_post path body =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.connect s (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
  let req =
    Printf.sprintf
      "POST %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Type: \
       application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
      path port (String.length body) body
  in
  ignore (Unix.write_substring s req 0 (String.length req));
  let buf = Buffer.create 1024 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match Unix.read s chunk 0 4096 with
    | 0 -> ()
    | n -> Buffer.add_subbytes buf chunk 0 n; loop ()
  in
  loop ();
  Unix.close s;
  let raw = Buffer.contents buf in
  let status =
    match String.split_on_char ' ' raw with
    | _ :: code :: _ -> (try int_of_string code with _ -> 0)
    | _ -> 0
  in
  let body =
    match Str.bounded_split_delim (Str.regexp_string "\r\n\r\n") raw 2 with
    | [ _; b ] -> b
    | _ -> ""
  in
  (status, body)

let wait_for_port () =
  let deadline = Unix.gettimeofday () +. 20.0 in
  let rec loop () =
    if Unix.gettimeofday () > deadline then false
    else
      let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      let ok =
        try
          Unix.connect s (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
          true
        with _ -> false
      in
      (try Unix.close s with _ -> ());
      if ok then true else (Unix.sleepf 0.1; loop ())
  in
  loop ()

let http_tests () =
  let pid =
    Unix.create_process Sys.executable_name
      [| Sys.executable_name; "serve" |] Unix.stdin Unix.stdout Unix.stderr
  in
  let ok = wait_for_port () in
  check "server came up" ok;
  if ok then begin
    let status, body = http_post "/rpc/Orders/reserve" {|["owner-7",2,null]|} in
    check "HTTP valid -> 200"
      (status = 200 && body = {|["Reserved",["owner-7",["ctx:none",null]]]|});
    let status, body = http_post "/rpc/Orders/reserve" {|["owner-7","x",null]|} in
    check "HTTP bad Drut -> 400"
      (status = 400 && String.length body > 0
       && String.sub body 0 (min 10 (String.length body)) = {|{"error":"|});
    let status, _ = http_post "/rpc/Orders/nope" {|null|} in
    check "HTTP unknown method -> 404" (status = 404)
  end;
  Unix.kill pid Sys.sigterm;
  ignore (Unix.waitpid [] pid)

let () =
  if Array.length Sys.argv > 1 && Sys.argv.(1) = "serve" then begin
    register_service ();
    Well.run ~port ()
  end
  else begin
    local_tests ();
    http_tests ();
    Printf.printf "\nW2 consumer: %d passed, %d failed\n" !pass !fail;
    if !fail > 0 then exit 1
  end