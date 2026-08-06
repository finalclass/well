[@@@warning "-69"]

type ctrl = {
  mutable vdom : Obj.t;
  node : Bridge.element;
  mutable children : ctrl array;
  mutable unsubs : (unit -> unit) list;
  mutable dispatch : Obj.t -> unit;
  is_text : bool;
}

let is_text_node (v : 'msg Html.vdom) = v.tag = ""

let attach_listener dispatch node (name, handler) =
  let cb ev =
    let msg_opt =
      match handler with
      | Html.Msg msg -> Some msg
      | Html.On_key f -> Some (f (Bridge.event_key ev))
      | Html.On_value f -> Some (f (Bridge.event_value ev))
      | Html.On_form f ->
        Bridge.event_prevent_default ev;
        Some (f (Bridge.event_form_data ev))
      | Html.On_event f -> f (Obj.repr ev)
      | Html.Ignore -> None
    in
    (match msg_opt with
     | None -> ()
     | Some msg -> dispatch (Obj.repr msg))
  in
  Bridge.add_event_listener node ~event_name:name (Bridge.fn1 cb)

let apply_bool_attrs node (bools : string list) =
  List.iter
    (fun name -> Bridge.set_bool_attribute node ~name ~enabled:true)
    bools

let sync_bool_attrs node (old_bools : string list) (new_bools : string list) =
  let old_s = List.sort String.compare old_bools in
  let new_s = List.sort String.compare new_bools in
  let rec merge a b =
    match a, b with
    | [], rest ->
      List.iter
        (fun name -> Bridge.set_bool_attribute node ~name ~enabled:true)
        rest
    | rest, [] ->
      List.iter
        (fun name -> Bridge.set_bool_attribute node ~name ~enabled:false)
        rest
    | na :: ta, nb :: tb ->
      if na = nb then merge ta tb
      else if na < nb then begin
        Bridge.set_bool_attribute node ~name:na ~enabled:false;
        merge ta b
      end else begin
        Bridge.set_bool_attribute node ~name:nb ~enabled:true;
        merge a tb
      end
  in
  merge old_s new_s

let rec blit_dispatch dispatch (v : 'msg Html.vdom) : ctrl =
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
    apply_bool_attrs node v.bool_attrs;
    (match v.text, v.children with
     | Some text, [] -> Bridge.set_text node text
     | _ -> ());
    let unsubs = List.map (attach_listener dispatch node) v.handlers in
    let children =
      Array.of_list (List.map (fun (`Html c) -> blit_dispatch dispatch c) v.children)
    in
    Array.iter
      (fun child -> Bridge.append_child ~parent:node ~child:child.node)
      children;
    { vdom = Obj.repr v; node; children; unsubs; dispatch; is_text = false }
  end

let blit (`Html v : 'msg Html.node) : ctrl = blit_dispatch (fun _ -> ()) v

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

let sync_text ctrl (old_v : 'msg Html.vdom) (new_v : 'msg Html.vdom) =
  match new_v.children with
  | [] ->
    (match new_v.text with
     | Some text ->
       (match old_v.children, old_v.text with
        | [], Some old_text when old_text = text -> ()
        | _ -> Bridge.set_text ctrl.node text)
     | None ->
       (match old_v.children with
        | [] -> Bridge.set_text ctrl.node ""
        | _ -> ()))
  | _ :: _ ->
    (match old_v.children with
     | [] -> Bridge.set_text ctrl.node ""
     | _ -> ())

let detach_node ctrl =
  match Bridge.get_parent ctrl.node with
  | Some parent -> Bridge.remove_child ~parent ~child:ctrl.node
  | None -> ()

let sync_handlers ctrl (new_handlers : (string * _ Html.handler) list) =
  List.iter (fun unsubscribe -> unsubscribe ()) ctrl.unsubs;
  ctrl.unsubs <- List.map (attach_listener ctrl.dispatch ctrl.node) new_handlers

let rec sync (ctrl : ctrl) (v : 'msg Html.vdom) =
  let old : 'msg Html.vdom = Obj.obj ctrl.vdom in
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
    sync_bool_attrs ctrl.node old.bool_attrs v.bool_attrs;
    sync_handlers ctrl v.handlers;
    sync_text ctrl old v;
    sync_children ctrl v.children
  end

and same_kind (old_ctrl : ctrl) (v : 'msg Html.vdom) =
  let old_v : 'msg Html.vdom = Obj.obj old_ctrl.vdom in
  old_ctrl.is_text = is_text_node v && old_v.tag = v.tag

and replace_child_ctrl parent (old_ctrl : ctrl) (v : 'msg Html.vdom) =
  List.iter (fun unsubscribe -> unsubscribe ()) old_ctrl.unsubs;
  let fresh = blit_dispatch old_ctrl.dispatch v in
  Bridge.replace_child ~parent ~old:old_ctrl.node ~new_:fresh.node;
  fresh

and sync_children ctrl (new_children : 'msg Html.node list) =
  let old_children = ctrl.children in
  let new_arr = Array.of_list new_children in
  let old_count = Array.length old_children in
  let new_count = Array.length new_arr in
  let common = min old_count new_count in
  for i = old_count - 1 downto common do
    List.iter (fun unsubscribe -> unsubscribe ()) old_children.(i).unsubs;
    detach_node old_children.(i)
  done;
  let result : ctrl array = Array.make new_count (Obj.magic ()) in
  for i = 0 to common - 1 do
    match new_arr.(i) with
    | `Html c ->
      let old_c = old_children.(i) in
      if same_kind old_c c then begin
        sync old_c c;
        result.(i) <- old_c
      end else
        result.(i) <- replace_child_ctrl ctrl.node old_c c
  done;
  for i = common to new_count - 1 do
    match new_arr.(i) with
    | `Html c ->
      let child = blit_dispatch ctrl.dispatch c in
      result.(i) <- child;
      Bridge.append_child ~parent:ctrl.node ~child:child.node
  done;
  ctrl.children <- result

let initialized = ref false

let table : (string, ctrl) Hashtbl.t = Hashtbl.create 64

let rec destroy_ctrl (c : ctrl) =
  List.iter (fun unsubscribe -> unsubscribe ()) c.unsubs;
  c.unsubs <- [];
  Array.iter destroy_ctrl c.children;
  c.children <- [||];
  detach_node c

let destroy_instance ~instance_id =
  match Hashtbl.find_opt table instance_id with
  | None -> ()
  | Some ctrl ->
    destroy_ctrl ctrl;
    Hashtbl.remove table instance_id

let on_vdom env =
  let instance_id = Message_bus.instance_id env in
  let (`Html v) : 'msg Html.node = Obj.obj (Message_bus.payload env) in
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
