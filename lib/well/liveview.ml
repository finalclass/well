(* LiveView — Server-side reactive components *)

(* Forward ref — set by well.ml to avoid circular module dependency *)
let _register_ws_route :
  (string -> (Types.request -> Websocket.t -> unit) -> unit) ref =
  ref (fun _ _ -> ())

(* Forward ref — set by well.ml to resolve routes for live navigation *)
let _resolve_route : (Types.request -> string -> string option) ref =
  ref (fun _ _ -> None)

(* ── Types ─────────────────────────────────────────────────────────── *)

type persistence =
  | Ephemeral
  | Session
  | User

module type VIEW = sig
  type model
  type msg

  val persistence : persistence
  val subscriptions : string list
  val init : Types.request -> Yojson.Safe.t -> model
  val update : Types.request -> model -> msg -> model
  val handle_params : Types.request -> model -> model
  val view : model -> Html.node
  val temporary_assigns : model -> model

  val model_to_yojson : model -> Yojson.Safe.t
  val model_of_yojson : Yojson.Safe.t -> (model, string) result
  val msg_of_yojson : Yojson.Safe.t -> (msg, string) result
end

(* ── Session store ─────────────────────────────────────────────────── *)

type session_state = {
  endpoint : string;
  model_json : Yojson.Safe.t;
  last_active : float;
}

let sessions : (string, session_state) Hashtbl.t = Hashtbl.create 64
let session_timeout = 300.0

(* ── Connection registry for User persistence broadcast ──────────── *)

type connection = {
  ws : Websocket.t;
  topics : (string, unit) Hashtbl.t;
}

let user_connections : (string, connection list) Hashtbl.t =
  Hashtbl.create 16

let register_connection user_id conn =
  let conns =
    match Hashtbl.find_opt user_connections user_id with
    | Some cs -> cs
    | None -> []
  in
  Hashtbl.replace user_connections user_id (conn :: conns)

let unregister_connection user_id ws =
  match Hashtbl.find_opt user_connections user_id with
  | Some conns ->
      let filtered =
        List.filter (fun c -> not (c.ws == ws)) conns
      in
      if filtered = [] then Hashtbl.remove user_connections user_id
      else Hashtbl.replace user_connections user_id filtered
  | None -> ()

let broadcast_to_user user_id topic exclude_ws msg =
  match Hashtbl.find_opt user_connections user_id with
  | Some conns ->
      List.iter
        (fun conn ->
          if not (conn.ws == exclude_ws) && Hashtbl.mem conn.topics topic
          then
            (try Websocket.send_json conn.ws msg with _ -> ()))
        conns
  | None -> ()

(* ── Session/connection introspection ─────────────────────────────── *)

let list_sessions () =
  Hashtbl.fold (fun key data acc ->
    (key, data.endpoint, data.last_active) :: acc
  ) sessions []

let count_connections () =
  Hashtbl.fold (fun _ conns acc ->
    acc + List.length conns
  ) user_connections 0

(* ── Session cleanup ───────────────────────────────────────────────── *)

let cleanup_sessions () =
  let now = Unix.gettimeofday () in
  let to_remove =
    Hashtbl.fold
      (fun key data acc ->
        if now -. data.last_active > session_timeout then key :: acc
        else acc)
      sessions []
  in
  List.iter (Hashtbl.remove sessions) to_remove

(* ── Patch type ────────────────────────────────────────────────────── *)

type patch = { offset : int; len : int; content : string }

(* ── JSON encoding ─────────────────────────────────────────────────── *)

let encode_msg topic type_ data =
  `Assoc (("topic", `String topic) :: ("type", `String type_) :: data)

let encode_full topic html =
  encode_msg topic "full" [ ("html", `String html) ]

