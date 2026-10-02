(* W4 in-repo acceptance for the socket transport, introspection and the
   legacy Actor.

   The socket hands the original payload text to the text-Drut handler; a
   number in that payload is never rounded by frame parsing. Introspection
   (list/describe/health) and the preserved [dispatch_by_name] entry cover
   text-Drut services as well as legacy Service/Actor entries.

   Plain executable (not the Well_test runner): the Eio server must run in a
   single unredirected Eio event loop for the whole process. *)

let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then begin incr pass; Printf.printf "ok   %s\n%!" name end
  else begin incr fail; Printf.printf "FAIL %s\n%!" name end

let socket_dir () =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "well-w4-%d-%d" (Unix.getpid ()) (Random.int 1_000_000)) in
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let int_literal s =
  let n = String.length s in
  n > 0
  && (let start = if s.[0] = '-' then 1 else 0 in
      start < n
      && (let ok = ref true in
          for i = start to n - 1 do
            if not (s.[i] >= '0' && s.[i] <= '9') then ok := false
          done;
          !ok))

let json_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let raw_seen : string list ref = ref []

let strict_spec =
  { Well.Service.dname = "OrdersDemo";
    drpcs =
      [ { Well.Service.rname = "echoInt";
          params = [ { Well.Service.pname = "value"; ptype = "int"; poptional = false } ];
          returns = [ { Well.Service.pname = "value"; ptype = "int"; poptional = false } ];
          returns_name = "IntEcho" } ];
    dhandler =
      (fun rpc _ctx payload_text ->
        if rpc <> "echoInt" then
          Error (Well.Service.Drut_dispatch_error ("unknown rpc: " ^ rpc))
        else begin
          raw_seen := payload_text :: !raw_seen;
          let t = String.trim payload_text in
          let n = String.length t in
          let inner =
            if n >= 2 && t.[0] = '[' && t.[n - 1] = ']' then String.sub t 1 (n - 2)
            else t
          in
          if int_literal inner then Ok ("[" ^ inner ^ "]")
          else Error (Well.Service.Drut_request_error ("not an integer: " ^ inner))
        end);
    dset_ref = (fun _ -> ()) }

let slow_spec =
  { Well.Service.dname = "SlowDemo";
    drpcs =
      [ { Well.Service.rname = "wait";
          params = [];
          returns = [];
          returns_name = "void" } ];
    dhandler =
      (fun _rpc _ctx _payload ->
        Well.Env.sleep 0.3;
        Ok "null");
    dset_ref = (fun _ -> ()) }

