[@@@warning "-69"]

open Component_access

type ctrl = {
  mutable vdom : Obj.t;
  node : Bridge.element;
  mutable children : ctrl array;
  mutable unsubs : (unit -> unit) list;
  mutable dispatch : Obj.t -> unit;
  is_text : bool;
}

let is_text_node (v : 'msg Vdom.t) = v.tag = ""

let attach_listener dispatch node (name, handler) =
  let cb ev =
    match handler ev with
    | None -> ()
    | Some msg -> dispatch (Obj.repr msg)
  in
  Bridge.add_event_listener node ~event_name:name (Bridge.fn1 cb)

let rec blit_dispatch dispatch (v : 'msg Vdom.t) : ctrl =
  if is_text_node v then
    let text = match v.text with Some s -> s | None -> "" in
    let node = Bridge.create_text_node text in
    { vdom = Obj.repr v; node; children = [||]; unsubs = []; dispatch;
      is_text = true }
  else begin
    let node = Bridge.create_element v.tag in
    List.iter
      (fun (name, value) -> Bridge.set_attribute node ~name ~value)
      v.attrs;
    (match v.text, v.children with
     | Some text, [] -> Bridge.set_text node text
     | _ -> ());
    let unsubs = List.map (attach_listener dispatch node) v.handlers in
    let children =
      Array.of_list (List.map (blit_dispatch dispatch) v.children)
    in
    Array.iter
      (fun child -> Bridge.append_child ~parent:node ~child:child.node)
      children;
    { vdom = Obj.repr v; node; children; unsubs; dispatch; is_text = false }
  end

let blit (v : 'msg Vdom.t) : ctrl = blit_dispatch (fun _ -> ()) v

let sync_attrs node (old_attrs : (string * string) list)
    (new_attrs : (string * string) list) =
  let rec merge a b =
    match a, b with
    | [], rest ->
      List.iter
        (fun (name, value) -> Bridge.set_attribute node ~name ~value)
        rest
    | rest, [] ->
      List.iter
        (fun (name, _) -> Bridge.remove_attribute node ~name)
        rest
    | (na, va) :: ta, (nb, vb) :: tb ->
      if na = nb then begin
        if va <> vb then Bridge.set_attribute node ~name:nb ~value:vb;
        merge ta tb
      end else if na < nb then begin
        Bridge.remove_attribute node ~name:na;
        merge ta b
      end else begin
        Bridge.set_attribute node ~name:nb ~value:vb;
        merge a tb
      end
  in
  merge (List.sort compare old_attrs) (List.sort compare new_attrs)

let sync_text ctrl (old_v : 'msg Vdom.t) (new_v : 'msg Vdom.t) =
  if new_v.children = [] then
    match new_v.text with
    | Some text ->
      (match old_v.text with
       | Some old_text when old_text <> text ->
         Bridge.set_text ctrl.node text
       | _ -> ())
    | None -> ()
  else
    match old_v.text with
    | Some _ -> Bridge.set_text ctrl.node ""
    | None -> ()

let detach_node ctrl =
  match Bridge.get_parent ctrl.node with
  | Some parent -> Bridge.remove_child ~parent ~child:ctrl.node
  | None -> ()

let sync_handlers ctrl (new_handlers : (string * _ Vdom.handler) list) =
  List.iter (fun unsubscribe -> unsubscribe ()) ctrl.unsubs;
  ctrl.unsubs <- List.map (attach_listener ctrl.dispatch ctrl.node) new_handlers

let rec sync (ctrl : ctrl) (v : 'msg Vdom.t) =
  let old : 'msg Vdom.t = Obj.obj ctrl.vdom in
  ctrl.vdom <- Obj.repr v;
  if ctrl.is_text then
    (match v.text with
     | Some text ->
       (match old.text with
        | Some old_text when old_text <> text ->
          Bridge.set_text ctrl.node text
        | _ -> ())
     | None -> ())
  else begin
    sync_attrs ctrl.node old.attrs v.attrs;
    sync_handlers ctrl v.handlers;
    sync_text ctrl old v;
    sync_children ctrl v.children
  end

and sync_children ctrl (new_children : 'msg Vdom.t list) =
  let old_children = ctrl.children in
  let new_arr = Array.of_list new_children in
  let old_count = Array.length old_children in
  let new_count = Array.length new_arr in
  let common = min old_count new_count in
  for i = common to old_count - 1 do
    detach_node old_children.(i)
  done;
  let result : ctrl array = Array.make new_count (Obj.magic ()) in
  for i = 0 to common - 1 do
    sync old_children.(i) new_arr.(i);
    result.(i) <- old_children.(i)
  done;
  for i = common to new_count - 1 do
    result.(i) <- blit_dispatch ctrl.dispatch new_arr.(i)
  done;
  for i = new_count - 1 downto 0 do
    let ref_ =
      if i + 1 < new_count then Some result.(i + 1).node else None
    in
    Bridge.insert_before ~parent:ctrl.node ~child:result.(i).node ~ref_
  done;
  ctrl.children <- result

let initialized = ref false

let table : (string, ctrl) Hashtbl.t = Hashtbl.create 64

let on_vdom env =
  let instance_id = Message_bus.instance_id env in
  let v : 'msg Vdom.t = Obj.obj (Message_bus.payload env) in
  let dispatch msg =
    Message_bus.publish ~topic:"msg"
      (Message_bus.create ~instance_id (Obj.obj msg))
  in
  match Hashtbl.find_opt table instance_id with
  | Some ctrl -> sync ctrl v
  | None ->
    let host = Component_access.dom_element ~instance_id in
    let ctrl = blit_dispatch dispatch v in
    Bridge.append_child ~parent:host ~child:ctrl.node;
    Hashtbl.add table instance_id ctrl

let init () =
  if not !initialized then begin
    initialized := true;
    ignore (Message_bus.subscribe ~topic:"vdom" on_vdom)
  end
