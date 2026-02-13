(* Service — In-process actor system with mailbox and crash isolation *)

(* ── Types ─────────────────────────────────────────────────────────── *)

type spec = {
  name : string;
  handler : string -> Yojson.Safe.t -> Yojson.Safe.t;
  set_ref : (string -> Yojson.Safe.t -> Yojson.Safe.t) -> unit;
  rpcs : string list;
}

type mailbox_msg =
  | Call of {
      rpc : string;
      payload : Yojson.Safe.t;
      reply : Yojson.Safe.t Eio.Promise.u;
    }
  | Stop

type actor = {
  spec : spec;
  mailbox : mailbox_msg Eio.Stream.t;
}

(* ── State ─────────────────────────────────────────────────────────── *)

let pending_specs : spec list ref = ref []
let actors : (string, actor) Hashtbl.t = Hashtbl.create 8
let exposed_services : string list ref = ref []

(* Forward ref — set by well.ml
   Takes: POST path, handler (request_body_string -> response_json_string) *)
let _register_post_json :
  (string -> (string -> string) -> unit) ref =
  ref (fun _path _handler -> ())

let _cast_sw : Eio.Switch.t option ref = ref None

(* ── Registration (at module init time) ──────────────────────────── *)

let register spec =
  pending_specs := spec :: !pending_specs

let expose name =
  exposed_services := name :: !exposed_services

(* ── Actor loop ──────────────────────────────────────────────────── *)

let actor_loop actor =
  let rec loop () =
    match Eio.Stream.take actor.mailbox with
    | Stop -> ()
    | Call { rpc; payload; reply } ->
      let result =
        try actor.spec.handler rpc payload
        with exn ->
          Printf.eprintf "[well] service %s rpc %s error: %s\n%!"
            actor.spec.name rpc (Printexc.to_string exn);
          `Assoc [("error", `String (Printexc.to_string exn))]
      in
      Eio.Promise.resolve reply result;
      loop ()
  in
  loop ()

(* ── Dispatch function (wired to convenience fns via set_ref) ─────── *)

let dispatch actor rpc payload =
  let promise, resolver = Eio.Promise.create () in
  Eio.Stream.add actor.mailbox (Call { rpc; payload; reply = resolver });
  Eio.Promise.await promise

(* ── Expose service over HTTP ─────────────────────────────────────── *)

let expose_http_routes () =
  List.iter (fun name ->
    match Hashtbl.find_opt actors name with
    | None ->
      Printf.eprintf "[well] warning: cannot expose service '%s' — not registered\n%!" name
    | Some actor ->
      List.iter (fun rpc_name ->
        let path = Printf.sprintf "/rpc/%s/%s" name rpc_name in
        !_register_post_json path (fun body_str ->
          let payload =
            if body_str = "" then `Null
            else Yojson.Safe.from_string body_str
          in
          let promise, resolver = Eio.Promise.create () in
          Eio.Stream.add actor.mailbox
            (Call { rpc = rpc_name; payload; reply = resolver });
          let result = Eio.Promise.await promise in
          Yojson.Safe.to_string result)
      ) actor.spec.rpcs
  ) !exposed_services

(* ── Start all actors (called by Well.run) ────────────────────────── *)

let start_all ~sw =
  let specs = List.rev !pending_specs in
  pending_specs := [];
  List.iter (fun spec ->
    let mailbox = Eio.Stream.create 64 in
    let actor = { spec; mailbox } in
    Hashtbl.replace actors spec.name actor;
    (* Wire convenience functions to mailbox dispatch *)
    spec.set_ref (dispatch actor);
    (* Spawn actor fiber *)
    Eio.Fiber.fork ~sw (fun () -> actor_loop actor)
  ) specs;
  (* Register HTTP routes for exposed services *)
  expose_http_routes ()

(* ── Cast (fire-and-forget) ──────────────────────────────────────── *)

let cast f =
  match !_cast_sw with
  | Some sw ->
    Eio.Fiber.fork ~sw (fun () ->
      try f ()
      with exn ->
        Printf.eprintf "[well] cast error: %s\n%!" (Printexc.to_string exn))
  | None ->
    Printf.eprintf "[well] warning: cast called outside Well.run\n%!";
    f ()
