open Well_test

let find_http meth route rows =
  List.find_opt
    (fun (row : Well.Metrics.http_row) -> row.meth = meth && row.route = route)
    rows

let find_service rpc rows =
  List.find_opt (fun (row : Well.Metrics.service_row) -> row.rpc = rpc) rows

let cookie_of headers =
  match
    List.find_map
      (fun (k, v) ->
        if String.lowercase_ascii k = "set-cookie" then Some v else None)
      headers
  with
  | None -> None
  | Some cookie ->
      let pair =
        match String.index_opt cookie ';' with
        | Some i -> String.sub cookie 0 i
        | None -> cookie
      in
      Some (String.trim pair)

let () =
  Well.Db.memory_mode := true;
  Well.Metrics._reset ();

  describe "Metrics" (fun () ->
      describe "aggregates" (fun () ->
          it "keeps one row per route template and splits status classes" (fun () ->
              Well.Metrics._reset ();
              for _ = 1 to 100 do
                Well.Metrics.observe_http ~class_:"app" ~meth:"GET" ~route:"/users/:id"
                  ~status:200 ~us:100
              done;
              Well.Metrics.observe_http ~class_:"app" ~meth:"GET" ~route:"/users/:id"
                ~status:404 ~us:100;
              Well.Metrics.observe_http ~class_:"static" ~meth:"GET" ~route:"/assets/*"
                ~status:200 ~us:50;
              let app = Well.Metrics.http_summary ~minutes:60 in
              let users =
                List.find
                  (fun (row : Well.Metrics.http_row) -> row.route = "/users/:id")
                  app
              in
              expect users.count |> to_equal_int 101;
              expect users.c2xx |> to_equal_int 100;
              expect users.c4xx |> to_equal_int 1;
              expect users.mean_us |> to_equal_int 100;
              expect users.p95_us |> to_equal_int 1000;
              let statics =
                List.filter (fun (row : Well.Metrics.http_row) -> row.class_ = "static") app
              in
              expect (List.length statics) |> to_equal_int 1);

          it "skips a muted method until the deadline passes" (fun () ->
              Well.Metrics._reset ();
              Well.Service.register_handler "MetricsProbe"
                { dispatch = (fun rpc _ _ ->
                      if rpc = "boom" then `Assoc [("error", `String "no")]
                      else `Assoc [("ok", `Bool true)])
                ; rpcs = []
                ; kind = `Service };
              ignore (Well.Service.dispatch_by_name "MetricsProbe" "ping" `Null `Null);
              ignore (Well.Service.dispatch_by_name "MetricsProbe" "boom" `Null `Null);
              let before = Well.Metrics.service_summary ~minutes:60 in
              let ping = find_service "ping" before in
              let boom = find_service "boom" before in
              expect (match ping with Some r -> r.ok | None -> 0) |> to_equal_int 1;
              expect (match boom with Some r -> r.err | None -> 0) |> to_equal_int 1;
              Well.Metrics.mute ~service:"MetricsProbe" ~rpc:"ping"
                ~until_unix:(Unix.gettimeofday () +. 3600.);
              ignore (Well.Service.dispatch_by_name "MetricsProbe" "ping" `Null `Null);
              let during = Well.Metrics.service_summary ~minutes:60 in
              expect
                (match find_service "ping" during with Some r -> r.count | None -> 0)
                |> to_equal_int 1;
              Well.Metrics._forget_cache ();
              let restored = Well.Metrics.active_mutes () in
              expect (List.exists (fun (m : Well.Metrics.mute) -> m.rpc = "ping") restored)
                |> to_be_true;
              Well.Metrics.unmute ~service:"MetricsProbe" ~rpc:"ping";
              ignore (Well.Service.dispatch_by_name "MetricsProbe" "ping" `Null `Null);
              let after = Well.Metrics.service_summary ~minutes:60 in
              expect
                (match find_service "ping" after with Some r -> r.count | None -> 0)
                |> to_equal_int 2);

          it "leaves a disabled service unmeasured until it is enabled" (fun () ->
              Well.Metrics._reset ();
              Well.Service.register_handler "MetricsOff"
                { dispatch = (fun _ _ _ -> `Assoc [("ok", `Bool true)])
                ; rpcs = []
                ; kind = `Service };
              let count () =
                match
                  find_service "ping" (Well.Metrics.service_summary ~minutes:60)
                with
                | Some row -> row.count
                | None -> 0
              in
              ignore (Well.Service.dispatch_by_name "MetricsOff" "ping" `Null `Null);
              expect (count ()) |> to_equal_int 1;
              Well.Metrics.disable_service ~service:"MetricsOff";
              ignore (Well.Service.dispatch_by_name "MetricsOff" "ping" `Null `Null);
              expect (count ()) |> to_equal_int 1;
              Well.Metrics._forget_cache ();
              expect (Well.Metrics.service_disabled "MetricsOff") |> to_be_true;
              ignore (Well.Service.dispatch_by_name "MetricsOff" "ping" `Null `Null);
              expect (count ()) |> to_equal_int 1;
              Well.Metrics.observe_http ~class_:"app" ~meth:"GET" ~route:"/still"
                ~status:200 ~us:100;
              let http = Well.Metrics.http_summary ~minutes:60 in
              expect
                (match find_http "GET" "/still" http with Some row -> row.count | None -> 0)
                |> to_equal_int 1;
              Well.Metrics.enable_service ~service:"MetricsOff";
              ignore (Well.Service.dispatch_by_name "MetricsOff" "ping" `Null `Null);
              expect (count ()) |> to_equal_int 2)));

  let result = run ~source_file:__FILE__ () in
  if result.failed > 0 then exit 1;
  Well.Metrics._reset ();
  let dir =
    Filename.get_temp_dir_name () ^ "/well-metrics-" ^ string_of_int (Unix.getpid ())
  in
  Unix.mkdir dir 0o755;
  let oc = open_out (Filename.concat dir "a.txt") in
  output_string oc "file";
  close_out oc;
  Well.static "/m-assets" dir;
  Well.get "/m/users/:id" (fun req ->
      Well.html ("<p>" ^ Option.value (Well.param req "id") ~default:"" ^ "</p>"));
  Well.get "/m/next" (fun _ -> Well.html "<p>next</p>");
  Well.get "/m/api" (fun _ -> Well.json (`Assoc [("ok", `Bool true)]));
  Well.with_test_server ~disable_cap:true ~workers:1 (fun port ->
      let fail exn =
        prerr_endline (Printexc.to_string exn);
        exit 1
      in
      try
        let url path = Printf.sprintf "http://127.0.0.1:%d%s" port path in
        let first = Well.fetch (url "/m/users/7") in
        expect first.status |> to_equal_int 200;
        let cookie =
          match cookie_of first.headers with
          | Some c -> c
          | None -> failwith "missing session cookie"
        in
        let headers = [("Cookie", cookie)] in
        let second = Well.fetch ~headers (url "/m/users/8") in
        expect second.status |> to_equal_int 200;
        let third = Well.fetch ~headers (url "/m/next") in
        expect third.status |> to_equal_int 200;
        let api = Well.fetch ~headers (url "/m/api") in
        expect api.status |> to_equal_int 200;
        let missing = Well.fetch ~headers (url "/m/missing") in
        expect missing.status |> to_equal_int 404;
        let asset = Well.fetch (url "/m-assets/a.txt") in
        expect asset.status |> to_equal_int 200;
        let http = Well.Metrics.http_summary ~minutes:60 in
        let users = find_http "GET" "/m/users/:id" http in
        expect (match users with Some r -> r.count | None -> 0) |> to_equal_int 2;
        expect (match users with Some r -> r.class_ | None -> "") |> to_equal_string "app";
        let unmatched = find_http "GET" Well.Metrics.unmatched http in
        expect (match unmatched with Some r -> r.c4xx | None -> 0) |> to_be_greater_than 0;
        let statics = find_http "GET" "/m-assets/*" http in
        expect (match statics with Some r -> r.class_ | None -> "")
          |> to_equal_string "static";
        let flow = Well.Metrics.flow_summary ~minutes:60 in
        let has from_route to_route =
          List.exists
            (fun (row : Well.Metrics.flow_row) ->
              row.from_route = from_route && row.to_route = to_route && row.count >= 1)
            flow
        in
        expect (has Well.Metrics.entry "GET /m/users/:id") |> to_be_true;
        expect (has "GET /m/users/:id" "GET /m/next") |> to_be_true;
        expect
          (List.exists
             (fun (row : Well.Metrics.flow_row) ->
               row.to_route = "GET /m/api" || row.from_route = "GET /m/api")
             flow)
          |> to_be_false;
        print_endline "document flow: passed";
        exit 0
      with
      | Assertion_failed _ as exn -> fail exn
      | exn -> fail exn)
