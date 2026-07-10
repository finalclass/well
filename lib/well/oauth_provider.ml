(** Well.OAuthProvider -- OAuth 2.0 Authorization Server.
    Simple Authorization Code flow where session_id serves as the access token. *)

(* ── Forward refs (wired by well.ml) ────────────────────────────── *)

let _session_get_ref : (string -> string -> string option) ref =
  ref (fun _ _ -> failwith "Oauth_provider._session_get_ref not wired")

let _session_set_ref : (string -> string -> string -> unit) ref =
  ref (fun _ _ _ -> failwith "Oauth_provider._session_set_ref not wired")

let _session_delete_ref : (string -> string -> unit) ref =
  ref (fun _ _ -> failwith "Oauth_provider._session_delete_ref not wired")

let _session_clear_ref : (string -> unit) ref =
  ref (fun _ -> failwith "Oauth_provider._session_clear_ref not wired")

let _login_ref :
    (   email:string
     -> password:string
     -> ?ip:string
     -> unit
     -> (Auth.user, string) result )
    ref =
  ref (fun ~email:_ ~password:_ ?ip:_ () ->
      failwith "Oauth_provider._login_ref not wired" )

let _current_user_ref : (Types.request -> string option) ref =
  ref (fun _ -> failwith "Oauth_provider._current_user_ref not wired")

let _register_get_ref :
    (   string
     -> (Types.request -> Types.response)
     -> unit )
    ref =
  ref (fun _ _ -> failwith "Oauth_provider._register_get_ref not wired")

let _register_post_ref :
    (   string
     -> (Types.request -> Types.response)
     -> unit )
    ref =
  ref (fun _ _ -> failwith "Oauth_provider._register_post_ref not wired")

(* Not needed currently — session_regenerate used in well.ml wiring only *)

let _log_ref : (string -> unit) ref = ref (fun _ -> ())

(* ── Types ──────────────────────────────────────────────────────── *)

(** An OAuth client application with allowed redirect URIs. *)
type client =
  { client_id: string
  ; redirect_uris: string list
  ; name: string }

(** OAuth provider configuration: registered clients and login page customization. *)
type config =
  { clients: client list
  ; login_title: string
  ; login_subtitle: string }

(* ── Crypto helpers ─────────────────────────────────────────────── *)

let hex_encode s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter
    (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c)))
    s ;
  Buffer.contents buf

let generate_code () = hex_encode (Mirage_crypto_rng.generate 32)

let constant_time_equal a b =
  let len_a = String.length a in
  let len_b = String.length b in
  if len_a <> len_b
  then false
  else
    let r = ref 0 in
    for i = 0 to len_a - 1 do
      r := !r lor (Char.code a.[i] lxor Char.code b.[i])
    done ;
    !r = 0

(* ── URL helpers ────────────────────────────────────────────────── *)

let url_encode str =
  let buf = Buffer.create (String.length str * 3) in
  String.iter
    (fun c ->
      match c with
      | 'A' .. 'Z'
       |'a' .. 'z'
       |'0' .. '9'
       |'_'
       |'-'
       |'~'
       |'.' ->
          Buffer.add_char buf c
      | _ -> Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c)) )
    str ;
  Buffer.contents buf

let url_decode s =
  let len = String.length s in
  let buf = Buffer.create len in
  let i = ref 0 in
  while !i < len do
    if s.[!i] = '%' && !i + 2 < len
    then begin
      let hi = Char.code s.[!i + 1] in
      let lo = Char.code s.[!i + 2] in
      let hex c =
        if c >= Char.code '0' && c <= Char.code '9'
        then c - Char.code '0'
        else if c >= Char.code 'a' && c <= Char.code 'f'
        then c - Char.code 'a' + 10
        else if c >= Char.code 'A' && c <= Char.code 'F'
        then c - Char.code 'A' + 10
        else -1
      in
      let h = hex hi and l = hex lo in
      if h >= 0 && l >= 0
      then begin
        Buffer.add_char buf (Char.chr ((h * 16) + l)) ;
        i := !i + 3
      end
      else begin
        Buffer.add_char buf s.[!i] ;
        incr i
      end
    end
    else if s.[!i] = '+'
    then begin
      Buffer.add_char buf ' ' ;
      incr i
    end
    else begin
      Buffer.add_char buf s.[!i] ;
      incr i
    end
  done ;
  Buffer.contents buf

let parse_form_body body =
  String.split_on_char '&' body
  |> List.filter_map (fun pair ->
      match String.split_on_char '=' pair with
      | [k; v] -> Some (url_decode k, url_decode v)
      | [k] -> Some (url_decode k, "")
      | _ -> None )

