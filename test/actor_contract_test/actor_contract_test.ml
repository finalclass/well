open Well_test

let fail msg = raise (Assertion_failed msg)

let () = ignore Actor_reporter_impl.definition; ignore Actor_summary_impl.definition

let examples =
  let rec find = function
    | [] -> failwith "examples dir not found"
    | p :: rest -> if Sys.file_exists (Filename.concat p "Reports.cyrograf") then p else find rest
  in
  find [
    "lib/well/actor/examples";
    "../../lib/well/actor/examples";
    "../../../lib/well/actor/examples";
    "examples";
  ]

let tmp_dir prefix =
  let p = Filename.temp_file prefix "" in
  Sys.remove p;
  Unix.mkdir p 0o700;
  p

let rec rm_rf p =
  if Sys.file_exists p then
    if Sys.is_directory p then begin
      Array.iter (fun n -> rm_rf (Filename.concat p n)) (Sys.readdir p);
      Unix.rmdir p
    end else Sys.remove p

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let compile_incs () =
  let cwd = Sys.getcwd () in
  let rec up p n =
    if n <= 0 then p else up (Filename.dirname p) (n - 1)
  in
  let try_paths =
    [
      Filename.concat cwd "../actor_example_contracts/.actor_example_contracts.objs/byte";
      Filename.concat cwd "../../lib/well/.well.objs/byte";
      Filename.concat cwd "../../lib/well/.well.objs/public_cmi";
      Filename.concat (up cwd 2) "test/actor_example_contracts/.actor_example_contracts.objs/byte";
      Filename.concat (up cwd 2) "lib/well/.well.objs/byte";
      Filename.concat (up cwd 2) "lib/well/.well.objs/public_cmi";
    ]
  in
  let yojson =
    let pkg = Filename.concat cwd "../../../_private/default/.pkg" in
    if not (Sys.file_exists pkg && Sys.is_directory pkg) then []
    else
      Sys.readdir pkg
      |> Array.to_list
      |> List.filter (fun n -> String.length n >= 6 && String.sub n 0 6 = "yojson")
      |> List.map (fun n -> Filename.concat (Filename.concat pkg n) "target/lib/yojson")
  in
  List.filter (fun p -> Sys.file_exists p && Sys.is_directory p) (try_paths @ yojson)

let compiler () =
  if Sys.command "command -v ocamlc.opt >/dev/null 2>&1" = 0 then "ocamlc.opt"
  else "ocamlc"

let compile_snippet src =
  let dir = tmp_dir "c03-neg-" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    let ml = Filename.concat dir "bad.ml" in
    let oc = open_out_bin ml in
    output_string oc src;
    close_out oc;
    let errf = Filename.concat dir "err" in
    let incs =
      compile_incs ()
      |> List.map (fun d -> "-I " ^ Filename.quote d)
      |> String.concat " "
    in
    if incs = "" then fail "C03: contract/well cmi directories not found";
    let cmd =
      Printf.sprintf "%s -c %s %s > %s 2>&1"
        (compiler ()) incs (Filename.quote ml) (Filename.quote errf)
    in
    let st = Sys.command cmd in
    let err = if Sys.file_exists errf then read_file errf else "" in
    st, err)

let contains s sub =
  let n = String.length sub in
  let rec go i =
    if i + n > String.length s then false
    else if String.sub s i n = sub then true
    else go (i + 1)
  in
  go 0

let expect_compile_error src needle =
  let st, err = compile_snippet src in
  if st = 0 then fail ("expected compile error, got success: " ^ err);
  if not (contains err needle) then fail ("compile error missing " ^ needle ^ ": " ^ err)

