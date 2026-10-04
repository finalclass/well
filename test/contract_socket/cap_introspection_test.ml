(* W4 in-repo acceptance for the Cap admin panel path.

   The Cap services panel and the Cap web REPL call [Well.Service.describe_services]
   for metadata and [Well.Service.dispatch_by_name] for execution. This test
   drives those module entry points directly against a text-Drut service to
   prove the panel reaches Cyrograf-backed services, not only legacy ones. *)

let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then begin incr pass; Printf.printf "ok   %s\n%!" name end
  else begin incr fail; Printf.printf "FAIL %s\n%!" name end

let req : Well.request =
  { Well.meth = "GET"; path = "/"; headers = []; body = "";
    params = []; query = []; session_id = "w4-cap"; _context = [] }

let spec =
  { Well.Service.dname = "CapDemo";
    drpcs =
      [ { Well.Service.rname = "echoInt";
          params = [ { Well.Service.pname = "value"; ptype = "int"; poptional = false } ];
          returns = [ { Well.Service.pname = "value"; ptype = "int"; poptional = false } ];
          returns_name = "IntEcho" } ];
    dhandler =
      (fun rpc _ctx payload_text ->
        if rpc <> "echoInt" then
          Error (Well.Service.Drut_dispatch_error ("unknown rpc: " ^ rpc))
        else begin
          let t = String.trim payload_text in
          let n = String.length t in
          let inner =
            if n >= 2 && t.[0] = '[' && t.[n - 1] = ']' then String.sub t 1 (n - 2)
            else t
          in
          Ok ("[" ^ inner ^ "]")
        end);
    dset_ref = (fun _ -> ()) }

let with_spec f =
  Hashtbl.replace Well.Service.drut_handlers "CapDemo" spec;
  Fun.protect
    ~finally:(fun () -> Hashtbl.remove Well.Service.drut_handlers "CapDemo")
    f

let test_services_panel () =
  with_spec (fun () ->
    let model, _ = Well_cap__Services_page.init req `Null in
    let model =
      Well_cap__Services_page.update req model
        (Well_cap__Services_page.SelectRPC ("CapDemo", "echoInt"))
    in
    let model =
      Well_cap__Services_page.update req model
        (Well_cap__Services_page.CallRPC {|{"value":7}|})
    in
    check "Cap services panel reaches text-Drut service"
      (let s = model.Well_cap__Services_page.call_result in
       let needle = "7" in
       let n = String.length s and m = String.length needle in
       let rec at i = i + m <= n && (String.sub s i m = needle || at (i + 1)) in
       m = 0 || at 0))

let test_web_repl () =
  with_spec (fun () ->
    let env : Well_cap__Repl_page.env =
      { schema = Well_cap__Repl_page.build_schema ();
        vars = Hashtbl.create 16;
        ctx = Well.rpc_ctx_to_wire (Well.rpc_ctx req) }
    in
    let value, type_ = Well_cap__Repl_page.eval env
      (Well_cap__Repl_page.parse "CapDemo.echoInt value:7") in
    check "Cap web REPL decoded the response" (value = `Assoc [("value", `Int 7)]);
    check "Cap web REPL preserves return type"
      (Well_cap__Repl_page.type_name type_ = "IntEcho"))

let () =
  test_services_panel ();
  test_web_repl ();
  Printf.printf "\nW4 Cap test: %d passed, %d failed\n%!" !pass !fail;
  exit (if !fail > 0 then 1 else 0)
