(** Authentication, user management, OTP, and brute-force protection.

    Uses PBKDF2-SHA256 for password hashing. All data stored in the shared
    framework SQLite database ([well.sqlite]). *)

(* Uses PBKDF2-SHA256 for password hashing, SQLite for storage *)

(* ── Forward refs (wired by well.ml) ────────────────────────────── *)

let _session_get_ref : (string -> string -> string option) ref =
  ref (fun _ _ -> failwith "Auth._session_get_ref not wired")

let _session_set_ref : (string -> string -> string -> unit) ref =
  ref (fun _ _ _ -> failwith "Auth._session_set_ref not wired")

let _session_delete_ref : (string -> string -> unit) ref =
  ref (fun _ _ -> failwith "Auth._session_delete_ref not wired")

(* ── Types ─────────────────────────────────────────────────────── *)

(** A registered user record. *)
type user = {
  id : int;
  email : string;
  first_name : string;
  last_name : string;
  language : string;
  phone_number : string;
  is_archived : bool;
  created_at : string;
}

(* ── Configuration ────────────────────────────────────────────── *)

(** Mutable auth configuration (OTP lifetimes, brute-force thresholds). *)
type config = {
  mutable otp_lifetime_seconds : int;
  mutable otp_max_active : int;
  mutable otp_code_length : int;
  mutable login_failures_limit : int;
  mutable login_failure_window_seconds : int;
}

let _config = {
  otp_lifetime_seconds = 600;
  otp_max_active = 3;
  otp_code_length = 8;
  login_failures_limit = 5;
  login_failure_window_seconds = 3600;
}

(** Override default auth settings. Only provided parameters are changed. *)
let configure
    ?otp_lifetime_seconds
    ?otp_max_active
    ?otp_code_length
    ?login_failures_limit
    ?login_failure_window_seconds
    () =
  (match otp_lifetime_seconds with Some v -> _config.otp_lifetime_seconds <- v | None -> ());
  (match otp_max_active with Some v -> _config.otp_max_active <- v | None -> ());
  (match otp_code_length with Some v -> _config.otp_code_length <- v | None -> ());
  (match login_failures_limit with Some v -> _config.login_failures_limit <- v | None -> ());
  (match login_failure_window_seconds with Some v -> _config.login_failure_window_seconds <- v | None -> ())

(* ── Database — uses shared well.sqlite pool ─────────────────── *)

(** Create auth tables in [well.sqlite] if they do not exist yet. Idempotent. *)
let ensure_tables, _reset_tables = Db.once_resettable (fun db ->
    let _ = Sqlite3.exec db
      {|CREATE TABLE IF NOT EXISTS _well_users (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          email TEXT NOT NULL UNIQUE,
          password_hash TEXT NOT NULL,
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
        )|} in
    (* Profile columns — idempotent ALTER TABLE *)
    let add col def =
      let sql = Printf.sprintf
        "ALTER TABLE _well_users ADD COLUMN %s TEXT NOT NULL DEFAULT '%s'" col def in
      ignore (Sqlite3.exec db sql)
    in
    add "first_name" "";
    add "last_name" "";
    add "language" "pl";
    add "phone_number" "";
    ignore (Sqlite3.exec db
      "ALTER TABLE _well_users ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0");
    let _ = Sqlite3.exec db
      {|CREATE TABLE IF NOT EXISTS _well_grants (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id INTEGER NOT NULL,
          grant_name TEXT NOT NULL,
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
          UNIQUE(user_id, grant_name)
        )|} in
    let _ = Sqlite3.exec db
      {|CREATE TABLE IF NOT EXISTS _well_otps (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          email TEXT NOT NULL,
          code TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          expires_at INTEGER NOT NULL
        )|} in
    let _ = Sqlite3.exec db
      {|CREATE TABLE IF NOT EXISTS _well_login_attempts (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          email TEXT NOT NULL,
          ip TEXT NOT NULL DEFAULT '',
          is_valid INTEGER NOT NULL DEFAULT 0,
          occurred_at INTEGER NOT NULL,
          is_forgiven INTEGER NOT NULL DEFAULT 0
        )|} in
    let _ = Sqlite3.exec db
      {|CREATE TABLE IF NOT EXISTS _well_user_settings (
          user_id INTEGER PRIMARY KEY,
          settings TEXT NOT NULL DEFAULT '{}'
        )|} in
    ())

(* ── Hex helpers ───────────────────────────────────────────────── *)

let hex_encode s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter (fun c ->
    Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) s;
  Buffer.contents buf

