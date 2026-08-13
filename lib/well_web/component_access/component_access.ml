[@@@warning "-69"]

module Props = struct
  type kind = Int | Float | Bool | String | List | Complex | Attr_or_prop

  type 'msg decl = Decl : {
    name : string;
    kind : kind;
    parse_string : string -> Obj.t option;
    parse_js : (Bridge.value -> Obj.t option) option;
    equal : Obj.t -> Obj.t -> bool;
    on : Obj.t -> 'msg;
    default_value : Obj.t option;
  } -> 'msg decl

  type 'msg t = 'msg decl list

  let parse_int s =
    try Some (Obj.repr (int_of_string s)) with _ -> None

  let parse_float s =
    try Some (Obj.repr (float_of_string s)) with _ -> None

  let parse_bool s =
    match String.lowercase_ascii s with
    | "true" | "1" | "" -> Some (Obj.repr true)
    | "false" | "0" -> Some (Obj.repr false)
    | _ -> None

  let parse_string s = Some (Obj.repr s)

  let make ~name ~kind ~parse ~equal ~on ~default_value ?(parse_js = None) () =
    Decl
      {
        name;
        kind;
        parse_string = parse;
        parse_js;
        equal;
        on;
        default_value;
      }

  let int name ~on ?(default = 0) () =
    let on' v =
      match v with
      | Some i -> on (Obj.obj i : int)
      | None -> on default
    in
    make ~name ~kind:Int ~parse:parse_int
      ~equal:(fun a b -> (Obj.obj a : int) = (Obj.obj b : int))
      ~on:(fun v -> on' (Some v))
      ~default_value:(Some (Obj.repr default))
      ()

  let float name ~on ?(default = 0.0) () =
    let on' v =
      match v with
      | Some f -> on (Obj.obj f : float)
      | None -> on default
    in
    make ~name ~kind:Float ~parse:parse_float
      ~equal:(fun a b -> (Obj.obj a : float) = (Obj.obj b : float))
      ~on:(fun v -> on' (Some v))
      ~default_value:(Some (Obj.repr default))
      ()

  let bool name ~on ?(default = false) () =
    let on' v =
      match v with
      | Some b -> on (Obj.obj b : bool)
      | None -> on default
    in
    make ~name ~kind:Bool ~parse:parse_bool
      ~equal:(fun a b -> (Obj.obj a : bool) = (Obj.obj b : bool))
      ~on:(fun v -> on' (Some v))
      ~default_value:(Some (Obj.repr default))
      ()

  let string name ~on ?(default = "") () =
    let on' v =
      match v with
      | Some s -> on (Obj.obj s : string)
      | None -> on default
    in
    make ~name ~kind:String ~parse:parse_string
      ~equal:(fun a b -> (Obj.obj a : string) = (Obj.obj b : string))
      ~on:(fun v -> on' (Some v))
      ~default_value:(Some (Obj.repr default))
      ()

  let list name ~eq ~(on : 'a list -> 'msg) =
    let on' v = on (Obj.obj v : 'a list) in
    let equal a b =
      let la = (Obj.obj a : 'a list) in
      let lb = (Obj.obj b : 'a list) in
      List.length la = List.length lb
      && List.for_all2 eq la lb
    in
    make ~name ~kind:List ~parse:(fun _ -> None) ~equal ~on:on'
      ~default_value:None ()

  let of_eq name ~eq ~(on : 'a -> 'msg) =
    let on' v = on (Obj.obj v : 'a) in
    let equal a b = eq (Obj.obj a : 'a) (Obj.obj b : 'a) in
    make ~name ~kind:Complex ~parse:(fun _ -> None) ~equal ~on:on'
      ~default_value:None ()

  let attr_or_prop name
      ~(of_string : string -> 'a option)
      ~(of_js : Bridge.value -> 'a option)
      ~eq
      ~(on : 'a -> 'msg)
      ?default
      () =
    let parse s =
      if String.trim s = "" then None
      else
        match of_string s with
        | None -> None
        | Some v -> Some (Obj.repr v)
    in
    let parse_js raw =
      match of_js raw with
      | None -> None
      | Some v -> Some (Obj.repr v)
    in
    let on' v = on (Obj.obj v : 'a) in
    let equal a b = eq (Obj.obj a : 'a) (Obj.obj b : 'a) in
    let default_value =
      match default with None -> None | Some v -> Some (Obj.repr v)
    in
    make ~name ~kind:Attr_or_prop ~parse ~equal ~on:on' ~default_value
      ~parse_js:(Some parse_js) ()

  let name (Decl d) = d.name
  let kind (Decl d) = d.kind
  let is_observable (Decl d) =
    match d.kind with
    | Int | Float | Bool | String | Attr_or_prop -> true
    | List | Complex -> false
end

module Vdom = Html

module Cmd = struct
  type ('msg, 'emits) t =
    | None
    | Msg of 'msg
    | Emit of 'emits
    | Emit_dom of string * Obj.t option
    | Focus of string
    | Batch of ('msg, 'emits) t list
    | Perform of (dispatch:('msg -> unit) -> unit)

  let none = None
  let msg m = Msg m
  let emit e = Emit e
  let emit_dom ~name ?detail () =
    Emit_dom (name, match detail with None -> None | Some d -> Some (Obj.repr d))
  let focus selector = Focus selector
  let batch cs = Batch cs
  let perform f = Perform f

  let rec is_none : (_, _) t -> bool = function
    | None -> true
    | Batch cs -> List.for_all is_none cs
    | _ -> false

  let rec iter ~none ~msg ~emit ~emit_dom ~focus ~perform cmd =
    match cmd with
    | None -> none ()
    | Msg m -> msg m
    | Emit e -> emit e
    | Emit_dom (name, detail) -> emit_dom ~name ~detail
    | Focus s -> focus s
    | Batch cs -> List.iter (iter ~none ~msg ~emit ~emit_dom ~focus ~perform) cs
    | Perform f -> perform f
end

type emits = Obj.t

type state = Obj.t

type msg = Obj.t

type cmd = Obj.t

let is_cmd_none : cmd -> bool =
 fun cmd -> (Obj.obj (Obj.repr cmd) : (_, _) Cmd.t) |> Cmd.is_none

type 'a envelope = {
  instance_id : string;
  payload : 'a;
}

module type COMPONENT = sig
  type state
  type msg
  type emits
  val props  : msg Props.t
  val init   : dispatch:(msg -> unit) -> state * (msg, emits) Cmd.t
  val update : state -> msg -> state * (msg, emits) Cmd.t
  val view   : state -> (msg -> unit) -> 'a Html.node -> msg Html.node
end

type instance = Instance : {
  module_ : (module COMPONENT);
  element : Bridge.element;
  state_key : unit ref;
  mutable projected : Bridge.element list;
  mutable projected_captured : bool;
  mutable dispatch : msg -> unit;
} -> instance

let types : (string, (module COMPONENT) * bool) Hashtbl.t =
  Hashtbl.create 16

let instances : (string, instance) Hashtbl.t =
  Hashtbl.create 64

let counter = ref 0

let next_instance_id () =
  incr counter;
  "inst_" ^ string_of_int !counter

let register_type ~module_ ~tag_name ?(shadow_dom = false) () =
  Hashtbl.replace types tag_name (module_, shadow_dom)

let create_instance ~tag_name ~dom_element =
  match Hashtbl.find_opt types tag_name with
  | None ->
    failwith ("ComponentAccess.create_instance: unregistered tag " ^ tag_name)
  | Some (module_, _shadow_dom) ->
    let instance_id = next_instance_id () in
    Hashtbl.replace instances instance_id
      (Instance
         {
           module_;
           element = dom_element;
           state_key = ref ();
           projected = [];
           projected_captured = false;
           dispatch = (fun _ -> ());
         });
    instance_id

let destroy_instance ~instance_id =
  Hashtbl.remove instances instance_id

let dom_element ~instance_id =
  match Hashtbl.find_opt instances instance_id with
  | None ->
    failwith ("ComponentAccess.dom_element: unknown instance " ^ instance_id)
  | Some (Instance r) -> r.element

let state_key ~instance_id =
  match Hashtbl.find_opt instances instance_id with
  | None ->
    failwith ("ComponentAccess.state_key: unknown instance " ^ instance_id)
  | Some (Instance r) -> r.state_key

let significant_light_dom_node (n : Bridge.element) : bool =
  match Bridge.node_type n with
  | 1 -> true
  | 3 ->
    (match Bridge.node_value n with
     | None -> false
     | Some s ->
       let trim =
         String.trim s
       in
       trim <> "")
  | _ -> false

let capture_projection ~instance_id =
  match Hashtbl.find_opt instances instance_id with
  | None ->
    failwith
      ("ComponentAccess.capture_projection: unknown instance " ^ instance_id)
  | Some (Instance r) ->
    if not r.projected_captured then begin
      let host = r.element in
      let nodes =
        List.filter significant_light_dom_node (Bridge.child_nodes host)
      in
      List.iter
        (fun child -> Bridge.remove_child ~parent:host ~child)
        nodes;
      r.projected <- nodes;
      r.projected_captured <- true
    end

let projected_nodes ~instance_id =
  match Hashtbl.find_opt instances instance_id with
  | None ->
    failwith
      ("ComponentAccess.projected_nodes: unknown instance " ^ instance_id)
  | Some (Instance r) -> r.projected

let slot_token ~instance_id : 'a Html.node =
  `Html
    {
      tag = "#slot";
      attrs = [ ("data-well-instance", instance_id) ];
      bool_attrs = [];
      handlers = [];
      children = [];
      text = None;
      void = false;
    }

let init_state ~instance_id ~dispatch =
  match Hashtbl.find_opt instances instance_id with
  | None ->
    failwith ("ComponentAccess.init_state: unknown instance " ^ instance_id)
  | Some (Instance r) ->
    r.dispatch <- dispatch;
    let (module M) = r.module_ in
    let dispatch_m (m : M.msg) =
      r.dispatch (Obj.obj (Obj.repr m) : msg)
    in
    let (st, cmd) = M.init ~dispatch:dispatch_m in
    { instance_id; payload = Obj.obj (Obj.repr (st, cmd)) }

let update_state ~instance_id state_env msg_env =
  match Hashtbl.find_opt instances instance_id with
  | None ->
    failwith ("ComponentAccess.update_state: unknown instance " ^ instance_id)
  | Some (Instance r) ->
    let (module M) = r.module_ in
    let st : M.state = Obj.obj (Obj.repr state_env.payload) in
    let m : M.msg = Obj.obj (Obj.repr msg_env.payload) in
    let (new_st, cmd) = M.update st m in
    { instance_id; payload = Obj.obj (Obj.repr (new_st, cmd)) }

let render_view ~instance_id state_env =
  match Hashtbl.find_opt instances instance_id with
  | None ->
    failwith ("ComponentAccess.render_view: unknown instance " ^ instance_id)
  | Some (Instance r) ->
    let (module M) = r.module_ in
    let st : M.state = Obj.obj (Obj.repr state_env.payload) in
    let dispatch_m (m : M.msg) =
      r.dispatch (Obj.obj (Obj.repr m) : msg)
    in
    let children = slot_token ~instance_id in
    let vdom = M.view st dispatch_m children in
    { instance_id; payload = Obj.obj (Obj.repr vdom) }

type prop_spec = {
  name : string;
  kind : Props.kind;
  parse_string : string -> Obj.t option;
  parse_js : (Bridge.value -> Obj.t option) option;
  equal : Obj.t -> Obj.t -> bool;
  to_msg : Obj.t -> msg;
  default_value : Obj.t option;
}

let props_of_instance ~instance_id : prop_spec list =
  match Hashtbl.find_opt instances instance_id with
  | None ->
    failwith ("ComponentAccess.props_of_instance: unknown instance " ^ instance_id)
  | Some (Instance r) ->
    let (module M) = r.module_ in
    List.map
      (fun (Props.Decl d) ->
        {
          name = d.name;
          kind = d.kind;
          parse_string = d.parse_string;
          parse_js = d.parse_js;
          equal = d.equal;
          to_msg =
            (fun v ->
              let m : M.msg = d.on v in
              (Obj.obj (Obj.repr m) : msg));
          default_value = d.default_value;
        })
      M.props

let props_of_tag ~tag_name : prop_spec list =
  match Hashtbl.find_opt types tag_name with
  | None ->
    failwith ("ComponentAccess.props_of_tag: unregistered tag " ^ tag_name)
  | Some (module_, _) ->
    let (module M) = module_ in
    List.map
      (fun (Props.Decl d) ->
        {
          name = d.name;
          kind = d.kind;
          parse_string = d.parse_string;
          parse_js = d.parse_js;
          equal = d.equal;
          to_msg =
            (fun v ->
              let m : M.msg = d.on v in
              (Obj.obj (Obj.repr m) : msg));
          default_value = d.default_value;
        })
      M.props

let instance_id_of_element (el : Bridge.element) : string option =
  let exception Found of string in
  try
    Hashtbl.iter
      (fun id (Instance r) -> if r.element == el then raise (Found id))
      instances;
    None
  with Found id -> Some id