(* ── Database — authorization codes in well.sqlite ───────────── *)

let ensure_tables = Db.once (fun db ->
    let _ =
      Sqlite3.exec
        db
        {|CREATE TABLE IF NOT EXISTS _well_oauth_codes (
          code TEXT PRIMARY KEY,
          client_id TEXT NOT NULL,
          redirect_uri TEXT NOT NULL,
          session_id TEXT NOT NULL,
          user_id INTEGER NOT NULL,
          created_at REAL NOT NULL
        )|}
    in
    ())

(* ── Code store ─────────────────────────────────────────────────── *)

(* Codes expire after 60 seconds (OAuth 2.0 spec recommends short-lived) *)
let code_lifetime = 60.0

let store_code ~code ~client_id ~redirect_uri ~session_id ~user_id =
  Db.with_well_db @@ fun db ->
  ensure_tables db ;
  let now = Unix.gettimeofday () in
  let stmt =
    Sqlite3.prepare
      db
      "INSERT INTO _well_oauth_codes (code, client_id, redirect_uri, \
       session_id, user_id, created_at) VALUES (?, ?, ?, ?, ?, ?)"
  in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT code) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT client_id) in
  let _ = Sqlite3.bind stmt 3 (Sqlite3.Data.TEXT redirect_uri) in
  let _ = Sqlite3.bind stmt 4 (Sqlite3.Data.TEXT session_id) in
  let _ = Sqlite3.bind stmt 5 (Sqlite3.Data.INT (Int64.of_int user_id)) in
  let _ = Sqlite3.bind stmt 6 (Sqlite3.Data.FLOAT now) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let consume_code ~code ~client_id ~redirect_uri =
  Db.with_well_db @@ fun db ->
  ensure_tables db ;
  let now = Unix.gettimeofday () in
  let stmt =
    Sqlite3.prepare
      db
      "SELECT session_id, user_id, created_at FROM _well_oauth_codes WHERE \
       code = ? AND client_id = ? AND redirect_uri = ?"
  in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT code) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT client_id) in
  let _ = Sqlite3.bind stmt 3 (Sqlite3.Data.TEXT redirect_uri) in
  let result =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
        let session_id = Sqlite3.column_text stmt 0 in
        let user_id = Sqlite3.column_int stmt 1 in
        let created_at = Sqlite3.column_double stmt 2 in
        if now -. created_at > code_lifetime
        then None (* expired *)
        else Some (session_id, user_id)
    | _ -> None
  in
  let _ = Sqlite3.finalize stmt in
  (* Always delete the code (single-use) *)
  let del = Sqlite3.prepare db "DELETE FROM _well_oauth_codes WHERE code = ?" in
  let _ = Sqlite3.bind del 1 (Sqlite3.Data.TEXT code) in
  let _ = Sqlite3.step del in
  let _ = Sqlite3.finalize del in
  result

let cleanup_expired_codes () =
  Db.with_well_db @@ fun db ->
  ensure_tables db ;
  let now = Unix.gettimeofday () in
  let stmt =
    Sqlite3.prepare db "DELETE FROM _well_oauth_codes WHERE created_at < ?"
  in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.FLOAT (now -. code_lifetime)) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

(* ── Client validation ──────────────────────────────────────────── *)

let _clients : (string, client) Hashtbl.t = Hashtbl.create 8

let find_client client_id = Hashtbl.find_opt _clients client_id

let validate_redirect_uri client uri =
  List.exists
    (fun allowed ->
      (* Exact match or prefix match for path-based redirects *)
      String.length uri >= String.length allowed
      && String.sub uri 0 (String.length allowed) = allowed )
    client.redirect_uris

(* ── HTML templates ─────────────────────────────────────────────── *)

let escape_html s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | '&' -> Buffer.add_string buf "&amp;"
      | '<' -> Buffer.add_string buf "&lt;"
      | '>' -> Buffer.add_string buf "&gt;"
      | '"' -> Buffer.add_string buf "&quot;"
      | '\'' -> Buffer.add_string buf "&#x27;"
      | _ -> Buffer.add_char buf c )
    s ;
  Buffer.contents buf

