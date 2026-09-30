(** Service -- concurrent, stateless RPC dispatch with fiber-per-request.
    Services register handler specs and are dispatched via HTTP routes or Unix socket. *)

(* ── Types ─────────────────────────────────────────────────────────── *)

(** Parameter metadata for RPC introspection. *)
type param_info = { pname : string; ptype : string; poptional : bool }

(** RPC endpoint metadata: name, parameter types, and return type. *)
type rpc_info = { rname : string; params : param_info list; returns : param_info list; returns_name : string }

(** Service specification: name, RPC handler, and supported endpoints. *)
type spec = {
  name : string;
  handler : string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t;
  set_ref : (string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t) -> unit;
  rpcs : rpc_info list;
}

(** Layered wire error for the text-Drut dispatch path. Each case maps to a
    distinct HTTP status; a request-conversion failure never runs the handler
    and a domain refusal is a normal [Ok] Drut answer. *)
type drut_error =
  | Drut_request_error of string
  | Drut_dispatch_error of string
  | Drut_handler_error of string
  | Drut_response_error of string

(** Response of a text-Drut RPC route: an HTTP status and a Drut body. *)
type http_reply = { status : int; body : string }

(** Text-Drut service specification: the transport hands the raw Drut payload
    text to the generated [from_drut], never a pre-parsed JSON AST. *)
type drut_spec = {
  dname : string;
  dhandler : string -> Yojson.Safe.t -> string -> (string, drut_error) result;
  dset_ref :
    (string -> Yojson.Safe.t -> string -> (string, drut_error) result) -> unit;
  drpcs : rpc_info list;
}

(* ── Unified dispatch table ───────────────────────────────────────── *)
(* Both Service (direct) and Actor (via mailbox) register here.
   HTTP routes, socket, health — all dispatch through this table. *)

(** Unified dispatch entry for both services and actors. *)
type handler_entry = {
  dispatch : string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t;
  rpcs : rpc_info list;
  kind : [ `Service | `Actor ];
}

let handlers : (string, handler_entry) Hashtbl.t = Hashtbl.create 8
let exposed_services : string list ref = ref []

(* Text-Drut handlers, keyed by service/actor name. *)
let drut_handlers : (string, drut_spec) Hashtbl.t = Hashtbl.create 8

(* Forward ref — set by well.ml. Registers a POST route whose handler receives
   the wire rpc context and the raw request body text and returns an HTTP
   status plus a Drut text body. *)
let _register_post_rpc :
  (string -> (Yojson.Safe.t -> string -> http_reply) -> unit) ref =
  ref (fun _path _handler -> ())

(* Forward ref — set by well.ml
   Takes: POST path, handler (request -> response_json_string) *)
let _register_post_json :
  (string -> (Types.request -> string) -> unit) ref =
  ref (fun _path _handler -> ())

(* Forward ref — set by well.ml, builds rpc_ctx JSON from request *)
let _build_rpc_ctx : (Types.request -> Yojson.Safe.t) ref =
  ref (fun _ -> `Null)

let _cast_sw : Eio.Switch.t option ref = ref None

(* Forward ref — ws rate limit (messages per second), set by well.ml *)
let _ws_rate_limit : float ref = ref 100.0

(* ── Registration (at module init time) ──────────────────────────── *)

let pending_specs : spec list ref = ref []

(** Register a service spec to be started when [Well.run] is called. *)
let register spec =
  pending_specs := spec :: !pending_specs

let pending_drut_specs : drut_spec list ref = ref []

(** Register a text-Drut service spec to be started when [Well.run] is called. *)
let register_drut spec =
  pending_drut_specs := spec :: !pending_drut_specs

(** Mark a service to be exposed over HTTP at [/rpc/:service/:rpc]. *)
let expose name =
  exposed_services := name :: !exposed_services

(* Register a handler entry — used by both Service and Actor *)
let register_handler name entry =
  Hashtbl.replace handlers name entry

(* ── Dispatch ─────────────────────────────────────────────────────── *)

(** Dispatch an RPC call to a named service or actor.

    The preserved [dispatch_by_name] entry accepts an already-parsed JSON AST.
    It is a value adapter for REPL/Cap and legacy Service/Actor; it carries no
    promise of recovering the original lexemes. A text-Drut service registered
    with [register_drut] is reachable here too: the AST is serialized back to
    text and handed to the generated [from_drut], which still validates it. Raw
    network inputs (HTTP, socket) never use this path. *)
let dispatch_by_name name rpc ctx payload =
  match Hashtbl.find_opt handlers name with
  | Some entry -> entry.dispatch rpc ctx payload
  | None ->
    (match Hashtbl.find_opt drut_handlers name with
     | None -> `Assoc [("error", `String (name ^ " is not registered"))]
     | Some spec ->
       let payload_text = Yojson.Safe.to_string payload in
       (match spec.dhandler rpc ctx payload_text with
        | Ok text -> (try Yojson.Safe.from_string text with _ -> `String text)
        | Error (Drut_request_error m)
        | Error (Drut_dispatch_error m)
        | Error (Drut_handler_error m)
        | Error (Drut_response_error m) ->
          `Assoc [("error", `String m)]))

