open Well_test

let () =
  (* Register a test table *)
  Well.Db.register_table {
    name = "test_users";
    columns = [
      { cname = "id"; sqlite_type = "INTEGER"; primary = true; nullable = false };
      { cname = "name"; sqlite_type = "TEXT"; primary = false; nullable = false };
      { cname = "email"; sqlite_type = "TEXT"; primary = false; nullable = false };
      { cname = "active"; sqlite_type = "INTEGER"; primary = false; nullable = false };
    ];
  };

  let run_domains count f =
    let domains = List.init count (fun i -> Domain.spawn (fun () -> f i)) in
    List.iter Domain.join domains
  in

  let expect_no_concurrent_leases with_db close =
    let active = Atomic.make 0 in
    let overlapped = Atomic.make false in
    Fun.protect
      ~finally:close
      (fun () ->
        run_domains 16 (fun domain_id ->
          for iteration = 1 to 20 do
            with_db (fun db ->
              if Atomic.fetch_and_add active 1 <> 0 then
                Atomic.set overlapped true;
              Fun.protect
                ~finally:(fun () -> ignore (Atomic.fetch_and_add active (-1)))
                (fun () ->
                  ignore (Well.Db.query db "SELECT ? + ?" [
                    Well.Db.Int domain_id;
                    Well.Db.Int iteration;
                  ] (fun row -> row.int 0));
                  Unix.sleepf 0.001))
          done);
        expect (Atomic.get overlapped) |> to_be_false)
  in

  let with_temp_data_dir f =
    let dir = Filename.temp_file "well-db-test-" "" in
    Sys.remove dir;
    Unix.mkdir dir 0o700;
    Fun.protect
      ~finally:(fun () ->
        Array.iter
          (fun name -> Sys.remove (Filename.concat dir name))
          (Sys.readdir dir);
        Unix.rmdir dir)
      (fun () -> f dir)
  in

  describe "Well.Db" (fun () ->

    describe "with_test_db" (fun () ->
      it "opens in-memory db" (fun () ->
        Well.Db.with_test_db (fun db ->
          let stmt = Sqlite3.prepare db "SELECT 1" in
          let ok = Sqlite3.step stmt = Sqlite3.Rc.ROW in
          ignore (Sqlite3.finalize stmt);
          expect ok |> to_be_true
        )
      );
      it "auto-migrates registered tables" (fun () ->
        Well.Db.with_test_db (fun db ->
          let stmt = Sqlite3.prepare db
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='test_users'" in
          let exists = Sqlite3.step stmt = Sqlite3.Rc.ROW in
          ignore (Sqlite3.finalize stmt);
          expect exists |> to_be_true
        )
      );
      it "table has correct columns" (fun () ->
        Well.Db.with_test_db (fun db ->
          let stmt = Sqlite3.prepare db "PRAGMA table_info(test_users)" in
          let cols = ref [] in
          let rec loop () =
            match Sqlite3.step stmt with
            | Sqlite3.Rc.ROW ->
                let name = match Sqlite3.column stmt 1 with
                  | Sqlite3.Data.TEXT s -> s | _ -> "" in
                cols := name :: !cols;
                loop ()
            | _ -> ()
          in
          loop ();
          ignore (Sqlite3.finalize stmt);
          let cols = !cols in
          expect (List.mem "id" cols) |> to_be_true;
          expect (List.mem "name" cols) |> to_be_true;
          expect (List.mem "email" cols) |> to_be_true;
          expect (List.mem "active" cols) |> to_be_true
        )
      );
    );

    describe "CRUD operations" (fun () ->
      it "insert and select" (fun () ->
        Well.Db.with_test_db (fun db ->
          ignore (Sqlite3.exec db
            "INSERT INTO test_users (name, email, active) VALUES ('alice', 'a@b.com', 1)");
          let stmt = Sqlite3.prepare db "SELECT name FROM test_users WHERE email='a@b.com'" in
          let _ = Sqlite3.step stmt in
          let name = Sqlite3.column_text stmt 0 in
          ignore (Sqlite3.finalize stmt);
          expect name |> to_equal_string "alice"
        )
      );
    );

    describe "diff" (fun () ->
      it "detects new table" (fun () ->
        let db = Sqlite3.db_open ":memory:" in
        (* Don't create any tables — diff should see test_users as needing creation *)
        let diffs = Well.Db.diff db in
        let has_create = List.exists (fun d ->
          match d with
          | Well.Db.Create_table t -> t.name = "test_users"
          | _ -> false
        ) diffs in
        expect has_create |> to_be_true;
        ignore (Sqlite3.db_close db)
      );
      it "detects new column" (fun () ->
        let db = Sqlite3.db_open ":memory:" in
        (* Create table with fewer columns *)
        ignore (Sqlite3.exec db
          "CREATE TABLE test_users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
        let diffs = Well.Db.diff db in
        let has_add = List.exists (fun d ->
          match d with
          | Well.Db.Add_column { table = "test_users"; column } ->
              column.cname = "email" || column.cname = "active"
          | _ -> false
        ) diffs in
        expect has_add |> to_be_true;
        ignore (Sqlite3.db_close db)
      );
    );

    describe "transaction" (fun () ->
      it "commits on success" (fun () ->
        Well.Db.with_test_db (fun db ->
          Well.Db.transaction db (fun db ->
            ignore (Sqlite3.exec db
              "INSERT INTO test_users (name, email, active) VALUES ('tx', 'tx@x.com', 1)")
          );
          let stmt = Sqlite3.prepare db "SELECT COUNT(*) FROM test_users WHERE name='tx'" in
          let _ = Sqlite3.step stmt in
          let count = Int64.to_int (Sqlite3.column_int64 stmt 0) in
          ignore (Sqlite3.finalize stmt);
          expect count |> to_equal_int 1
        )
      );
      it "rolls back on exception" (fun () ->
        Well.Db.with_test_db (fun db ->
          (try
            Well.Db.transaction db (fun db ->
              ignore (Sqlite3.exec db
                "INSERT INTO test_users (name, email, active) VALUES ('fail', 'f@x.com', 1)");
              failwith "boom"
            )
          with Failure _ -> ());
          let stmt = Sqlite3.prepare db "SELECT COUNT(*) FROM test_users WHERE name='fail'" in
          let _ = Sqlite3.step stmt in
          let count = Int64.to_int (Sqlite3.column_int64 stmt 0) in
          ignore (Sqlite3.finalize stmt);
          expect count |> to_equal_int 0
        )
      );
    );

    describe "transaction_result" (fun () ->
      it "commits on Ok" (fun () ->
        Well.Db.with_test_db (fun db ->
          let result = Well.Db.transaction_result db (fun db ->
            ignore (Sqlite3.exec db
              "INSERT INTO test_users (name, email, active) VALUES ('ok', 'ok@x.com', 1)");
            Ok 1
          ) in
          (match result with Ok n -> expect n |> to_equal_int 1 | Error _ -> ());
          let stmt = Sqlite3.prepare db "SELECT COUNT(*) FROM test_users WHERE name='ok'" in
          let _ = Sqlite3.step stmt in
          let count = Int64.to_int (Sqlite3.column_int64 stmt 0) in
          ignore (Sqlite3.finalize stmt);
          expect count |> to_equal_int 1
        )
      );
    );

    describe "connection pools" (fun () ->
      it "leases create_pool connections exclusively across domains" (fun () ->
        let old_memory_mode = !(Well.Db.memory_mode) in
        Well.Db.memory_mode := true;
        Fun.protect
          ~finally:(fun () -> Well.Db.memory_mode := old_memory_mode)
          (fun () ->
            let pool = Well.Db.create_pool ~size:1 ~filename:"pool_concurrency" () in
            expect_no_concurrent_leases
              (fun f -> Well.Db.with_conn pool f)
              (fun () -> Well.Db.close_pool pool))
      );

      it "serializes create_pool callbacks across multiple connections" (fun () ->
        let old_memory_mode = !(Well.Db.memory_mode) in
        let old_data_dir = !(Well.Db.data_dir) in
        Well.Db.memory_mode := false;
        Fun.protect
          ~finally:(fun () ->
            Well.Db.memory_mode := old_memory_mode;
            Well.Db.data_dir := old_data_dir)
          (fun () ->
            with_temp_data_dir @@ fun dir ->
            Well.Db.data_dir := dir;
            let pool = Well.Db.create_pool ~size:4 ~filename:"pool_serial.sqlite" () in
            expect_no_concurrent_leases
              (fun f -> Well.Db.with_conn pool f)
              (fun () -> Well.Db.close_pool pool))
      );

      it "returns create_pool connections when callbacks raise" (fun () ->
        let old_memory_mode = !(Well.Db.memory_mode) in
        Well.Db.memory_mode := true;
        Fun.protect
          ~finally:(fun () -> Well.Db.memory_mode := old_memory_mode)
          (fun () ->
            let pool = Well.Db.create_pool ~size:1 ~filename:"pool_raise" () in
            Fun.protect
              ~finally:(fun () -> Well.Db.close_pool pool)
              (fun () ->
                (try
                   Well.Db.with_conn pool (fun _db -> failwith "expected")
                 with Failure _ -> ());
                Well.Db.with_conn pool (fun db ->
                  let rows = Well.Db.query db "SELECT 1" [] (fun row -> row.int 0) in
                  expect (List.hd rows) |> to_equal_int 1)))
      );

      it "leases well.sqlite connections exclusively across domains" (fun () ->
        let old_memory_mode = !(Well.Db.memory_mode) in
        Well.Db.close_well_db ();
        Well.Db.memory_mode := true;
        Fun.protect
          ~finally:(fun () ->
            Well.Db.close_well_db ();
            Well.Db.memory_mode := old_memory_mode)
          (fun () ->
            expect_no_concurrent_leases
              (fun f -> Well.Db.with_well_db f)
              Well.Db.close_well_db)
      );

      it "serializes well.sqlite callbacks across multiple connections" (fun () ->
        let old_memory_mode = !(Well.Db.memory_mode) in
        let old_data_dir = !(Well.Db.data_dir) in
        Well.Db.close_well_db ();
        Well.Db.memory_mode := false;
        Fun.protect
          ~finally:(fun () ->
            Well.Db.close_well_db ();
            Well.Db.memory_mode := old_memory_mode;
            Well.Db.data_dir := old_data_dir)
          (fun () ->
            with_temp_data_dir @@ fun dir ->
            Well.Db.data_dir := dir;
            expect_no_concurrent_leases
              (fun f -> Well.Db.with_well_db f)
              Well.Db.close_well_db)
      );
    );
  );

  run ~source_file:__FILE__ () |> exit_with_result
