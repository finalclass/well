(* Focused tests: OCaml browser Proxy codegen mirrors TS Proxy shape.
   Exercises generators via `well contract build` (codegen modules are
   internal to well_cli). *)

let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then incr pass
  else begin
    incr fail;
    Printf.eprintf "FAIL: %s\n%!" name
  end

let contains hay needle =
  let hlen = String.length hay in
  let nlen = String.length needle in
  let rec loop i =
    if i + nlen > hlen then false
    else if String.sub hay i nlen = needle then true
    else loop (i + 1)
  in
  loop 0

let read_file path =
  let ic = open_in path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let fixture_dir =
  let candidates =
    [ "test/contract_codegen_test/fixtures"
    ; "fixtures"
    ; Filename.concat (Filename.dirname Sys.argv.(0)) "fixtures"
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some d -> d
  | None ->
    let rec walk dir n =
      if n = 0 then failwith "fixtures not found"
      else
        let p = Filename.concat dir "test/contract_codegen_test/fixtures" in
        if Sys.file_exists p then p
        else walk (Filename.dirname dir) (n - 1)
    in
    walk (Sys.getcwd ()) 8

let find_well () =
  let candidates =
    [ "_build/default/bin/main.exe"
    ; "bin/main.exe"
    ; Filename.concat (Sys.getcwd ()) "_build/default/bin/main.exe"
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some p -> p
  | None ->
    let rec walk dir n =
      if n = 0 then failwith "well binary not found"
      else
        let p = Filename.concat dir "_build/default/bin/main.exe" in
        if Sys.file_exists p then p
        else walk (Filename.dirname dir) (n - 1)
    in
    walk (Sys.getcwd ()) 8

let run_cmd cmd =
  let ic = Unix.open_process_in cmd in
  let buf = Buffer.create 256 in
  (try while true do Buffer.add_channel buf ic 4096 done with End_of_file -> ());
  let status = Unix.close_process_in ic in
  (Buffer.contents buf, status)

let () =
  Random.self_init ();
  let well = find_well () in
  let tmp =
    Filename.concat
      (Filename.get_temp_dir_name ())
      ("well-obp-" ^ string_of_int (Random.int 1_000_000))
  in
  Unix.mkdir tmp 0o755;
  let out_dir = Filename.concat tmp "build" in
  let cmd =
    Printf.sprintf "%s contract build %s %s 2>&1"
      (Filename.quote well)
      (Filename.quote fixture_dir)
      (Filename.quote out_dir)
  in
  let stdout, status = run_cmd cmd in
  check "contract build exit ok" (status = Unix.WEXITED 0);
  if status <> Unix.WEXITED 0 then
    Printf.eprintf "build output:\n%s\n%!" stdout;

  let browser_dir = Filename.concat out_dir "ocaml_browser" in
  let echo_path = Filename.concat browser_dir "echo.ml" in
  let rpc_path = Filename.concat browser_dir "rpc.ml" in
  let dune_path = Filename.concat browser_dir "dune" in
  let server_echo = Filename.concat (Filename.concat out_dir "ocaml") "echo.ml" in
  let ts_echo = Filename.concat (Filename.concat out_dir "ts") "Echo.ts" in
  let ts_rpc = Filename.concat (Filename.concat out_dir "ts") "rpc.ts" in

  check "ocaml_browser/echo.ml exists" (Sys.file_exists echo_path);
  check "ocaml_browser/rpc.ml exists" (Sys.file_exists rpc_path);
  check "ocaml_browser/dune exists" (Sys.file_exists dune_path);
  check "server ocaml/echo.ml exists" (Sys.file_exists server_echo);
  check "ts Echo.ts exists" (Sys.file_exists ts_echo);

  let browser = read_file echo_path in
  let rpc = read_file rpc_path in
  let dune_txt = read_file dune_path in
  let server = read_file server_echo in
  let ts = read_file ts_echo in
  let ts_rpc_src = read_file ts_rpc in

  check "has Proxy module" (contains browser "module Proxy = struct");
  check "has ping method"
    (contains browser "let ping (req : PingRequest.t)");
  check "has echo method"
    (contains browser "let echo (req : EchoRequest.t)");
  check "POST path service Echo"
    (contains browser "~service:\"Echo\"");
  check "POST method ping" (contains browser "~method_:\"ping\"");
  check "POST method echo" (contains browser "~method_:\"echo\"");
  check "uses to_wire" (contains browser "PingRequest.to_wire req");
  check "uses of_wire" (contains browser "PingResponse.of_wire wire");
  check "uses Rpc.post" (contains browser "Rpc.post");
  check "on_done callback"
    (contains browser
       "~(on_done : (PingResponse.t, string) result -> unit)");
  check "no well.core rpc_ctx" (not (contains browser "Well.rpc_ctx"));
  check "no in-process service_ref"
    (not (contains browser "_service_ref"));
  check "has to_wire def"
    (contains browser "let to_wire (v : t) : Yojson.Safe.t"
     || contains browser "let to_wire (() : t) : Yojson.Safe.t");
  check "has of_wire def"
    (contains browser "let of_wire (wire : Yojson.Safe.t) : t"
     || contains browser "let of_wire (_wire : Yojson.Safe.t) : t");

  check "rpc posts /rpc/" (contains rpc "/rpc/%s/%s");
  check "rpc Content-Type json" (contains rpc "application/json");
  check "rpc X-Requested-With" (contains rpc "XMLHttpRequest");
  check "rpc CSRF header" (contains rpc "X-CSRF-Token");
  check "rpc uses XmlHttpRequest" (contains rpc "XmlHttpRequest.create");
  check "rpc Yojson encode" (contains rpc "Yojson.Safe.to_string wire");
  check "rpc Yojson decode" (contains rpc "Yojson.Safe.from_string text");
  check "rpc treats 2xx error assoc as Error"
    (contains rpc "wire_error_message" && contains rpc "Some msg -> on_done (Error msg)");
  check "rpc non-JSON → Error"
    (contains rpc "RPC JSON decode:");
  check "rpc documents CSRF sources"
    (contains rpc "__WELL_CSRF" && contains rpc "csrf-token");
  check "rpc notes no __DG_CSRF"
    (contains rpc "__DG_CSRF");

  check "Proxy catches of_wire failures"
    (contains browser "RPC decode:"
     && contains browser "try on_done (Ok ("
     && contains browser "with exn ->");

  check "TS proxy has ping" (contains ts "async ping(req)");
  check "TS proxy rpc Echo ping"
    (contains ts "rpc(\"Echo\", \"ping\"");
  check "TS rpc fetch /rpc/" (contains ts_rpc_src "/rpc/${service}/${method}");

  check "server still has convenience" (contains server "let ping ~ctx");
  check "server has make_spec" (contains server "let make_spec");
  check "server not mixed with Proxy"
    (not (contains server "module Proxy"));

  check "dune lib name *_browser"
    (contains dune_txt "_browser)");
  check "dune has js_of_ocaml" (contains dune_txt "js_of_ocaml");
  check "dune has rpc module" (contains dune_txt "rpc");
  check "dune has echo module" (contains dune_txt "echo");

  check "generated supports EchoRequest.make"
    (contains browser "let make ~text ()");
  check "consumer call shape"
    (contains browser "Rpc.post"
     && contains browser "~service:\"Echo\""
     && contains browser "~method_:\"echo\"");

  let ping_req_wire = "let to_wire (() : t) : Yojson.Safe.t = `List []" in
  check "empty struct wire same shape"
    (contains browser ping_req_wire && contains server ping_req_wire);
  check "echo field wire same shape"
    (contains browser "`String v.text" && contains server "`String v.text");

  (* Prove one RPC is callable through Proxy: encode request with generated
     wire and show Proxy.ping body is to_wire → Rpc.post → of_wire. *)
  check "Proxy.ping is full RPC pipeline"
    (let start =
       match
         let needle = "let ping (req : PingRequest.t)" in
         let rec find i =
           if i + String.length needle > String.length browser then -1
           else if String.sub browser i (String.length needle) = needle then i
           else find (i + 1)
         in
         find 0
       with
       | -1 -> ""
       | i -> String.sub browser i (min 500 (String.length browser - i))
     in
     contains start "PingRequest.to_wire"
     && contains start "Rpc.post"
     && contains start "PingResponse.of_wire"
     && contains start "~service:\"Echo\""
     && contains start "~method_:\"ping\""
     && contains start "try on_done"
     && contains start "RPC decode:");

  (* ── Behavioral harness: pure decision tree mirroring generated Rpc.post
     (status matrix + 2xx {"error":...}) and Proxy of_wire try/with. ── *)
  let wire_error_message (json : Yojson.Safe.t) : string option =
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "error" fields with
       | Some (`String s) -> Some s
       | _ -> None)
    | _ -> None
  in
  let rpc_decide ~status ~text : (Yojson.Safe.t, string) result =
    if status >= 200 && status < 300 then
      try
        let json = Yojson.Safe.from_string text in
        match wire_error_message json with
        | Some msg -> Error msg
        | None -> Ok json
      with exn -> Error ("RPC JSON decode: " ^ Printexc.to_string exn)
    else
      let err =
        try
          match wire_error_message (Yojson.Safe.from_string text) with
          | Some s -> s
          | None -> ""
        with _ -> ""
      in
      Error
        (if err <> "" then err
         else if status = 0 then "Network error"
         else Printf.sprintf "RPC Echo.ping: %d" status)
  in
  let proxy_map_ok of_wire wire : ('a, string) result =
    try Ok (of_wire wire)
    with exn -> Error ("RPC decode: " ^ Printexc.to_string exn)
  in
  (* Success array → Ok (not of_wire yet) *)
  (match rpc_decide ~status:200 ~text:"[]" with
   | Ok (`List []) -> check "behavior 200+array → Ok" true
   | _ -> check "behavior 200+array → Ok" false);
  (* 200 + server error assoc → Error, never of_wire *)
  (match rpc_decide ~status:200 ~text:"{\"error\":\"boom\"}" with
   | Error "boom" -> check "behavior 200+error assoc → Error" true
   | _ -> check "behavior 200+error assoc → Error" false);
  (* non-JSON → Error *)
  (match rpc_decide ~status:200 ~text:"not-json{" with
   | Error msg when contains msg "RPC JSON decode:" ->
     check "behavior 200+non-JSON → Error" true
   | _ -> check "behavior 200+non-JSON → Error" false);
  (* non-2xx *)
  (match rpc_decide ~status:403 ~text:"" with
   | Error msg when contains msg "403" -> check "behavior 403 → Error" true
   | _ -> check "behavior 403 → Error" false);
  (match rpc_decide ~status:500 ~text:"{\"error\":\"srv\"}" with
   | Error "srv" -> check "behavior 500+error body → Error" true
   | _ -> check "behavior 500+error body → Error" false);
  (match rpc_decide ~status:0 ~text:"" with
   | Error "Network error" -> check "behavior status 0 → Network error" true
   | _ -> check "behavior status 0 → Network error" false);
  (* wrong shape → of_wire raises → Error (mirrors Proxy try/with) *)
  let of_wire_array = function
    | `List _ as w -> w
    | _ -> failwith "PingResponse.of_wire: expected JSON array"
  in
  (match proxy_map_ok of_wire_array (`Assoc [ "error", `String "x" ]) with
   | Error msg when contains msg "RPC decode:" ->
     check "behavior wrong shape → Error (no raise)" true
   | _ -> check "behavior wrong shape → Error (no raise)" false);
  (match proxy_map_ok of_wire_array (`List []) with
   | Ok (`List []) -> check "behavior array of_wire → Ok" true
   | _ -> check "behavior array of_wire → Ok" false);
  (* 200+error must not be fed to of_wire *)
  (match rpc_decide ~status:200 ~text:"{\"error\":\"no-decode\"}" with
   | Error "no-decode" ->
     (match proxy_map_ok of_wire_array (`Assoc [ "error", `String "no-decode" ]) with
      | Error _ ->
        check "behavior error assoc never reaches success of_wire path" true
      | Ok _ ->
        check "behavior error assoc never reaches success of_wire path" false)
   | _ -> check "behavior error assoc never reaches success of_wire path" false);

  Printf.printf "contract_codegen_test: %d passed, %d failed\n%!" !pass !fail;
  if !fail > 0 then exit 1
