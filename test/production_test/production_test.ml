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

let contains_str ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen > hlen then false
  else
    let rec search i =
      if i > hlen - nlen then false
      else if String.sub haystack i nlen = needle then true
      else search (i + 1)
    in
    search 0

let () =
  Mirage_crypto_rng_unix.use_default ();

  (* ══════════════════════════════════════════════════════════════════
     1. PATH SAFETY — is_safe_path
     ══════════════════════════════════════════════════════════════════ *)

  check "safe: /static/style.css" (Well.is_safe_path "/static/style.css");
  check "safe: /images/logo.png" (Well.is_safe_path "/images/logo.png");
  check "safe: /a/b/c/d" (Well.is_safe_path "/a/b/c/d");
  check "safe: /" (Well.is_safe_path "/");

  (* Traversal attacks *)
  check "unsafe: /../etc/passwd" (not (Well.is_safe_path "/../etc/passwd"));
  check "unsafe: /static/../../../etc/shadow" (not (Well.is_safe_path "/static/../../../etc/shadow"));
  check "unsafe: /." (not (Well.is_safe_path "/."));
  check "unsafe: /./hidden" (not (Well.is_safe_path "/./hidden"));

  (* Encoded traversal *)
  check "unsafe: %2e%2e" (not (Well.is_safe_path "/%2e%2e/etc/passwd"));
  check "unsafe: %2E%2E" (not (Well.is_safe_path "/%2E%2E/etc/passwd"));
  check "unsafe: mixed %2e." (not (Well.is_safe_path "/%2e./etc/passwd"));
  check "unsafe: .%2e" (not (Well.is_safe_path "/.%2e/etc/passwd"));

  (* Double encoding — %252e decodes to %2e, then to . *)
  check "unsafe: null byte" (not (Well.is_safe_path "/static/file%00.txt"));
  check "unsafe: null in middle" (not (Well.is_safe_path "/static%00/../etc/passwd"));

  (* Valid paths that look suspicious but are fine *)
  check "safe: /..hidden" (Well.is_safe_path "/..hidden");
  check "safe: /file..ext" (Well.is_safe_path "/file..ext");
  check "safe: /a...b" (Well.is_safe_path "/a...b");

  (* ══════════════════════════════════════════════════════════════════
     2. URL ENCODING / DECODING
     ══════════════════════════════════════════════════════════════════ *)

  check "url_decode: basic" (Well.url_decode "hello%20world" = "hello world");
  check "url_decode: plus" (Well.url_decode "hello+world" = "hello world");
  check "url_decode: special chars" (Well.url_decode "%3C%3E%22" = "<>\"");
  check "url_decode: pass through" (Well.url_decode "normal" = "normal");
  check "url_decode: empty" (Well.url_decode "" = "");
  check "url_decode: percent at end" (Well.url_decode "test%" = "test%");
  check "url_decode: partial percent" (Well.url_decode "test%2" = "test%2");
  check "url_decode: unicode" (Well.url_decode "%C3%A9" = "\xc3\xa9");

  check "url_encode: basic" (Well.url_encode "hello world" = "hello%20world");
  check "url_encode: special" (Well.url_encode "<>&\"" = "%3C%3E%26%22");
  check "url_encode: passthrough" (Well.url_encode "abc-_.~" = "abc-_.~");
  check "url_encode: empty" (Well.url_encode "" = "");

  check "roundtrip: encode→decode" (Well.url_decode (Well.url_encode "héllo wörld") = "héllo wörld");

  (* ══════════════════════════════════════════════════════════════════
     3. MULTIPART PARSING
     ══════════════════════════════════════════════════════════════════ *)

  (* extract_boundary lowercases content-type before matching *)
  check "extract_boundary: normal"
    (Well.extract_boundary "multipart/form-data; boundary=----webkitformboundary"
     = Some "----webkitformboundary");
  check "extract_boundary: not multipart"
    (Well.extract_boundary "application/json" = None);
  check "extract_boundary: case insensitive"
    (Well.extract_boundary "Multipart/Form-Data; boundary=abc" = Some "abc");

  let boundary = "----testboundary" in
  let body = String.concat ""
    [ "------testboundary\r\n";
      "Content-Disposition: form-data; name=\"field1\"\r\n";
      "\r\n";
      "value1\r\n";
      "------testboundary\r\n";
      "Content-Disposition: form-data; name=\"field2\"\r\n";
      "\r\n";
      "value2\r\n";
      "------testboundary--\r\n" ]
  in
  let mp = Well.parse_multipart boundary body in
  check "multipart: 2 fields" (List.length mp.fields = 2);
  check "multipart: field1 value" (List.assoc "field1" mp.fields = "value1");
  check "multipart: field2 value" (List.assoc "field2" mp.fields = "value2");
  check "multipart: no files" (List.length mp.files = 0);

  (* Multipart with file *)
  let body_file = String.concat ""
    [ "------testboundary\r\n";
      "Content-Disposition: form-data; name=\"doc\"; filename=\"test.txt\"\r\n";
      "Content-Type: text/plain\r\n";
      "\r\n";
      "file content here\r\n";
      "------testboundary--\r\n" ]
  in
  let mp_f = Well.parse_multipart boundary body_file in
  check "multipart file: 0 fields" (List.length mp_f.fields = 0);
  check "multipart file: 1 file" (List.length mp_f.files = 1);
  let (_, uploaded) = List.hd mp_f.files in
  check "multipart file: filename" (uploaded.filename = "test.txt");
  check "multipart file: content_type" (uploaded.content_type = "text/plain");
  check "multipart file: data" (uploaded.data = "file content here");
  check "multipart file: size" (uploaded.size = 17);

  (* Empty multipart body *)
  let empty_mp = Well.parse_multipart boundary "------testboundary--\r\n" in
  check "multipart empty: no fields" (List.length empty_mp.fields = 0);

  (* ══════════════════════════════════════════════════════════════════
     4. FORM PARAMS PARSING
     ══════════════════════════════════════════════════════════════════ *)

  let mk_form_req body : Well.request =
    { meth = "POST"; path = "/"; body;
      headers = [("content-type", "application/x-www-form-urlencoded")];
      params = []; query = []; session_id = "test"; _context = [] }
  in
  let fps = Well.form_params (mk_form_req "name=John&age=30&city=New+York") in
  check "form_params: name" (List.assoc "name" fps = "John");
  check "form_params: age" (List.assoc "age" fps = "30");
  check "form_params: space" (List.assoc "city" fps = "New York");

  let fps2 = Well.form_params (mk_form_req "key=hello%20world") in
  check "form_params: url encoded" (List.assoc "key" fps2 = "hello world");

  let fps_empty = Well.form_params (mk_form_req "") in
  check "form_params: empty body" (fps_empty = [] || (List.length fps_empty = 1 && snd (List.hd fps_empty) = ""));

  (* ══════════════════════════════════════════════════════════════════
     INTEGRATION TESTS — with_test_server
     ══════════════════════════════════════════════════════════════════ *)

  (* ── Route registration ────────────────────────────────────────── *)

  (* Multiple params *)
  Well.get "/t/prod/users/:user_id/posts/:post_id" (fun req ->
    let uid = Well.param req "user_id" in
    let pid = Well.param req "post_id" in
    Well.text (uid ^ ":" ^ pid));

  (* URL-encoded param values *)
  Well.get "/t/prod/echo/:val_" (fun req ->
    Well.text (Well.param req "val_"));

  (* Body echo *)
  Well.post "/t/prod/echo-body" (fun req ->
    Well.text req.body);

  (* Large response for compression test *)
  Well.get "/t/prod/large-text" (fun _req ->
    Well.text (String.make 2000 'A'));

  Well.get "/t/prod/small-text" (fun _req ->
    Well.text "tiny");

  Well.get "/t/prod/large-json" (fun _req ->
    let data = String.make 2000 'x' in
    Well.json (`Assoc [("data", `String data)]));

  (* Binary content type — should not be compressed *)
  Well.get "/t/prod/binary" (fun _req ->
    Well.text (String.make 2000 '\x00')
    |> Well.header "Content-Type" "application/octet-stream");

  (* Session tests *)
  Well.get "/t/prod/session-set" (fun req ->
    Well.session_set req "test_key" "test_value";
    Well.text "set");

  Well.get "/t/prod/session-get" (fun req ->
    let v = match Well.session_get req "test_key" with
      | Some v -> v | None -> "empty" in
    Well.text v);

  Well.get "/t/prod/session-delete" (fun req ->
    Well.session_delete req "test_key";
    Well.text "deleted");

  Well.get "/t/prod/session-id" (fun req ->
    Well.text req.session_id);

  Well.get "/t/prod/session-regen" (fun req ->
    Well.session_set req "keep_this" "yes";
    let (_new_req, set_cookie) = Well.session_regenerate req in
    Well.text "regenerated" |> set_cookie);

  (* Flash messages *)
  Well.get "/t/prod/flash-set" (fun req ->
    Well.put_flash req "info" "Hello flash!";
    Well.text "flash set");

  Well.get "/t/prod/flash-get" (fun req ->
    let msg = match Well.get_flash req "info" with
      | Some v -> v | None -> "no flash" in
    Well.text msg);

  (* CSRF tests *)
  Well.use Well.csrf;
  Well.get "/t/prod/csrf-token" (fun req ->
    Well.text (Well.csrf_token req));

  Well.post "/t/prod/csrf-check" (fun _req ->
    Well.text "csrf ok");

  (* Error handling tests *)
  Well.get "/t/prod/error-runtime" (fun _req ->
    failwith "intentional test error");

  Well.get "/t/prod/error-division" (fun _req ->
    let _ = 1 / 0 in Well.text "never");

  Well.use Well.error_handler;

  Well.get "/t/prod/error-with-handler" (fun _req ->
    failwith "handled error");

  (* Custom error handler *)
  Well.on_error (fun _exn _req ->
    Well.text "custom error page" |> Well.status 500);

  Well.get "/t/prod/error-custom" (fun _req ->
    failwith "custom handled");

  (* Middleware ordering *)
  let order_log = ref [] in
  let mw_a : Well.middleware = fun next req ->
    order_log := "A-before" :: !order_log;
    let resp = next req in
    order_log := "A-after" :: !order_log;
    resp
  in
  let mw_b : Well.middleware = fun next req ->
    order_log := "B-before" :: !order_log;
    let resp = next req in
    order_log := "B-after" :: !order_log;
    resp
  in

  Well.get ~middleware:[mw_a; mw_b] "/t/prod/mw-order" (fun _req ->
    order_log := "handler" :: !order_log;
    Well.text "ok");

  (* Scope tests *)
  Well.scope "/t/prod/api" (fun () ->
    Well.get "/users" (fun _req -> Well.text "users list");
    Well.get "/users/:id" (fun req -> Well.text ("user " ^ Well.param req "id"));
    Well.scope "/admin" (fun () ->
      Well.get "/stats" (fun _req -> Well.text "admin stats"));
  );

  (* Multiple query params *)
  Well.get "/t/prod/multi-query" (fun req ->
    let a = match Well.query req "a" with Some v -> v | None -> "" in
    let b = match Well.query req "b" with Some v -> v | None -> "" in
    Well.text (a ^ "," ^ b));

  (* Method-specific behavior *)
  Well.get "/t/prod/method-test" (fun _req -> Well.text "GET");
  Well.post "/t/prod/method-test" (fun _req -> Well.text "POST");

  (* Content-type detection *)
  Well.get "/t/prod/ct-html" (fun _req -> Well.html "<p>hi</p>");
  Well.get "/t/prod/ct-json" (fun _req -> Well.json (`Assoc [("ok", `Bool true)]));
  Well.get "/t/prod/ct-text" (fun _req -> Well.text "plain");

  (* Streaming response *)
  Well.get "/t/prod/stream" (fun _req ->
    Well.stream ~content_type:"text/plain" (fun write_chunk ->
      write_chunk "chunk1";
      write_chunk "chunk2";
      write_chunk "chunk3"));

  (* Rate limiting test endpoint *)
  let rl = Well.rate_limit ~max_requests:3 ~window_ms:5000 () in
  Well.get ~middleware:[rl] "/t/prod/rate-limited" (fun _req ->
    Well.text "ok");

  (* Request body size *)
  Well.post "/t/prod/body-size" (fun req ->
    Well.text (string_of_int (String.length req.body)));

  (* Auth_denied through error_handler *)
  Well.get "/t/prod/auth-denied-401" (fun _req ->
    raise (Well.Auth.Auth_denied (401, "Unauthorized")));

  Well.get "/t/prod/auth-denied-403" (fun _req ->
    raise (Well.Auth.Auth_denied (403, "Forbidden")));

  (* Response header stacking *)
  Well.get "/t/prod/multi-header" (fun _req ->
    Well.text "ok"
    |> Well.header "X-One" "1"
    |> Well.header "X-Two" "2"
    |> Well.status 201);

  (* Empty body responses *)
  Well.get "/t/prod/204" (fun _req ->
    Well.text "" |> Well.status 204);

  (* Static file setup for traversal tests *)
  Well.static "/t/prod/static" "test/production_test/fixtures";

  Well.with_test_server ~disable_cap:true (fun port ->
    let url path = Printf.sprintf "http://127.0.0.1:%d%s" port path in

    (* ══════════════════════════════════════════════════════════════
       5. ROUTE MATCHING
       ══════════════════════════════════════════════════════════════ *)

    let resp = Well.fetch (url "/t/prod/users/42/posts/99") in
    check "multi param: status" (resp.status = 200);
    check "multi param: body" (resp.body = "42:99");

    (* Router does NOT auto-decode path segments — raw value is returned *)
    let resp = Well.fetch (url "/t/prod/echo/hello%20world") in
    check "url-encoded param: raw" (resp.body = "hello%20world");

    let resp = Well.fetch (url "/t/prod/echo/caf%C3%A9") in
    check "utf8 param: raw" (resp.body = "caf%C3%A9");

    (* Handlers can use Well.url_decode to decode *)
    check "url_decode on param" (Well.url_decode "hello%20world" = "hello world");

    (* 404 on unknown *)
    let resp = Well.fetch (url "/t/prod/nonexistent/deep/path") in
    check "404 deep path" (resp.status = 404);

    (* 405 Method Not Allowed — use XHR bypass so CSRF doesn't intercept *)
    let resp = Well.fetch ~method_:"DELETE"
      ~headers:[("x-requested-with", "XMLHttpRequest")]
      (url "/t/prod/method-test") in
    check "405 wrong method" (resp.status = 405);
    let allow = get_header "allow" resp in
    check "405 has Allow header" (allow <> None);
    (match allow with
     | Some v ->
       check "405 Allow contains GET" (contains_str ~needle:"GET" v);
       check "405 Allow contains POST" (contains_str ~needle:"POST" v)
     | None -> ());

    (* HEAD auto-response *)
    let resp = Well.fetch ~method_:"HEAD" (url "/t/prod/ct-text") in
    check "HEAD status 200" (resp.status = 200);
    check "HEAD empty body" (resp.body = "");

    (* Scope routes *)
    let resp = Well.fetch (url "/t/prod/api/users") in
    check "scope: /api/users" (resp.body = "users list");

    let resp = Well.fetch (url "/t/prod/api/users/7") in
    check "scope: /api/users/:id" (resp.body = "user 7");

    let resp = Well.fetch (url "/t/prod/api/admin/stats") in
    check "nested scope" (resp.body = "admin stats");

    (* ══════════════════════════════════════════════════════════════
       6. QUERY STRING EDGE CASES
       ══════════════════════════════════════════════════════════════ *)

    let resp = Well.fetch (url "/t/prod/multi-query?a=1&b=2") in
    check "multi query params" (resp.body = "1,2");

    let resp = Well.fetch (url "/t/prod/multi-query?a=hello%20world&b=") in
    check "query: encoded value" (resp.body = "hello world,");

    let resp = Well.fetch (url "/t/prod/multi-query?a=&b=") in
    check "query: empty values" (resp.body = ",");

    (* ══════════════════════════════════════════════════════════════
       7. CONTENT-TYPE DETECTION
       ══════════════════════════════════════════════════════════════ *)

    let resp = Well.fetch (url "/t/prod/ct-html") in
    (match get_header "content-type" resp with
     | Some ct -> check "ct: html" (contains_str ~needle:"text/html" ct)
     | None -> check "ct: html present" false);

    let resp = Well.fetch (url "/t/prod/ct-json") in
    (match get_header "content-type" resp with
     | Some ct -> check "ct: json" (contains_str ~needle:"application/json" ct)
     | None -> check "ct: json present" false);

    let resp = Well.fetch (url "/t/prod/ct-text") in
    (match get_header "content-type" resp with
     | Some ct -> check "ct: text" (contains_str ~needle:"text/plain" ct)
     | None -> check "ct: text present" false);

    (* ══════════════════════════════════════════════════════════════
       8. GZIP COMPRESSION
       ══════════════════════════════════════════════════════════════ *)

    (* Large text should be compressed when Accept-Encoding: gzip *)
    let resp = Well.fetch ~headers:[("accept-encoding", "gzip")] (url "/t/prod/large-text") in
    check "gzip: large text compressed" (has_header "content-encoding" resp);
    (match get_header "content-encoding" resp with
     | Some v -> check "gzip: header is gzip" (v = "gzip")
     | None -> check "gzip: header is gzip" false);
    check "gzip: body smaller than 2000" (String.length resp.body < 2000);

    (* Vary: Accept-Encoding header present *)
    check "gzip: Vary header" (has_header "vary" resp);

    (* Small text should NOT be compressed *)
    let resp = Well.fetch ~headers:[("accept-encoding", "gzip")] (url "/t/prod/small-text") in
    check "no gzip: small text" (not (has_header "content-encoding" resp));
    check "no gzip: body intact" (resp.body = "tiny");

    (* No Accept-Encoding → no compression *)
    let resp = Well.fetch (url "/t/prod/large-text") in
    check "no gzip: no accept-encoding" (not (has_header "content-encoding" resp));

    (* Binary content should NOT be compressed *)
    let resp = Well.fetch ~headers:[("accept-encoding", "gzip")] (url "/t/prod/binary") in
    check "no gzip: binary content" (not (has_header "content-encoding" resp));

    (* Large JSON should be compressed *)
    let resp = Well.fetch ~headers:[("accept-encoding", "gzip")] (url "/t/prod/large-json") in
    check "gzip: large json" (has_header "content-encoding" resp);

    (* ══════════════════════════════════════════════════════════════
       9. SESSION MANAGEMENT
       ══════════════════════════════════════════════════════════════ *)

    (* First request should get Set-Cookie *)
    let resp = Well.fetch (url "/t/prod/session-id") in
    check "session: new gets Set-Cookie" (has_header "set-cookie" resp);
    let cookie = get_header "set-cookie" resp in
    (match cookie with
     | Some c ->
       check "session: cookie has well_session" (contains_str ~needle:"well_session=" c);
       check "session: HttpOnly" (contains_str ~needle:"HttpOnly" c);
       check "session: SameSite=Lax" (contains_str ~needle:"SameSite=Lax" c);
       check "session: Path=/" (contains_str ~needle:"Path=/" c);

       (* Extract session ID from cookie *)
       let eq_pos = String.index c '=' in
       let semi_pos = try String.index c ';' with Not_found -> String.length c in
       let sid = String.sub c (eq_pos + 1) (semi_pos - eq_pos - 1) in
       check "session: id is 64 hex chars" (String.length sid = 64);
       check "session: id is hex" (
         String.to_seq sid |> Seq.for_all (fun c ->
           (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')));

       (* Reuse session: no new Set-Cookie *)
       let cookie_header = "well_session=" ^ sid in
       let resp2 = Well.fetch ~headers:[("cookie", cookie_header)] (url "/t/prod/session-id") in
       check "session: reuse no Set-Cookie" (not (has_header "set-cookie" resp2));
       check "session: same id returned" (resp2.body = sid);

       (* Session data persistence *)
       let _ = Well.fetch ~headers:[("cookie", cookie_header)] (url "/t/prod/session-set") in
       let resp3 = Well.fetch ~headers:[("cookie", cookie_header)] (url "/t/prod/session-get") in
       check "session: data persists" (resp3.body = "test_value");

       (* Session data delete *)
       let _ = Well.fetch ~headers:[("cookie", cookie_header)] (url "/t/prod/session-delete") in
       let resp4 = Well.fetch ~headers:[("cookie", cookie_header)] (url "/t/prod/session-get") in
       check "session: data deleted" (resp4.body = "empty");

       (* Session regeneration — new session ID, data migrated *)
       let _ = Well.fetch ~headers:[("cookie", cookie_header)] (url "/t/prod/session-set") in
       let resp_regen = Well.fetch ~headers:[("cookie", cookie_header)] (url "/t/prod/session-regen") in
       check "session: regen has Set-Cookie" (has_header "set-cookie" resp_regen);
       let new_cookie = get_header "set-cookie" resp_regen in
       (match new_cookie with
        | Some nc ->
          let eq2 = String.index nc '=' in
          let semi2 = try String.index nc ';' with Not_found -> String.length nc in
          let new_sid = String.sub nc (eq2 + 1) (semi2 - eq2 - 1) in
          check "session: regen new id" (new_sid <> sid);
          check "session: regen id length" (String.length new_sid = 64);

          (* Data should be migrated to new session *)
          let new_cookie_h = "well_session=" ^ new_sid in
          let resp_migrated = Well.fetch ~headers:[("cookie", new_cookie_h)]
            (url "/t/prod/session-get") in
          check "session: data migrated after regen" (resp_migrated.body = "test_value")
        | None -> check "session: regen cookie present" false);

     | None -> check "session: cookie present" false);

    (* ══════════════════════════════════════════════════════════════
       10. FLASH MESSAGES
       ══════════════════════════════════════════════════════════════ *)

    (* Get a session first *)
    let resp_s = Well.fetch (url "/t/prod/session-id") in
    let sid_cookie =
      match get_header "set-cookie" resp_s with
      | Some c ->
        let eq = String.index c '=' in
        let semi = try String.index c ';' with Not_found -> String.length c in
        "well_session=" ^ String.sub c (eq + 1) (semi - eq - 1)
      | None -> ""
    in

    (* Set flash, then read it *)
    let _ = Well.fetch ~headers:[("cookie", sid_cookie)] (url "/t/prod/flash-set") in
    let resp_flash = Well.fetch ~headers:[("cookie", sid_cookie)] (url "/t/prod/flash-get") in
    check "flash: message delivered" (resp_flash.body = "Hello flash!");

    (* Flash consumed — second read should be empty *)
    let resp_flash2 = Well.fetch ~headers:[("cookie", sid_cookie)] (url "/t/prod/flash-get") in
    check "flash: consumed after read" (resp_flash2.body = "no flash");

    (* ══════════════════════════════════════════════════════════════
       11. CSRF PROTECTION
       ══════════════════════════════════════════════════════════════ *)

    (* Get a CSRF token via GET *)
    let resp_csrf = Well.fetch ~headers:[("cookie", sid_cookie)] (url "/t/prod/csrf-token") in
    check "csrf: token non-empty" (String.length resp_csrf.body = 64);
    let csrf_token = resp_csrf.body in

    (* POST without CSRF token → 403 *)
    let resp_no_csrf = Well.fetch ~method_:"POST" ~headers:[("cookie", sid_cookie)]
      (url "/t/prod/csrf-check") in
    check "csrf: missing token 403" (resp_no_csrf.status = 403);
    check "csrf: 403 body" (contains_str ~needle:"CSRF" resp_no_csrf.body
                            || contains_str ~needle:"Forbidden" resp_no_csrf.body);

    (* POST with valid CSRF in form body → 200 *)
    let csrf_body = "_csrf_token=" ^ csrf_token in
    let resp_with_csrf = Well.fetch ~method_:"POST"
      ~headers:[("cookie", sid_cookie);
                ("content-type", "application/x-www-form-urlencoded")]
      ~body:csrf_body
      (url "/t/prod/csrf-check") in
    check "csrf: valid token 200" (resp_with_csrf.status = 200);
    check "csrf: valid body" (resp_with_csrf.body = "csrf ok");

    (* POST with CSRF in X-CSRF-Token header → 200 *)
    let resp_header_csrf = Well.fetch ~method_:"POST"
      ~headers:[("cookie", sid_cookie);
                ("x-csrf-token", csrf_token)]
      (url "/t/prod/csrf-check") in
    check "csrf: header token 200" (resp_header_csrf.status = 200);

    (* POST with wrong CSRF token → 403 *)
    let resp_bad_csrf = Well.fetch ~method_:"POST"
      ~headers:[("cookie", sid_cookie);
                ("x-csrf-token", "0000000000000000000000000000000000000000000000000000000000000000")]
      (url "/t/prod/csrf-check") in
    check "csrf: wrong token 403" (resp_bad_csrf.status = 403);

    (* XHR bypass — X-Requested-With: XMLHttpRequest skips CSRF *)
    let resp_xhr = Well.fetch ~method_:"POST"
      ~headers:[("cookie", sid_cookie);
                ("x-requested-with", "XMLHttpRequest")]
      (url "/t/prod/csrf-check") in
    check "csrf: XHR bypass 200" (resp_xhr.status = 200);

    (* GET/HEAD/OPTIONS skip CSRF *)
    let resp_get = Well.fetch ~headers:[("cookie", sid_cookie)] (url "/t/prod/csrf-token") in
    check "csrf: GET skips" (resp_get.status = 200);

    (* ══════════════════════════════════════════════════════════════
       12. ERROR HANDLING
       ══════════════════════════════════════════════════════════════ *)

    (* Runtime error → custom error handler returns 500 *)
    let resp = Well.fetch (url "/t/prod/error-custom") in
    check "error: custom handler 500" (resp.status = 500);
    check "error: custom body" (resp.body = "custom error page");

    (* Errors should not leak exception details *)
    let resp = Well.fetch (url "/t/prod/error-with-handler") in
    check "error: no stack trace" (not (contains_str ~needle:"Failure" resp.body));
    check "error: no file paths" (not (contains_str ~needle:".ml" resp.body));

    (* Auth_denied → proper status codes *)
    let resp = Well.fetch (url "/t/prod/auth-denied-401") in
    check "auth_denied: 401 status" (resp.status = 401);
    check "auth_denied: 401 body" (resp.body = "Unauthorized");

    let resp = Well.fetch (url "/t/prod/auth-denied-403") in
    check "auth_denied: 403 status" (resp.status = 403);
    check "auth_denied: 403 body" (resp.body = "Forbidden");

    (* Division by zero → 500, no leak *)
    let resp = Well.fetch (url "/t/prod/error-division") in
    check "error: division by zero 500" (resp.status = 500);
    check "error: no Division_by_zero leak" (not (contains_str ~needle:"Division_by_zero" resp.body));

    (* ══════════════════════════════════════════════════════════════
       13. MIDDLEWARE ORDERING
       ══════════════════════════════════════════════════════════════ *)

    order_log := [];
    let _ = Well.fetch (url "/t/prod/mw-order") in
    let log = List.rev !order_log in
    check "mw order: 5 entries" (List.length log = 5);
    check "mw order: A first" (List.nth log 0 = "A-before");
    check "mw order: B second" (List.nth log 1 = "B-before");
    check "mw order: handler middle" (List.nth log 2 = "handler");
    check "mw order: B unwind" (List.nth log 3 = "B-after");
    check "mw order: A unwind" (List.nth log 4 = "A-after");

    (* ══════════════════════════════════════════════════════════════
       14. POST WITH BODY
       ══════════════════════════════════════════════════════════════ *)

    let big_body = String.make 100_000 'X' in
    let resp = Well.fetch ~method_:"POST"
      ~headers:[("x-requested-with", "XMLHttpRequest")]
      ~body:big_body (url "/t/prod/body-size") in
    check "post: 100KB body" (resp.body = "100000");

    let resp = Well.fetch ~method_:"POST"
      ~headers:[("x-requested-with", "XMLHttpRequest")]
      ~body:"" (url "/t/prod/body-size") in
    check "post: empty body" (resp.body = "0");

    (* ══════════════════════════════════════════════════════════════
       15. RESPONSE HEADER STACKING
       ══════════════════════════════════════════════════════════════ *)

    let resp = Well.fetch (url "/t/prod/multi-header") in
    check "multi-header: status 201" (resp.status = 201);
    check "multi-header: X-One" (get_header "x-one" resp = Some "1");
    check "multi-header: X-Two" (get_header "x-two" resp = Some "2");

    (* ══════════════════════════════════════════════════════════════
       16. EMPTY / SPECIAL STATUS RESPONSES
       ══════════════════════════════════════════════════════════════ *)

    let resp = Well.fetch (url "/t/prod/204") in
    check "204: status" (resp.status = 204);
    check "204: empty body" (resp.body = "");

    (* ══════════════════════════════════════════════════════════════
       17. STREAMING RESPONSE
       ══════════════════════════════════════════════════════════════ *)

    let resp = Well.fetch (url "/t/prod/stream") in
    check "stream: status 200" (resp.status = 200);
    check "stream: body" (resp.body = "chunk1chunk2chunk3");
    (match get_header "content-type" resp with
     | Some ct -> check "stream: content-type" (contains_str ~needle:"text/plain" ct)
     | None -> check "stream: content-type present" false);

    (* ══════════════════════════════════════════════════════════════
       18. RATE LIMITING
       ══════════════════════════════════════════════════════════════ *)

    (* Use unique session for rate limit to avoid leaking from other tests *)
    let rl_headers = [("x-forwarded-for", "10.99.99.99")] in
    let resp1 = Well.fetch ~headers:rl_headers (url "/t/prod/rate-limited") in
    check "rate limit: req 1 ok" (resp1.status = 200);
    let resp2 = Well.fetch ~headers:rl_headers (url "/t/prod/rate-limited") in
    check "rate limit: req 2 ok" (resp2.status = 200);
    let resp3 = Well.fetch ~headers:rl_headers (url "/t/prod/rate-limited") in
    check "rate limit: req 3 ok" (resp3.status = 200);
    let resp4 = Well.fetch ~headers:rl_headers (url "/t/prod/rate-limited") in
    check "rate limit: req 4 blocked" (resp4.status = 429);

    (* Different IP should not be rate limited *)
    let resp_other = Well.fetch ~headers:[("x-forwarded-for", "10.88.88.88")]
      (url "/t/prod/rate-limited") in
    check "rate limit: different IP ok" (resp_other.status = 200);

    (* ══════════════════════════════════════════════════════════════
       19. STATIC FILE SERVING — PATH TRAVERSAL
       ══════════════════════════════════════════════════════════════ *)

    (* Traversal attempts — should all fail with 400 or 404 *)
    let resp = Well.fetch (url "/t/prod/static/../../../etc/passwd") in
    check "static traversal: ../ blocked" (resp.status >= 400);

    let resp = Well.fetch (url "/t/prod/static/%2e%2e/%2e%2e/etc/passwd") in
    check "static traversal: encoded ../ blocked" (resp.status >= 400);

    let resp = Well.fetch (url "/t/prod/static/..%2f..%2f..%2fetc/passwd") in
    check "static traversal: mixed encoding blocked" (resp.status >= 400);

    let resp = Well.fetch (url "/t/prod/static/file%00.txt") in
    check "static traversal: null byte blocked" (resp.status >= 400);

    (* ══════════════════════════════════════════════════════════════
       20. CONCURRENT REQUESTS
       ══════════════════════════════════════════════════════════════ *)

    (* Sequential burst — verify server handles many requests without degradation *)
    let all_ok = ref true in
    for i = 0 to 49 do
      let resp = Well.fetch (url (Printf.sprintf "/t/prod/echo/%d" i)) in
      if resp.body <> string_of_int i || resp.status <> 200 then
        all_ok := false
    done;
    check "burst: 50 sequential requests" !all_ok;

    (* ══════════════════════════════════════════════════════════════
       21. KEEP-ALIVE
       ══════════════════════════════════════════════════════════════ *)

    (* Connection header in response *)
    let resp = Well.fetch ~headers:[("connection", "keep-alive")] (url "/t/prod/ct-text") in
    (match get_header "connection" resp with
     | Some v -> check "keep-alive: response header" (String.lowercase_ascii v = "keep-alive")
     | None -> check "keep-alive: header present" false);

    let resp = Well.fetch ~headers:[("connection", "close")] (url "/t/prod/ct-text") in
    (match get_header "connection" resp with
     | Some v -> check "connection close: response header" (String.lowercase_ascii v = "close")
     | None -> check "connection close: or absent" true);

    (* ══════════════════════════════════════════════════════════════
       22. HEALTH / READY / METRICS ENDPOINTS
       ══════════════════════════════════════════════════════════════ *)

    let resp = Well.fetch (url "/health") in
    check "health: 200" (resp.status = 200);

    let resp = Well.fetch (url "/ready") in
    check "ready: 200" (resp.status = 200);
    check "ready: has status" (contains_str ~needle:"ready" resp.body);

    let resp = Well.fetch (url "/metrics") in
    check "metrics: 200" (resp.status = 200);
    check "metrics: has requests_total" (contains_str ~needle:"well_http_requests_total" resp.body);
    check "metrics: has latency" (contains_str ~needle:"well_http_latency_avg_us" resp.body);
    check "metrics: has rss" (contains_str ~needle:"well_process_rss_bytes" resp.body);

    (* ══════════════════════════════════════════════════════════════
       23. X-REQUEST-ID
       ══════════════════════════════════════════════════════════════ *)

    let resp = Well.fetch (url "/t/prod/ct-text") in
    check "request-id: present" (has_header "x-request-id" resp);
    (match get_header "x-request-id" resp with
     | Some rid -> check "request-id: 16 chars" (String.length rid = 16)
     | None -> ());

    (* Client-provided request-id should be echoed back *)
    let resp = Well.fetch ~headers:[("x-request-id", "custom-req-id-12")]
      (url "/t/prod/ct-text") in
    (match get_header "x-request-id" resp with
     | Some rid -> check "request-id: client provided" (rid = "custom-req-id-12")
     | None -> check "request-id: client provided" false);

    (* ══════════════════════════════════════════════════════════════
       24. METHOD OVERRIDE (GET/POST same path)
       ══════════════════════════════════════════════════════════════ *)

    let resp = Well.fetch (url "/t/prod/method-test") in
    check "method: GET response" (resp.body = "GET");

    let resp = Well.fetch ~method_:"POST"
      ~headers:[("x-requested-with", "XMLHttpRequest")]
      (url "/t/prod/method-test") in
    check "method: POST response" (resp.body = "POST");

    (* ══════════════════════════════════════════════════════════════
       DONE
       ══════════════════════════════════════════════════════════════ *)

    Printf.printf "Production tests: %d passed, %d failed\n%!" !pass !fail;
    exit (if !fail > 0 then 1 else 0)
  )
