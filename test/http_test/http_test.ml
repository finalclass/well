let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then incr pass
  else begin
    incr fail;
    Printf.eprintf "FAIL: %s\n%!" name
  end

let () =
  (* ── Unit tests (no server needed) ─────────────────────────────── *)

  (* response constructors *)
  (match Well.html "<h1>hi</h1>" with
   | `Html s -> check "html variant" (s = "<h1>hi</h1>")
   | _ -> check "html variant" false);

  (match Well.text "hello" with
   | `Text s -> check "text variant" (s = "hello")
   | _ -> check "text variant" false);

  (match Well.json (`Assoc [("ok", `Bool true)]) with
   | `Assoc [("ok", `Bool true)] -> check "json coerce" true
   | _ -> check "json coerce" false);

  (match Well.redirect "/home" with
   | `Redirect url -> check "redirect variant" (url = "/home")
   | _ -> check "redirect variant" false);

  (* response transformers *)
  (match Well.html "x" |> Well.status 201 with
   | `Custom c ->
       check "status wraps Custom" (c.status = Some 201);
       (match c.body with `Html s -> check "status body" (s = "x") | _ -> check "status body" false)
   | _ -> check "status wraps Custom" false);

  (match Well.html "x" |> Well.header "X-Foo" "bar" with
   | `Custom c -> check "header wraps Custom" (List.assoc "X-Foo" c.headers = "bar")
   | _ -> check "header wraps Custom" false);

  (match Well.text "x" |> Well.status 404 |> Well.header "X-A" "1" with
   | `Custom c ->
       check "status+header status" (c.status = Some 404);
       check "status+header header" (List.assoc "X-A" c.headers = "1")
   | _ -> check "status+header" false);

  (* request helpers *)
  let mk_req ?(params=[]) ?(query=[]) () : Well.request =
    { meth = "GET"; path = "/"; headers = []; body = "";
      params; query; session_id = "test"; _context = [] }
  in

  check "param returns value" (Well.param (mk_req ~params:[("id", "42")] ()) "id" = Some "42");
  check "param missing" (Well.param (mk_req ()) "id" = None);
  check "query returns Some" (Well.query (mk_req ~query:[("page", "2")] ()) "page" = Some "2");
  check "query missing" (Well.query (mk_req ()) "page" = None);

  (* ── Integration tests (with_test_server + Well.fetch) ─────────── *)
  Well.get "/t/ok" (fun _req -> Well.text "ok");
  Well.post "/t/post" (fun _req -> Well.text "posted");
  Well.put "/t/put" (fun _req -> Well.text "updated");
  Well.delete "/t/delete" (fun _req -> Well.text "deleted");
  Well.get "/t/json" (fun _req -> Well.json (`Assoc [("ok", `Bool true)]));
  Well.get "/t/201" (fun _req -> Well.text "created" |> Well.status 201);
  Well.get "/t/users/:id" (fun req -> Well.text (Option.value ~default:"" (Well.param req "id")));
  Well.get "/t/search" (fun req ->
    let q = match Well.query req "q" with Some v -> v | None -> "none" in
    Well.text q);
  Well.get "/t/redir" (fun _req -> Well.redirect "/new");
  Well.get "/t/html-node" (fun _req ->
    (Html.div ~children:[Html.txt "hi"] () :> Well.response));
  Well.get "/t/custom-header" (fun _req ->
    Well.text "x" |> Well.header "X-Custom" "yes");

  Well.with_test_server ~disable_cap:true (fun port ->
    let url path = Printf.sprintf "http://127.0.0.1:%d%s" port path in

    let resp = Well.fetch (url "/t/ok") in
    check "GET /t/ok status" (resp.status = 200);
    check "GET /t/ok body" (resp.body = "ok");

    let resp = Well.fetch ~method_:"POST" (url "/t/post") in
    check "POST status" (resp.status = 200);
    check "POST body" (resp.body = "posted");

    let resp = Well.fetch ~method_:"PUT" (url "/t/put") in
    check "PUT status" (resp.status = 200);
    check "PUT body" (resp.body = "updated");

    let resp = Well.fetch ~method_:"DELETE" (url "/t/delete") in
    check "DELETE status" (resp.status = 200);
    check "DELETE body" (resp.body = "deleted");

    let resp = Well.fetch (url "/t/nonexistent") in
    check "404 for unknown" (resp.status = 404);

    let resp = Well.fetch (url "/t/json") in
    check "JSON status" (resp.status = 200);

    let resp = Well.fetch (url "/t/201") in
    check "custom status 201" (resp.status = 201);

    let resp = Well.fetch (url "/t/users/42") in
    check "path param" (resp.body = "42");

    let resp = Well.fetch (url "/t/search?q=hello") in
    check "query param" (resp.body = "hello");

    let resp = Well.fetch (url "/t/redir") in
    check "redirect 302" (resp.status = 302);

    let resp = Well.fetch (url "/t/html-node") in
    check "html node" (resp.status = 200);

    let resp = Well.fetch (url "/t/custom-header") in
    let has_header = List.exists (fun (k, v) ->
      String.lowercase_ascii k = "x-custom" && v = "yes"
    ) resp.headers in
    check "custom header" has_header;

    let routes = Well.list_routes () in
    let paths = List.map (fun (_, p, _) -> p) routes in
    check "list_routes /t/ok" (List.mem "/t/ok" paths);
    check "list_routes /t/users/:id" (List.mem "/t/users/:id" paths);

    (* Print and exit from within the callback — workaround for shutdown hang *)
    Printf.printf "HTTP tests: %d passed, %d failed\n%!" !pass !fail;
    exit (if !fail > 0 then 1 else 0)
  )
