let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then incr pass
  else begin
    incr fail;
    Printf.eprintf "FAIL: %s\n%!" name
  end

let has_header name resp =
  List.exists (fun (k, _) -> String.lowercase_ascii k = String.lowercase_ascii name) resp.Well.headers

let get_header name resp =
  List.find_map (fun (k, v) ->
    if String.lowercase_ascii k = String.lowercase_ascii name then Some v else None
  ) resp.Well.headers

let () =
  (* ── Unit tests ─────────────────────────────────────────────────── *)

  (* request_id generation *)
  let id1 = Well.generate_request_id () in
  let id2 = Well.generate_request_id () in
  check "request_id length" (String.length id1 = 16);
  check "request_id unique" (id1 <> id2);

  (* session_id crypto entropy — should be 64 hex chars *)
  Mirage_crypto_rng_unix.use_default ();
  let sid1 = Well.generate_session_id () in
  let sid2 = Well.generate_session_id () in
  check "session_id length 64" (String.length sid1 = 64);
  check "session_id unique" (sid1 <> sid2);
  check "session_id hex chars" (
    String.to_seq sid1 |> Seq.for_all (fun c ->
      (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')));

  (* parse_range_header unit tests *)
  let pr = Well.parse_range_header in
  check "range: bytes=0-499" (pr [("range", "bytes=0-499")] 1000 = Some (0, 499));
  check "range: bytes=500-999" (pr [("range", "bytes=500-999")] 1000 = Some (500, 999));
  check "range: bytes=500-" (pr [("range", "bytes=500-")] 1000 = Some (500, 999));
  check "range: bytes=-200" (pr [("range", "bytes=-200")] 1000 = Some (800, 999));
  check "range: no header" (pr [] 1000 = None);
  check "range: invalid past end" (pr [("range", "bytes=1500-2000")] 1000 = Some (-1, -1));
  check "range: multipart rejected" (pr [("range", "bytes=0-100, 200-300")] 1000 = None);

  (* allowed_hosts middleware unit test *)
  let mw = Well.allowed_hosts ~hosts:["example.com"; "localhost"] () in
  let mk_req ?(headers=[]) () : Well.request =
    { meth = "GET"; path = "/"; headers; body = "";
      params = []; query = []; session_id = "test"; _context = [] }
  in
  let test_handler _req = Well.text "ok" in
  (match mw test_handler (mk_req ~headers:[("host", "example.com")] ()) with
   | `Text "ok" -> check "allowed_hosts: valid host" true
   | _ -> check "allowed_hosts: valid host" false);
  (match mw test_handler (mk_req ~headers:[("host", "localhost:4000")] ()) with
   | `Text "ok" -> check "allowed_hosts: valid host with port" true
   | _ -> check "allowed_hosts: valid host with port" false);
  (match mw test_handler (mk_req ~headers:[("host", "evil.com")] ()) with
   | `Custom c when c.status = Some 403 -> check "allowed_hosts: rejected" true
   | _ -> check "allowed_hosts: rejected" false);
  (match mw test_handler (mk_req ~headers:[] ()) with
   | `Text "ok" -> check "allowed_hosts: no host header passes" true
   | _ -> check "allowed_hosts: no host header passes" false);

  (* secure_headers middleware unit test *)
  let sh = Well.secure_headers () in
  let resp = sh test_handler (mk_req ()) in
  let rec collect_headers (resp : Well.response) =
    match resp with
    | `Custom c ->
        let inner = collect_headers c.Well.body in
        c.Well.headers @ inner
    | _ -> []
  in
  let hdrs = collect_headers resp in
  check "secure_headers: CSP" (List.assoc_opt "Content-Security-Policy" hdrs <> None);
  check "secure_headers: X-Frame-Options" (List.assoc_opt "X-Frame-Options" hdrs = Some "DENY");
  check "secure_headers: X-Content-Type-Options" (List.assoc_opt "X-Content-Type-Options" hdrs = Some "nosniff");
  check "secure_headers: Referrer-Policy" (List.assoc_opt "Referrer-Policy" hdrs <> None);
  check "secure_headers: HSTS" (List.assoc_opt "Strict-Transport-Security" hdrs <> None);

  (* ── Integration tests ──────────────────────────────────────────── *)

  (* Register test routes before starting server *)
  Well.get "/t/plain" (fun _req -> Well.text "hello");
  Well.post "/t/post-only" (fun _req -> Well.text "posted");
  Well.get "/t/error" (fun _req -> failwith "secret-internal-error-detail");
  Well.get "/t/session-regen" (fun req ->
    let _new_req, set_cookie = Well.session_regenerate req in
    Well.text "regenerated" |> set_cookie);

  (* Security headers test route *)
  Well.use (Well.secure_headers ());

  (* Static files for range request testing *)
  let test_static_dir = "/tmp/well_test_static" in
  (try Unix.mkdir test_static_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let test_file = Filename.concat test_static_dir "testfile.txt" in
  let test_content = String.make 1000 'A' in
  let oc = open_out test_file in
  output_string oc test_content;
  close_out oc;
  Well.static "/static" test_static_dir;

  Well.with_test_server ~disable_cap:true (fun port ->
    let url path = Printf.sprintf "http://127.0.0.1:%d%s" port path in

    (* ── X-Request-ID ─────────────────────────────────────────────── *)
    let resp = Well.fetch (url "/t/plain") in
    check "X-Request-ID present" (has_header "X-Request-ID" resp);
    let rid = get_header "X-Request-ID" resp in
    check "X-Request-ID non-empty" (match rid with Some s -> String.length s > 0 | None -> false);

    (* Forwarded request ID *)
    let resp = Well.fetch ~headers:[("X-Request-ID", "my-custom-id")] (url "/t/plain") in
    check "X-Request-ID forwarded" (get_header "X-Request-ID" resp = Some "my-custom-id");

    (* ── Security headers ─────────────────────────────────────────── *)
    let resp = Well.fetch (url "/t/plain") in
    check "CSP header present" (has_header "Content-Security-Policy" resp);
    check "X-Frame-Options present" (has_header "X-Frame-Options" resp);
    check "X-Content-Type-Options present" (has_header "X-Content-Type-Options" resp);
    check "Referrer-Policy present" (has_header "Referrer-Policy" resp);
    check "HSTS present" (has_header "Strict-Transport-Security" resp);

    (* ── /health ──────────────────────────────────────────────────── *)
    let resp = Well.fetch (url "/health") in
    check "/health 200" (resp.status = 200);

    (* ── /ready ───────────────────────────────────────────────────── *)
    let resp = Well.fetch (url "/ready") in
    check "/ready 200" (resp.status = 200);
    check "/ready body" (String.length resp.body > 0);
    let json = Yojson.Safe.from_string resp.body in
    let status_val = Yojson.Safe.Util.(json |> member "status" |> to_string) in
    check "/ready status=ready" (status_val = "ready");

    (* ── /metrics ─────────────────────────────────────────────────── *)
    let resp = Well.fetch (url "/metrics") in
    check "/metrics 200" (resp.status = 200);
    check "/metrics content-type" (
      match get_header "Content-Type" resp with
      | Some ct -> String.length ct > 0 && String.sub ct 0 10 = "text/plain"
      | None -> false);
    check "/metrics has requests_total" (
      let _ = Str.search_forward (Str.regexp "well_http_requests_total") resp.body 0 in true);
    check "/metrics has errors_5xx" (
      try let _ = Str.search_forward (Str.regexp "well_http_errors_5xx_total") resp.body 0 in true
      with Not_found -> false);
    check "/metrics has latency" (
      try let _ = Str.search_forward (Str.regexp "well_http_latency_avg_us") resp.body 0 in true
      with Not_found -> false);
    check "/metrics has rps" (
      try let _ = Str.search_forward (Str.regexp "well_http_requests_per_second") resp.body 0 in true
      with Not_found -> false);
    check "/metrics has ws_messages" (
      try let _ = Str.search_forward (Str.regexp "well_ws_messages_total") resp.body 0 in true
      with Not_found -> false);
    check "/metrics has active_connections" (
      try let _ = Str.search_forward (Str.regexp "well_active_connections") resp.body 0 in true
      with Not_found -> false);
    check "/metrics has cpu" (
      try let _ = Str.search_forward (Str.regexp "well_process_cpu_percent") resp.body 0 in true
      with Not_found -> false);
    check "/metrics has rss" (
      try let _ = Str.search_forward (Str.regexp "well_process_rss_bytes") resp.body 0 in true
      with Not_found -> false);
    check "/metrics has gc" (
      try let _ = Str.search_forward (Str.regexp "well_gc_major_collections_total") resp.body 0 in true
      with Not_found -> false);
    check "/metrics has uptime" (
      try let _ = Str.search_forward (Str.regexp "well_uptime_seconds") resp.body 0 in true
      with Not_found -> false);

    (* ── Keep-alive (Connection header) ───────────────────────────── *)
    (* Well.fetch sends Connection: close by default, so test explicit keep-alive *)
    let resp = Well.fetch ~headers:[("Connection", "keep-alive")] (url "/t/plain") in
    let conn_header = get_header "Connection" resp in
    check "keep-alive: explicit keep-alive" (conn_header = Some "keep-alive");

    let resp = Well.fetch ~headers:[("Connection", "close")] (url "/t/plain") in
    let conn_header = get_header "Connection" resp in
    check "keep-alive: respects close" (conn_header = Some "close");

    (* ── Path traversal prevention ─────────────────────────────────── *)
    let resp = Well.fetch (url "/static/%2e%2e/%2e%2e/etc/passwd") in
    check "path traversal %2e%2e blocked" (resp.status = 404);

    let resp = Well.fetch (url "/static/../../../etc/passwd") in
    check "path traversal .. blocked" (resp.status = 404);

    let resp = Well.fetch (url "/static/%00evil") in
    check "path traversal null byte blocked" (resp.status = 404);

    (* ── Range requests ───────────────────────────────────────────── *)
    let resp = Well.fetch (url "/static/testfile.txt") in
    check "static 200" (resp.status = 200);
    check "static Accept-Ranges" (get_header "Accept-Ranges" resp = Some "bytes");
    check "static full body" (String.length resp.body = 1000);

    let resp = Well.fetch ~headers:[("Range", "bytes=0-99")] (url "/static/testfile.txt") in
    check "range 206" (resp.status = 206);
    check "range body length" (String.length resp.body = 100);
    check "range Content-Range present" (has_header "Content-Range" resp);
    let cr = get_header "Content-Range" resp in
    check "range Content-Range value" (cr = Some "bytes 0-99/1000");

    let resp = Well.fetch ~headers:[("Range", "bytes=900-")] (url "/static/testfile.txt") in
    check "range suffix 206" (resp.status = 206);
    check "range suffix body" (String.length resp.body = 100);

    let resp = Well.fetch ~headers:[("Range", "bytes=5000-6000")] (url "/static/testfile.txt") in
    check "range invalid 416" (resp.status = 416);

    (* ── Session regeneration ─────────────────────────────────────── *)
    let resp = Well.fetch (url "/t/session-regen") in
    check "session regen 200" (resp.status = 200);
    check "session regen body" (resp.body = "regenerated");
    let has_set_cookie = List.exists (fun (k, v) ->
      String.lowercase_ascii k = "set-cookie" && String.length v > 20
    ) resp.headers in
    check "session regen Set-Cookie" has_set_cookie;

    (* ── Telemetry active_connections counter ──────────────────────── *)
    let ac = Atomic.get Well.Telemetry.active_connections in
    check "active_connections counter works" (ac >= 0);
    let aw = Atomic.get Well.Telemetry.active_ws_connections in
    check "active_ws_connections counter works" (aw >= 0);

    (* ── HEAD auto-response from GET ────────────────────────────── *)
    let resp = Well.fetch ~method_:"HEAD" (url "/t/plain") in
    check "HEAD on GET route: 200" (resp.status = 200);
    check "HEAD on GET route: empty body" (resp.body = "");

    (* ── 405 Method Not Allowed ─────────────────────────────────── *)
    let resp = Well.fetch ~method_:"DELETE" (url "/t/post-only") in
    check "405 for wrong method" (resp.status = 405);
    let allow = get_header "Allow" resp in
    check "405 has Allow header" (match allow with Some _ -> true | None -> false);

    (* GET on POST-only route should also be 405 *)
    let resp = Well.fetch (url "/t/post-only") in
    check "405 GET on POST route" (resp.status = 405);

    (* ── 500 doesn't leak exception details ─────────────────────── *)
    let resp = Well.fetch (url "/t/error") in
    check "500 status on error" (resp.status = 500);
    check "500 no exception details" (
      not (try let _ = Str.search_forward (Str.regexp "secret-internal") resp.body 0 in true
           with Not_found -> false));
    check "500 generic message" (
      try let _ = Str.search_forward (Str.regexp "Internal Server Error") resp.body 0 in true
      with Not_found -> false);

    (* ── SameSite=Lax in cookies ─────────────────────────────────── *)
    let resp = Well.fetch (url "/t/session-regen") in
    let cookie = List.find_map (fun (k, v) ->
      if String.lowercase_ascii k = "set-cookie" then Some v else None
    ) resp.headers in
    check "SameSite=Lax in cookie" (
      match cookie with
      | Some c ->
          (try let _ = Str.search_forward (Str.regexp "SameSite=Lax") c 0 in true
           with Not_found -> false)
      | None -> false);

    Printf.printf "Hardening tests: %d passed, %d failed\n%!" !pass !fail;
    (* Clean up *)
    (try Sys.remove test_file with _ -> ());
    (try Unix.rmdir test_static_dir with _ -> ());
    exit (if !fail > 0 then 1 else 0)
  )