let hex_decode s =
  let len = String.length s / 2 in
  let buf = Buffer.create len in
  for i = 0 to len - 1 do
    let hi = Char.code s.[i * 2] in
    let lo = Char.code s.[i * 2 + 1] in
    let hex_val c =
      if c >= 0x30 && c <= 0x39 then c - 0x30
      else if c >= 0x61 && c <= 0x66 then c - 0x61 + 10
      else if c >= 0x41 && c <= 0x46 then c - 0x41 + 10
      else 0
    in
    Buffer.add_char buf (Char.chr ((hex_val hi lsl 4) lor hex_val lo))
  done;
  Buffer.contents buf

(* ── PBKDF2-SHA256 ─────────────────────────────────────────────── *)

let hmac_sha256 ~key data =
  Digestif.SHA256.hmac_string ~key data |> Digestif.SHA256.to_raw_string

let pbkdf2 ~password ~salt ~iterations =
  let hash_len = 32 in (* SHA256 output *)
  (* PBKDF2 single block (dk_len <= hash_len, so one block suffices) *)
  let u0 = hmac_sha256 ~key:password (salt ^ "\000\000\000\001") in
  let result = Bytes.of_string u0 in
  let prev = ref u0 in
  for _ = 2 to iterations do
    let u = hmac_sha256 ~key:password !prev in
    for j = 0 to hash_len - 1 do
      Bytes.set result j
        (Char.chr (Char.code (Bytes.get result j) lxor Char.code u.[j]))
    done;
    prev := u
  done;
  Bytes.to_string result

let iterations = 100_000
let max_password_length = 1024

(* Dummy hash — burned on nonexistent user to prevent timing oracle *)
let _dummy_hash = ref ""
let get_dummy_hash () =
  if !_dummy_hash = "" then begin
    let salt = String.make 16 '\x00' in
    let hash = pbkdf2 ~password:"dummy" ~salt ~iterations in
    _dummy_hash := Printf.sprintf "pbkdf2-sha256$%d$%s$%s"
      iterations (hex_encode salt) (hex_encode hash)
  end;
  !_dummy_hash

(** Hash a password with PBKDF2-SHA256 and a random 16-byte salt. *)
let hash_password password =
  let salt = Mirage_crypto_rng.generate 16 in
  let hash = pbkdf2 ~password ~salt ~iterations in
  Printf.sprintf "pbkdf2-sha256$%d$%s$%s" iterations (hex_encode salt) (hex_encode hash)

(** Verify [password] against a stored [hash]. Uses constant-time comparison. *)
let verify_password ~password ~hash =
  match String.split_on_char '$' hash with
  | ["pbkdf2-sha256"; iter_s; salt_hex; hash_hex] ->
    let iter = match int_of_string_opt iter_s with Some i -> i | None -> 0 in
    if iter <= 0 then false
    else
      let salt = hex_decode salt_hex in
      let expected = hex_decode hash_hex in
      let computed = pbkdf2 ~password ~salt ~iterations:iter in
      (* Constant-time comparison *)
      let len = String.length expected in
      if String.length computed <> len then false
      else begin
        let diff = ref 0 in
        for i = 0 to len - 1 do
          diff := !diff lor (Char.code expected.[i] lxor Char.code computed.[i])
        done;
        !diff = 0
      end
  | _ -> false

(* ── Email normalization ───────────────────────────────────────── *)

(** Trim and lowercase an email address. *)
let normalize_email email =
  String.lowercase_ascii (String.trim email)

(** Basic structural validation of an email address. *)
let validate_email email =
  let len = String.length email in
  if len = 0 || len > 254 then false
  else
    match String.index_opt email '@' with
    | None -> false
    | Some at_pos ->
      let local = String.sub email 0 at_pos in
      let domain = String.sub email (at_pos + 1) (len - at_pos - 1) in
      String.length local > 0 && String.length local <= 64
      && String.length domain > 0
      && String.contains domain '.'
      (* Reject control chars and whitespace *)
      && not (String.exists (fun c -> c < ' ' || c = ' ') email)

(* ── Time helpers ─────────────────────────────────────────────── *)

let now_unix () = int_of_float (Unix.gettimeofday ())

(* ── Random code generation ───────────────────────────────────── *)

let generate_code len =
  let bytes = Mirage_crypto_rng.generate len in
  let buf = Buffer.create (len * 2) in
  String.iter (fun c ->
    Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) bytes;
  let hex = Buffer.contents buf in
  String.sub hex 0 len