let login_page ~title ~subtitle ~client_id ~redirect_uri ~state ?(error = "") ()
    : Types.response =
  let error_html =
    if error = ""
    then ""
    else
      Printf.sprintf
        {|<div style="color:#dc2626;background:#fef2f2;border:1px solid #fecaca;padding:12px 16px;border-radius:8px;margin-bottom:20px;font-size:14px">%s</div>|}
        (escape_html error)
  in
  (Html.raw
     (Printf.sprintf
        {|<!DOCTYPE html>
<html lang="pl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>%s — Logowanie</title>
  <style>
    *{margin:0;padding:0;box-sizing:border-box}
    body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#f8fafc;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:20px}
    .card{background:#fff;border-radius:12px;box-shadow:0 1px 3px rgba(0,0,0,.1);padding:40px;width:100%%;max-width:400px}
    h1{font-size:24px;font-weight:700;color:#0f172a;margin-bottom:4px}
    .subtitle{color:#64748b;font-size:14px;margin-bottom:28px}
    label{display:block;font-size:14px;font-weight:500;color:#334155;margin-bottom:6px}
    input[type=email],input[type=password]{width:100%%;padding:10px 14px;border:1px solid #e2e8f0;border-radius:8px;font-size:15px;outline:none;transition:border .15s}
    input:focus{border-color:#3b82f6;box-shadow:0 0 0 3px rgba(59,130,246,.1)}
    .field{margin-bottom:18px}
    button{width:100%%;padding:12px;background:#0f172a;color:#fff;border:none;border-radius:8px;font-size:15px;font-weight:600;cursor:pointer;transition:background .15s}
    button:hover{background:#1e293b}
  </style>
</head>
<body>
  <div class="card">
    <h1>%s</h1>
    <p class="subtitle">%s</p>
    %s
    <form method="POST" action="/oauth/authorize">
      <input type="hidden" name="client_id" value="%s">
      <input type="hidden" name="redirect_uri" value="%s">
      <input type="hidden" name="state" value="%s">
      <div class="field">
        <label for="email">Email</label>
        <input type="email" id="email" name="email" required autofocus autocomplete="email">
      </div>
      <div class="field">
        <label for="password">Hasło</label>
        <input type="password" id="password" name="password" required autocomplete="current-password">
      </div>
      <button type="submit">Zaloguj się</button>
    </form>
  </div>
</body>
</html>|}
        (escape_html title)
        (escape_html title)
        (escape_html subtitle)
        error_html
        (escape_html client_id)
        (escape_html redirect_uri)
        (escape_html state))
   :> Types.response)

(* ── Setup — registers OAuth provider routes ─────────────────── *)

let _config : config option ref = ref None

(** Register OAuth clients and configure the authorization server. Call before [Well.run]. *)
let setup
    ?(title = "Logowanie")
    ?(subtitle = "Zaloguj się, aby kontynuować")
    (clients : client list) =
  List.iter (fun c -> Hashtbl.replace _clients c.client_id c) clients ;
  _config := Some {clients; login_title= title; login_subtitle= subtitle}

let _register_routes () =
  match !_config with
  | None -> ()
  | Some {login_title= title; login_subtitle= subtitle; _} ->
      (* GET /oauth/authorize — show login form or redirect if already logged in *)
      !_register_get_ref "/oauth/authorize" (fun req ->
          let client_id =
            match List.assoc_opt "client_id" req.query with
            | Some v -> v
            | None -> ""
          in
          let redirect_uri =
            match List.assoc_opt "redirect_uri" req.query with
            | Some v -> v
            | None -> ""
          in
          let response_type =
            match List.assoc_opt "response_type" req.query with
            | Some v -> v
            | None -> ""
          in
          let state =
            match List.assoc_opt "state" req.query with
            | Some v -> v
            | None -> ""
          in

          (* Validate client_id *)
          match find_client client_id with
          | None ->
              !_log_ref (Printf.sprintf "OAuth: unknown client_id=%s" client_id) ;
              (login_page
                   ~title
                   ~subtitle
                   ~client_id
                   ~redirect_uri
                   ~state
                   ~error:"Nieprawidłowy client_id"
                   () )
          | Some client ->
              (* Validate redirect_uri *)
              if not (validate_redirect_uri client redirect_uri)
              then begin
                !_log_ref
                  (Printf.sprintf
                     "OAuth: invalid redirect_uri=%s for client=%s"
                     redirect_uri
                     client_id ) ;
                (login_page
                     ~title
                     ~subtitle
                     ~client_id
                     ~redirect_uri
                     ~state
                     ~error:"Nieprawidłowy redirect_uri"
                     () )
              end (* Validate response_type *)
              else if response_type <> "code"
              then
                (login_page
                     ~title
                     ~subtitle
                     ~client_id
                     ~redirect_uri
                     ~state
                     ~error:"response_type musi być 'code'"
                     () )
              else begin
                (* Check if user already logged in *)
                let debug_msg =
                  Printf.sprintf
                    "DEBUG authorize: client=%s, session=%s"
                    client_id
                    req.session_id
                in
                print_endline debug_msg ;
                match !_current_user_ref req with
                | Some user_id_str ->
                    let debug_msg2 =
                      Printf.sprintf
                        "DEBUG authorize: already logged in, user=%s"
                        user_id_str
                    in
                    print_endline debug_msg2 ;
                    (* Already logged in — issue code directly *)
                    let user_id = int_of_string user_id_str in
                    let code = generate_code () in
                    store_code
                      ~code
                      ~client_id
                      ~redirect_uri
                      ~session_id:req.session_id
                      ~user_id ;
                    let sep =
                      if String.contains redirect_uri '?' then "&" else "?"
                    in
                    let target =
                      Printf.sprintf
                        "%s%scode=%s%s"
                        redirect_uri
                        sep
                        (url_encode code)
                        (if state = "" then "" else "&state=" ^ url_encode state)
                    in
                    `Redirect target
                | None ->
                    let debug_msg3 =
                      "DEBUG authorize: not logged in, showing login form"
                    in
                    print_endline debug_msg3 ;
                    (* Show login form *)
                    (login_page
                         ~title
                         ~subtitle
                         ~client_id
                         ~redirect_uri
                         ~state
                         () )
              end ) ;

      (* POST /oauth/authorize — handle login form submission *)
      !_register_post_ref "/oauth/authorize" (fun req ->
          let form = parse_form_body req.body in
          let get k =
            match List.assoc_opt k form with
            | Some v -> v
            | None -> ""
          in
          let client_id = get "client_id" in
          let redirect_uri = get "redirect_uri" in
          let state = get "state" in
          let email = get "email" in
          let password = get "password" in

          (* Re-validate client + redirect_uri *)
          match find_client client_id with
          | None ->
              (login_page
                   ~title
                   ~subtitle
                   ~client_id
                   ~redirect_uri
                   ~state
                   ~error:"Nieprawidłowy client_id"
                   () )
          | Some client ->
              if not (validate_redirect_uri client redirect_uri)
              then
                (login_page
                     ~title
                     ~subtitle
                     ~client_id
                     ~redirect_uri
                     ~state
                     ~error:"Nieprawidłowy redirect_uri"
                     () )
              else
                (* Authenticate *)
                begin match !_login_ref ~email ~password () with
                | Error _msg ->
                    (login_page
                         ~title
                         ~subtitle
                         ~client_id
                         ~redirect_uri
                         ~state
                         ~error:"Nieprawidłowy email lub hasło"
                         () )
                | Ok user ->
                    (* Set session *)
                    !_session_set_ref
                      req.session_id
                      "user_id"
                      (string_of_int user.Auth.id) ;
                    !_session_set_ref req.session_id "user_name" user.Auth.email ;
                    (* Generate authorization code *)
                    let code = generate_code () in
                    store_code
                      ~code
                      ~client_id
                      ~redirect_uri
                      ~session_id:req.session_id
                      ~user_id:user.Auth.id ;
                    (* Redirect back to client with code *)
                    let sep =
                      if String.contains redirect_uri '?' then "&" else "?"
                    in
                    let target =
                      Printf.sprintf
                        "%s%scode=%s%s"
                        redirect_uri
                        sep
                        (url_encode code)
                        (if state = "" then "" else "&state=" ^ url_encode state)
                    in
                    `Redirect target
                end ) ;

      (* POST /oauth/token — exchange code for session_id *)
      !_register_post_ref "/oauth/token" (fun req ->
          let form = parse_form_body req.body in
          let get k =
            match List.assoc_opt k form with
            | Some v -> v
            | None -> ""
          in
          let grant_type = get "grant_type" in
          let code = get "code" in
          let client_id = get "client_id" in
          let redirect_uri = get "redirect_uri" in

          if grant_type <> "authorization_code"
          then `Assoc [("error", `String "unsupported_grant_type")]
          else if code = "" || client_id = ""
          then `Assoc [("error", `String "invalid_request")]
          else
            match find_client client_id with
            | None -> `Assoc [("error", `String "invalid_client")]
            | Some _client -> (
              match consume_code ~code ~client_id ~redirect_uri with
              | None -> `Assoc [("error", `String "invalid_grant")]
              | Some (session_id, user_id) ->
                  cleanup_expired_codes () ;
                  `Assoc
                    [ ("session_id", `String session_id)
                    ; ("user_id", `Int user_id)
                    ; ("token_type", `String "bearer") ] ) ) ;

      (* GET /oauth/logout — clear session and redirect *)
      !_register_get_ref "/oauth/logout" (fun req ->
          let redirect_uri =
            match List.assoc_opt "redirect_uri" req.query with
            | Some v -> v
            | None -> "/"
          in
          (* Clear session *)
          !_session_clear_ref req.session_id ;
          `Redirect redirect_uri )
