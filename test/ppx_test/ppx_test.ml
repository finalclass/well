(* Test: [@@deriving table] + let%query *)
[@@@warning "-69-32"]

type user = {
  id : int;
  name : string;
  email : string;
  active : bool;
} [@@deriving table ~name:"users"]

type post = {
  id : int;
  user_id : int;
  title : string;
  body : string option;
} [@@deriving table ~name:"posts"]

(* Simple SELECT — all columns *)
let%query all_users = "SELECT id, name, email, active FROM users"

(* SELECT with WHERE — no params *)
let%query active_users = "SELECT id, name FROM users WHERE active = 1"

(* SELECT with :param *)
let%query user_by_id = "SELECT id, name, email FROM users WHERE id = :id"

(* SELECT with multiple params *)
let%query users_by_name_email =
  "SELECT id, name FROM users WHERE name = :name AND email = :email"

(* JOIN *)
let%query user_posts =
  "SELECT users.name, posts.title FROM users JOIN posts ON users.id = posts.user_id"

(* INSERT *)
let%query insert_user =
  "INSERT INTO users (name, email, active) VALUES (:name, :email, :active)"

(* UPDATE *)
let%query update_user_name =
  "UPDATE users SET name = :name WHERE id = :id"

(* DELETE *)
let%query delete_user =
  "DELETE FROM users WHERE id = :id"

(* SELECT with alias *)
let%query count_users = "SELECT COUNT(*) AS cnt FROM users"

let () =
  let db = Sqlite3.db_open ":memory:" in
  (* Create tables *)
  ignore (Sqlite3.exec db user_create_table_sql);
  ignore (Sqlite3.exec db post_create_table_sql);
  (* Insert test data *)
  Insert_user.exec db ~name:"Alice" ~email:"alice@example.com" ~active:1;
  Insert_user.exec db ~name:"Bob" ~email:"bob@example.com" ~active:0;
  (* Query all users *)
  let users = All_users.query db in
  assert (List.length users = 2);
  let alice = List.hd users in
  assert (alice.id = 1);
  assert (alice.name = "Alice");
  assert (alice.email = "alice@example.com");
  assert (alice.active = 1);
  (* Query active users *)
  let active = Active_users.query db in
  assert (List.length active = 1);
  assert ((List.hd active).name = "Alice");
  (* Query by id *)
  let by_id = User_by_id.query db ~id:2 in
  assert (List.length by_id = 1);
  assert ((List.hd by_id).name = "Bob");
  (* Query by name and email *)
  let found =
    Users_by_name_email.query db ~name:"Alice" ~email:"alice@example.com"
  in
  assert (List.length found = 1);
  (* Update *)
  Update_user_name.exec db ~name:"Bobby" ~id:2;
  let updated = User_by_id.query db ~id:2 in
  assert ((List.hd updated).name = "Bobby");
  (* Count *)
  let counts = Count_users.query db in
  assert (List.length counts = 1);
  assert ((List.hd counts).cnt = "2");
  (* Delete *)
  Delete_user.exec db ~id:1;
  let remaining = All_users.query db in
  assert (List.length remaining = 1);
  ignore (Sqlite3.db_close db);
  Printf.printf "All PPX tests passed!\n"
