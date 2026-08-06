[@@@warning "-69"]

open Js_of_ocaml

type 'a envelope = {
  instance_id : string;
  payload : 'a;
}

let last_values : (string, Obj.t) Hashtbl.t = Hashtbl.create 64

let cache_key ~instance_id ~name = instance_id ^ "\x00" ^ name

let publish_msg ~instance_id (m : Component_access.msg) =
  Message_bus.publish ~topic:"msg"
    (Message_bus.create ~instance_id (Obj.obj (Obj.repr m)))

let remembered_equal ~instance_id ~name ~equal (v : Obj.t) : bool =
  let key = cache_key ~instance_id ~name in
  match Hashtbl.find_opt last_values key with
  | Some prev when equal prev v -> true
  | _ ->
    Hashtbl.replace last_values key v;
    false

let forget_instance ~instance_id =
  let prefix = instance_id ^ "\x00" in
  let to_drop = ref [] in
  Hashtbl.iter
    (fun k _ ->
      if String.length k >= String.length prefix
         && String.sub k 0 (String.length prefix) = prefix
      then to_drop := k :: !to_drop)
    last_values;
  List.iter (Hashtbl.remove last_values) !to_drop

let find_spec specs name =
  List.find_opt (fun (s : Component_access.prop_spec) -> s.name = name) specs

let coerce_list (raw : Bridge.value) : Obj.t option =
  let raw_any : Js.Unsafe.any = Obj.magic raw in
  try
    let kind =
      Js.to_string
        (Js.Unsafe.fun_call
           (Js.Unsafe.js_expr
              {|function (v) {
                 function isOCamlList(x) {
                   if (x === 0) return true;
                   if (!Array.isArray(x) || x.length < 3) return false;
                   if (x[0] !== 0) return false;
                   return isOCamlList(x[2]);
                 }
                 if (isOCamlList(v)) return "ocaml";
                 if (Array.isArray(v)) return "js";
                 return "no";
               }|})
           [| raw_any |])
    in
    if kind = "ocaml" then Some (Obj.magic raw)
    else if kind = "js" then
      let arr : 'a Js.js_array Js.t = Js.Unsafe.coerce raw_any in
      let len = arr##.length in
      let rec go i acc =
        if i < 0 then acc
        else
          let el = Js.array_get arr i in
          let el_js : Js.Unsafe.any =
            match Js.Optdef.to_option el with
            | None -> Js.Unsafe.inject Js.undefined
            | Some v -> Js.Unsafe.inject v
          in
          let el_oc : Obj.t =
            let t = Js.to_string (Js.typeof el_js) in
            if t = "string" then
              Obj.repr
                (Js.to_string (Js.Unsafe.coerce el_js : Js.js_string Js.t))
            else if t = "number" then
              Obj.repr
                (Js.to_float (Js.Unsafe.coerce el_js : Js.number Js.t))
            else if t = "boolean" then
              Obj.repr (Js.to_bool (Js.Unsafe.coerce el_js : bool Js.t))
            else Obj.magic el_js
          in
          go (i - 1) (el_oc :: acc)
      in
      Some (Obj.repr (go (len - 1) []))
    else None
  with _ -> None

let coerce_js_scalar (spec : Component_access.prop_spec) (raw : Bridge.value)
    : Obj.t option =
  let raw_any : Js.Unsafe.any = Obj.magic raw in
  try
    match spec.kind with
    | Component_access.Props.String ->
      let s = Js.to_string (Js.Unsafe.coerce raw_any : Js.js_string Js.t) in
      Some (Obj.repr s)
    | Component_access.Props.Int ->
      let n =
        int_of_float
          (Js.to_float (Js.Unsafe.coerce raw_any : Js.number Js.t))
      in
      Some (Obj.repr n)
    | Component_access.Props.Float ->
      let f = Js.to_float (Js.Unsafe.coerce raw_any : Js.number Js.t) in
      Some (Obj.repr f)
    | Component_access.Props.Bool ->
      let b = Js.to_bool (Js.Unsafe.coerce raw_any : bool Js.t) in
      Some (Obj.repr b)
    | Component_access.Props.List -> coerce_list raw
    | Component_access.Props.Complex -> Some (Obj.magic raw)
  with _ -> None

