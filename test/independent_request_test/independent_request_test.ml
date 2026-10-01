let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then incr pass
  else begin
    incr fail;
    Printf.eprintf "FAIL: %s\n%!" name
  end

let slow_held = Atomic.make false
let slow_release = Atomic.make false

let () =
  Well.get "/indep/slow" (fun _req ->
    Atomic.set slow_held true;
    while not (Atomic.get slow_release) do
      Unix.sleepf 0.01
    done;
    Well.text "slow");

  Well.get "/indep/fast" (fun _req -> Well.text "fast");

  Well.with_test_server ~disable_cap:true ~workers:4 (fun port ->
    let url path = Printf.sprintf "http://127.0.0.1:%d%s" port path in
    Eio.Switch.run @@ fun sw ->

    let isolated = Well.fetch (url "/indep/fast") in
    check "isolated fast status" (isolated.status = 200);
    check "isolated fast body" (isolated.body = "fast");

    let slow_result = ref None in
    Eio.Fiber.fork ~sw (fun () ->
      slow_result := Some (Well.fetch (url "/indep/slow")));

    let entry_deadline = Unix.gettimeofday () +. 2.0 in
    while (not (Atomic.get slow_held)) && Unix.gettimeofday () < entry_deadline do
      Well.Env.sleep 0.005
    done;
    check "slow handler entered" (Atomic.get slow_held);

    let started = Unix.gettimeofday () in
    let fast =
      try Some (Well.Env.with_timeout 2.0 (fun () -> Well.fetch (url "/indep/fast")))
      with Eio.Time.Timeout -> None
    in
    let elapsed = Unix.gettimeofday () -. started in
    let before_release = not (Atomic.get slow_release) in

    check "fast completed while slow held" (fast <> None);
    (match fast with
     | Some r ->
         check "fast status" (r.status = 200);
         check "fast body" (r.body = "fast")
     | None -> ());
    check "fast arrived before slow release" before_release;
    check "fast not serialized by slow" (elapsed < 1.0);

    Atomic.set slow_release true;
    let slow_deadline = Unix.gettimeofday () +. 2.0 in
    while !slow_result = None && Unix.gettimeofday () < slow_deadline do
      Well.Env.sleep 0.005
    done;
    (match !slow_result with
     | Some r ->
         check "slow status" (r.status = 200);
         check "slow body" (r.body = "slow")
     | None -> check "slow completed" false);

    Printf.printf "independent request tests: %d passed, %d failed\n%!"
      !pass !fail;
    exit (if !fail > 0 then 1 else 0))