let send_line ~sw ~net path line =
  let flow = Eio.Net.connect ~sw net (`Unix path) in
  Eio.Flow.copy_string (line ^ "\n") flow;
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let resp = Eio.Buf_read.line reader in
  Eio.Flow.close flow;
  resp

let frame service rpc payload =
  Printf.sprintf {|{"service":%S,"rpc":%S,"payload":%s}|} service rpc payload

let test_introspection () =
  Hashtbl.replace Well.Service.drut_handlers "OrdersDemo" strict_spec;
  Fun.protect
    ~finally:(fun () -> Hashtbl.remove Well.Service.drut_handlers "OrdersDemo")
    (fun () ->
      check "list_services includes text-Drut service"
        (List.mem_assoc "OrdersDemo" (Well.Service.list_services ()));
      let listed = List.assoc "OrdersDemo" (Well.Service.list_services ()) in
      check "list_services carries the rpc name" (List.mem "echoInt" listed);
      let desc = Well.Service.describe_services () in
      let rpc_info = json_field "OrdersDemo" desc in
      check "describe_services includes text-Drut service" (rpc_info <> None);
      (match rpc_info with
       | Some (`Assoc methods) ->
         (match List.assoc_opt "echoInt" methods with
          | Some info ->
            (match json_field "params" info with
             | Some (`List (p :: _)) ->
               check "canonical param name"
                 (Yojson.Safe.to_string (Option.get (json_field "name" p)) = {|"value"|});
               check "canonical param type"
                 (Yojson.Safe.to_string (Option.get (json_field "type" p)) = {|"int"|})
             | _ -> check "canonical params" false)
          | None -> check "describe has echoInt" false)
       | _ -> check "describe shape" false);
      check "full_health includes text-Drut service"
        (List.mem_assoc "OrdersDemo" (Well.Service.full_health ())))

let test_socket_raw ~sw ~net ~path =
  raw_seen := [];
  let resp = send_line ~sw ~net path (frame "OrdersDemo" "echoInt" "[1.0000000000000001]") in
  let json = Yojson.Safe.from_string resp in
  check "fractional Int rejected over socket" (json_field "error" json <> None);
  (match !raw_seen with
   | raw :: _ ->
     check "raw payload text preserved verbatim" (raw = "[1.0000000000000001]")
   | [] -> check "handler saw payload" false);
  (* The failed call must not block the next one. *)
  let resp2 = send_line ~sw ~net path (frame "OrdersDemo" "echoInt" "[2]") in
  let json2 = Yojson.Safe.from_string resp2 in
  check "valid call after rejection"
    (Yojson.Safe.to_string (Option.get (json_field "result" json2)) = "[2]")

let test_socket_system ~sw ~net ~path =
  let resp = send_line ~sw ~net path (frame "_system" "list" "null") in
  let json = Yojson.Safe.from_string resp in
  (match json_field "result" json with
   | Some (`Assoc services) -> check "_system list includes service" (List.mem_assoc "OrdersDemo" services)
   | _ -> check "_system list shape" false);
  let resp = send_line ~sw ~net path (frame "_system" "describe" "null") in
  let json = Yojson.Safe.from_string resp in
  (match json_field "result" json with
   | Some (`Assoc services) -> check "_system describe includes service" (List.mem_assoc "OrdersDemo" services)
   | _ -> check "_system describe shape" false);
  let resp = send_line ~sw ~net path (frame "_system" "health" "null") in
  let json = Yojson.Safe.from_string resp in
  (match json_field "result" json with
   | Some (`Assoc statuses) ->
     check "_system health includes service" (List.assoc_opt "OrdersDemo" statuses <> None)
   | _ -> check "_system health shape" false)

let test_socket_legacy_failure ~sw ~net ~path =
  let calls = ref 0 in
  Well.Service.register_handler "LegacyBoom"
    { Well.Service.dispatch =
        (fun _rpc _ctx _payload ->
          incr calls;
          if !calls = 1 then failwith "boom" else `String "ok");
      rpcs = [ { Well.Service.rname = "Go"; params = []; returns = []; returns_name = "void" } ];
      kind = `Service };
  Fun.protect
    ~finally:(fun () -> Hashtbl.remove Well.Service.handlers "LegacyBoom")
    (fun () ->
      let resp = send_line ~sw ~net path (frame "LegacyBoom" "Go" "null") in
      let json = Yojson.Safe.from_string resp in
      check "legacy handler exception -> error" (json_field "error" json <> None);
      let resp2 = send_line ~sw ~net path (frame "LegacyBoom" "Go" "null") in
      let json2 = Yojson.Safe.from_string resp2 in
      check "legacy handler works after failure"
        (Yojson.Safe.to_string (Option.get (json_field "result" json2)) = {|"ok"|}))

let test_concurrency ~sw ~net ~path =
  let started = Unix.gettimeofday () in
  let one () = ignore (send_line ~sw ~net path (frame "SlowDemo" "wait" "null")) in
  Eio.Fiber.both one one;
  let elapsed = Unix.gettimeofday () -. started in
  check "two service calls run concurrently" (elapsed < 0.55)

let test_legacy_actor ~sw =
  let seen = ref [] in
  let spec =
    { Well.Service.name = "EchoActorW4";
      handler =
        (fun rpc _ctx payload ->
          match rpc with
          | "Echo" -> seen := payload :: !seen; payload
          | "Boom" -> failwith "actor boom"
          | _ -> `Null);
      set_ref = ignore;
      rpcs =
        [ { Well.Service.rname = "Echo"; params = []; returns = []; returns_name = "void" };
          { Well.Service.rname = "Boom"; params = []; returns = []; returns_name = "void" } ] }
  in
  Well.Actor.register ~restart:Well.Actor.Permanent spec;
  Well.Actor.start_all ~sw;
  for i = 1 to 3 do
    ignore (Well.Actor.dispatch "EchoActorW4" "Echo" `Null (`Int i))
  done;
  check "mailbox order preserved"
    (Yojson.Safe.to_string (`List !seen) = "[3,2,1]");
  (match Well.Actor.dispatch "EchoActorW4" "Boom" `Null `Null with
   | `Assoc fields -> check "actor handler exception is isolated" (List.mem_assoc "error" fields)
   | _ -> check "actor handler exception is isolated" false);
  check "actor serves after failure"
    (Yojson.Safe.to_string (Well.Actor.dispatch "EchoActorW4" "Echo" `Null (`Int 4)) = "4");
  check "supervised actor still running"
    (List.assoc_opt "EchoActorW4" (Well.Actor.health ()) = Some "running")

let test_failure_cleanup ~net dir =
  let path = Filename.concat dir "cleanup.sock" in
  let original = Failure "io_uring is not available (ENOMEM)" in
  let captured =
    match
      Eio.Switch.run @@ fun sw ->
      Well.Service.start_socket ~sw ~net path;
      Eio.Switch.fail sw original
    with
    | () -> None
    | exception exn -> Some exn
  in
  check "failure cleanup preserves the original failure"
    (match captured with
     | Some (Failure message) -> message = "io_uring is not available (ENOMEM)"
     | _ -> false);
  check "failure cleanup removes the socket path"
    (not (Sys.file_exists path))

let () =
  test_introspection ();
  Eio_main.run @@ fun env ->
  Well.Env.set env;
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let dir = socket_dir () in
  let path = Filename.concat dir "well.sock" in
  Hashtbl.replace Well.Service.drut_handlers "OrdersDemo" strict_spec;
  Hashtbl.replace Well.Service.drut_handlers "SlowDemo" slow_spec;
  Well.Service.start_socket ~sw ~net path;
  Fun.protect
    ~finally:(fun () ->
      Hashtbl.remove Well.Service.drut_handlers "OrdersDemo";
      Hashtbl.remove Well.Service.drut_handlers "SlowDemo")
    (fun () ->
      test_socket_raw ~sw ~net ~path;
      test_socket_system ~sw ~net ~path;
      test_socket_legacy_failure ~sw ~net ~path;
      test_concurrency ~sw ~net ~path;
      test_legacy_actor ~sw;
      test_failure_cleanup ~net dir);
  Printf.printf "\nW4 socket test: %d passed, %d failed\n%!" !pass !fail;
  exit (if !fail > 0 then 1 else 0)