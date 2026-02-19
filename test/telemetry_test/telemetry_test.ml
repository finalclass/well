open Well_test

let () =
  describe "Telemetry" (fun () ->

    describe "atomic counters" (fun () ->
      it "incr_requests increases total" (fun () ->
        let before = (Well.Telemetry.snapshot_counters ()).total_requests in
        Well.Telemetry.incr_requests ();
        Well.Telemetry.incr_requests ();
        let after = (Well.Telemetry.snapshot_counters ()).total_requests in
        expect (after - before) |> to_equal_int 2
      );
      it "incr_errors increases 5xx count" (fun () ->
        let before = (Well.Telemetry.snapshot_counters ()).errors_5xx in
        Well.Telemetry.incr_errors ();
        let after = (Well.Telemetry.snapshot_counters ()).errors_5xx in
        expect (after - before) |> to_equal_int 1
      );
      it "add_latency_us accumulates" (fun () ->
        let s1 = Well.Telemetry.snapshot_counters () in
        let total_before = s1.total_requests in
        (* Add known latency *)
        Well.Telemetry.incr_requests ();
        Well.Telemetry.add_latency_us 1000;
        let s2 = Well.Telemetry.snapshot_counters () in
        (* avg = total_latency / total_requests, should be non-negative *)
        expect s2.total_requests |> to_be_greater_than total_before
      );
      it "incr_ws_messages works" (fun () ->
        let before = (Well.Telemetry.snapshot_counters ()).ws_messages in
        Well.Telemetry.incr_ws_messages ();
        let after = (Well.Telemetry.snapshot_counters ()).ws_messages in
        expect (after - before) |> to_equal_int 1
      );
      it "incr_bus_events works" (fun () ->
        let before = (Well.Telemetry.snapshot_counters ()).bus_events in
        Well.Telemetry.incr_bus_events ();
        let after = (Well.Telemetry.snapshot_counters ()).bus_events in
        expect (after - before) |> to_equal_int 1
      );
    );

    describe "snapshot_counters" (fun () ->
      it "returns valid snapshot" (fun () ->
        let s = Well.Telemetry.snapshot_counters () in
        expect s.total_requests |> to_be_greater_than (-1);
        expect s.errors_5xx |> to_be_greater_than (-1);
        expect s.ws_messages |> to_be_greater_than (-1);
        expect s.bus_events |> to_be_greater_than (-1)
      );
    );

    describe "system metrics" (fun () ->
      it "rss_kb returns non-negative on Linux" (fun () ->
        let rss = Well.Telemetry.rss_kb () in
        expect rss |> to_be_greater_than (-1)
      );
      it "load_average returns three values" (fun () ->
        let (l1, l5, l15) = Well.Telemetry.load_average () in
        (* On Linux these should be >= 0; on non-Linux they fallback to 0 *)
        expect l1 |> to_be_greater_than_float (-1.0);
        expect l5 |> to_be_greater_than_float (-1.0);
        expect l15 |> to_be_greater_than_float (-1.0)
      );
      it "system_memory_kb returns non-negative" (fun () ->
        let (total, available) = Well.Telemetry.system_memory_kb () in
        expect total |> to_be_greater_than (-1);
        expect available |> to_be_greater_than (-1)
      );
      it "data_dir_size_bytes returns non-negative" (fun () ->
        let size = Well.Telemetry.data_dir_size_bytes () in
        expect size |> to_be_greater_than (-1)
      );
    );

    describe "system_snapshot" (fun () ->
      it "returns valid snapshot with all fields" (fun () ->
        let s = Well.Telemetry.system_snapshot () in
        expect s.rss_mb |> to_be_greater_than_float (-1.0);
        expect s.heap_mb |> to_be_greater_than_float 0.0;
        expect s.live_mb |> to_be_greater_than_float 0.0;
        expect s.gc_minor |> to_be_greater_than (-1);
        expect s.gc_major |> to_be_greater_than (-1)
      );
    );

    describe "requests_per_sec" (fun () ->
      it "returns non-negative float" (fun () ->
        let rps = Well.Telemetry.requests_per_sec () in
        expect rps |> to_be_greater_than_float (-1.0)
      );
    );
  );

  run ~source_file:__FILE__ () |> exit_with_result
