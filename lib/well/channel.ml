(* Channel — authorization gateway between MessageBus and WebSocket clients *)
(* Bridges MessageBus → WebSocket with per-topic join auth *)

(* Forward ref — set by well.ml *)
let _register_ws_route :
  (string -> (Types.request -> Websocket.t -> unit) -> unit) ref =
  ref (fun _ _ -> ())

(* ── Types ─────────────────────────────────────────────────────────── *)

type join_result = {
  subscribe : string list;
  initial_state : Yojson.Safe.t option;
}

type push_result = {
  reply : Yojson.Safe.t option;
  broadcast : (string * Yojson.Safe.t) option;
}

type channel_def = {
  pattern : string;
  on_join : Types.request -> string -> (join_result, string) result;
  on_push : (Types.request -> string -> string -> Yojson.Safe.t -> push_result) option;
}

(* ── Registry ──────────────────────────────────────────────────────── *)

let channel_defs : channel_def list ref = ref []

let channel ?on_push pattern on_join =
  channel_defs := { pattern; on_join; on_push } :: !channel_defs

let find_channel_def topic =
  List.find_opt
    (fun def -> Message_bus.matches_pattern def.pattern topic)
    !channel_defs

(* ── Handler message type ──────────────────────────────────────────── *)

type handler_msg =
  | WsMsg of Yojson.Safe.t
  | WsClosed
  | BusEvent of Message_bus.event

(* ── WebSocket handler ─────────────────────────────────────────────── *)

let _ws_registered = ref false

let handler (req : Types.request) (ws : Websocket.t) =
  (* Per-client subscription tracking: channel -> sub_id list *)
  let client_subs : (string, int list) Hashtbl.t = Hashtbl.create 8 in
  Eio.Switch.run @@ fun sw ->
  Websocket.start_keepalive ~sw ~sleep:(Env.sleep) ws;
  let rate = !(Service._ws_rate_limit) in
  let limiter = Websocket.create_limiter ~max_tokens:rate ~refill_rate:rate () in
  let unified = Eio.Stream.create 64 in
  (* WS reader fiber *)
  Eio.Fiber.fork ~sw (fun () ->
    let rec read_loop () =
      match Websocket.receive_json ws with
      | None -> Eio.Stream.add unified WsClosed
      | Some json ->
          if Websocket.rate_limit_allow limiter then
            Eio.Stream.add unified (WsMsg json)
          else
            Log.log ~level:"warn" "channel ws rate limit exceeded — dropping message";
          read_loop ()
      | exception Websocket.Frame_too_large ->
          Log.log ~level:"warn" "channel ws frame too large — closing connection";
          Websocket.close ws;
          Eio.Stream.add unified WsClosed
    in
    read_loop ()
  );
  let send_ok channel =
    Websocket.send_json ws
      (`Assoc [("type", `String "ok"); ("channel", `String channel)])
  in
  let send_error channel reason =
    Websocket.send_json ws
      (`Assoc [("type", `String "error");
               ("channel", `String channel);
               ("reason", `String reason)])
  in
  let handle_join topic =
    match find_channel_def topic with
    | None -> send_error topic "no matching channel"
    | Some def ->
        match def.on_join req topic with
        | Error reason -> send_error topic reason
        | Ok result ->
            let sub_ids =
              List.map
                (fun pattern ->
                  Message_bus.subscribe pattern (fun event ->
                    Eio.Stream.add unified (BusEvent event)))
                result.subscribe
            in
            Hashtbl.replace client_subs topic sub_ids;
            (match result.initial_state with
             | Some state ->
               Websocket.send_json ws
                 (`Assoc [("type", `String "join_ok");
                          ("channel", `String topic);
                          ("state", state)])
             | None -> send_ok topic)
  in
  let handle_leave topic =
    (match Hashtbl.find_opt client_subs topic with
     | Some ids ->
         List.iter Message_bus.unsubscribe ids;
         Hashtbl.remove client_subs topic
     | None -> ());
    Websocket.send_json ws
      (`Assoc [("type", `String "ok"); ("channel", `String topic)])
  in
  let cleanup () =
    Hashtbl.iter
      (fun _topic ids -> List.iter Message_bus.unsubscribe ids)
      client_subs;
    Hashtbl.clear client_subs
  in
  (* Main loop *)
  let rec loop () =
    match Eio.Stream.take unified with
    | WsClosed -> cleanup ()
    | WsMsg json ->
        let open Yojson.Safe.Util in
        let type_ = try json |> member "type" |> to_string with _ -> "" in
        let ch = try json |> member "channel" |> to_string with _ -> "" in
        (match type_ with
         | "join" -> handle_join ch; loop ()
         | "leave" -> handle_leave ch; loop ()
         | "push" ->
             let event =
               try json |> member "event" |> to_string with _ -> ""
             in
             let payload =
               try json |> member "payload" with _ -> `Null
             in
             (match find_channel_def ch with
              | Some def ->
                (match def.on_push with
                 | Some handler ->
                   (try
                     let result = handler req ch event payload in
                     (match result.reply with
                      | Some reply_json ->
                        Websocket.send_json ws
                          (`Assoc [("type", `String "reply");
                                   ("channel", `String ch);
                                   ("event", `String event);
                                   ("payload", reply_json)])
                      | None -> ());
                     (match result.broadcast with
                      | Some (evt_name, evt_payload) ->
                        ignore (Message_bus.publish ch
                          (`Assoc [("event", `String evt_name);
                                   ("payload", evt_payload)]))
                      | None -> ())
                   with exn ->
                     send_error ch (Printexc.to_string exn))
                 | None -> () (* no push handler registered *))
              | None -> send_error ch "no matching channel");
             loop ()
         | _ -> loop ())
    | BusEvent event ->
        let evt_name =
          try
            match event.payload with
            | `Assoc pairs ->
              (match List.assoc_opt "event" pairs with
               | Some (`String e) -> e
               | _ -> "message")
            | _ -> "message"
          with _ -> "message"
        in
        let evt_payload =
          if evt_name <> "message" then
            try
              match event.payload with
              | `Assoc pairs ->
                (match List.assoc_opt "payload" pairs with
                 | Some p -> p
                 | _ -> event.payload)
              | _ -> event.payload
            with _ -> event.payload
          else event.payload
        in
        Websocket.send_json ws
          (`Assoc [("type", `String "event");
                   ("channel", `String event.channel);
                   ("event", `String evt_name);
                   ("payload", evt_payload)]);
        loop ()
  in
  loop ()

let ensure_ws_route () =
  if not !_ws_registered then begin
    _ws_registered := true;
    !_register_ws_route "/ws" handler
  end