(** Dispatch a raw text-Drut RPC to a named text-Drut service. *)
let dispatch_drut_by_name name rpc ctx_wire payload_text =
  match Hashtbl.find_opt drut_handlers name with
  | None -> Error (Drut_dispatch_error (name ^ " is not registered"))
  | Some entry -> entry.dhandler rpc ctx_wire payload_text

(* ── Expose service over HTTP ─────────────────────────────────────── *)

let expose_http_routes () =
  List.iter (fun name ->
    match Hashtbl.find_opt handlers name with
    | None ->
      if not (Hashtbl.mem drut_handlers name) then
        Log.log ~level:"warn" "cannot expose service '%s' — not registered" name
    | Some entry ->
      List.iter (fun (rpc : rpc_info) ->
        let path = Printf.sprintf "/rpc/%s/%s" name rpc.rname in
        !_register_post_json path (fun req ->
          let ctx = !_build_rpc_ctx req in
          let payload =
            if req.body = "" then `Null
            else Yojson.Safe.from_string req.body
          in
          let result = dispatch_by_name name rpc.rname ctx payload in
          Yojson.Safe.to_string result)
      ) entry.rpcs
  ) !exposed_services;
  let error_body message = Yojson.Safe.to_string (`Assoc [("error", `String message)]) in
  List.iter (fun name ->
    match Hashtbl.find_opt drut_handlers name with
    | None -> ()
    | Some spec ->
      List.iter (fun (rpc : rpc_info) ->
        let path = Printf.sprintf "/rpc/%s/%s" name rpc.rname in
        !_register_post_rpc path (fun ctx_wire body ->
          match spec.dhandler rpc.rname ctx_wire body with
          | Ok text -> { status = 200; body = text }
          | Error (Drut_request_error m) -> { status = 400; body = error_body m }
          | Error (Drut_dispatch_error m) -> { status = 404; body = error_body m }
          | Error (Drut_handler_error m) -> { status = 500; body = error_body m }
          | Error (Drut_response_error m) -> { status = 500; body = error_body m })
      ) spec.drpcs
  ) !exposed_services

(* ── Start all services (called by Well.run) ──────────────────────── *)

let start_all ~sw:_ =
  let specs = List.rev !pending_specs in
  pending_specs := [];
  List.iter (fun spec ->
    let entry = {
      dispatch = (fun rpc ctx payload ->
        try spec.handler rpc ctx payload
        with exn ->
          Log.log ~level:"error" "service %s rpc %s error: %s"
            spec.name rpc (Printexc.to_string exn);
          `Assoc [("error", `String (Printexc.to_string exn))]);
      rpcs = spec.rpcs;
      kind = `Service;
    } in
    register_handler spec.name entry;
    spec.set_ref (dispatch_by_name spec.name)
  ) specs;
  let drut_specs = List.rev !pending_drut_specs in
  pending_drut_specs := [];
  List.iter (fun spec ->
    Hashtbl.replace drut_handlers spec.dname spec;
    spec.dset_ref (fun rpc ctx_wire payload_text ->
      match Hashtbl.find_opt drut_handlers spec.dname with
      | None ->
        Error (Drut_dispatch_error (spec.dname ^ " is not registered"))
      | Some entry ->
        (try entry.dhandler rpc ctx_wire payload_text
         with exn ->
           Error (Drut_handler_error (Printexc.to_string exn))))
  ) drut_specs;
  expose_http_routes ()

(* ── Introspection over both dispatch tables ──────────────────────── *)

(* Unified view of every registered name: legacy Service/Actor entries and
   text-Drut services. Metadata always comes from the schema-generated
   [rpc_info], so REPL and Cap render canonical names for both kinds. *)
let entries () =
  let seen = Hashtbl.create 16 in
  let acc = ref [] in
  Hashtbl.iter
    (fun name entry ->
      Hashtbl.replace seen name ();
      acc := (name, entry.rpcs, entry.kind) :: !acc)
    handlers;
  Hashtbl.iter
    (fun name spec ->
      if not (Hashtbl.mem seen name) then
        acc := (name, spec.drpcs, `Service) :: !acc)
    drut_handlers;
  List.sort (fun (a, _, _) (b, _, _) -> String.compare a b) !acc

(* ── Health ────────────────────────────────────────────────────────── *)

(** Return the health status of all registered services. *)
let health () =
  List.map (fun (name, _, _) -> (name, "running")) (entries ())

(* Actor can override health entries *)
let _actor_health : (unit -> (string * string) list) ref = ref (fun () -> [])

(** Return health of all services, with actor-specific overrides applied. *)
let full_health () =
  let base = health () in
  let actor_statuses = !_actor_health () in
  (* Override base health with actor-specific statuses *)
  List.map (fun (name, base_st) ->
    match List.assoc_opt name actor_statuses with
    | Some st -> (name, st)
    | None -> (name, base_st)
  ) base

(* ── Unix socket transport (local IPC) ────────────────────────────── *)

(** List all registered services with their RPC names. *)
let list_services () =
  List.map
    (fun (name, rpcs, _) ->
      (name, List.map (fun (r : rpc_info) -> r.rname) rpcs))
    (entries ())

(** Return JSON schema of all services with parameter and return type info. *)
let describe_services () =
  let param_to_json p =
    `Assoc [("name", `String p.pname);
            ("type", `String p.ptype);
            ("optional", `Bool p.poptional)]
  in
  `Assoc
    (List.map
       (fun (name, rpcs, _) ->
         let rpcs_json =
           `Assoc
             (List.map
                (fun (rpc : rpc_info) ->
                  (rpc.rname,
                   `Assoc
                     [ ("params", `List (List.map param_to_json rpc.params));
                       ("returns", `List (List.map param_to_json rpc.returns));
                       ("returns_name", `String rpc.returns_name) ]))
                rpcs)
         in
         (name, rpcs_json))
       (entries ()))

(* ── Socket frame: raw payload text ───────────────────────────────── *)

(* The socket frame is {service, rpc, payload}. The adapter must hand the
   original payload text to the generated [from_drut]; parsing the frame must
   not round a number in that payload first. The scanner below therefore
   copies the payload substring verbatim instead of decoding and re-encoding
   it. Raw network inputs always take this path. *)

type socket_frame = { f_service : string; f_rpc : string; f_payload : string }

let is_ws = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false

let hex_digit c =
  if c >= '0' && c <= '9' then Char.code c - Char.code '0'
  else if c >= 'a' && c <= 'f' then Char.code c - Char.code 'a' + 10
  else if c >= 'A' && c <= 'F' then Char.code c - Char.code 'A' + 10
  else -1

let utf8_of_codepoint buf cp =
  if cp < 0x80 then Buffer.add_char buf (Char.chr cp)
  else if cp < 0x800 then begin
    Buffer.add_char buf (Char.chr (0xC0 lor (cp lsr 6)));
    Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
  end
  else if cp < 0x10000 then begin
    Buffer.add_char buf (Char.chr (0xE0 lor (cp lsr 12)));
    Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
  end
  else begin
    Buffer.add_char buf (Char.chr (0xF0 lor (cp lsr 18)));
    Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 12) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
  end

(* Decode a JSON string at [i] (the opening quote). Returns the decoded value
   and the index just past the closing quote. *)
let scan_json_string s i =
  let n = String.length s in
  let buf = Buffer.create 16 in
  let rec loop i =
    if i >= n then None
    else
      match s.[i] with
      | '\\' when i + 1 < n ->
        (match s.[i + 1] with
         | '"' -> Buffer.add_char buf '"'; loop (i + 2)
         | '\\' -> Buffer.add_char buf '\\'; loop (i + 2)
         | '/' -> Buffer.add_char buf '/'; loop (i + 2)
         | 'n' -> Buffer.add_char buf '\n'; loop (i + 2)
         | 't' -> Buffer.add_char buf '\t'; loop (i + 2)
         | 'r' -> Buffer.add_char buf '\r'; loop (i + 2)
         | 'b' -> Buffer.add_char buf '\b'; loop (i + 2)
         | 'f' -> Buffer.add_char buf '\012'; loop (i + 2)
         | 'u' when i + 5 < n ->
           let d k = hex_digit s.[i + 2 + k] in
           let d0, d1, d2, d3 = d 0, d 1, d 2, d 3 in
           if d0 < 0 || d1 < 0 || d2 < 0 || d3 < 0 then None
           else begin
             let cp = (d0 lsl 12) lor (d1 lsl 8) lor (d2 lsl 4) lor d3 in
             utf8_of_codepoint buf cp;
             loop (i + 6)
           end
         | c -> Buffer.add_char buf c; loop (i + 2))
      | '"' -> Some (Buffer.contents buf, i + 1)
      | c -> Buffer.add_char buf c; loop (i + 1)
  in
  loop (i + 1)

let skip_ws s i =
  let n = String.length s in
  let rec loop i = if i < n && is_ws s.[i] then loop (i + 1) else i in
  loop i

(* Given [i] at the start of a JSON value, return the index just past it. The
   value is inspected only for structure; its bytes are never reinterpreted. *)
let skip_value s i =
  let n = String.length s in
  let rec nested i depth =
    if i >= n then i
    else
      match s.[i] with
      | '"' ->
        (match scan_json_string s i with
         | Some (_, j) -> nested j depth
         | None -> i)
      | '{' | '[' -> nested (i + 1) (depth + 1)
      | '}' | ']' -> if depth <= 1 then i + 1 else nested (i + 1) (depth - 1)
      | _ -> nested (i + 1) depth
  in
  let rec scalar i =
    if i >= n then i
    else match s.[i] with
      | ',' | '}' | ']' | ' ' | '\t' | '\n' | '\r' -> i
      | _ -> scalar (i + 1)
  in
  if i >= n then i
  else
    match s.[i] with
    | '"' -> (match scan_json_string s i with Some (_, j) -> j | None -> i)
    | '{' | '[' -> nested i 0
    | _ -> scalar i

let parse_socket_frame line =
  let n = String.length line in
  let i = ref (skip_ws line 0) in
  if !i >= n || line.[!i] <> '{' then
    Error "frame must be a JSON object"
  else begin
    incr i;
    let service = ref "" and rpc = ref "" and payload = ref "null" in
    let rec loop () =
      i := skip_ws line !i;
      if !i >= n then Error "unterminated frame"
      else if line.[!i] = '}' then Ok ()
      else if line.[!i] <> '"' then Error "frame key must be a string"
      else
        match scan_json_string line !i with
        | None -> Error "invalid frame key"
        | Some (key, j) ->
          i := skip_ws line j;
          if !i >= n || line.[!i] <> ':' then Error "missing ':' in frame"
          else begin
            incr i;
            i := skip_ws line !i;
            if !i >= n then Error "missing frame value"
            else begin
              (match key with
               | "service" ->
                 (match scan_json_string line !i with
                  | Some (v, j) -> service := v; i := j
                  | None -> i := skip_value line !i)
               | "rpc" ->
                 (match scan_json_string line !i with
                  | Some (v, j) -> rpc := v; i := j
                  | None -> i := skip_value line !i)
               | "payload" ->
                 let start = !i in
                 let stop = skip_value line !i in
                 payload := String.sub line start (stop - start);
                 i := stop
               | _ -> i := skip_value line !i);
              i := skip_ws line !i;
              if !i < n && line.[!i] = ',' then begin
                incr i;
                loop ()
              end
              else if !i < n && line.[!i] = '}' then Ok ()
              else Error "malformed frame"
            end
          end
    in
    match loop () with
    | Error e -> Error e
    | Ok () -> Ok { f_service = !service; f_rpc = !rpc; f_payload = !payload }
  end

let handle_socket_line line =
  try
    match parse_socket_frame line with
    | Error msg ->
      Yojson.Safe.to_string
        (`Assoc [("error", `String ("bad frame: " ^ msg))])
    | Ok frame ->
      let service = frame.f_service in
      let rpc = frame.f_rpc in
      let payload_text = frame.f_payload in
      let reply json = Yojson.Safe.to_string json in
      if service = "_system" then begin
        let payload =
          try Yojson.Safe.from_string payload_text with _ -> `Null
        in
        if rpc = "db_diff" then
          let db_path = match payload with
            | `String s -> s
            | _ -> "data/app.sqlite"
          in
          (* Restrict to paths under data/ to prevent information disclosure *)
          let safe_path =
            String.length db_path >= 5
            && String.sub db_path 0 5 = "data/"
            && not (String.contains db_path '\000')
            && (let decoded = db_path in
                let segs = String.split_on_char '/' decoded in
                not (List.exists (fun s -> s = ".." || s = ".") segs))
          in
          if not safe_path then
            reply (`Assoc [("error", `String "invalid db path")])
          else
            let db = Sqlite3.db_open db_path in
            let entries = Db.diff db in
            ignore (Sqlite3.db_close db);
            let result = `List (List.map Db.diff_entry_to_json entries) in
            reply (`Assoc [("result", result)])
        else if rpc = "describe" then
          reply (`Assoc [("result", describe_services ())])
        else if rpc = "list" then
          let services = list_services () in
          let result = `Assoc (List.map (fun (name, rpcs) ->
            (name, `List (List.map (fun r -> `String r) rpcs))
          ) services) in
          reply (`Assoc [("result", result)])
        else if rpc = "health" then
          let statuses = full_health () in
          let result = `Assoc (List.map (fun (name, st) ->
            (name, `String st)
          ) statuses) in
          reply (`Assoc [("result", result)])
        else
          reply (`Assoc [("result", dispatch_by_name service rpc `Null payload)])
      end
      else if Hashtbl.mem drut_handlers service then
        (* Raw network input: the original payload text goes to from_drut. *)
        (match dispatch_drut_by_name service rpc `Null payload_text with
         | Ok text ->
           (try reply (`Assoc [("result", Yojson.Safe.from_string text)])
            with _ -> reply (`Assoc [("result", `String text)]))
         | Error (Drut_request_error m)
         | Error (Drut_dispatch_error m)
         | Error (Drut_handler_error m)
         | Error (Drut_response_error m) ->
           reply (`Assoc [("error", `String m)]))
      else
        (* Legacy Service/Actor: preserved value adapter over JSON AST. *)
        let payload =
          try Yojson.Safe.from_string payload_text with _ -> `Null
        in
        reply (`Assoc [("result", dispatch_by_name service rpc `Null payload)])
  with exn ->
    Yojson.Safe.to_string
      (`Assoc [("error", `String (Printexc.to_string exn))])

let handle_socket_client flow _addr =
  let reader = Eio.Buf_read.of_flow ~max_size:(10 * 1024 * 1024) flow in
  (try
     while true do
       let line = Eio.Buf_read.line reader in
       let line =
         if String.length line > 0 && line.[String.length line - 1] = '\r'
         then String.sub line 0 (String.length line - 1)
         else line
       in
       if line <> "" then begin
         let response = handle_socket_line line in
         Eio.Flow.copy_string (response ^ "\n") flow
       end
     done
   with
   | End_of_file | Eio.Io _ -> ());
  Eio.Flow.close flow

(** Start a Unix domain socket server for local IPC at the given path. *)
let start_socket ~sw ~net path =
  (try Unix.unlink path with Unix.Unix_error _ -> ());
  let socket = Eio.Net.listen net ~sw ~backlog:16 ~reuse_addr:true
    (`Unix path) in
  Unix.chmod path 0o770;
  Log.log "socket on %s" path;
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect ~finally:(fun () ->
      try Unix.unlink path with Unix.Unix_error _ -> ())
    (fun () ->
      let rec accept_loop () =
        Eio.Net.accept_fork socket ~sw
          ~on_error:(fun exn ->
            match exn with
            | Eio.Cancel.Cancelled _ -> ()
            | _ ->
              Log.log ~level:"error" "socket error: %s"
                (Printexc.to_string exn))
          handle_socket_client;
        accept_loop ()
      in
      try accept_loop ()
      with Eio.Cancel.Cancelled _ -> ()))

(* ── Cast (fire-and-forget) ──────────────────────────────────────── *)

(** Fire-and-forget: run [f] in a background fiber. Errors are logged. *)
let cast f =
  match !_cast_sw with
  | Some sw ->
    Eio.Fiber.fork ~sw (fun () ->
      try f ()
      with exn ->
        Log.log ~level:"error" "cast error: %s" (Printexc.to_string exn))
  | None ->
    Log.log ~level:"warn" "cast called outside Well.run";
    f ()
