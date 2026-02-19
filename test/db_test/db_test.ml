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
  );

  run ~source_file:__FILE__ () |> exit_with_result
