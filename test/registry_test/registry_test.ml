open Well_test

let registry : Well.Registry.t =
  { id = "companies"
  ; table = "registry_companies_test"
  ; title = "Firmy"
  ; fields =
      [ { Well.Registry.name = "name"
        ; label = "Nazwa"
        ; field_type = Well.Registry.String
        ; required = true
        ; unique = true }
      ; { Well.Registry.name = "nip"
        ; label = "NIP"
        ; field_type = Well.Registry.String
        ; required = false
        ; unique = true }
      ; { Well.Registry.name = "regon"
        ; label = "REGON"
        ; field_type = Well.Registry.String
        ; required = false
        ; unique = true } ]
  ; display = ["name"]
  ; soft_delete = true }

let upgrade_registry : Well.Registry.t =
  { id = "upgrade"
  ; table = "registry_upgrade_test"
  ; title = "Upgrade"
  ; fields =
      [ { Well.Registry.name = "name"
        ; label = "Nazwa"
        ; field_type = Well.Registry.String
        ; required = true
        ; unique = true }
      ; { Well.Registry.name = "nip"
        ; label = "NIP"
        ; field_type = Well.Registry.String
        ; required = false
        ; unique = true } ]
  ; display = ["name"]
  ; soft_delete = false }

let values ?(name = "") ?(nip = "") ?(regon = "") () =
  [("name", name); ("nip", nip); ("regon", regon)]

let saved = function
  | Well.Registry.Saved id -> id
  | Well.Registry.Invalid issues ->
      failwith
        ("unexpected validation issues: "
        ^ String.concat ","
            (List.map
               (fun (issue : Well.Registry.issue) -> issue.field)
               issues))

let is_saved = function Well.Registry.Saved _ -> true | _ -> false
let is_invalid = function Well.Registry.Invalid _ -> true | _ -> false

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
            results.(i) <- Some (f i)) )
  in
  while Atomic.get arrived < n do
    Domain.cpu_relax ()
  done;
  Atomic.set go true;
  Array.iter Domain.join domains;
  Array.map (function Some value -> value | None -> assert false) results

let () =
  let dir = Filename.temp_file "well-registry-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  at_exit (fun () ->
      (try
         Array.iter
           (fun name -> Sys.remove (Filename.concat dir name))
           (Sys.readdir dir)
       with _ -> ());
      try Unix.rmdir dir with _ -> ());
  Well.Db.memory_mode := false;
  Well.Db.data_dir := dir;
  Well.Registry.register_tables [registry; upgrade_registry];

  describe "Well.Registry" (fun () ->
      it "admits only one of two concurrent saves with the same unique name"
        (fun () ->
          let results =
            run_concurrently 2 (fun i ->
                Well.Registry.save registry
                  (values ~name:"Concurrent Co"
                     ~nip:(Printf.sprintf "NIP-%d" i) ()) )
          in
          let count pred =
            Array.fold_left
              (fun acc result -> if pred result then acc + 1 else acc)
              0 results
          in
          expect (count is_saved) |> to_equal_int 1;
          expect (count is_invalid) |> to_equal_int 1 ) ;

      it "persists distinct companies whose optional identifiers are blank"
        (fun () ->
          expect
            (Well.Registry.save registry (values ~name:"Blank A" ()) |> is_saved)
          |> to_be_true;
          expect
            (Well.Registry.save registry (values ~name:"Blank B" ()) |> is_saved)
          |> to_be_true;
          let rows = Well.Registry.list_rows registry in
          let names =
            List.filter_map
              (fun (row : Well.Registry.row) -> List.assoc_opt "name" row.values)
              rows
          in
          expect (List.mem "Blank A" names && List.mem "Blank B" names)
          |> to_be_true ) ;

      it "rejects another company's identifier and retains the current value"
        (fun () ->
          match
            Well.Registry.save registry
              (values ~name:"Id A" ~nip:"111" ())
          with
          | Well.Registry.Invalid _ -> failwith "Id A rejected"
          | Well.Registry.Saved a_id -> (
              let b_id =
                saved
                  (Well.Registry.save registry
                     (values ~name:"Id B" ~nip:"222" ()))
              in
              match
                Well.Registry.save registry ~id:b_id
                  (values ~name:"Id B" ~nip:"111" ())
              with
              | Well.Registry.Saved _ -> failwith "duplicate identifier accepted"
              | Well.Registry.Invalid issues ->
                  expect
                    (List.exists
                       (fun (issue : Well.Registry.issue) -> issue.field = "nip")
                       issues)
                  |> to_be_true;
                  let row =
                    match Well.Registry.find_row registry b_id with
                    | Some row -> row
                    | None -> failwith "Id B missing after rejected save"
                  in
                  expect
                    (Option.value ~default:""
                       (List.assoc_opt "nip" row.values))
                  |> to_equal_string "222";
                  ignore a_id ) ) ;

      it "updates a company without changing its own unique values" (fun () ->
          let a_id =
            saved
              (Well.Registry.save registry (values ~name:"Self A" ~nip:"555" ()))
          in
          (match
             Well.Registry.save registry ~id:a_id
               (values ~name:"Self A" ~nip:"555" ())
           with
          | Well.Registry.Saved id -> expect id |> to_equal_string a_id
          | Well.Registry.Invalid _ -> failwith "self update rejected") ) ;

      it "drops legacy unique indexes on upgrade without losing records"
        (fun () ->
          let u_id =
            saved
              (Well.Registry.save upgrade_registry
                 (values ~name:"Legacy U" ()))
          in
          let filename =
            Well.Config.get_string ~default:"app.sqlite" "well.registry.db"
          in
          let raw = Well.Db.open_db ~filename () in
          Fun.protect
            ~finally:(fun () -> ignore (Sqlite3.db_close raw))
            (fun () ->
              ignore
                (Well.Db.exec raw
                   "CREATE UNIQUE INDEX IF NOT EXISTS \
                    \"idx_registry_upgrade_test_nip_unique\" \
                    ON \"registry_upgrade_test\" (\"nip\")"
                   []) ;
              let index_count () =
                Well.Db.query_one raw
                  "SELECT count(*) FROM sqlite_master WHERE type='index' \
                   AND name='idx_registry_upgrade_test_nip_unique'"
                  [] (fun row -> row.int 0)
                |> Option.value ~default:0
              in
              expect (index_count () = 1) |> to_be_true;
              expect
                (Well.Registry.save upgrade_registry
                   (values ~name:"Legacy V" ())
                |> is_saved)
              |> to_be_true;
              expect (index_count () = 0) |> to_be_true;
              let row =
                match Well.Registry.find_row upgrade_registry u_id with
                | Some row -> row
                | None -> failwith "Legacy U missing after upgrade"
              in
              expect
                (Option.value ~default:"" (List.assoc_opt "name" row.values))
              |> to_equal_string "Legacy U" ) ) ) ;

  run ~source_file:__FILE__ () |> exit_with_result