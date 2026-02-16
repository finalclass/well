(* Channel — authorization gateway between MessageBus and WebSocket clients *)
(* Bridges MessageBus → WebSocket with per-topic join auth *)

(* Forward ref — set by well.ml *)
let _register_ws_route :
  (string -> (Types.request -> Websocket.t -> unit) -> unit) ref =
  ref (fun _ _ -> ())

(* ── Types ─────────────────────────────────────────────────────────── *)

type join_result = { subscribe : string list }

type channel_def = {
  pattern : string;
  on_join : Types.request -> string -> (join_result, string) result;
}

(* ── Registry ──────────────────────────────────────────────────────── *)

let channel_defs : channel_def list ref = ref []

let channel pattern on_join =
  channel_defs := { pattern; on_join } :: !channel_defs

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
  let unified = Eio.Stream.create 64 in
  (* WS reader fiber *)
  Eio.Fiber.fork ~sw (fun () ->
    let rec read_loop () =
      match Websocket.receive_json ws with
      | None -> Eio.Stream.add unified WsClosed
      | Some json -> Eio.Stream.add unified (WsMsg json); read_loop ()
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
            send_ok topic
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
             ignore (event, payload);
             (* push handling reserved for V2 *)
             loop ()
         | _ -> loop ())
    | BusEvent event ->
        Websocket.send_json ws
          (`Assoc [("type", `String "event");
                   ("channel", `String event.channel);
                   ("event", `String "message");
                   ("payload", event.payload)]);
        loop ()
  in
  loop ()

let ensure_ws_route () =
  if not !_ws_registered then begin
    _ws_registered := true;
    !_register_ws_route "/ws" handler
  end
