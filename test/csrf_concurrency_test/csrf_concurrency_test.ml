let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then incr pass
  else begin
    incr fail;
    Printf.eprintf "FAIL: %s\n%!" name
  end

let mk_req session_id : Well.request =
  { meth = "GET"; path = "/"; headers = []; body = "";
    params = []; query = []; session_id; _context = [] }

let token_for session_id =
  let resolved =
    Well.resolve
      (Well.csrf (fun req -> Well.text (Well.csrf_token req))
         (mk_req session_id))
  in
  resolved.r_body

let run_concurrently n f =
  let arrived = Atomic.make 0 in
  let go = Atomic.make false in
  let results = Array.make n None in
  let domains =
    Array.init n (fun i ->
      Domain.spawn (fun () ->
        ignore (Atomic.fetch_and_add arrived 1);
        while not (Atomic.get go) do
          Domain.cpu_relax ()
        done;
        results.(i) <- Some (f i)))
  in
  while Atomic.get arrived < n do
    Domain.cpu_relax ()
  done;
  Atomic.set go true;
  Array.iter Domain.join domains;
  Array.map (function Some v -> v | None -> assert false) results

let distinct_sessions n = List.init n (Printf.sprintf "csrf-session-%d")

let () =
  Mirage_crypto_rng_unix.use_default ();
  Well.Db.memory_mode := true;
  let n = 16 in

  let shared_sid = "csrf-shared-session" in
  let shared = run_concurrently n (fun _ -> token_for shared_sid) in
  let first = shared.(0) in
  check "shared session token generated" (first <> "");
  check "shared session token stable under concurrency"
    (Array.for_all (fun t -> t = first) shared);
  check "shared session token persisted" (token_for shared_sid = first);

  let sessions = distinct_sessions n in
  let distinct =
    run_concurrently n (fun i -> token_for (List.nth sessions i))
  in
  check "distinct session tokens non-empty"
    (Array.for_all (fun t -> t <> "") distinct);
  check "distinct session tokens unique"
    (List.length (List.sort_uniq compare (Array.to_list distinct)) = n);
  check "distinct session tokens stable"
    (List.for_all2 (fun t sid -> token_for sid = t)
       (Array.to_list distinct) sessions);

  let stop = Atomic.make false in
  let cleanup_failed = Atomic.make false in
  let cleaner =
    Domain.spawn (fun () ->
      while not (Atomic.get stop) do
        (try Well.Middleware.cleanup_csrf_tokens ()
         with _ -> Atomic.set cleanup_failed true);
        Domain.cpu_relax ()
      done)
  in
  let _ =
    run_concurrently n (fun i ->
      for j = 1 to 40 do
        ignore (token_for (Printf.sprintf "csrf-live-%d-%d" i j))
      done)
  in
  Atomic.set stop true;
  Domain.join cleaner;
  check "cleanup concurrent with writes does not raise"
    (not (Atomic.get cleanup_failed));

  Printf.printf "csrf concurrency tests: %d passed, %d failed\n%!"
    !pass !fail;
  exit (if !fail > 0 then 1 else 0)