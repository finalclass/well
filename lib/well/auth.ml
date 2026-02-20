(* Well.Auth — password-based authentication + flat grants *)
(* Uses PBKDF2-SHA256 for password hashing, SQLite for storage *)

(* ── Forward refs (wired by well.ml) ────────────────────────────── *)

let _session_get_ref : (string -> string -> string option) ref =
  ref (fun _ _ -> failwith "Auth._session_get_ref not wired")

let _session_set_ref : (string -> string -> string -> unit) ref =
  ref (fun _ _ _ -> failwith "Auth._session_set_ref not wired")

let _session_delete_ref : (string -> string -> unit) ref =
  ref (fun _ _ -> failwith "Auth._session_delete_ref not wired")

(* ── Types ─────────────────────────────────────────────────────── *)

type user = {
  id : int;
  email : string;
  created_at : string;
}

(* ── Database ──────────────────────────────────────────────────── *)

let db : Sqlite3.db option ref = ref None
let mu = Mutex.create ()

let get_db () =
  match !db with
  | Some d -> d
  | None ->
    let path = "data/auth.sqlite" in
    (try Unix.mkdir "data" 0o755
     with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let d = Sqlite3.db_open path in
    let _ = Sqlite3.exec d "PRAGMA journal_mode=WAL" in
    let _ = Sqlite3.exec d "PRAGMA synchronous=NORMAL" in
    let _ = Sqlite3.exec d
      {|CREATE TABLE IF NOT EXISTS users (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          email TEXT NOT NULL UNIQUE,
          password_hash TEXT NOT NULL,
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
        )|} in
    let _ = Sqlite3.exec d
      {|CREATE TABLE IF NOT EXISTS grants (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id INTEGER NOT NULL,
          grant_name TEXT NOT NULL,
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
          UNIQUE(user_id, grant_name)
        )|} in
    db := Some d;
    d

let with_lock f =
  Mutex.lock mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock mu) f

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

let hash_password password =
  let salt = Mirage_crypto_rng.generate 16 in
  let hash = pbkdf2 ~password ~salt ~iterations in
  Printf.sprintf "pbkdf2-sha256$%d$%s$%s" iterations (hex_encode salt) (hex_encode hash)

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

let normalize_email email =
  String.lowercase_ascii (String.trim email)

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

(* ── Core API ──────────────────────────────────────────────────── *)

let register ~email ~password =
  let email = normalize_email email in
  if String.length password < 8 then
    Error "Password must be at least 8 characters"
  else if String.length password > max_password_length then
    Error "Password is too long"
  else if not (validate_email email) then
    Error "Invalid email address"
  else
    with_lock @@ fun () ->
    let db = get_db () in
    let password_hash = hash_password password in
    let stmt = Sqlite3.prepare db
      "INSERT INTO users (email, password_hash) VALUES (?, ?)" in
    let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT email) in
    let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT password_hash) in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE ->
      let _ = Sqlite3.finalize stmt in
      let id = Int64.to_int (Sqlite3.last_insert_rowid db) in
      let sel = Sqlite3.prepare db
        "SELECT created_at FROM users WHERE id = ?" in
      let _ = Sqlite3.bind sel 1 (Sqlite3.Data.INT (Int64.of_int id)) in
      let created_at = match Sqlite3.step sel with
        | Sqlite3.Rc.ROW -> Sqlite3.column_text sel 0
        | _ -> "" in
      let _ = Sqlite3.finalize sel in
      Ok { id; email; created_at }
    | _ ->
      let _ = Sqlite3.finalize stmt in
      Error "Email already taken"

let login ~email ~password =
  let email = normalize_email email in
  (* Cap password length to prevent DoS via PBKDF2 on huge input *)
  if String.length password > max_password_length then
    Error "Invalid email or password"
  else
    with_lock @@ fun () ->
    let db = get_db () in
    let stmt = Sqlite3.prepare db
      "SELECT id, email, password_hash, created_at FROM users WHERE email = ?" in
    let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT email) in
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      let id = Sqlite3.column_int stmt 0 in
      let email = Sqlite3.column_text stmt 1 in
      let pw_hash = Sqlite3.column_text stmt 2 in
      let created_at = Sqlite3.column_text stmt 3 in
      let _ = Sqlite3.finalize stmt in
      if verify_password ~password ~hash:pw_hash then
        Ok { id; email; created_at }
      else
        Error "Invalid email or password"
    | _ ->
      let _ = Sqlite3.finalize stmt in
      (* Burn CPU on dummy hash to prevent timing oracle on email existence *)
      ignore (verify_password ~password ~hash:(get_dummy_hash ()));
      Error "Invalid email or password"

let get_user id =
  with_lock @@ fun () ->
  let db = get_db () in
  let stmt = Sqlite3.prepare db
    "SELECT id, email, created_at FROM users WHERE id = ?" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int id)) in
  match Sqlite3.step stmt with
  | Sqlite3.Rc.ROW ->
    let id = Sqlite3.column_int stmt 0 in
    let email = Sqlite3.column_text stmt 1 in
    let created_at = Sqlite3.column_text stmt 2 in
    let _ = Sqlite3.finalize stmt in
    Some { id; email; created_at }
  | _ ->
    let _ = Sqlite3.finalize stmt in
    None

let logout (req : Types.request) =
  !_session_delete_ref req.session_id "user_id";
  !_session_delete_ref req.session_id "user_name"

let login_and_set_session (req : Types.request) ~email ~password =
  match login ~email ~password with
  | Ok user ->
    !_session_set_ref req.session_id "user_id" (string_of_int user.id);
    !_session_set_ref req.session_id "user_name" user.email;
    Ok user
  | Error _ as e -> e

(* ── Grants ────────────────────────────────────────────────────── *)

let grant ~user_id name =
  with_lock @@ fun () ->
  let db = get_db () in
  let stmt = Sqlite3.prepare db
    "INSERT OR IGNORE INTO grants (user_id, grant_name) VALUES (?, ?)" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int user_id)) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT name) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let revoke ~user_id name =
  with_lock @@ fun () ->
  let db = get_db () in
  let stmt = Sqlite3.prepare db
    "DELETE FROM grants WHERE user_id = ? AND grant_name = ?" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int user_id)) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT name) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let has_grant ~user_id name =
  with_lock @@ fun () ->
  let db = get_db () in
  let stmt = Sqlite3.prepare db
    "SELECT 1 FROM grants WHERE user_id = ? AND grant_name = ?" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int user_id)) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT name) in
  let found = Sqlite3.step stmt = Sqlite3.Rc.ROW in
  let _ = Sqlite3.finalize stmt in
  found

let user_grants ~user_id =
  with_lock @@ fun () ->
  let db = get_db () in
  let stmt = Sqlite3.prepare db
    "SELECT grant_name FROM grants WHERE user_id = ? ORDER BY grant_name" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int user_id)) in
  let results = ref [] in
  while Sqlite3.step stmt = Sqlite3.Rc.ROW do
    results := Sqlite3.column_text stmt 0 :: !results
  done;
  let _ = Sqlite3.finalize stmt in
  List.rev !results

(* ── Middleware ─────────────────────────────────────────────────── *)

exception Auth_denied of int * string

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

(* ── Lifecycle ─────────────────────────────────────────────────── *)

let close () =
  with_lock @@ fun () ->
  match !db with
  | Some d -> ignore (Sqlite3.db_close d); db := None
  | None -> ()
