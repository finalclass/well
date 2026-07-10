open Js_of_ocaml

type 'a envelope = {
  instance_id : string;
  payload : 'a;
}

type subscription = {
  id : string;
  deliver : Obj.t -> unit;
}

let subscriptions : (string, subscription list) Hashtbl.t =
  Hashtbl.create 16

let topic_of_id : (string, string) Hashtbl.t =
  Hashtbl.create 16

let pending : (string * Obj.t) Queue.t =
  Queue.create ()

let flushing = ref false

let next_subscription_id =
  let counter = ref 0 in
  fun () ->
    incr counter;
    string_of_int !counter

let create ~instance_id payload =
  { instance_id; payload }

let instance_id envelope =
  envelope.instance_id

let payload envelope =
  envelope.payload

let flush () =
  while not (Queue.is_empty pending) do
    let (topic, envelope_repr) = Queue.take pending in
    match Hashtbl.find_opt subscriptions topic with
    | None -> ()
    | Some subscribers ->
      List.iter (fun subscription -> subscription.deliver envelope_repr) subscribers
  done;
  flushing := false

let schedule_flush () =
  if not !flushing then begin
    flushing := true;
    ignore (Dom_html.setTimeout flush 0.0)
  end

let publish ~topic envelope =
  Queue.push (topic, Obj.repr envelope) pending;
  schedule_flush ()

let subscribe ~topic callback =
  let id = next_subscription_id () in
  let deliver envelope_repr =
    try callback (Obj.obj envelope_repr) with _ -> ()
  in
  let subscription = { id; deliver } in
  let current =
    try Hashtbl.find subscriptions topic with Not_found -> []
  in
  Hashtbl.replace subscriptions topic (subscription :: current);
  Hashtbl.add topic_of_id id topic;
  id

let unsubscribe ~subscription_id =
  match Hashtbl.find_opt topic_of_id subscription_id with
  | None -> ()
  | Some topic ->
    Hashtbl.remove topic_of_id subscription_id;
    let current =
      try Hashtbl.find subscriptions topic with Not_found -> []
    in
    let remaining =
      List.filter
        (fun subscription -> subscription.id <> subscription_id)
        current
    in
    Hashtbl.replace subscriptions topic remaining