let encode_restored topic html =
  encode_msg topic "restored" [ ("html", `String html) ]

let encode_morph topic patches =
  let patches_json = `List (List.map (fun p ->
    `List [`Int p.offset; `Int p.len; `String p.content]
  ) patches) in
  encode_msg topic "morph" [ ("patches", patches_json) ]

let encode_event topic event payload =
  encode_msg topic "event" [("event", `String event); ("payload", payload)]

let encode_navigate url html =
  `Assoc [("type", `String "navigate"); ("url", `String url); ("html", `String html)]

(* PubSub — delegated to Message_bus *)

(* ── Uploads ──────────────────────────────────────────────────────── *)

let _max_upload_size = ref (50 * 1024 * 1024)  (* 50 MB default *)

type upload_entry = {
  upload_id : string;
  filename : string;
  content_type : string;
  size : int;
  chunks : Buffer.t;
  mutable chunks_received : int;
  chunk_count : int;
  created_at : float;
}

let active_uploads : (string, upload_entry) Hashtbl.t = Hashtbl.create 16

let _upload_max_age = 300.0  (* 5 minutes — abandon timeout *)

let consume_upload upload_id =
  match Hashtbl.find_opt active_uploads upload_id with
  | Some entry ->
      let data = Buffer.contents entry.chunks in
      Hashtbl.remove active_uploads upload_id;
      Some (entry.filename, entry.content_type, data)
  | None -> None

let cleanup_uploads () =
  let now = Unix.gettimeofday () in
  let to_remove = Hashtbl.fold (fun id entry acc ->
    if now -. entry.created_at > _upload_max_age then id :: acc else acc
  ) active_uploads [] in
  List.iter (Hashtbl.remove active_uploads) to_remove

(* ── Unified handler message type ─────────────────────────────────── *)

type handler_msg =
  | WsMsg of Yojson.Safe.t
  | WsClosed
  | InfoMsg of Message_bus.event  (* from MessageBus *)

(* ── Patch diffing ─────────────────────────────────────────────────── *)

(* Compute minimal string patches between prev and next HTML.
   Returns list of (offset, old_len, new_content) sorted by offset. *)
let compute_patches prev next =
  let prev_len = String.length prev in
  let next_len = String.length next in
  (* Find common prefix *)
  let max_prefix = min prev_len next_len in
  let prefix = ref 0 in
  while !prefix < max_prefix && prev.[!prefix] = next.[!prefix] do
    incr prefix
  done;
  if !prefix = prev_len && !prefix = next_len then
    []  (* identical *)
  else begin
    (* Find common suffix (don't overlap with prefix) *)
    let suffix = ref 0 in
    while !suffix < prev_len - !prefix
          && !suffix < next_len - !prefix
          && prev.[prev_len - 1 - !suffix] = next.[next_len - 1 - !suffix]
    do
      incr suffix
    done;
    let p = !prefix in
    let s = !suffix in
    let prev_mid = String.sub prev p (prev_len - p - s) in
    let next_mid = String.sub next p (next_len - p - s) in
    (* Try to split on longest common substring within the middles *)
    let rec split_patches base_offset prev_m next_m depth =
      let pm_len = String.length prev_m in
      let nm_len = String.length next_m in
      if pm_len = 0 && nm_len = 0 then []
      else if depth > 5 || pm_len = 0 || nm_len = 0 then
        (* Base case: single patch for the whole region *)
        [{ offset = base_offset; len = pm_len; content = next_m }]
      else begin
        (* Find longest common substring *)
        let best_pi = ref 0 in
        let best_ni = ref 0 in
        let best_len = ref 0 in
        (* Scan for common substrings — minimum length 8 to avoid spurious matches *)
        for pi = 0 to pm_len - 1 do
          for ni = 0 to nm_len - 1 do
            if prev_m.[pi] = next_m.[ni] then begin
              let l = ref 1 in
              while pi + !l < pm_len && ni + !l < nm_len
                    && prev_m.[pi + !l] = next_m.[ni + !l] do
                incr l
              done;
              if !l > !best_len then begin
                best_len := !l;
                best_pi := pi;
                best_ni := ni
              end
            end
          done
        done;
        if !best_len < 8 then
          (* No good common substring — emit single patch *)
          [{ offset = base_offset; len = pm_len; content = next_m }]
        else begin
          let bp = !best_pi in
          let bn = !best_ni in
          let bl = !best_len in
          let left =
            split_patches base_offset
              (String.sub prev_m 0 bp)
              (String.sub next_m 0 bn)
              (depth + 1)
          in
          let right =
            split_patches (base_offset + bp + bl)
              (String.sub prev_m (bp + bl) (pm_len - bp - bl))
              (String.sub next_m (bn + bl) (nm_len - bn - bl))
              (depth + 1)
          in
          left @ right
        end
      end
    in
    split_patches p prev_mid next_mid 0
  end

(* ── View instance ─────────────────────────────────────────────────── *)

type view_instance = {
  get_html : unit -> string;
  handle_msg : Yojson.Safe.t -> patch list option;
  handle_params : Types.request -> patch list option;
  get_model_json : unit -> Yojson.Safe.t;
  load_model : Yojson.Safe.t -> unit;
}

(* ── Registry ──────────────────────────────────────────────────────── *)

type view_entry = {
  factory : Types.request -> Yojson.Safe.t -> view_instance;
  view_persistence : persistence;
  view_subscriptions : string list;
}

let view_registry : (string, view_entry) Hashtbl.t = Hashtbl.create 16

(* ── Persistence helpers ───────────────────────────────────────────── *)

let load_state persistence session_id topic endpoint =
  match persistence with
  | Ephemeral -> None
  | Session ->
      let key = session_id ^ ":" ^ topic in
      (match Hashtbl.find_opt sessions key with
       | Some saved when saved.endpoint = endpoint ->
           Some saved.model_json
       | _ -> None)
  | User ->
      (match Liveview_store.load ~user_id:session_id ~topic with
       | Some (ep, model_json) when ep = endpoint -> Some model_json
       | _ -> None)

let save_state persistence session_id topic endpoint model_json =
  match persistence with
  | Ephemeral -> ()
  | Session ->
      let key = session_id ^ ":" ^ topic in
      Hashtbl.replace sessions key
        { endpoint; model_json; last_active = Unix.gettimeofday () }
  | User ->
      Liveview_store.save ~user_id:session_id ~topic ~endpoint ~model_json

(* ── Topic state ───────────────────────────────────────────────────── *)

type topic_state = {
  ts_endpoint : string;
  ts_topic : string;
  ts_persistence : persistence;
  ts_instance : view_instance;
}

(* ── Multiplexed WebSocket handler ─────────────────────────────────── *)

let save_all_topics topics session_id =
  Hashtbl.iter
    (fun _ ts ->
      save_state ts.ts_persistence session_id ts.ts_topic
        ts.ts_endpoint (ts.ts_instance.get_model_json ()))
    topics

let handler (req : Types.request) (ws : Websocket.t) =
  let topics : (string, topic_state) Hashtbl.t = Hashtbl.create 8 in
  let session_id = req.session_id in
  let conn_topics : (string, unit) Hashtbl.t = Hashtbl.create 8 in
  let conn = { ws; topics = conn_topics } in
  let sub_ids : (string * int) list ref = ref [] in
  register_connection session_id conn;
  cleanup_sessions ();
  Eio.Switch.run @@ fun sw ->
  Websocket.start_keepalive ~sw ~sleep:(!Service._sleep) ws;
  let rate = !(Service._ws_rate_limit) in
  let limiter = Websocket.create_limiter ~max_tokens:rate ~refill_rate:rate () in
  let unified = Eio.Stream.create 64 in
  (* Fork: WS reader fiber *)
  Eio.Fiber.fork ~sw (fun () ->
    let rec read_loop () =
      match Websocket.receive_json ws with
      | None -> Eio.Stream.add unified WsClosed
      | Some json ->
          if Websocket.rate_limit_allow limiter then begin
            Telemetry.incr_ws_messages ();
            Eio.Stream.add unified (WsMsg json)
          end else
            Log.log ~level:"warn" "ws rate limit exceeded — dropping message";
          read_loop ()
      | exception Websocket.Frame_too_large ->
          Log.log ~level:"warn" "ws frame too large — closing connection";
          Websocket.close ws;
          Eio.Stream.add unified WsClosed
    in
    read_loop ()
  );
  let handle_join topic endpoint init_args =
    match Hashtbl.find_opt view_registry endpoint with
    | Some { factory; view_persistence; view_subscriptions } ->
        let saved_state =
          load_state view_persistence session_id topic endpoint
        in
        let instance, msg_type =
          match saved_state with
          | Some model_json -> (factory req model_json, "restored")
          | None -> (factory req init_args, "full")
        in
        let html = instance.get_html () in
        Hashtbl.replace topics topic
          { ts_endpoint = endpoint;
            ts_topic = topic;
            ts_persistence = view_persistence;
            ts_instance = instance };
        Hashtbl.replace conn_topics topic ();
        (* Subscribe to MessageBus: own topic + VIEW subscriptions *)
        let channels = topic :: view_subscriptions in
        List.iter (fun ch ->
          let sub_id = Message_bus.subscribe ch (fun event ->
            Eio.Stream.add unified (InfoMsg event)
          ) in
          sub_ids := (ch, sub_id) :: !sub_ids
        ) channels;
        let msg =
          if msg_type = "restored" then encode_restored topic html
          else encode_full topic html
        in
        Websocket.send_json ws msg
    | None -> ()
  in
  let handle_leave topic =
    (match Hashtbl.find_opt topics topic with
     | Some ts ->
         save_state ts.ts_persistence session_id ts.ts_topic
           ts.ts_endpoint (ts.ts_instance.get_model_json ());
         Hashtbl.remove topics topic;
         Hashtbl.remove conn_topics topic;
         (* Unsubscribe from MessageBus *)
         let to_remove, remaining =
           List.partition (fun (ch, _) ->
             ch = topic || List.mem ch
               (match Hashtbl.find_opt view_registry ts.ts_endpoint with
                | Some ve -> ve.view_subscriptions | None -> []))
             !sub_ids
         in
         List.iter (fun (_, id) -> Message_bus.unsubscribe id) to_remove;
         sub_ids := remaining
     | None -> ())
  in
  let handle_msg topic msg_json =
    match Hashtbl.find_opt topics topic with
    | Some ts ->
        (* For User persistence, reload from DB before processing *)
        (match ts.ts_persistence with
         | User ->
             (match Liveview_store.load ~user_id:session_id ~topic with
              | Some (_, model_json) -> ts.ts_instance.load_model model_json
              | None -> ())
         | _ -> ());
        (match ts.ts_instance.handle_msg msg_json with
         | Some patches ->
             let morph_msg = encode_morph topic patches in
             Websocket.send_json ws morph_msg;
             save_state ts.ts_persistence session_id ts.ts_topic
               ts.ts_endpoint (ts.ts_instance.get_model_json ());
             (match ts.ts_persistence with
              | User ->
                  broadcast_to_user session_id topic ws morph_msg
              | _ -> ())
         | None -> ())
    | None -> ()
  in
  let handle_params_change topic query_params =
    match Hashtbl.find_opt topics topic with
    | Some ts ->
        let nav_req = { req with query = query_params } in
        (match ts.ts_instance.handle_params nav_req with
         | Some patches ->
             Websocket.send_json ws (encode_morph topic patches);
             save_state ts.ts_persistence session_id ts.ts_topic
               ts.ts_endpoint (ts.ts_instance.get_model_json ())
         | None -> ())
    | None -> ()
  in
  let handle_navigate url =
    (* Save all current topics *)
    save_all_topics topics session_id;
    (* Resolve the URL to HTML via the route system *)
    match !_resolve_route req url with
    | Some html ->
        Websocket.send_json ws (encode_navigate url html)
    | None ->
        (* Send navigate with empty html — client will do full reload *)
        Websocket.send_json ws (encode_navigate url "")
  in
  (* Main loop reads from unified stream *)
  let rec loop () =
    match Eio.Stream.take unified with
    | WsClosed ->
        (* Clean up subscriptions *)
        List.iter (fun (_, id) -> Message_bus.unsubscribe id) !sub_ids;
        sub_ids := [];
        save_all_topics topics session_id;
        unregister_connection session_id ws
    | WsMsg json ->
        let open Yojson.Safe.Util in
        let type_ = try json |> member "type" |> to_string with _ -> "" in
        let topic = try json |> member "topic" |> to_string with _ -> "" in
        (match type_ with
         | "join" ->
             let endpoint =
               try json |> member "endpoint" |> to_string with _ -> ""
             in
             let init_args =
               try json |> member "props" with _ -> `Null
             in
             handle_join topic endpoint init_args;
             loop ()
         | "leave" ->
             handle_leave topic;
             loop ()
         | "msg" ->
             let msg_json =
               try json |> member "msg" with _ -> `Null
             in
             handle_msg topic msg_json;
             loop ()
         | "navigate" ->
             let url =
               try json |> member "url" |> to_string with _ -> ""
             in
             if url <> "" then handle_navigate url;
             loop ()
         | "params" ->
             let query_params =
               try
                 let params = json |> member "params" in
                 match params with
                 | `Assoc kvs ->
                     List.map (fun (k, v) ->
                       (k, try Yojson.Safe.Util.to_string v with _ -> ""))
                       kvs
                 | _ -> []
               with _ -> []
             in
             handle_params_change topic query_params;
             loop ()
         | "upload" ->
             let upload_id = try json |> member "upload_id" |> to_string with _ -> "" in
             let filename = try json |> member "filename" |> to_string with _ -> "" in
             let content_type = try json |> member "content_type" |> to_string with _ -> "" in
             let _chunk_index = try json |> member "chunk_index" |> to_int with _ -> 0 in
             let chunk_count = try json |> member "chunk_count" |> to_int with _ -> 1 in
             let size = try json |> member "size" |> to_int with _ -> 0 in
             if size > !_max_upload_size then begin
               Log.log ~level:"warn" "upload rejected: size %d exceeds limit %d" size !_max_upload_size;
               Websocket.send_json ws
                 (encode_event topic "upload_error"
                    (`Assoc [("upload_id", `String upload_id);
                             ("error", `String "file too large")]));
               loop ()
             end else
             let chunk_data = try json |> member "chunk_data" |> to_string with _ -> "" in
             (* Decode base64 chunk *)
             let decoded =
               try
                 let padded =
                   let rem = String.length chunk_data mod 4 in
                   if rem = 0 then chunk_data
                   else chunk_data ^ String.make (4 - rem) '='
                 in
                 (* Simple base64 decode *)
                 let b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in
                 let buf = Buffer.create (String.length padded * 3 / 4) in
                 let i = ref 0 in
                 let len = String.length padded in
                 while !i + 3 < len do
                   let a = try String.index b64 padded.[!i] with Not_found -> 0 in
                   let b = try String.index b64 padded.[!i+1] with Not_found -> 0 in
                   let c = if padded.[!i+2] = '=' then 0 else (try String.index b64 padded.[!i+2] with Not_found -> 0) in
                   let d = if padded.[!i+3] = '=' then 0 else (try String.index b64 padded.[!i+3] with Not_found -> 0) in
                   Buffer.add_char buf (Char.chr ((a lsl 2) lor (b lsr 4)));
                   if padded.[!i+2] <> '=' then
                     Buffer.add_char buf (Char.chr (((b land 0x0F) lsl 4) lor (c lsr 2)));
                   if padded.[!i+3] <> '=' then
                     Buffer.add_char buf (Char.chr (((c land 0x03) lsl 6) lor d));
                   i := !i + 4
                 done;
                 Buffer.contents buf
               with _ -> ""
             in
             (* Get or create upload entry *)
             let entry =
               match Hashtbl.find_opt active_uploads upload_id with
               | Some e -> e
               | None ->
                   let e = { upload_id; filename; content_type; size;
                             chunks = Buffer.create (max 1024 size);
                             chunks_received = 0; chunk_count;
                             created_at = Unix.gettimeofday () } in
                   Hashtbl.replace active_uploads upload_id e;
                   e
             in
             Buffer.add_string entry.chunks decoded;
             entry.chunks_received <- entry.chunks_received + 1;
             (* Send progress event to hooks *)
             let progress_pct = entry.chunks_received * 100 / (max 1 entry.chunk_count) in
             Websocket.send_json ws
               (encode_event topic "upload_progress"
                  (`Assoc [("upload_id", `String upload_id);
                           ("filename", `String filename);
                           ("progress", `Int progress_pct)]));
             (* If complete, send upload_complete as a msg *)
             if entry.chunks_received >= entry.chunk_count then begin
               let complete_msg =
                 `Assoc [("upload_id", `String upload_id);
                         ("filename", `String filename);
                         ("content_type", `String content_type);
                         ("size", `Int (Buffer.length entry.chunks))]
               in
               (* Dispatch as a hook event *)
               Websocket.send_json ws
                 (encode_event topic "upload_complete" complete_msg)
             end;
             loop ()
         | _ -> loop ())
    | InfoMsg bus_event ->
        let msg_json = bus_event.Message_bus.payload in
        let open Yojson.Safe.Util in
        (* Check if this is a hook event or a regular broadcast *)
        let is_hook_event =
          try ignore (msg_json |> member "__well_event" |> to_string); true
          with _ -> false
        in
        if is_hook_event then begin
          (* Server→client hook event — send to all active topics *)
          let event =
            try msg_json |> member "__well_event" |> to_string with _ -> ""
          in
          let payload =
            try msg_json |> member "__well_payload" with _ -> `Null
          in
          Hashtbl.iter
            (fun topic _ts ->
              let ev_msg = encode_event topic event payload in
              (try Websocket.send_json ws ev_msg with _ -> ()))
            topics
        end else begin
          (* Regular broadcast — dispatch through update cycle *)
          Hashtbl.iter
            (fun topic ts ->
              (match ts.ts_persistence with
               | User ->
                   (match Liveview_store.load ~user_id:session_id ~topic with
                    | Some (_, model_json) ->
                        ts.ts_instance.load_model model_json
                    | None -> ())
               | _ -> ());
              match ts.ts_instance.handle_msg msg_json with
              | Some patches ->
                  Websocket.send_json ws (encode_morph topic patches);
                  save_state ts.ts_persistence session_id ts.ts_topic
                    ts.ts_endpoint (ts.ts_instance.get_model_json ())
              | None -> ())
            topics
        end;
        loop ()
  in
  loop ()

(* ── Registration ──────────────────────────────────────────────────── *)

let _ws_registered = ref false

let register
    (type m msg)
    endpoint
    (module View : VIEW with type model = m and type msg = msg) =
  let factory (req : Types.request) (props_or_saved : Yojson.Safe.t) =
    let initial_model =
      match View.model_of_yojson props_or_saved with
      | Ok model -> model
      | Error _ -> View.init req props_or_saved
    in
    let state = ref (View.handle_params req initial_model) in
    let initial_html = View.view !state |> Html.element_to_string in
    state := View.temporary_assigns !state;
    let _ = Html.collect_and_clear_lists () in
    let prev_html = ref initial_html in
    let get_html () =
      let html = View.view !state |> Html.element_to_string in
      state := View.temporary_assigns !state;
      let _ = Html.collect_and_clear_lists () in
      html
    in
    let render_and_diff () =
      let new_html = View.view !state |> Html.element_to_string in
      state := View.temporary_assigns !state;
      let _ = Html.collect_and_clear_lists () in
      if new_html <> !prev_html then begin
        let patches = compute_patches !prev_html new_html in
        prev_html := new_html;
        Some patches
      end else None
    in
    let handle_msg msg_json =
      match View.msg_of_yojson msg_json with
      | Ok msg ->
          state := View.update req !state msg;
          render_and_diff ()
      | Error _ -> None
    in
    let handle_params nav_req =
      state := View.handle_params nav_req !state;
      render_and_diff ()
    in
    let get_model_json () = View.model_to_yojson !state in
    let load_model model_json =
      match View.model_of_yojson model_json with
      | Ok new_model -> state := new_model
      | Error _ -> ()
    in
    { get_html; handle_msg; handle_params; get_model_json; load_model }
  in
  Hashtbl.replace view_registry endpoint
    { factory; view_persistence = View.persistence;
      view_subscriptions = View.subscriptions };
  if not !_ws_registered then begin
    _ws_registered := true;
    !_register_ws_route "/live" handler
  end

(* ── Server push helpers ───────────────────────────────────────────── *)

let send_event topic event payload =
  ignore (Message_bus.publish ~ephemeral:true topic
    (`Assoc [("__well_event", `String event);
             ("__well_payload", payload)]))

(* ── SSR: render initial HTML ──────────────────────────────────────── *)

let render_initial
    (type m msg)
    (module View : VIEW with type model = m and type msg = msg)
    ~(req : Types.request) ~topic init_args =
  let model =
    match (View.persistence, req.session_id) with
    | User, uid ->
        (match Liveview_store.load ~user_id:uid ~topic with
         | Some (_, model_json) ->
             (match View.model_of_yojson model_json with
              | Ok m -> m
              | Error _ -> View.init req init_args)
         | None -> View.init req init_args)
    | _ -> View.init req init_args
  in
  let model = View.handle_params req model in
  let el = View.view model in
  let _ = Html.collect_and_clear_lists () in
  el

(* ── HTML helpers ──────────────────────────────────────────────────── *)

let live_view ~endpoint ?(topic = "") ?(props = [])
    ?(children : Html.node list = []) () : Html.node =
  let topic = if topic = "" then endpoint else topic in
  let props_json =
    `Assoc (List.map (fun (k, v) -> (k, `String v)) props)
    |> Yojson.Safe.to_string
  in
  let children_html =
    String.concat "" (List.map Html.element_to_string children)
  in
  `Html
    (Printf.sprintf
       {|<live-view data-liveview="%s" data-topic="%s" data-props="%s">%s</live-view>|}
       (Html.escape_html endpoint)
       (Html.escape_html topic)
       (Html.escape_html props_json)
       children_html)

let live_view_script () : Html.node =
  `Html {|<script type="module" src="/static/well.js"></script>|}

(* MLX component: <LiveView name="counter" /> *)
let createElement ~name ?(props : (string * string) list = [])
    ?(children : Html.node list = []) () : Html.node =
  let endpoint = "/live/" ^ name in
  live_view ~endpoint ~topic:endpoint ~props ~children ()