let apply_msg_sync ~instance_id (state : Component_access.state)
    (m : Component_access.msg) : Component_access.state =
  let state_env : Component_access.state Component_access.envelope =
    Obj.magic { instance_id; payload = state }
  in
  let msg_env : Component_access.msg Component_access.envelope =
    Obj.magic { instance_id; payload = m }
  in
  let updated =
    Component_access.update_state ~instance_id state_env msg_env
  in
  let (new_state, cmd) : Component_access.state * Component_access.cmd =
    (Obj.magic updated : _ envelope).payload
  in
  let key = Component_access.state_key ~instance_id in
  State_access.persist key new_state;
  if not (Component_access.is_cmd_none cmd) then begin
    let cmd_bus : _ Message_bus.envelope =
      Obj.magic ({ instance_id; payload = cmd } : _ envelope)
    in
    Message_bus.publish ~topic:"cmd" cmd_bus
  end;
  new_state

let maybe_publish ~instance_id ~(spec : Component_access.prop_spec) (v : Obj.t) =
  if
    not
      (remembered_equal ~instance_id ~name:spec.name ~equal:spec.equal v)
  then publish_msg ~instance_id (spec.to_msg v)

let transfer_own_properties ~host ~instance_id =
  let specs = Component_access.props_of_instance ~instance_id in
  List.iter
    (fun (spec : Component_access.prop_spec) ->
      match Bridge.take_own_js_property host ~name:spec.name with
      | None -> ()
      | Some raw ->
        Bridge.set_well_prop_storage host ~name:spec.name ~value:raw)
    specs

let hydrate_instance ~instance_id ~host ~initial_state =
  transfer_own_properties ~host ~instance_id;
  let specs = Component_access.props_of_instance ~instance_id in
  List.fold_left
    (fun state (spec : Component_access.prop_spec) ->
      let from_attr =
        match Bridge.get_attribute host ~name:spec.name with
        | None -> None
        | Some s ->
          (match spec.parse_string s with
           | None -> None
           | Some v -> Some v)
      in
      let from_prop =
        match Bridge.get_js_property host ~name:spec.name with
        | None -> None
        | Some raw -> coerce_js_scalar spec raw
      in
      let chosen =
        match from_prop, from_attr with
        | Some v, _ -> Some v
        | None, Some v -> Some v
        | None, None -> None
      in
      match chosen with
      | None -> state
      | Some v ->
        if remembered_equal ~instance_id ~name:spec.name ~equal:spec.equal v
        then state
        else
          let m = spec.to_msg v in
          apply_msg_sync ~instance_id state m)
    initial_state specs

let handle_attribute_change ~host ~name ~old_value:_ ~new_value =
  match Component_access.instance_id_of_element host with
  | None -> ()
  | Some instance_id ->
    let specs = Component_access.props_of_instance ~instance_id in
    (match find_spec specs name with
     | None -> ()
     | Some spec ->
       (match new_value with
        | None ->
          (match spec.default_value with
           | None -> ()
           | Some v -> maybe_publish ~instance_id ~spec v)
        | Some s ->
          (match spec.parse_string s with
           | None -> ()
           | Some v -> maybe_publish ~instance_id ~spec v)))

let handle_property_set ~host ~name ~value =
  match Component_access.instance_id_of_element host with
  | None -> ()
  | Some instance_id ->
    let specs = Component_access.props_of_instance ~instance_id in
    (match find_spec specs name with
     | None -> ()
     | Some spec ->
       (match coerce_js_scalar spec value with
        | None -> ()
        | Some v -> maybe_publish ~instance_id ~spec v))

let observed_attribute_names ~tag_name =
  Component_access.props_of_tag ~tag_name
  |> List.filter_map (fun (s : Component_access.prop_spec) ->
      match s.kind with
      | Component_access.Props.Int | Component_access.Props.Float
      | Component_access.Props.Bool | Component_access.Props.String ->
        Some s.name
      | Component_access.Props.List | Component_access.Props.Complex -> None)

let property_names ~tag_name =
  Component_access.props_of_tag ~tag_name
  |> List.map (fun (s : Component_access.prop_spec) -> s.name)
