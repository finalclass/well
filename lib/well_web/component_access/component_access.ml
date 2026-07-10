[@@@warning "-69"]

module Props = struct
  type 'msg decl = Decl : {
    name : string;
    parse_string : string -> Obj.t option;
    equal : Obj.t -> Obj.t -> bool;
    on : Obj.t -> 'msg;
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

  let make ~name ~parse ~equal ~on =
    Decl { name; parse_string = parse; equal; on }

  let int name ~on ?(default = 0) () =
    let on' v =
      match v with
      | Some i -> on (Obj.obj i : int)
      | None -> on default
    in
    make ~name ~parse:parse_int
      ~equal:(fun a b -> (Obj.obj a : int) = (Obj.obj b : int))
      ~on:(fun v -> on' (Some v))

  let float name ~on ?(default = 0.0) () =
    let on' v =
      match v with
      | Some f -> on (Obj.obj f : float)
      | None -> on default
    in
    make ~name ~parse:parse_float
      ~equal:(fun a b -> (Obj.obj a : float) = (Obj.obj b : float))
      ~on:(fun v -> on' (Some v))

  let bool name ~on ?(default = false) () =
    let on' v =
      match v with
      | Some b -> on (Obj.obj b : bool)
      | None -> on default
    in
    make ~name ~parse:parse_bool
      ~equal:(fun a b -> (Obj.obj a : bool) = (Obj.obj b : bool))
      ~on:(fun v -> on' (Some v))

  let string name ~on ?(default = "") () =
    let on' v =
      match v with
      | Some s -> on (Obj.obj s : string)
      | None -> on default
    in
    make ~name ~parse:parse_string
      ~equal:(fun a b -> (Obj.obj a : string) = (Obj.obj b : string))
      ~on:(fun v -> on' (Some v))

  let list name ~eq ~(on : 'a list -> 'msg) =
    let on' v = on (Obj.obj v : 'a list) in
    let equal a b =
      let la = (Obj.obj a : 'a list) in
      let lb = (Obj.obj b : 'a list) in
      List.length la = List.length lb
      && List.for_all2 eq la lb
    in
    make ~name ~parse:(fun _ -> None) ~equal ~on:on'

  let of_eq name ~eq ~(on : 'a -> 'msg) =
    let on' v = on (Obj.obj v : 'a) in
    let equal a b = eq (Obj.obj a : 'a) (Obj.obj b : 'a) in
    make ~name ~parse:(fun _ -> None) ~equal ~on:on'
end

module Vdom = struct
  type 'msg handler = Bridge.event -> 'msg option

  type 'msg t = {
    tag : string;
    attrs : (string * string) list;
    children : 'msg t list;
    handlers : (string * 'msg handler) list;
    text : string option;
  }

  let element ?(attrs = []) ?(handlers = []) ?(children = []) ?text tag =
    { tag; attrs; handlers; children; text }

  let text str : 'msg t =
    { tag = ""; attrs = []; handlers = []; children = []; text = Some str }

  let on_click (msg : 'msg) : 'msg handler =
    Fun.const (Some msg)

  let on_event (name : string) (handler : 'msg handler) (node : 'msg t) : 'msg t =
    { node with handlers = (name, handler) :: node.handlers }
end

module Cmd = struct
  type ('msg, 'emits) t =
    | None
    | Msg of 'msg
    | Emit of 'emits
    | Focus of string

  let none = None
  let msg m = Msg m
  let emit e = Emit e
  let focus selector = Focus selector

  let is_none : (_, _) t -> bool = function
    | None -> true
    | _ -> false
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
  val view   : state -> (msg -> unit) -> 'a Vdom.t -> msg Vdom.t
end

type instance = Instance : {
  module_ : (module COMPONENT);
  element : Bridge.element;
  state_key : unit ref;
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
      (Instance { module_; element = dom_element; state_key = ref () });
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

let init_state ~instance_id =
  match Hashtbl.find_opt instances instance_id with
  | None ->
    failwith ("ComponentAccess.init_state: unknown instance " ^ instance_id)
  | Some (Instance r) ->
    let (module M) = r.module_ in
    let (st, _cmd) = M.init ~dispatch:(fun (_ : M.msg) -> ()) in
    { instance_id; payload = Obj.obj (Obj.repr st) }

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
    let children = Obj.obj (Obj.repr ()) in
    let vdom = M.view st (fun (_ : M.msg) -> ()) children in
    { instance_id; payload = Obj.obj (Obj.repr vdom) }