let html_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (function
      | '&' -> Buffer.add_string buf "&amp;"
      | '<' -> Buffer.add_string buf "&lt;"
      | '>' -> Buffer.add_string buf "&gt;"
      | '"' -> Buffer.add_string buf "&quot;"
      | '\'' -> Buffer.add_string buf "&#39;"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

(* ── User row reader ─────────────────────────────────────────── *)

let _user_cols = "id, email, first_name, last_name, language, phone_number, is_archived, created_at"

let _read_user stmt =
  let id = Sqlite3.column_int stmt 0 in
  let email = Sqlite3.column_text stmt 1 in
  let first_name = Sqlite3.column_text stmt 2 in
  let last_name = Sqlite3.column_text stmt 3 in
  let language = Sqlite3.column_text stmt 4 in
  let phone_number = Sqlite3.column_text stmt 5 in
  let is_archived = Sqlite3.column_int stmt 6 <> 0 in
  let created_at = Sqlite3.column_text stmt 7 in
  { id; email; first_name; last_name; language; phone_number; is_archived; created_at }

(* ── Brute-force protection ──────────────────────────────────── *)

let _count_recent_failures db ~email =
  let cutoff = now_unix () - _config.login_failure_window_seconds in
  let stmt = Sqlite3.prepare db
    "SELECT COUNT(*) FROM _well_login_attempts WHERE email = ? AND is_valid = 0 AND is_forgiven = 0 AND occurred_at > ?" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT email) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.INT (Int64.of_int cutoff)) in
  let n =
    if Sqlite3.step stmt = Sqlite3.Rc.ROW then Sqlite3.column_int stmt 0
    else 0
  in
  let _ = Sqlite3.finalize stmt in
  n

let _record_attempt db ~email ~ip ~is_valid =
  let stmt = Sqlite3.prepare db
    "INSERT INTO _well_login_attempts (email, ip, is_valid, occurred_at) VALUES (?, ?, ?, ?)" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT email) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT ip) in
  let _ = Sqlite3.bind stmt 3 (Sqlite3.Data.INT (if is_valid then 1L else 0L)) in
  let _ = Sqlite3.bind stmt 4 (Sqlite3.Data.INT (Int64.of_int (now_unix ()))) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let _forgive_attempts db ~email =
  let stmt = Sqlite3.prepare db
    "UPDATE _well_login_attempts SET is_forgiven = 1 WHERE email = ? AND is_valid = 0 AND is_forgiven = 0" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT email) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

(* ── Core API ──────────────────────────────────────────────────── *)

(** Register a new user with email and password. Returns [Error] on validation failure or duplicate email. *)
let register ~email ~password ?(first_name = "") ?(last_name = "") () =
  let email = normalize_email email in
  if String.length password < 8 then
    Error "Password must be at least 8 characters"
  else if String.length password > max_password_length then
    Error "Password is too long"
  else if not (validate_email email) then
    Error "Invalid email address"
  else
    Db.with_well_db @@ fun db ->
    ensure_tables db;
    let password_hash = hash_password password in
    let stmt = Sqlite3.prepare db
      "INSERT INTO _well_users (email, password_hash, first_name, last_name) VALUES (?, ?, ?, ?)" in
    let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT email) in
    let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT password_hash) in
    let _ = Sqlite3.bind stmt 3 (Sqlite3.Data.TEXT first_name) in
    let _ = Sqlite3.bind stmt 4 (Sqlite3.Data.TEXT last_name) in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE ->
      let _ = Sqlite3.finalize stmt in
      let id = Int64.to_int (Sqlite3.last_insert_rowid db) in
      let sel = Sqlite3.prepare db
        (Printf.sprintf "SELECT %s FROM _well_users WHERE id = ?" _user_cols) in
      let _ = Sqlite3.bind sel 1 (Sqlite3.Data.INT (Int64.of_int id)) in
      (match Sqlite3.step sel with
       | Sqlite3.Rc.ROW ->
         let user = _read_user sel in
         let _ = Sqlite3.finalize sel in
         Ok user
       | _ ->
         let _ = Sqlite3.finalize sel in
         Ok { id; email; first_name; last_name; language = "pl";
              phone_number = ""; is_archived = false; created_at = "" })
    | _ ->
      let _ = Sqlite3.finalize stmt in
      Error "Email already taken"