let jcs_bits hex expected =
  let f = Int64.float_of_bits (Int64.of_string ("0x" ^ hex)) in
  expect (Well.Actor._canonicalize (`Float f)) |> to_equal_string expected

let () =
  Well_test.default_timeout 30.;
  describe "Actor.Contract" (fun () ->
    it "C01 generates types witness inbound outbound impl make descriptor" (fun () ->
      let out = tmp_dir "actor-c01-" in
      Fun.protect ~finally:(fun () -> rm_rf out) (fun () ->
        match Well.Actor.Contract.build ~source_dir:examples ~output_dir:out with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok () ->
          expect (Sys.file_exists (Filename.concat out "descriptor.json")) |> to_be_true;
          let reporter = read_file (Filename.concat out "ocaml/reporter.ml") in
          expect reporter |> to_contain "module Inbound";
          expect reporter |> to_contain "module Outbound";
          expect reporter |> to_contain "module type IMPL";
          expect reporter |> to_contain "let make";
          let reports = read_file (Filename.concat out "ocaml/reports.ml") in
          expect reports |> to_contain "let message_type";
          expect reports |> to_contain "let to_wire";
          expect reports |> to_contain "let of_wire";
          let dune = read_file (Filename.concat out "ocaml/dune") in
          expect dune |> to_contain "well.core";
          expect dune |> to_contain "actor_contracts"));

    it "C02 example impl libraries do not depend on each other" (fun () ->
      let rec find = function
        | [] -> ""
        | p :: rest -> if Sys.file_exists p then p else find rest
      in
      let reporter = find [
        "test/actor_reporter_impl/dune";
        "../../test/actor_reporter_impl/dune";
        "../../../test/actor_reporter_impl/dune";
      ] in
      let summary = find [
        "test/actor_summary_impl/dune";
        "../../test/actor_summary_impl/dune";
        "../../../test/actor_summary_impl/dune";
      ] in
      expect (reporter <> "") |> to_be_true;
      expect (summary <> "") |> to_be_true;
      expect (contains (read_file reporter) "actor_summary_impl") |> to_be_false;
      expect (contains (read_file summary) "actor_reporter_impl") |> to_be_false;
      expect (contains (read_file reporter) "well") |> to_be_true;
      expect (contains (read_file summary) "well") |> to_be_true);

    it "C04 positional wire field order" (fun () ->
      let out = tmp_dir "actor-c04-" in
      Fun.protect ~finally:(fun () -> rm_rf out) (fun () ->
        match Well.Actor.Contract.build ~source_dir:examples ~output_dir:out with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok () ->
          let reports = read_file (Filename.concat out "ocaml_data/reports.ml") in
          expect reports |> to_contain "v.reporter_id";
          expect reports |> to_contain "v.subject";
          expect reports |> to_contain "`List";
          let desc = Yojson.Safe.from_file (Filename.concat out "descriptor.json") in
          let fields_of name =
            match desc with
            | `Assoc root ->
              (match List.assoc "messages" root with
               | `Assoc msgs ->
                 (match List.assoc name msgs with
                  | `Assoc body ->
                    (match List.assoc "schema" body with
                     | `Assoc sch ->
                       (match List.assoc "fields" sch with
                        | `List fs -> fs
                        | _ -> [])
                     | _ -> [])
                  | _ -> [])
               | _ -> [])
            | _ -> []
          in
          let req = fields_of "Reports.Request" in
          expect (List.length req) |> to_equal_int 2;
          (match List.nth req 0 with
           | `Assoc fs ->
             expect (match List.assoc "name" fs with `String s -> s | _ -> "")
             |> to_equal_string "reporter_id";
             expect (match List.assoc "index" fs with `Int n -> n | _ -> -1) |> to_equal_int 0
           | _ -> fail "field 0");
          (match List.nth req 1 with
           | `Assoc fs ->
             expect (match List.assoc "name" fs with `String s -> s | _ -> "")
             |> to_equal_string "subject";
             expect (match List.assoc "index" fs with `Int n -> n | _ -> -1) |> to_equal_int 1
           | _ -> fail "field 1");
          let batch = fields_of "Reports.ReportBatch" in
          (match List.nth batch 0 with
           | `Assoc fs ->
             expect (match List.assoc "name" fs with `String s -> s | _ -> "")
             |> to_equal_string "items";
             expect (match List.assoc "index" fs with `Int n -> n | _ -> -1) |> to_equal_int 0
           | _ -> fail "batch");
          match Well.Actor.Generated.descriptor desc with
          | Error errs -> fail (List.map (fun (e : Well.Actor.error) -> e.message) errs |> String.concat "; ")
          | Ok d ->
            let src = tmp_dir "c04-var-" in
            Fun.protect ~finally:(fun () -> rm_rf src) (fun () ->
              let oc = open_out (Filename.concat src "Var.toml") in
              output_string oc
                "[msg.Choice.variant]\nA = \"string\"\nB = \"int\"\n[msg.Wrap.struct]\nchoice = \"Choice\"\nitems = { type = \"list\", of = \"string\" }\nnote = { type = \"string\", optional = true }\n[actor]\nname = \"VarAct\"\nversion = 1\n[actor.accepts]\nGo = \"Wrap\"\n";
              close_out oc;
              let out2 = tmp_dir "c04-var-out-" in
              Fun.protect ~finally:(fun () -> rm_rf out2) (fun () ->
                match Well.Actor.Contract.build ~source_dir:src ~output_dir:out2 with
                | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
                | Ok () ->
                  let wrap = read_file (Filename.concat out2 "ocaml_data/var.ml") in
                  expect wrap |> to_contain "module Choice";
                  expect wrap |> to_contain "option";
                  expect wrap |> to_contain "list";
                  ignore d))));

    it "C05 rejects actor+service reserved name and unknown type" (fun () ->
      let src = tmp_dir "actor-c05-src-" in
      let out = tmp_dir "actor-c05-out-" in
      Fun.protect ~finally:(fun () -> rm_rf src; rm_rf out) (fun () ->
        let oc = open_out (Filename.concat src "Bad.toml") in
        output_string oc "[service.rpc]\nx = \"A -> B\"\n[actor]\nname = \"__well.join\"\nversion = 1\n[actor.accepts]\nGo = \"Nope.Thing\"\n";
        close_out oc;
        match Well.Actor.Contract.build ~source_dir:src ~output_dir:out with
        | Ok () -> fail "expected errors"
        | Error errs ->
          expect (List.length errs > 0) |> to_be_true;
          expect (Sys.file_exists (Filename.concat out "descriptor.json")) |> to_be_false));

    it "C06 identical generation" (fun () ->
      let out1 = tmp_dir "actor-c06a-" in
      let out2 = tmp_dir "actor-c06b-" in
      Fun.protect ~finally:(fun () -> rm_rf out1; rm_rf out2) (fun () ->
        match
          Well.Actor.Contract.build ~source_dir:examples ~output_dir:out1,
          Well.Actor.Contract.build ~source_dir:examples ~output_dir:out2
        with
        | Ok (), Ok () ->
          expect (read_file (Filename.concat out1 "descriptor.json"))
          |> to_equal_string (read_file (Filename.concat out2 "descriptor.json"));
          expect (read_file (Filename.concat out1 "ocaml/reports.ml"))
          |> to_equal_string (read_file (Filename.concat out2 "ocaml/reports.ml"))
        | _ -> fail "build");
      let src_a = tmp_dir "c06-fa-" in
      let src_b = tmp_dir "c06-fb-" in
      let out_a = tmp_dir "c06-oa-" in
      let out_b = tmp_dir "c06-ob-" in
      Fun.protect ~finally:(fun () -> rm_rf src_a; rm_rf src_b; rm_rf out_a; rm_rf out_b) (fun () ->
        let write dir body =
          let oc = open_out (Filename.concat dir "Msg.toml") in
          output_string oc body; close_out oc
        in
        write src_a "[msg.Rec.struct]\na = \"string\"\nb = \"int\"\n[actor]\nname = \"Ord\"\nversion = 1\n[actor.accepts]\nGo = \"Rec\"\n";
        write src_b "[msg.Rec.struct]\nb = \"int\"\na = \"string\"\n[actor]\nname = \"Ord\"\nversion = 1\n[actor.accepts]\nGo = \"Rec\"\n";
        match
          Well.Actor.Contract.build ~source_dir:src_a ~output_dir:out_a,
          Well.Actor.Contract.build ~source_dir:src_b ~output_dir:out_b
        with
        | Ok (), Ok () ->
          let ha = read_file (Filename.concat out_a "descriptor.json") in
          let hb = read_file (Filename.concat out_b "descriptor.json") in
          expect (ha <> hb) |> to_be_true
        | _ -> fail "field order build"));

    it "C01b split cyrograf and actor.toml equals the legacy mixed TOML" (fun () ->
      let src_native = tmp_dir "actor-c01b-nat-" in
      let src_legacy = tmp_dir "actor-c01b-leg-" in
      let out_native = tmp_dir "actor-c01b-nat-out-" in
      let out_legacy = tmp_dir "actor-c01b-leg-out-" in
      Fun.protect
        ~finally:(fun () ->
          rm_rf src_native; rm_rf src_legacy; rm_rf out_native; rm_rf out_legacy)
        (fun () ->
          let write dir name body =
            let oc = open_out (Filename.concat dir name) in
            output_string oc body; close_out oc
          in
          write src_native "Msg.cyrograf" "struct Request {\n  a: String\n  b: Int\n}\n";
          write src_native "Actor.actor.toml"
            "[actor]\nname = \"Actor\"\nversion = 1\n[actor.accepts]\nGo = \"Msg.Request\"\n[actor.emits]\nOut = \"Msg.Request\"\n";
          write src_legacy "Msg.toml" "[msg.Request.struct]\na = \"string\"\nb = \"int\"\n";
          write src_legacy "Actor.toml"
            "[actor]\nname = \"Actor\"\nversion = 1\n[actor.accepts]\nGo = \"Msg.Request\"\n[actor.emits]\nOut = \"Msg.Request\"\n";
          match
            Well.Actor.Contract.build ~source_dir:src_native ~output_dir:out_native,
            Well.Actor.Contract.build ~source_dir:src_legacy ~output_dir:out_legacy
          with
          | Ok (), Ok () ->
            expect (read_file (Filename.concat out_native "descriptor.json"))
            |> to_equal_string (read_file (Filename.concat out_legacy "descriptor.json"));
            let data = read_file (Filename.concat out_native "ocaml_data/msg.ml") in
            expect data |> to_contain "to_drut";
            expect (Sys.file_exists (Filename.concat out_native "ocaml_data/drut_runtime.ml"))
            |> to_be_true;
            expect (Sys.file_exists (Filename.concat out_native "ocaml/actor.ml")) |> to_be_true
          | _ -> fail "split build"));

    it "C05d legacy unknown top-level key is not silently dropped" (fun () ->
      let src = tmp_dir "actor-c05d-src-" in
      let out = tmp_dir "actor-c05d-out-" in
      Fun.protect ~finally:(fun () -> rm_rf src; rm_rf out) (fun () ->
        let oc = open_out (Filename.concat src "Bad.toml") in
        output_string oc
          "[msg.X.struct]\na = \"string\"\n[bogus]\nx = 1\n[actor]\nname = \"Bad\"\nversion = 1\n[actor.accepts]\nGo = \"X\"\n";
        close_out oc;
        match Well.Actor.Contract.build ~source_dir:src ~output_dir:out with
        | Ok () -> fail "expected unknown top-level key error"
        | Error errs ->
          expect (List.length errs > 0) |> to_be_true;
          expect (Sys.file_exists (Filename.concat out "descriptor.json")) |> to_be_false));

    it "C08 generated of_wire rejects bad arity" (fun () ->
      let out = tmp_dir "actor-c08-" in
      Fun.protect ~finally:(fun () -> rm_rf out) (fun () ->
        match Well.Actor.Contract.build ~source_dir:examples ~output_dir:out with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok () ->
          let desc = Yojson.Safe.from_file (Filename.concat out "descriptor.json") in
          match Well.Actor.Generated.descriptor desc with
          | Error _ -> fail "descriptor"
          | Ok d ->
            match Well.Actor.Generated.message_type d ~name:"Reports.Request"
                    ~encode:(fun x -> x) ~decode:(fun x -> Ok x) with
            | Error e -> fail e.message
            | Ok mt ->
              (match Well.Actor.decode mt (`List [`String "a"]) with
               | Ok _ -> fail "expected reject short array"
               | Error e -> expect e.code |> to_equal_string "InvalidInput");
              (match Well.Actor.decode mt (`Float nan) with
               | Ok _ -> fail "expected reject nan"
               | Error e -> expect e.code |> to_equal_string "InvalidInput")));

    it "C10 foreign output_dir" (fun () ->
      let out = tmp_dir "actor-c10-" in
      Fun.protect ~finally:(fun () -> rm_rf out) (fun () ->
        let oc = open_out (Filename.concat out "foreign.txt") in
        output_string oc "nope";
        close_out oc;
        match Well.Actor.Contract.build ~source_dir:examples ~output_dir:out with
        | Ok () -> fail "should reject foreign files"
        | Error errs -> expect (List.length errs > 0) |> to_be_true));

    it "C03 generated inbound outbound bind witnesses" (fun () ->
      let of_in = function Reporter.Inbound.Generate r -> r.reporter_id in
      let of_out = function Reporter.Outbound.Produced r -> r.source in
      expect (of_in (Reporter.Inbound.Generate (Reports.Request.make ~reporter_id:"a" ~subject:"s" ())))
      |> to_equal_string "a";
      expect (of_out (Reporter.Outbound.Produced (Reports.Report.make ~source:"src" ~text:"t" ())))
      |> to_equal_string "src");

    it "C03 compiler rejects wrong inbound and Message packing" (fun () ->
      expect_compile_error
        "let _ : Reporter.Inbound.t =\n  Reporter.Inbound.Generate (Reports.Summary.make ~text:\"x\" ())\n"
        "Reports.Request.t";
      expect_compile_error
        "let _ = Well.Actor.Message (Reports.Request.message_type, Reports.Summary.make ~text:\"x\" ())\n"
        "Reports.Request.t";
      expect_compile_error
        {|module M : Reporter.IMPL = struct
  type state = unit
  let state_version = 1
  let init _ = ()
  let state_to_wire (_ : state) : Yojson.Safe.t = `Null
  let state_of_wire _ = Ok ()
  let handle _ () = function
    | Reporter.Inbound.Generate _ ->
      Ok ((), [Summary_builder.Outbound.Built (Reports.Summary.make ~text:"x" ())])
end
|}
        "Reporter.Outbound.t");

    it "C05 cycle duplicate and bad type syntax" (fun () ->
      let src = tmp_dir "actor-c05b-src-" in
      let out = tmp_dir "actor-c05b-out-" in
      Fun.protect ~finally:(fun () -> rm_rf src; rm_rf out) (fun () ->
        let write name body =
          let oc = open_out (Filename.concat src name) in
          output_string oc body; close_out oc
        in
        write "Cycle.toml" "[msg.A.struct]\nb = \"B\"\n[msg.B.struct]\na = \"A\"\n[actor]\nname = \"Cyc\"\nversion = 1\n[actor.accepts]\nGo = \"A\"\n";
        (match Well.Actor.Contract.build ~source_dir:src ~output_dir:out with
         | Ok () -> fail "cycle"
         | Error errs ->
           expect (List.length errs > 0) |> to_be_true;
           expect (Sys.file_exists (Filename.concat out "descriptor.json")) |> to_be_false);
        Array.iter (fun n -> Sys.remove (Filename.concat src n)) (Sys.readdir src);
        write "A.toml" "[msg.X.struct]\na = \"string\"\n[actor]\nname = \"Dup\"\nversion = 1\n[actor.accepts]\nGo = \"X\"\n";
        write "B.toml" "[msg.Y.struct]\na = \"string\"\n[actor]\nname = \"Dup\"\nversion = 1\n[actor.accepts]\nGo = \"Y\"\n";
        (match Well.Actor.Contract.build ~source_dir:src ~output_dir:out with
         | Ok () -> fail "duplicate actor"
         | Error errs -> expect (List.length errs > 0) |> to_be_true);
        Array.iter (fun n -> Sys.remove (Filename.concat src n)) (Sys.readdir src);
        write "BadTy.toml" "[msg.Y.struct]\na = \"notatype\"\n[actor]\nname = \"Bad\"\nversion = 1\n[actor.accepts]\nGo = \"Y\"\n";
        match Well.Actor.Contract.build ~source_dir:src ~output_dir:out with
        | Ok () -> fail "bad type"
        | Error errs -> expect (List.length errs > 0) |> to_be_true));

    it "C05 isolated unknown collision reserved actor-service and struct-variant" (fun () ->
      let src = tmp_dir "actor-c05c-src-" in
      let out = tmp_dir "actor-c05c-out-" in
      Fun.protect ~finally:(fun () -> rm_rf src; rm_rf out) (fun () ->
        let write name body =
          let oc = open_out (Filename.concat src name) in
          output_string oc body; close_out oc
        in
        write "Unk.toml" "[msg.X.struct]\na = \"Nope.Thing\"\n[actor]\nname = \"Unk\"\nversion = 1\n[actor.accepts]\nGo = \"X\"\n";
        (match Well.Actor.Contract.build ~source_dir:src ~output_dir:out with
         | Ok () -> fail "unknown name"
         | Error errs ->
           expect (List.length errs > 0) |> to_be_true;
           expect (Sys.file_exists (Filename.concat out "descriptor.json")) |> to_be_false);
        Array.iter (fun n -> Sys.remove (Filename.concat src n)) (Sys.readdir src);
        write "foo.toml" "[msg.A.struct]\na = \"string\"\n[actor]\nname = \"FooA\"\nversion = 1\n[actor.accepts]\nGo = \"A\"\n";
        write "Foo.toml" "[msg.B.struct]\nb = \"string\"\n[actor]\nname = \"FooB\"\nversion = 1\n[actor.accepts]\nGo = \"B\"\n";
        (match Well.Actor.Contract.build ~source_dir:src ~output_dir:out with
         | Ok () -> fail "module collision"
         | Error errs -> expect (List.length errs > 0) |> to_be_true);
        Array.iter (fun n -> Sys.remove (Filename.concat src n)) (Sys.readdir src);
        write "Res.toml" "[msg.X.struct]\na = \"string\"\n[actor]\nname = \"__well.join\"\nversion = 1\n[actor.accepts]\nGo = \"X\"\n";
        (match Well.Actor.Contract.build ~source_dir:src ~output_dir:out with
         | Ok () -> fail "reserved"
         | Error errs -> expect (List.length errs > 0) |> to_be_true);
        Array.iter (fun n -> Sys.remove (Filename.concat src n)) (Sys.readdir src);
        write "Both.toml" "[service.rpc]\nx = \"A -> B\"\n[msg.X.struct]\na = \"string\"\n[actor]\nname = \"Both\"\nversion = 1\n[actor.accepts]\nGo = \"X\"\n";
        (match Well.Actor.Contract.build ~source_dir:src ~output_dir:out with
         | Ok () -> fail "actor+service"
         | Error errs -> expect (List.length errs > 0) |> to_be_true);
        Array.iter (fun n -> Sys.remove (Filename.concat src n)) (Sys.readdir src);
        write "BothKind.toml" "[msg.X.struct]\na = \"string\"\n[msg.X.variant]\nA = \"string\"\n[actor]\nname = \"BothKind\"\nversion = 1\n[actor.accepts]\nGo = \"X\"\n";
        match Well.Actor.Contract.build ~source_dir:src ~output_dir:out with
        | Ok () -> fail "struct+variant"
        | Error errs ->
          expect (List.length errs > 0) |> to_be_true;
          expect (Sys.file_exists (Filename.concat out "descriptor.json")) |> to_be_false));

    it "C08 rejects extra positions unknown variant infinity and int range" (fun () ->
      let src = tmp_dir "actor-c08-src-" in
      let out = tmp_dir "actor-c08-out-" in
      Fun.protect ~finally:(fun () -> rm_rf src; rm_rf out) (fun () ->
        let oc = open_out (Filename.concat src "Num.toml") in
        output_string oc
          "[msg.Num.struct]\nn = \"int\"\nf = \"float\"\n[msg.Tag.variant]\nA = \"string\"\nB = \"void\"\n[actor]\nname = \"NumAct\"\nversion = 1\n[actor.accepts]\nGo = \"Num\"\n";
        close_out oc;
        match Well.Actor.Contract.build ~source_dir:src ~output_dir:out with
        | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
        | Ok () ->
          let desc = Yojson.Safe.from_file (Filename.concat out "descriptor.json") in
          match Well.Actor.Generated.descriptor desc with
          | Error _ -> fail "descriptor"
          | Ok d ->
            let mt name =
              match Well.Actor.Generated.message_type d ~name ~encode:(fun x -> x) ~decode:(fun x -> Ok x) with
              | Ok t -> t | Error e -> failwith e.message
            in
            let num = mt "Num.Num" in
            let tag = mt "Num.Tag" in
            (match Well.Actor.decode num (`List [`Int 1; `Float 1.0; `Int 2]) with
             | Ok _ -> fail "extra positions"
             | Error e -> expect e.code |> to_equal_string "InvalidInput");
            (match Well.Actor.decode num (`List [`Int 1]) with
             | Ok _ -> fail "missing positions"
             | Error e -> expect e.code |> to_equal_string "InvalidInput");
            (match Well.Actor.decode tag (`List [`String "Z"; `Null]) with
             | Ok _ -> fail "unknown variant"
             | Error e -> expect e.code |> to_equal_string "InvalidInput");
            (match Well.Actor.decode num (`List [`Int 1; `Float infinity]) with
             | Ok _ -> fail "infinity"
             | Error e -> expect e.code |> to_equal_string "InvalidInput");
            (match Well.Actor.decode num (`List [`Int 1; `Float nan]) with
             | Ok _ -> fail "nan"
             | Error e -> expect e.code |> to_equal_string "InvalidInput");
            match Well.Actor.decode num (`List [`Intlit "9007199254740992"; `Float 1.0]) with
            | Ok _ -> fail "int range"
            | Error e -> expect e.code |> to_equal_string "InvalidInput"));

    it "C10 incomplete manifest and source error keep previous output" (fun () ->
      let out = tmp_dir "actor-c10b-" in
      Fun.protect ~finally:(fun () -> rm_rf out) (fun () ->
        (match Well.Actor.Contract.build ~source_dir:examples ~output_dir:out with
         | Error e -> fail (List.map (fun (e : Well.Actor.error) -> e.message) e |> String.concat "; ")
         | Ok () -> ());
        let prev = read_file (Filename.concat out "descriptor.json") in
        Sys.remove (Filename.concat out "ocaml/reports.ml");
        (match Well.Actor.Contract.build ~source_dir:examples ~output_dir:out with
         | Ok () -> fail "incomplete output dir"
         | Error errs -> expect (List.length errs > 0) |> to_be_true);
        expect (Sys.file_exists (Filename.concat out "descriptor.json")) |> to_be_true;
        expect (read_file (Filename.concat out "descriptor.json")) |> to_equal_string prev;
        let src = tmp_dir "actor-c10-bad-" in
        Fun.protect ~finally:(fun () -> rm_rf src) (fun () ->
          let oc = open_out (Filename.concat src "Bad.toml") in
          output_string oc "[actor]\nname = \"__well.join\"\n";
          close_out oc;
          match Well.Actor.Contract.build ~source_dir:src ~output_dir:out with
          | Ok () -> fail "bad source"
          | Error _ ->
            expect (read_file (Filename.concat out "descriptor.json")) |> to_equal_string prev)));

    it "C09 RFC 8785 number samples" (fun () ->
      jcs_bits "0000000000000000" "0";
      jcs_bits "8000000000000000" "0";
      jcs_bits "0000000000000001" "5e-324";
      jcs_bits "8000000000000001" "-5e-324";
      jcs_bits "7fefffffffffffff" "1.7976931348623157e+308";
      jcs_bits "ffefffffffffffff" "-1.7976931348623157e+308";
      jcs_bits "4340000000000000" "9007199254740992";
      jcs_bits "c340000000000000" "-9007199254740992";
      jcs_bits "4430000000000000" "295147905179352830000";
      jcs_bits "44b52d02c7e14af5" "9.999999999999997e+22";
      jcs_bits "44b52d02c7e14af6" "1e+23";
      jcs_bits "44b52d02c7e14af7" "1.0000000000000001e+23";
      jcs_bits "444b1ae4d6e2ef4e" "999999999999999700000";
      jcs_bits "444b1ae4d6e2ef4f" "999999999999999900000";
      jcs_bits "444b1ae4d6e2ef50" "1e+21";
      jcs_bits "3eb0c6f7a0b5ed8c" "9.999999999999997e-7";
      jcs_bits "3eb0c6f7a0b5ed8d" "0.000001";
      jcs_bits "41b3de4355555553" "333333333.3333332";
      jcs_bits "41b3de4355555554" "333333333.33333325";
      jcs_bits "41b3de4355555555" "333333333.3333333";
      jcs_bits "41b3de4355555556" "333333333.3333334";
      jcs_bits "41b3de4355555557" "333333333.33333343";
      jcs_bits "becbf647612f3696" "-0.0000033333333333333333";
      jcs_bits "43143ff3c1cb0959" "1424953923781206.2";
      (try ignore (Well.Actor._canonicalize (`Float nan)); fail "NaN"
       with Invalid_argument _ -> ());
      (try ignore (Well.Actor._canonicalize (`Float infinity)); fail "Infinity"
       with Invalid_argument _ -> ()));

    it "C09 RFC 8785 string and UTF-16 key order" (fun () ->
      let sample_string = "\u{20AC}$\x0F\nA'B\"\\\\\"/" in
      expect (Well.Actor._canonicalize (`String sample_string))
      |> to_equal_string "\"\u{20AC}$\\u000f\\nA'B\\\"\\\\\\\\\\\"/\"";
      let sample =
        `Assoc [
          "numbers", `List [
            `Float (Int64.float_of_bits (Int64.of_string "0x41b3de4355555555"));
            `Float 1e30;
            `Float 4.5;
            `Float 0.002;
            `Float 1e-27;
          ];
          "string", `String sample_string;
          "literals", `List [`Null; `Bool true; `Bool false];
        ]
      in
      expect (Well.Actor._canonicalize sample)
      |> to_equal_string
        "{\"literals\":[null,true,false],\"numbers\":[333333333.3333333,1e+30,4.5,0.002,1e-27],\"string\":\"\u{20AC}$\\u000f\\nA'B\\\"\\\\\\\\\\\"/\"}";
      let sorted =
        Well.Actor._canonicalize (`Assoc [
          "\u{20AC}", `String "Euro Sign";
          "\r", `String "Carriage Return";
          "\u{FB33}", `String "Hebrew Letter Dalet With Dagesh";
          "1", `String "One";
          "\u{1F600}", `String "Emoji: Grinning Face";
          "\u{0080}", `String "Control";
          "\u{00F6}", `String "Latin Small Letter O With Diaeresis";
        ])
      in
      let keys = [
        "Carriage Return";
        "One";
        "Control";
        "Latin Small Letter O With Diaeresis";
        "Euro Sign";
        "Emoji: Grinning Face";
        "Hebrew Letter Dalet With Dagesh";
      ] in
      let rec positions acc = function
        | [] -> List.rev acc
        | k :: rest ->
          match
            let rec find i =
              if i + String.length k > String.length sorted then fail ("missing key " ^ k)
              else if String.sub sorted i (String.length k) = k then i
              else find (i + 1)
            in
            find 0
          with
          | i -> positions (i :: acc) rest
      in
      let ps = positions [] keys in
      let rec ordered = function
        | a :: b :: rest ->
          if a < b then ordered (b :: rest) else fail "UTF-16 key order"
        | _ -> ()
      in
      ordered ps);
  );
  run ~source_file:__FILE__ () |> exit_with_result
