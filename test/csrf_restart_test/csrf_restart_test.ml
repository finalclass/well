let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then incr pass
  else begin
    incr fail;
    Printf.eprintf "FAIL: %s\n%!" name
  end

let mk_req session_id : Well.request =
  { meth = "GET"; path = "/"; headers = []; body = "";
    params = []; query = []; session_id; _context = [] }

let token_for session_id =
  let resolved =
    Well.resolve
      (Well.csrf (fun req -> `Text (Well.csrf_token req)) (mk_req session_id))
  in
  resolved.r_body

let submit ?token session_id =
  let headers =
    match token with
    | Some token -> [("x-csrf-token", token)]
    | None -> []
  in
  let resolved =
    Well.resolve
      (Well.csrf (fun _ -> `Text "accepted")
         { (mk_req session_id) with meth = "POST"; headers })
  in
  resolved.r_status

let read path =
  let channel = open_in path in
  let line = input_line channel in
  close_in channel;
  line

let write path line =
  let channel = open_out path in
  output_string channel (line ^ "\n");
  close_out channel

let signed_in = "csrf-restart-signed-in"
let anonymous = "csrf-restart-anonymous"

let issue () =
  Well.Session.set ~session_id:signed_in ~key:"user" ~value:"anna";
  write "signed-in.token" (token_for signed_in);
  write "anonymous.token" (token_for anonymous)

let verify () =
  let before = read "signed-in.token" in
  check "a token issued before a restart is non-empty" (before <> "");
  check "a form rendered before a restart is accepted after it"
    (submit ~token:before signed_in = 200);
  check "an anonymous form rendered before a restart is accepted after it"
    (submit ~token:(read "anonymous.token") anonymous = 200);
  check "a token of another session is refused"
    (submit ~token:before anonymous = 403);
  check "a missing token is refused" (submit signed_in = 403);
  let regenerated, _ = Well.session_regenerate (mk_req signed_in) in
  check "a regenerated session accepts the same form"
    (submit ~token:before regenerated.session_id = 200);
  check "the replaced session no longer accepts it"
    (submit ~token:before signed_in = 403);
  Well.Middleware.cleanup_csrf_tokens ();
  check "cleanup keeps the token of a session with data"
    (submit ~token:before regenerated.session_id = 200);
  check "cleanup drops the token of a session without data"
    (submit ~token:(read "anonymous.token") anonymous = 403)

let () =
  Mirage_crypto_rng_unix.use_default ();
  (match Sys.argv.(1) with
   | "issue" -> issue ()
   | _ -> verify ());
  Well.Db.close_well_db ();
  if Sys.argv.(1) <> "issue" then
    Printf.printf "csrf restart tests: %d passed, %d failed\n%!" !pass !fail;
  exit (if !fail > 0 then 1 else 0)