(** Authenticate a user by email and password. Enforces brute-force limits. *)
let login ~email ~password ?(ip = "") () =
  let email = normalize_email email in
  (* Cap password length to prevent DoS via PBKDF2 on huge input *)
  if String.length password > max_password_length then
    Error "Invalid email or password"
  else
    Db.with_well_db @@ fun db ->
    ensure_tables db;
    (* Check brute-force limit *)
    let failures = _count_recent_failures db ~email in
    if failures >= _config.login_failures_limit then begin
      _record_attempt db ~email ~ip ~is_valid:false;
      Error "Account temporarily locked"
    end
    else
      let stmt = Sqlite3.prepare db
        (Printf.sprintf "SELECT %s, password_hash FROM _well_users WHERE email = ?" _user_cols) in
      let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT email) in
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let user = _read_user stmt in
        let pw_hash = Sqlite3.column_text stmt 8 in
        let _ = Sqlite3.finalize stmt in
        if user.is_archived then begin
          _record_attempt db ~email ~ip ~is_valid:false;
          Error "Invalid email or password"
        end
        else if verify_password ~password ~hash:pw_hash then begin
          _record_attempt db ~email ~ip ~is_valid:true;
          _forgive_attempts db ~email;
          Ok user
        end
        else begin
          _record_attempt db ~email ~ip ~is_valid:false;
          Error "Invalid email or password"
        end
      | _ ->
        let _ = Sqlite3.finalize stmt in
        (* Burn CPU on dummy hash to prevent timing oracle on email existence *)
        ignore (verify_password ~password ~hash:(get_dummy_hash ()));
        _record_attempt db ~email ~ip ~is_valid:false;
        Error "Invalid email or password"

(** Look up a user by integer [id]. Returns [None] if not found. *)
let get_user id =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let stmt = Sqlite3.prepare db
    (Printf.sprintf "SELECT %s FROM _well_users WHERE id = ?" _user_cols) in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int id)) in
  match Sqlite3.step stmt with
  | Sqlite3.Rc.ROW ->
    let user = _read_user stmt in
    let _ = Sqlite3.finalize stmt in
    Some user
  | _ ->
    let _ = Sqlite3.finalize stmt in
    None

(** Clear the current user from the session. *)
let logout (req : Types.request) =
  !_session_delete_ref req.session_id "user_id";
  !_session_delete_ref req.session_id "user_name"

(** Authenticate and store the user id in the session on success. *)
let login_and_set_session (req : Types.request) ~email ~password =
  let ip = match List.assoc_opt "x-forwarded-for" req.headers with
    | Some v -> (match String.split_on_char ',' v with h :: _ -> String.trim h | [] -> "")
    | None -> "" in
  match login ~email ~password ~ip () with
  | Ok user ->
    !_session_set_ref req.session_id "user_id" (string_of_int user.id);
    !_session_set_ref req.session_id "user_name" user.email;
    Ok user
  | Error _ as e -> e

(* ── Helpers for OAuth ─────────────────────────────────────────── *)

(** Open the framework database with auth tables ensured, then call [f]. *)
let with_db f =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  f db

(** Find a user by exact email (case-insensitive). *)
let find_user_by_email email =
  let email = normalize_email email in
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let stmt = Sqlite3.prepare db
    (Printf.sprintf "SELECT %s FROM _well_users WHERE email = ?" _user_cols) in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT email) in
  match Sqlite3.step stmt with
  | Sqlite3.Rc.ROW ->
    let user = _read_user stmt in
    let _ = Sqlite3.finalize stmt in
    Some user
  | _ ->
    let _ = Sqlite3.finalize stmt in
    None

(** Create a user with no password (for OAuth / OTP-only flows). *)
let create_user_without_password ~email =
  let email = normalize_email email in
  if not (validate_email email) then
    Error "Invalid email address"
  else
    Db.with_well_db @@ fun db ->
    ensure_tables db;
    let stmt = Sqlite3.prepare db
      "INSERT INTO _well_users (email, password_hash) VALUES (?, '')" in
    let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT email) in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE ->
      let _ = Sqlite3.finalize stmt in
      let id = Int64.to_int (Sqlite3.last_insert_rowid db) in
      let sel = Sqlite3.prepare db
        (Printf.sprintf "SELECT %s FROM _well_users WHERE id = ?" _user_cols) in
      let _ = Sqlite3.bind sel 1 (Sqlite3.Data.INT (Int64.of_int id)) in
      (match Sqlite3.step sel with
       | Sqlite3.Rc.ROW ->
         let user = _read_user sel in
         let _ = Sqlite3.finalize sel in
         Ok user
       | _ ->
         let _ = Sqlite3.finalize sel in
         Ok { id; email; first_name = ""; last_name = ""; language = "pl";
              phone_number = ""; is_archived = false; created_at = "" })
    | _ ->
      let _ = Sqlite3.finalize stmt in
      Error "Email already taken"

(* ── Profile management ──────────────────────────────────────── *)

(** Update profile fields for a user. Only provided fields are changed. *)
let edit_profile ~id ?first_name ?last_name ?language ?phone_number () =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let sets = ref [] in
  let vals = ref [] in
  (match first_name with Some v -> sets := "first_name = ?" :: !sets; vals := v :: !vals | None -> ());
  (match last_name with Some v -> sets := "last_name = ?" :: !sets; vals := v :: !vals | None -> ());
  (match language with Some v -> sets := "language = ?" :: !sets; vals := v :: !vals | None -> ());
  (match phone_number with Some v -> sets := "phone_number = ?" :: !sets; vals := v :: !vals | None -> ());
  if !sets = [] then Ok ()
  else
    let sql = Printf.sprintf "UPDATE _well_users SET %s WHERE id = ?"
      (String.concat ", " (List.rev !sets)) in
    let stmt = Sqlite3.prepare db sql in
    let i = ref 1 in
    List.iter (fun v ->
      let _ = Sqlite3.bind stmt !i (Sqlite3.Data.TEXT v) in
      incr i
    ) (List.rev !vals);
    let _ = Sqlite3.bind stmt !i (Sqlite3.Data.INT (Int64.of_int id)) in
    let _ = Sqlite3.step stmt in
    let _ = Sqlite3.finalize stmt in
    Ok ()

(** Set or clear the archived flag on a user. *)
let archive_user ~id ~is_archived () =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let stmt = Sqlite3.prepare db
    "UPDATE _well_users SET is_archived = ? WHERE id = ?" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (if is_archived then 1L else 0L)) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.INT (Int64.of_int id)) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

(** Query users with optional filters: [current] id, [ids] list, [email] substring. *)
let find_users ?current ?ids ?email ?(include_archived = false) () =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let base = Printf.sprintf "SELECT %s FROM _well_users" _user_cols in
  let wheres = ref [] in
  if not include_archived then
    wheres := "is_archived = 0" :: !wheres;
  (* Build query based on filters *)
  let bind_fns = ref [] in
  (match current with
   | Some uid ->
     wheres := "id = ?" :: !wheres;
     bind_fns := (fun stmt i ->
       let _ = Sqlite3.bind stmt i (Sqlite3.Data.INT (Int64.of_int uid)) in
       i + 1) :: !bind_fns
   | None -> ());
  (match ids with
   | Some id_list when id_list <> [] ->
     let placeholders = String.concat ", " (List.map (fun _ -> "?") id_list) in
     wheres := (Printf.sprintf "id IN (%s)" placeholders) :: !wheres;
     bind_fns := (fun stmt i ->
       let j = ref i in
       List.iter (fun id ->
         let _ = Sqlite3.bind stmt !j (Sqlite3.Data.INT (Int64.of_int id)) in
         incr j
       ) id_list;
       !j) :: !bind_fns
   | _ -> ());
  (match email with
   | Some e ->
     wheres := "email LIKE ?" :: !wheres;
     bind_fns := (fun stmt i ->
       let _ = Sqlite3.bind stmt i (Sqlite3.Data.TEXT ("%" ^ e ^ "%")) in
       i + 1) :: !bind_fns
   | None -> ());
  let where_clause = match !wheres with
    | [] -> ""
    | ws -> " WHERE " ^ String.concat " AND " (List.rev ws)
  in
  let sql = base ^ where_clause ^ " ORDER BY id" in
  let stmt = Sqlite3.prepare db sql in
  let idx = ref 1 in
  List.iter (fun f -> idx := f stmt !idx) (List.rev !bind_fns);
  let results = ref [] in
  while Sqlite3.step stmt = Sqlite3.Rc.ROW do
    results := _read_user stmt :: !results
  done;
  let _ = Sqlite3.finalize stmt in
  List.rev !results

(* ── OTP (One-Time Password) ─────────────────────────────────── *)

(** Generate a one-time password for [email]. Returns the code string on success. *)
let initiate_otp ~email () =
  let email = normalize_email email in
  if not (validate_email email) then
    Error "Invalid email address"
  else
    Db.with_well_db @@ fun db ->
    ensure_tables db;
    let now = now_unix () in
    (* Clean up expired OTPs *)
    let del = Sqlite3.prepare db
      "DELETE FROM _well_otps WHERE expires_at < ?" in
    let _ = Sqlite3.bind del 1 (Sqlite3.Data.INT (Int64.of_int now)) in
    let _ = Sqlite3.step del in
    let _ = Sqlite3.finalize del in
    (* Check active OTP count *)
    let cnt = Sqlite3.prepare db
      "SELECT COUNT(*) FROM _well_otps WHERE email = ? AND expires_at >= ?" in
    let _ = Sqlite3.bind cnt 1 (Sqlite3.Data.TEXT email) in
    let _ = Sqlite3.bind cnt 2 (Sqlite3.Data.INT (Int64.of_int now)) in
    let active =
      if Sqlite3.step cnt = Sqlite3.Rc.ROW then Sqlite3.column_int cnt 0
      else 0 in
    let _ = Sqlite3.finalize cnt in
    if active >= _config.otp_max_active then
      Error "Too many active codes"
    else
      let code = generate_code _config.otp_code_length in
      let expires_at = now + _config.otp_lifetime_seconds in
      let stmt = Sqlite3.prepare db
        "INSERT INTO _well_otps (email, code, created_at, expires_at) VALUES (?, ?, ?, ?)" in
      let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT email) in
      let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT code) in
      let _ = Sqlite3.bind stmt 3 (Sqlite3.Data.INT (Int64.of_int now)) in
      let _ = Sqlite3.bind stmt 4 (Sqlite3.Data.INT (Int64.of_int expires_at)) in
      let _ = Sqlite3.step stmt in
      let _ = Sqlite3.finalize stmt in
      Ok code

(** Generate a one-time password for [email] and deliver it via [Well.Mailer].
    The code is intentionally not returned to callers. *)
let initiate_otp_and_send ?(subject = "Your sign-in code") ~email () =
  match initiate_otp ~email () with
  | Error _ as error -> error
  | Ok code ->
    let email = normalize_email email in
    let minutes =
      max 1 ((_config.otp_lifetime_seconds + 59) / 60)
    in
    let html =
      Printf.sprintf
        {|<p>Your sign-in code is:</p><p><strong>%s</strong></p><p>This code expires in %d minutes.</p>|}
        (html_escape code)
        minutes
    in
    let text =
      Printf.sprintf
        "Your sign-in code is: %s\n\nThis code expires in %d minutes."
        code
        minutes
    in
    (match
       Mailer.send
         { to_ = [("", email)]
         ; subject
         ; html
         ; text
         }
     with
    | Ok () -> Ok ()
    | Error message -> Error message)

(** Verify an OTP code. On success, returns the user (auto-created if new). *)
let verify_otp ~email ~code ?(ip = "") () =
  let email = normalize_email email in
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let now = now_unix () in
  (* Find valid OTP *)
  let stmt = Sqlite3.prepare db
    "SELECT id FROM _well_otps WHERE email = ? AND code = ? AND expires_at >= ?" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT email) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT code) in
  let _ = Sqlite3.bind stmt 3 (Sqlite3.Data.INT (Int64.of_int now)) in
  match Sqlite3.step stmt with
  | Sqlite3.Rc.ROW ->
    let _ = Sqlite3.finalize stmt in
    (* Delete all OTPs for this email (single-use) *)
    let del = Sqlite3.prepare db
      "DELETE FROM _well_otps WHERE email = ?" in
    let _ = Sqlite3.bind del 1 (Sqlite3.Data.TEXT email) in
    let _ = Sqlite3.step del in
    let _ = Sqlite3.finalize del in
    (* Forgive login attempts on successful OTP *)
    _forgive_attempts db ~email;
    _record_attempt db ~email ~ip ~is_valid:true;
    (* Find or create user *)
    let user_stmt = Sqlite3.prepare db
      (Printf.sprintf "SELECT %s FROM _well_users WHERE email = ?" _user_cols) in
    let _ = Sqlite3.bind user_stmt 1 (Sqlite3.Data.TEXT email) in
    (match Sqlite3.step user_stmt with
     | Sqlite3.Rc.ROW ->
       let user = _read_user user_stmt in
       let _ = Sqlite3.finalize user_stmt in
       if user.is_archived then
         Error "Account is archived"
       else
         Ok user
     | _ ->
       let _ = Sqlite3.finalize user_stmt in
       (* Auto-create user without password for OTP-only flow *)
       let ins = Sqlite3.prepare db
         "INSERT INTO _well_users (email, password_hash) VALUES (?, '')" in
       let _ = Sqlite3.bind ins 1 (Sqlite3.Data.TEXT email) in
       (match Sqlite3.step ins with
        | Sqlite3.Rc.DONE ->
          let _ = Sqlite3.finalize ins in
          let id = Int64.to_int (Sqlite3.last_insert_rowid db) in
          Ok { id; email; first_name = ""; last_name = ""; language = "pl";
               phone_number = ""; is_archived = false; created_at = "" }
        | _ ->
          let _ = Sqlite3.finalize ins in
          Error "Failed to create user"))
  | _ ->
    let _ = Sqlite3.finalize stmt in
    _record_attempt db ~email ~ip ~is_valid:false;
    Error "Invalid or expired code"

(* ── User settings ───────────────────────────────────────────── *)

(** Retrieve JSON settings for a user. Returns [None] if no settings stored. *)
let get_settings ~user_id () =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let stmt = Sqlite3.prepare db
    "SELECT settings FROM _well_user_settings WHERE user_id = ?" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int user_id)) in
  match Sqlite3.step stmt with
  | Sqlite3.Rc.ROW ->
    let s = Sqlite3.column_text stmt 0 in
    let _ = Sqlite3.finalize stmt in
    (match Yojson.Safe.from_string s with
     | json -> Some json
     | exception _ -> Some (`Assoc []))
  | _ ->
    let _ = Sqlite3.finalize stmt in
    None

(** Store JSON settings for a user (insert or replace). *)
let set_settings ~user_id ~settings () =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let json_str = Yojson.Safe.to_string settings in
  let stmt = Sqlite3.prepare db
    "INSERT OR REPLACE INTO _well_user_settings (user_id, settings) VALUES (?, ?)" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int user_id)) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT json_str) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

(* ── Login attempt management ────────────────────────────────── *)

(** Forgive all failed login attempts for [email], resetting the lockout counter. *)
let reset_attempts ~email () =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let email = normalize_email email in
  _forgive_attempts db ~email

(** Count recent failed login attempts for [email] within the configured window. *)
let login_attempts ~email () =
  let email = normalize_email email in
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  _count_recent_failures db ~email

(* ── Grants ────────────────────────────────────────────────────── *)

(** Grant a named permission to a user. No-op if already granted. *)
let grant ~user_id name =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let stmt = Sqlite3.prepare db
    "INSERT OR IGNORE INTO _well_grants (user_id, grant_name) VALUES (?, ?)" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int user_id)) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT name) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

(** Revoke a named permission from a user. *)
let revoke ~user_id name =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let stmt = Sqlite3.prepare db
    "DELETE FROM _well_grants WHERE user_id = ? AND grant_name = ?" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int user_id)) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT name) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

(** Check whether a user holds a specific grant. *)
let has_grant ~user_id name =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let stmt = Sqlite3.prepare db
    "SELECT 1 FROM _well_grants WHERE user_id = ? AND grant_name = ?" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int user_id)) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT name) in
  let found = Sqlite3.step stmt = Sqlite3.Rc.ROW in
  let _ = Sqlite3.finalize stmt in
  found

(** List all grant names held by a user, sorted alphabetically. *)
let user_grants ~user_id =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let stmt = Sqlite3.prepare db
    "SELECT grant_name FROM _well_grants WHERE user_id = ? ORDER BY grant_name" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int user_id)) in
  let results = ref [] in
  while Sqlite3.step stmt = Sqlite3.Rc.ROW do
    results := Sqlite3.column_text stmt 0 :: !results
  done;
  let _ = Sqlite3.finalize stmt in
  List.rev !results

(* ── Middleware ─────────────────────────────────────────────────── *)

(** Raised by {!require_grant} when the user is missing or lacks the grant. *)
exception Auth_denied of int * string

(** Middleware: wrap a handler to require the session user holds [grant_name].
    Raises {!Auth_denied} with 401 or 403 on failure. *)
let require_grant grant_name (handler : Types.request -> _) (req : Types.request) =
  let user_id_opt = !_session_get_ref req.session_id "user_id" in
  match user_id_opt with
  | None -> raise (Auth_denied (401, "Unauthorized"))
  | Some uid_s ->
    match int_of_string_opt uid_s with
    | None -> raise (Auth_denied (401, "Unauthorized"))
    | Some user_id ->
      if has_grant ~user_id grant_name then
        handler req
      else
        raise (Auth_denied (403, "Forbidden"))

(* ── CRUD ─────────────────────────────────────────────────────── *)

(** List all users, optionally filtering by email substring and archive status. *)
let list_users ?(search = "") ?(include_archived = false) () =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let base = Printf.sprintf "SELECT %s FROM _well_users" _user_cols in
  let wheres = ref [] in
  if not include_archived then wheres := "is_archived = 0" :: !wheres;
  if search <> "" then wheres := "email LIKE ?" :: !wheres;
  let where_clause = match !wheres with
    | [] -> ""
    | ws -> " WHERE " ^ String.concat " AND " (List.rev ws)
  in
  let sql = base ^ where_clause ^ " ORDER BY id" in
  let stmt = Sqlite3.prepare db sql in
  if search <> "" then
    ignore (Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT ("%" ^ search ^ "%")));
  let results = ref [] in
  while Sqlite3.step stmt = Sqlite3.Rc.ROW do
    results := _read_user stmt :: !results
  done;
  let _ = Sqlite3.finalize stmt in
  List.rev !results

(** Permanently delete a user and their grants and settings. *)
let delete_user id =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let stmt = Sqlite3.prepare db "DELETE FROM _well_grants WHERE user_id = ?" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int id)) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  let stmt2 = Sqlite3.prepare db "DELETE FROM _well_user_settings WHERE user_id = ?" in
  let _ = Sqlite3.bind stmt2 1 (Sqlite3.Data.INT (Int64.of_int id)) in
  let _ = Sqlite3.step stmt2 in
  let _ = Sqlite3.finalize stmt2 in
  let stmt3 = Sqlite3.prepare db "DELETE FROM _well_users WHERE id = ?" in
  let _ = Sqlite3.bind stmt3 1 (Sqlite3.Data.INT (Int64.of_int id)) in
  let _ = Sqlite3.step stmt3 in
  let _ = Sqlite3.finalize stmt3 in
  ()

(** Change a user's email address. Returns [Error] if invalid or already taken. *)
let update_email id new_email =
  let new_email = normalize_email new_email in
  if not (validate_email new_email) then
    Error "Invalid email address"
  else
    Db.with_well_db @@ fun db ->
    ensure_tables db;
    let stmt = Sqlite3.prepare db "UPDATE _well_users SET email = ? WHERE id = ?" in
    let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT new_email) in
    let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.INT (Int64.of_int id)) in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE ->
      let _ = Sqlite3.finalize stmt in
      Ok ()
    | _ ->
      let _ = Sqlite3.finalize stmt in
      Error "Email already taken"

(** Set a new password for a user. Validates minimum length. *)
let set_password id password =
  if String.length password < 8 then
    Error "Password must be at least 8 characters"
  else if String.length password > max_password_length then
    Error "Password is too long"
  else
    Db.with_well_db @@ fun db ->
    ensure_tables db;
    let password_hash = hash_password password in
    let stmt = Sqlite3.prepare db "UPDATE _well_users SET password_hash = ? WHERE id = ?" in
    let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT password_hash) in
    let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.INT (Int64.of_int id)) in
    let _ = Sqlite3.step stmt in
    let _ = Sqlite3.finalize stmt in
    Ok ()

(** Create a user for seeding (no email validation, minimal password check). *)
let create_seed_user ~login ~password =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  if String.length password < 1 then Error "Password required"
  else
    let password_hash = hash_password password in
    let stmt = Sqlite3.prepare db
      "INSERT INTO _well_users (email, password_hash) VALUES (?, ?)" in
    let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT login) in
    let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT password_hash) in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE ->
      let _ = Sqlite3.finalize stmt in
      let id = Int64.to_int (Sqlite3.last_insert_rowid db) in
      Ok { id; email = login; first_name = ""; last_name = ""; language = "pl";
           phone_number = ""; is_archived = false; created_at = "" }
    | _ ->
      let _ = Sqlite3.finalize stmt in
      Error "User already exists"

(** Check whether any user in the system holds the given grant. *)
let has_any_grant name =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let stmt = Sqlite3.prepare db
    "SELECT 1 FROM _well_grants WHERE grant_name = ? LIMIT 1" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT name) in
  let found = Sqlite3.step stmt = Sqlite3.Rc.ROW in
  let _ = Sqlite3.finalize stmt in
  found

(** Count how many users hold the given grant. *)
let count_grant_holders name =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let stmt = Sqlite3.prepare db
    "SELECT COUNT(*) FROM _well_grants WHERE grant_name = ?" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT name) in
  let n =
    if Sqlite3.step stmt = Sqlite3.Rc.ROW then Sqlite3.column_int stmt 0
    else 0
  in
  let _ = Sqlite3.finalize stmt in
  n

(** Return all [(user_id, grant_name)] pairs, ordered by user then grant. *)
let all_grants () =
  Db.with_well_db @@ fun db ->
  ensure_tables db;
  let stmt = Sqlite3.prepare db
    "SELECT user_id, grant_name FROM _well_grants ORDER BY user_id, grant_name" in
  let results = ref [] in
  while Sqlite3.step stmt = Sqlite3.Rc.ROW do
    let user_id = Sqlite3.column_int stmt 0 in
    let name = Sqlite3.column_text stmt 1 in
    results := (user_id, name) :: !results
  done;
  let _ = Sqlite3.finalize stmt in
  List.rev !results

(* ── Lifecycle ─────────────────────────────────────────────────── *)

(** Reset internal state so tables are re-created on next use. *)
let close () =
  _reset_tables ()
