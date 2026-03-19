(* Contract OCaml codegen — generates one .ml file per contract module *)

open Contract_types

(* ── Helpers ──────────────────────────────────────────────────────── *)

let snake_case name =
  let buf = Buffer.create (String.length name) in
  String.iteri (fun i c ->
    if c >= 'A' && c <= 'Z' then begin
      if i > 0 then Buffer.add_char buf '_';
      Buffer.add_char buf (Char.lowercase_ascii c)
    end else
      Buffer.add_char buf c
  ) name;
  Buffer.contents buf

let ocaml_module_name name =
  String.capitalize_ascii (snake_case name)

(* Convert a possibly-qualified message ref to OCaml path *)
(* "TaskAccess.ListReq" -> "Task_access.ListReq" *)
(* "ListReq" -> "ListReq" *)
let ocaml_msg_path s =
  match String.index_opt s '.' with
  | Some i ->
    let mod_part = String.sub s 0 i in
    let rest = String.sub s i (String.length s - i) in
    ocaml_module_name mod_part ^ rest
  | None -> s

let indent n s =
  let pad = String.make (n * 2) ' ' in
  String.split_on_char '\n' s
  |> List.map (fun line -> if line = "" then "" else pad ^ line)
  |> String.concat "\n"

(* ── Type display string (for REPL describe) ─────────────────────── *)

let rec type_to_display = function
  | Prim String -> "string"
  | Prim Int -> "int"
  | Prim Float -> "float"
  | Prim Bool -> "bool"
  | Prim Void -> "void"
  | Prim Date -> "date"
  | Prim Record -> "record"
  | Prim Ctx -> "ctx"
  | Custom { msg_name; _ } -> msg_name
  | List inner -> type_to_display inner ^ " list"
  | Optional inner -> type_to_display inner ^ " option"

(* ── Type to OCaml string ─────────────────────────────────────────── *)

let rec type_to_ocaml ~local_module = function
  | Prim String -> "string"
  | Prim Int -> "int"
  | Prim Float -> "float"
  | Prim Bool -> "bool"
  | Prim Void -> "unit"
  | Prim Date -> "string"
  | Prim Record -> "Yojson.Safe.t"
  | Prim Ctx -> "Well.rpc_ctx"
  | Custom { module_name; msg_name } ->
    if module_name = local_module then
      msg_name ^ ".t"
    else
      ocaml_module_name module_name ^ "." ^ msg_name ^ ".t"
  | List inner ->
    type_to_ocaml ~local_module inner ^ " list"
  | Optional inner ->
    type_to_ocaml ~local_module inner ^ " option"

(* ── Wire encoding expressions ────────────────────────────────────── *)

let rec to_wire_expr ~local_module expr = function
  | Prim String -> Printf.sprintf "`String %s" expr
  | Prim Int -> Printf.sprintf "`Int %s" expr
  | Prim Float -> Printf.sprintf "`Float %s" expr
  | Prim Bool -> Printf.sprintf "`Bool %s" expr
  | Prim Void -> "`Null"
  | Prim Date -> Printf.sprintf "`String %s" expr
  | Prim Record -> Printf.sprintf "(%s :> Yojson.Safe.t)" expr
  | Prim Ctx -> Printf.sprintf "Well.rpc_ctx_to_wire %s" expr
  | Custom { module_name; msg_name } ->
    if module_name = local_module then
      Printf.sprintf "%s.to_wire %s" msg_name expr
    else
      Printf.sprintf "%s.%s.to_wire %s" (ocaml_module_name module_name) msg_name expr
  | List inner ->
    let item_expr = to_wire_expr ~local_module "item" inner in
    Printf.sprintf "`List (List.map (fun item -> %s) %s)" item_expr expr
  | Optional inner ->
    let some_expr = to_wire_expr ~local_module "x" inner in
    Printf.sprintf "(match %s with Some x -> %s | None -> `Null)" expr some_expr

(* ── Wire decoding expressions ────────────────────────────────────── *)

let rec of_wire_expr ~local_module expr = function
  | Prim String ->
    Printf.sprintf "(match %s with `String s -> s | _ -> \"\")" expr
  | Prim Int ->
    Printf.sprintf "(match %s with `Int i -> i | _ -> 0)" expr
  | Prim Float ->
    Printf.sprintf "(match %s with `Float f -> f | `Int i -> float_of_int i | _ -> 0.0)" expr
  | Prim Bool ->
    Printf.sprintf "(match %s with `Bool b -> b | _ -> false)" expr
  | Prim Void -> "()"
  | Prim Date ->
    Printf.sprintf "(match %s with `String s -> s | _ -> \"\")" expr
  | Prim Record ->
    Printf.sprintf "(%s :> Yojson.Safe.t)" expr
  | Prim Ctx ->
    Printf.sprintf "Well.rpc_ctx_of_wire %s" expr
  | Custom { module_name; msg_name } ->
    if module_name = local_module then
      Printf.sprintf "%s.of_wire %s" msg_name expr
    else
      Printf.sprintf "%s.%s.of_wire %s" (ocaml_module_name module_name) msg_name expr
  | List inner ->
    let item_expr = of_wire_expr ~local_module "item" inner in
    Printf.sprintf "(match %s with `List items -> List.map (fun item -> %s) items | _ -> [])"
      expr item_expr
  | Optional inner ->
    let some_expr = of_wire_expr ~local_module "x" inner in
    Printf.sprintf "(match %s with `Null -> None | x -> Some (%s))" expr some_expr

(* ── Generate struct module ──────────────────────────────────────── *)

let generate_struct_module ~local_module msg_name props =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in

  (* type t *)
  p "module %s = struct\n" msg_name;
  p "  type t = {\n";
  List.iter (fun (prop : property) ->
    let ty = type_to_ocaml ~local_module prop.type_info in
    let ty = if prop.optional then ty ^ " option" else ty in
    p "    %s : %s;\n" prop.name ty
  ) props;
  p "  }\n\n";

  (* make *)
  p "  let make";
  List.iter (fun (prop : property) ->
    if prop.optional then
      p " ?%s" prop.name
    else
      p " ~%s" prop.name
  ) props;
  p " () =\n    {";
  List.iteri (fun i (prop : property) ->
    if i > 0 then p ";";
    if prop.optional then
      p " %s = (match %s with Some v -> Some v | None -> None)" prop.name prop.name
    else
      p " %s" prop.name
  ) props;
  p " }\n\n";

  (* to_wire — positional JSON array, fields in definition order *)
  p "  let to_wire (v : t) : Yojson.Safe.t =\n";
  p "    `List [\n";
  List.iter (fun (prop : property) ->
    let expr =
      if prop.optional then
        to_wire_expr ~local_module ("x") (Optional prop.type_info)
        |> Printf.sprintf "(let x = v.%s in %s)" prop.name
      else
        to_wire_expr ~local_module (Printf.sprintf "v.%s" prop.name) prop.type_info
    in
    p "      %s;\n" expr
  ) props;
  p "    ]\n\n";

  (* of_wire — positional JSON array *)
  p "  let of_wire (wire : Yojson.Safe.t) : t =\n";
  p "    match wire with\n";
  p "    | `List arr ->\n";
  p "      let a = Array.of_list arr in\n";
  p "      let _g i = if i < Array.length a then a.(i) else `Null in\n";
  List.iteri (fun i (prop : property) ->
    let access = Printf.sprintf "(_g %d)" i in
    let expr =
      if prop.optional then
        of_wire_expr ~local_module access (Optional prop.type_info)
      else
        of_wire_expr ~local_module access prop.type_info
    in
    p "      let %s = %s in\n" prop.name expr
  ) props;
  p "      {";
  List.iteri (fun i (prop : property) ->
    if i > 0 then p ";";
    p " %s" prop.name
  ) props;
  p " }\n";
  p "    | _ -> failwith \"%s.of_wire: expected JSON array\"\n" msg_name;

  p "end\n";
  Buffer.contents buf

(* ── Generate variant module ─────────────────────────────────────── *)

let generate_variant_module ~local_module msg_name ctors =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in

  (* type t *)
  p "module %s = struct\n" msg_name;
  p "  type t =\n";
  List.iter (fun (ctor : constructor) ->
    match ctor.payload with
    | Prim Void -> p "    | %s\n" ctor.name
    | ti -> p "    | %s of %s\n" ctor.name (type_to_ocaml ~local_module ti)
  ) ctors;
  p "\n";

  (* to_wire *)
  p "  let to_wire (v : t) : Yojson.Safe.t =\n";
  p "    match v with\n";
  List.iter (fun (ctor : constructor) ->
    match ctor.payload with
    | Prim Void ->
      p "    | %s -> `List [`String \"%s\"; `Null]\n" ctor.name ctor.name
    | ti ->
      let expr = to_wire_expr ~local_module "payload" ti in
      p "    | %s payload -> `List [`String \"%s\"; %s]\n" ctor.name ctor.name expr
  ) ctors;
  p "\n";

  (* of_wire *)
  p "  let of_wire (wire : Yojson.Safe.t) : t =\n";
  p "    match wire with\n";
  List.iter (fun (ctor : constructor) ->
    match ctor.payload with
    | Prim Void ->
      p "    | `List [`String \"%s\"; `Null] | `List [`String \"%s\"] -> %s\n"
        ctor.name ctor.name ctor.name
    | ti ->
      let expr = of_wire_expr ~local_module "payload" ti in
      p "    | `List [`String \"%s\"; payload] -> %s (%s)\n"
        ctor.name ctor.name expr
  ) ctors;
  p "    | _ -> failwith \"%s.of_wire: unexpected wire format\"\n" msg_name;

  p "end\n";
  Buffer.contents buf

(* ── Generate message module ─────────────────────────────────────── *)

let generate_msg ~local_module (msg : msg) =
  match msg.kind with
  | Struct props -> generate_struct_module ~local_module msg.name props
  | Variant ctors -> generate_variant_module ~local_module msg.name ctors

(* ── Generate IMPL module type ────────────────────────────────────── *)

let resolve_msg_type ~local_module msgs msg_ref =
  if List.exists (fun (m : msg) -> m.name = msg_ref) msgs then
    msg_ref ^ ".t"
  else
    match String.index_opt msg_ref '.' with
    | Some i ->
      let mod_name = String.sub msg_ref 0 i in
      let msg_name = String.sub msg_ref (i + 1) (String.length msg_ref - i - 1) in
      if mod_name = local_module then msg_name ^ ".t"
      else ocaml_module_name mod_name ^ "." ^ msg_name ^ ".t"
    | None -> msg_ref ^ ".t"

let generate_impl_sig ~local_module service msgs =
  let buf = Buffer.create 256 in
  let p fmt = Printf.bprintf buf fmt in
  p "module type IMPL = sig\n";
  List.iter (fun (rpc : rpc) ->
    let req_type = resolve_msg_type ~local_module msgs rpc.request_msg in
    let resp_type = resolve_msg_type ~local_module msgs rpc.response_msg in
    p "  val %s : Well.rpc_ctx -> %s -> %s\n" (snake_case rpc.name) req_type resp_type
  ) service.rpcs;
  p "end\n";
  Buffer.contents buf

(* ── Generate make_spec ──────────────────────────────────────────── *)

let generate_make_spec ~local_module:_ cm service =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in

  p "let make_spec (module I : IMPL) : Well.Service.spec =\n";
  p "  { name = \"%s\"\n" cm.name;
  p "  ; rpcs = [\n";
  List.iter (fun (rpc : rpc) ->
    let req_msg = List.find_opt (fun (m : msg) -> m.name = rpc.request_msg) cm.msgs in
    let resp_msg = List.find_opt (fun (m : msg) -> m.name = rpc.response_msg) cm.msgs in
    let gen_params msg_opt =
      match msg_opt with
      | Some { kind = Struct props; _ } ->
        String.concat "; " (List.map (fun (prop : property) ->
          let ty = if prop.optional then type_to_display (Optional prop.type_info)
                   else type_to_display prop.type_info in
          Printf.sprintf "{ Well.Service.pname = \"%s\"; ptype = \"%s\"; poptional = %b }"
            prop.name ty prop.optional
        ) props)
      | _ -> ""
    in
    let returns_name = match resp_msg with
      | Some m -> m.name | None -> rpc.response_msg in
    p "      { Well.Service.rname = \"%s\"\n" rpc.name;
    p "      ; params = [%s]\n" (gen_params req_msg);
    p "      ; returns = [%s]\n" (gen_params resp_msg);
    p "      ; returns_name = \"%s\" };\n" returns_name
  ) service.rpcs;
  p "    ]\n";
  p "  ; handler = (fun rpc_name ctx_json payload ->\n";
  p "      let ctx = Well.rpc_ctx_of_wire ctx_json in\n";
  p "      match rpc_name with\n";
  List.iter (fun (rpc : rpc) ->
    p "      | \"%s\" ->\n" rpc.name;
    p "          %s.to_wire (I.%s ctx (%s.of_wire payload))\n"
      (ocaml_msg_path rpc.response_msg) (snake_case rpc.name) (ocaml_msg_path rpc.request_msg)
  ) service.rpcs;
  p "      | _ -> failwith (\"Unknown RPC: \" ^ rpc_name))\n";
  p "  ; set_ref = (fun f -> _service_ref := Some f)\n";
  p "  }\n";
  Buffer.contents buf

(* ── Generate convenience functions ──────────────────────────────── *)

let generate_convenience_fns cm service =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in

  List.iter (fun (rpc : rpc) ->
    let fn_name = snake_case rpc.name in
    (* Find the request msg to get its fields *)
    let req_msg =
      List.find_opt (fun (m : msg) -> m.name = rpc.request_msg) cm.msgs
    in
    match req_msg with
    | Some { kind = Struct props; _ } ->
      let req_path = ocaml_msg_path rpc.request_msg in
      let resp_path = ocaml_msg_path rpc.response_msg in
      let has_optional = List.exists (fun (p : property) -> p.optional) props in
      p "let %s ~ctx" fn_name;
      List.iter (fun (prop : property) ->
        if prop.optional then
          p " ?%s" prop.name
        else
          p " ~%s" prop.name
      ) props;
      if has_optional then p " ()";
      p " =\n";
      p "  let ctx_wire = Well.rpc_ctx_to_wire ctx in\n";
      p "  let wire = %s.to_wire (%s.make" req_path req_path;
      List.iter (fun (prop : property) ->
        if prop.optional then
          p " ?%s" prop.name
        else
          p " ~%s" prop.name
      ) props;
      p " ()) in\n";
      p "  %s.of_wire\n" resp_path;
      p "    ((match !_service_ref with\n";
      p "      | Some f -> f \"%s\" ctx_wire wire\n" rpc.name;
      p "      | None -> failwith \"%s: service not registered\"))\n\n" cm.name
    | _ ->
      (* Variant or external request — take raw value *)
      let req_path = ocaml_msg_path rpc.request_msg in
      let resp_path = ocaml_msg_path rpc.response_msg in
      p "let %s ~ctx req =\n" fn_name;
      p "  let ctx_wire = Well.rpc_ctx_to_wire ctx in\n";
      p "  let wire = %s.to_wire req in\n" req_path;
      p "  %s.of_wire\n" resp_path;
      p "    ((match !_service_ref with\n";
      p "      | Some f -> f \"%s\" ctx_wire wire\n" rpc.name;
      p "      | None -> failwith \"%s: service not registered\"))\n\n" cm.name
  ) service.rpcs;
  Buffer.contents buf

(* ── Generate complete module ─────────────────────────────────────── *)

let generate_module cm =
  let buf = Buffer.create 2048 in
  let p fmt = Printf.bprintf buf fmt in
  let local_module = cm.name in

  p "[@@@warning \"-32\"]\n\n";

  (* Message modules — topologically sorted *)
  List.iter (fun msg ->
    p "%s\n" (generate_msg ~local_module msg)
  ) cm.msgs;

  (* Service-specific code *)
  (match cm.service with
   | Some service ->
     (* Service ref *)
     p "let _service_ref : (string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t) option ref = ref None\n\n";

     (* IMPL module type *)
     p "%s\n" (generate_impl_sig ~local_module service cm.msgs);

     (* make_spec *)
     p "%s\n" (generate_make_spec ~local_module cm service);

     (* Convenience functions *)
     p "%s" (generate_convenience_fns cm service)

   | None -> ());

  Buffer.contents buf

(* ── Generate dune file ──────────────────────────────────────────── *)

let generate_dune modules ~output_dir =
  let lib_name =
    (* Walk up past build/{ocaml,ts} to find the real library name *)
    let base = Filename.basename output_dir in
    let parent = Filename.basename (Filename.dirname output_dir) in
    if base = "ocaml" && parent = "build" then
      Filename.basename (Filename.dirname (Filename.dirname output_dir))
      |> String.lowercase_ascii
    else
      String.lowercase_ascii base
  in
  let module_names =
    List.map (fun (cm : contract_module) -> snake_case cm.name) modules
  in
  let buf = Buffer.create 256 in
  let p fmt = Printf.bprintf buf fmt in
  p "(library\n";
  p " (name %s)\n" lib_name;
  p " (wrapped false)\n";
  p " (libraries well.core yojson)\n";
  p " (modules %s))\n" (String.concat " " module_names);
  Buffer.contents buf

(* ══════════════════════════════════════════════════════════════════ *)
(* TypeScript codegen                                                *)
(* ══════════════════════════════════════════════════════════════════ *)

(* ── TS type string ──────────────────────────────────────────────── *)

let rec ts_type ~local_module = function
  | Prim String -> "string"
  | Prim Int -> "number"
  | Prim Float -> "number"
  | Prim Bool -> "boolean"
  | Prim Void -> "void"
  | Prim Date -> "string"
  | Prim Record -> "unknown"
  | Prim Ctx -> "RpcCtx"
  | Custom { module_name; msg_name } ->
    if module_name = local_module then msg_name
    else module_name ^ "." ^ msg_name
  | List inner ->
    ts_type ~local_module inner ^ "[]"
  | Optional inner ->
    ts_type ~local_module inner ^ " | null"

(* ── TS encode expression ────────────────────────────────────────── *)

let rec ts_encode ~local_module expr = function
  | Prim (String | Int | Float | Bool | Date | Record) -> expr
  | Prim Ctx -> Printf.sprintf "encodeRpcCtx(%s)" expr
  | Prim Void -> "null"
  | Custom { module_name; msg_name } ->
    if module_name = local_module then
      Printf.sprintf "encode%s(%s)" msg_name expr
    else
      Printf.sprintf "%s.encode%s(%s)" module_name msg_name expr
  | List inner ->
    let item = ts_encode ~local_module "v" inner in
    if item = "v" then expr
    else Printf.sprintf "%s.map(v => %s)" expr item
  | Optional inner ->
    let enc = ts_encode ~local_module "v" inner in
    if enc = "v" then expr
    else
      let v_expr = ts_encode ~local_module expr inner in
      Printf.sprintf "%s !== null ? %s : null" expr v_expr

(* ── TS decode expression ────────────────────────────────────────── *)

let rec ts_decode ~local_module expr = function
  | Prim String -> Printf.sprintf "%s as string" expr
  | Prim Int | Prim Float -> Printf.sprintf "%s as number" expr
  | Prim Bool -> Printf.sprintf "%s as boolean" expr
  | Prim Void -> "undefined"
  | Prim Date -> Printf.sprintf "%s as string" expr
  | Prim Record -> expr
  | Prim Ctx -> Printf.sprintf "decodeRpcCtx(%s as unknown[])" expr
  | Custom { module_name; msg_name } ->
    if module_name = local_module then
      Printf.sprintf "decode%s(%s as unknown[])" msg_name expr
    else
      Printf.sprintf "%s.decode%s(%s as unknown[])" module_name msg_name expr
  | List inner ->
    let item = ts_decode ~local_module "v" inner in
    Printf.sprintf "(%s as unknown[]).map(v => %s)" expr item
  | Optional inner ->
    let dec = ts_decode ~local_module "v" inner in
    Printf.sprintf "%s === null ? null : (v => %s)(%s)" expr dec expr

(* ── Generate TS interface + encode/decode for a struct msg ───────── *)

let generate_ts_struct ~local_module msg_name props =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in

  (* interface *)
  p "export interface %s {\n" msg_name;
  List.iter (fun (prop : property) ->
    let ty = ts_type ~local_module prop.type_info in
    let ty = if prop.optional then ty ^ " | null" else ty in
    p "  %s: %s;\n" prop.name ty
  ) props;
  p "}\n\n";

  (* encode — returns positional array *)
  p "export function encode%s(v: %s): unknown[] {\n" msg_name msg_name;
  p "  return [";
  List.iteri (fun i (prop : property) ->
    if i > 0 then p ", ";
    let expr =
      if prop.optional then
        let enc = ts_encode ~local_module ("v." ^ prop.name) (Optional prop.type_info) in
        enc
      else
        ts_encode ~local_module ("v." ^ prop.name) prop.type_info
    in
    p "%s" expr
  ) props;
  p "];\n";
  p "}\n\n";

  (* decode — from positional array *)
  p "export function decode%s(wire: unknown[]): %s {\n" msg_name msg_name;
  p "  return {\n";
  List.iteri (fun i (prop : property) ->
    let access = Printf.sprintf "wire[%d]" i in
    let expr =
      if prop.optional then
        ts_decode ~local_module access (Optional prop.type_info)
      else
        ts_decode ~local_module access prop.type_info
    in
    p "    %s: %s,\n" prop.name expr
  ) props;
  p "  };\n";
  p "}\n";
  Buffer.contents buf

(* ── Generate TS for a variant msg ───────────────────────────────── *)

let generate_ts_variant ~local_module msg_name ctors =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in

  (* type union *)
  p "export type %s =\n" msg_name;
  List.iteri (fun i (ctor : constructor) ->
    let prefix = if i = 0 then "  | " else "  | " in
    match ctor.payload with
    | Prim Void -> p "%s{ tag: \"%s\" }\n" prefix ctor.name
    | ti -> p "%s{ tag: \"%s\"; value: %s }\n" prefix ctor.name (ts_type ~local_module ti)
  ) ctors;
  p ";\n\n";

  (* encode *)
  p "export function encode%s(v: %s): unknown[] {\n" msg_name msg_name;
  p "  switch (v.tag) {\n";
  List.iter (fun (ctor : constructor) ->
    match ctor.payload with
    | Prim Void ->
      p "    case \"%s\": return [\"%s\", null];\n" ctor.name ctor.name
    | ti ->
      let expr = ts_encode ~local_module "(v as any).value" ti in
      p "    case \"%s\": return [\"%s\", %s];\n" ctor.name ctor.name expr
  ) ctors;
  p "  }\n";
  p "}\n\n";

  (* decode *)
  p "export function decode%s(wire: unknown[]): %s {\n" msg_name msg_name;
  p "  const tag = wire[0] as string;\n";
  p "  switch (tag) {\n";
  List.iter (fun (ctor : constructor) ->
    match ctor.payload with
    | Prim Void ->
      p "    case \"%s\": return { tag: \"%s\" };\n" ctor.name ctor.name
    | ti ->
      let expr = ts_decode ~local_module "wire[1]" ti in
      p "    case \"%s\": return { tag: \"%s\", value: %s };\n" ctor.name ctor.name expr
  ) ctors;
  p "    default: throw new Error(`Unknown %s tag: ${tag}`);\n" msg_name;
  p "  }\n";
  p "}\n";
  Buffer.contents buf

(* ── Generate TS for one message ─────────────────────────────────── *)

let generate_ts_msg ~local_module (msg : msg) =
  match msg.kind with
  | Struct props -> generate_ts_struct ~local_module msg.name props
  | Variant ctors -> generate_ts_variant ~local_module msg.name ctors

(* ── Generate TS Impl interface ──────────────────────────────────── *)

let generate_ts_impl ~local_module service msgs =
  let buf = Buffer.create 256 in
  let p fmt = Printf.bprintf buf fmt in
  p "export interface Impl {\n";
  List.iter (fun (rpc : rpc) ->
    let req_type =
      let r = rpc.request_msg in
      if List.exists (fun (m : msg) -> m.name = r) msgs then r
      else
        match String.index_opt r '.' with
        | Some i ->
          let m = String.sub r 0 i in
          let n = String.sub r (i + 1) (String.length r - i - 1) in
          if m = local_module then n else m ^ "." ^ n
        | None -> r
    in
    let resp_type =
      let r = rpc.response_msg in
      if List.exists (fun (m : msg) -> m.name = r) msgs then r
      else
        match String.index_opt r '.' with
        | Some i ->
          let m = String.sub r 0 i in
          let n = String.sub r (i + 1) (String.length r - i - 1) in
          if m = local_module then n else m ^ "." ^ n
        | None -> r
    in
    p "  %s(req: %s): Promise<%s>;\n" (snake_case rpc.name) req_type resp_type
  ) service.rpcs;
  p "}\n";
  Buffer.contents buf

(* ── Generate TS Proxy ───────────────────────────────────────────── *)

let generate_ts_proxy ~local_module cm service =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in
  p "export const Proxy: Impl = {\n";
  List.iter (fun (rpc : rpc) ->
    let req_msg = rpc.request_msg in
    let resp_msg = rpc.response_msg in
    (* Resolve encode function *)
    let encode_fn =
      match String.index_opt req_msg '.' with
      | Some i ->
        let m = String.sub req_msg 0 i in
        let n = String.sub req_msg (i + 1) (String.length req_msg - i - 1) in
        if m = local_module then Printf.sprintf "encode%s" n
        else Printf.sprintf "%s.encode%s" m n
      | None -> Printf.sprintf "encode%s" req_msg
    in
    (* Resolve decode function *)
    let decode_fn =
      match String.index_opt resp_msg '.' with
      | Some i ->
        let m = String.sub resp_msg 0 i in
        let n = String.sub resp_msg (i + 1) (String.length resp_msg - i - 1) in
        if m = local_module then Printf.sprintf "decode%s" n
        else Printf.sprintf "%s.decode%s" m n
      | None -> Printf.sprintf "decode%s" resp_msg
    in
    p "  async %s(req) {\n" (snake_case rpc.name);
    p "    return %s(await rpc(\"%s\", \"%s\", %s(req)) as unknown[]);\n"
      decode_fn cm.name rpc.name encode_fn;
    p "  },\n"
  ) service.rpcs;
  p "};\n";
  Buffer.contents buf

(* ── Collect cross-module imports ────────────────────────────────── *)

let ts_imports cm =
  let modules = Hashtbl.create 4 in
  let rec scan_type = function
    | Prim _ -> ()
    | Custom { module_name; _ } ->
      if module_name <> cm.name then
        Hashtbl.replace modules module_name true
    | List inner -> scan_type inner
    | Optional inner -> scan_type inner
  in
  let scan_msg (msg : msg) =
    match msg.kind with
    | Struct props ->
      List.iter (fun (p : property) -> scan_type p.type_info) props
    | Variant ctors ->
      List.iter (fun (c : constructor) -> scan_type c.payload) ctors
  in
  List.iter scan_msg cm.msgs;
  (* Also scan RPC refs *)
  (match cm.service with
   | Some service ->
     List.iter (fun (rpc : rpc) ->
       let check ref_ =
         match String.index_opt ref_ '.' with
         | Some i ->
           let m = String.sub ref_ 0 i in
           if m <> cm.name then Hashtbl.replace modules m true
         | None -> ()
       in
       check rpc.request_msg;
       check rpc.response_msg
     ) service.rpcs
   | None -> ());
  let result = Hashtbl.fold (fun k _ acc -> k :: acc) modules [] in
  List.sort String.compare result

(* ── Generate complete TS module ─────────────────────────────────── *)

let generate_ts_module cm =
  let buf = Buffer.create 2048 in
  let p fmt = Printf.bprintf buf fmt in
  let local_module = cm.name in

  (* Imports *)
  let imports = ts_imports cm in
  if cm.service <> None then
    p "import { rpc } from './rpc';\n";
  List.iter (fun m ->
    p "import * as %s from './%s';\n" m m
  ) imports;
  if imports <> [] || cm.service <> None then p "\n";

  (* Message types *)
  List.iter (fun msg ->
    p "%s\n" (generate_ts_msg ~local_module msg)
  ) cm.msgs;

  (* Service *)
  (match cm.service with
   | Some service ->
     p "%s\n" (generate_ts_impl ~local_module service cm.msgs);
     p "%s" (generate_ts_proxy ~local_module cm service)
   | None -> ());

  Buffer.contents buf

(* ── rpc.ts (fixed content) ──────────────────────────────────────── *)

let generate_ts_rpc () =
  {|export async function rpc(service: string, method: string, payload: unknown[]): Promise<unknown> {
  const res = await fetch(`/rpc/${service}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest" },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`RPC ${service}.${method}: ${res.status}`);
  return res.json();
}
|}

(* ══════════════════════════════════════════════════════════════════ *)
(* Go codegen                                                        *)
(* ══════════════════════════════════════════════════════════════════ *)

(* ── Go naming helpers ───────────────────────────────────────────── *)

let go_public_name name =
  (* snake_case → PascalCase, or capitalize first letter *)
  if String.contains name '_' then
    String.split_on_char '_' name
    |> List.map (fun w ->
      if w = "" then ""
      else String.capitalize_ascii w)
    |> String.concat ""
  else
    String.capitalize_ascii name

let go_pkg_name name =
  String.lowercase_ascii name

(* ── Go type string ──────────────────────────────────────────────── *)

let rec go_type ~local_module = function
  | Prim String -> "string"
  | Prim Int -> "int"
  | Prim Float -> "float64"
  | Prim Bool -> "bool"
  | Prim Void -> "struct{}"
  | Prim Date -> "string"
  | Prim Record -> "map[string]any"
  | Prim Ctx -> "RpcCtx"
  | Custom { module_name; msg_name } ->
    if module_name = local_module then msg_name
    else go_pkg_name module_name ^ "." ^ msg_name
  | List inner ->
    "[]" ^ go_type ~local_module inner
  | Optional inner ->
    "*" ^ go_type ~local_module inner

(* ── Go ToWire expression ────────────────────────────────────────── *)

let rec go_to_wire ~local_module expr = function
  | Prim (String | Int | Float | Bool | Date) -> expr
  | Prim Void -> "nil"
  | Prim Record -> expr
  | Prim Ctx -> Printf.sprintf "%s.ToWire()" expr
  | Custom { module_name; msg_name = _ } ->
    if module_name = local_module then
      Printf.sprintf "%s.ToWire()" expr
    else
      Printf.sprintf "%s.ToWire()" expr
  | List inner ->
    let needs_map = match inner with
      | Prim (String | Int | Float | Bool | Date) -> false
      | _ -> true
    in
    if needs_map then
      let item = go_to_wire ~local_module "v" inner in
      Printf.sprintf "func() []any { r := make([]any, len(%s)); for i, v := range %s { r[i] = %s }; return r }()"
        expr expr item
    else
      expr
  | Optional inner ->
    let enc = go_to_wire ~local_module ("*" ^ expr) inner in
    Printf.sprintf "func() any { if %s != nil { return %s }; return nil }()" expr enc

(* ── Go FromWire expression ──────────────────────────────────────── *)

let rec go_from_wire ~local_module expr = function
  | Prim String -> Printf.sprintf "%s.(string)" expr
  | Prim Int -> Printf.sprintf "int(%s.(float64))" expr
  | Prim Float -> Printf.sprintf "%s.(float64)" expr
  | Prim Bool -> Printf.sprintf "%s.(bool)" expr
  | Prim Void -> "struct{}{}"
  | Prim Date -> Printf.sprintf "%s.(string)" expr
  | Prim Record -> Printf.sprintf "%s.(map[string]any)" expr
  | Prim Ctx -> Printf.sprintf "RpcCtxFromWire(%s)" expr
  | Custom { module_name; msg_name } ->
    if module_name = local_module then
      Printf.sprintf "%sFromWire(%s)" msg_name expr
    else
      Printf.sprintf "%s.%sFromWire(%s)" (go_pkg_name module_name) msg_name expr
  | List inner ->
    let item = go_from_wire ~local_module "e" inner in
    let ty = go_type ~local_module inner in
    Printf.sprintf "func() %s { arr := %s.([]any); r := make(%s, len(arr)); for i, e := range arr { r[i] = %s }; return r }()"
      (go_type ~local_module (List inner)) expr (go_type ~local_module (List inner))
      (Printf.sprintf "func(_ int, _ any) %s { return %s }(i, e)" ty item)
  | Optional inner ->
    let dec = go_from_wire ~local_module expr inner in
    let ty = go_type ~local_module inner in
    Printf.sprintf "func() *%s { if %s == nil { return nil }; v := %s; return &v }()" ty expr dec

(* ── Go: simplify list FromWire — less closures ─────────────────── *)

let go_from_wire_list ~local_module expr inner =
  let item = go_from_wire ~local_module "arr[i]" inner in
  let list_ty = go_type ~local_module (List inner) in
  Printf.sprintf "func() %s {\n\t\tarr := %s.([]any)\n\t\tr := make(%s, len(arr))\n\t\tfor i := range arr {\n\t\t\tr[i] = %s\n\t\t}\n\t\treturn r\n\t}()"
    list_ty expr list_ty item

(* ── Generate Go struct ──────────────────────────────────────────── *)

let generate_go_struct ~local_module msg_name props =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in

  (* struct type *)
  p "type %s struct {\n" msg_name;
  List.iter (fun (prop : property) ->
    let ty = go_type ~local_module prop.type_info in
    let ty = if prop.optional then "*" ^ ty else ty in
    (* Remove double pointer for Optional types *)
    let ty = if prop.optional then
      match prop.type_info with
      | Optional _ -> go_type ~local_module prop.type_info
      | _ -> ty
    else ty in
    p "\t%s %s\n" (go_public_name prop.name) ty
  ) props;
  p "}\n\n";

  (* ToWire *)
  p "func (v %s) ToWire() []any {\n" msg_name;
  p "\treturn []any{";
  List.iteri (fun i (prop : property) ->
    if i > 0 then p ", ";
    let field = "v." ^ go_public_name prop.name in
    if prop.optional then
      p "%s" (go_to_wire ~local_module field (Optional prop.type_info))
    else
      p "%s" (go_to_wire ~local_module field prop.type_info)
  ) props;
  p "}\n";
  p "}\n\n";

  (* FromWire *)
  p "func %sFromWire(data any) %s {\n" msg_name msg_name;
  p "\tarr := data.([]any)\n";
  p "\treturn %s{\n" msg_name;
  List.iteri (fun i (prop : property) ->
    let access = Printf.sprintf "arr[%d]" i in
    let expr =
      if prop.optional then
        go_from_wire ~local_module access (Optional prop.type_info)
      else
        match prop.type_info with
        | List inner -> go_from_wire_list ~local_module access inner
        | _ -> go_from_wire ~local_module access prop.type_info
    in
    p "\t\t%s: %s,\n" (go_public_name prop.name) expr
  ) props;
  p "\t}\n";
  p "}\n";
  Buffer.contents buf

(* ── Generate Go variant ─────────────────────────────────────────── *)

let generate_go_variant ~local_module msg_name ctors =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in

  (* struct with tag + payload *)
  p "type %s struct {\n" msg_name;
  p "\tTag     string\n";
  p "\tPayload any\n";
  p "}\n\n";

  (* Constructors *)
  List.iter (fun (ctor : constructor) ->
    match ctor.payload with
    | Prim Void ->
      p "func %s%s() %s {\n" msg_name ctor.name msg_name;
      p "\treturn %s{Tag: \"%s\"}\n" msg_name ctor.name;
      p "}\n\n"
    | ti ->
      let ty = go_type ~local_module ti in
      p "func %s%s(payload %s) %s {\n" msg_name ctor.name ty msg_name;
      p "\treturn %s{Tag: \"%s\", Payload: payload}\n" msg_name ctor.name;
      p "}\n\n"
  ) ctors;

  (* ToWire *)
  p "func (v %s) ToWire() []any {\n" msg_name;
  p "\tswitch v.Tag {\n";
  List.iter (fun (ctor : constructor) ->
    match ctor.payload with
    | Prim Void ->
      p "\tcase \"%s\":\n" ctor.name;
      p "\t\treturn []any{\"%s\", nil}\n" ctor.name
    | ti ->
      let expr = go_to_wire ~local_module (Printf.sprintf "v.Payload.(%s)" (go_type ~local_module ti)) ti in
      p "\tcase \"%s\":\n" ctor.name;
      p "\t\treturn []any{\"%s\", %s}\n" ctor.name expr
  ) ctors;
  p "\tdefault:\n";
  p "\t\treturn []any{v.Tag, nil}\n";
  p "\t}\n";
  p "}\n\n";

  (* FromWire *)
  p "func %sFromWire(data any) %s {\n" msg_name msg_name;
  p "\tarr := data.([]any)\n";
  p "\ttag := arr[0].(string)\n";
  p "\tswitch tag {\n";
  List.iter (fun (ctor : constructor) ->
    match ctor.payload with
    | Prim Void ->
      p "\tcase \"%s\":\n" ctor.name;
      p "\t\treturn %s%s()\n" msg_name ctor.name
    | ti ->
      let expr = go_from_wire ~local_module "arr[1]" ti in
      p "\tcase \"%s\":\n" ctor.name;
      p "\t\treturn %s%s(%s)\n" msg_name ctor.name expr
  ) ctors;
  p "\tdefault:\n";
  p "\t\tpanic(\"unknown %s tag: \" + tag)\n" msg_name;
  p "\t}\n";
  p "}\n";
  Buffer.contents buf

(* ── Generate Go msg ─────────────────────────────────────────────── *)

let generate_go_msg ~local_module (msg : msg) =
  match msg.kind with
  | Struct props -> generate_go_struct ~local_module msg.name props
  | Variant ctors -> generate_go_variant ~local_module msg.name ctors

(* ── Go interface ────────────────────────────────────────────────── *)

let generate_go_interface ~local_module service msgs =
  let buf = Buffer.create 256 in
  let p fmt = Printf.bprintf buf fmt in
  let resolve ref_ =
    if List.exists (fun (m : msg) -> m.name = ref_) msgs then ref_
    else
      match String.index_opt ref_ '.' with
      | Some i ->
        let m = String.sub ref_ 0 i in
        let n = String.sub ref_ (i + 1) (String.length ref_ - i - 1) in
        if m = local_module then n
        else go_pkg_name m ^ "." ^ n
      | None -> ref_
  in
  p "type %s interface {\n" (go_public_name "handler");
  List.iter (fun (rpc : rpc) ->
    p "\t%s(req %s) %s\n"
      (go_public_name rpc.name) (resolve rpc.request_msg) (resolve rpc.response_msg)
  ) service.rpcs;
  p "}\n";
  Buffer.contents buf

(* ── Go proxy (Call functions) ───────────────────────────────────── *)

let generate_go_calls ~local_module cm service msgs =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in
  let resolve ref_ =
    if List.exists (fun (m : msg) -> m.name = ref_) msgs then ref_
    else
      match String.index_opt ref_ '.' with
      | Some i ->
        let m = String.sub ref_ 0 i in
        let n = String.sub ref_ (i + 1) (String.length ref_ - i - 1) in
        if m = local_module then n
        else go_pkg_name m ^ "." ^ n
      | None -> ref_
  in
  let resolve_from_wire ref_ =
    match String.index_opt ref_ '.' with
    | Some i ->
      let m = String.sub ref_ 0 i in
      let n = String.sub ref_ (i + 1) (String.length ref_ - i - 1) in
      if m = local_module then Printf.sprintf "%sFromWire" n
      else Printf.sprintf "%s.%sFromWire" (go_pkg_name m) n
    | None -> Printf.sprintf "%sFromWire" ref_
  in
  List.iter (fun (rpc : rpc) ->
    let fn_name = go_public_name rpc.name in
    let req_type = resolve rpc.request_msg in
    let resp_type = resolve rpc.response_msg in
    let from_wire = resolve_from_wire rpc.response_msg in
    p "func Call%s(baseURL string, req %s) (%s, error) {\n" fn_name req_type resp_type;
    p "\twire, err := rpc(baseURL, \"%s\", \"%s\", req.ToWire())\n" cm.name rpc.name;
    p "\tif err != nil {\n";
    p "\t\tvar zero %s\n" resp_type;
    p "\t\treturn zero, err\n";
    p "\t}\n";
    p "\treturn %s(wire), nil\n" from_wire;
    p "}\n\n"
  ) service.rpcs;
  Buffer.contents buf

(* ── Go cross-module imports ─────────────────────────────────────── *)

let go_imports cm =
  let modules = Hashtbl.create 4 in
  let rec scan_type = function
    | Prim _ -> ()
    | Custom { module_name; _ } ->
      if module_name <> cm.name then
        Hashtbl.replace modules module_name true
    | List inner -> scan_type inner
    | Optional inner -> scan_type inner
  in
  let scan_msg (msg : msg) =
    match msg.kind with
    | Struct props ->
      List.iter (fun (p : property) -> scan_type p.type_info) props
    | Variant ctors ->
      List.iter (fun (c : constructor) -> scan_type c.payload) ctors
  in
  List.iter scan_msg cm.msgs;
  (match cm.service with
   | Some service ->
     List.iter (fun (rpc : rpc) ->
       let check ref_ =
         match String.index_opt ref_ '.' with
         | Some i ->
           let m = String.sub ref_ 0 i in
           if m <> cm.name then Hashtbl.replace modules m true
         | None -> ()
       in
       check rpc.request_msg;
       check rpc.response_msg
     ) service.rpcs
   | None -> ());
  let result = Hashtbl.fold (fun k _ acc -> k :: acc) modules [] in
  List.sort String.compare result

(* ── Generate complete Go module ─────────────────────────────────── *)

let generate_go_module ~go_module_path cm =
  let buf = Buffer.create 2048 in
  let p fmt = Printf.bprintf buf fmt in
  let local_module = cm.name in
  let pkg = go_pkg_name cm.name in

  p "package %s\n\n" pkg;

  (* Imports *)
  let ext_modules = go_imports cm in
  let has_service = cm.service <> None in
  if has_service || ext_modules <> [] then begin
    p "import (\n";
    if has_service then begin
      p "\t\"bytes\"\n";
      p "\t\"encoding/json\"\n";
      p "\t\"fmt\"\n";
      p "\t\"io\"\n";
      p "\t\"net/http\"\n";
    end;
    List.iter (fun m ->
      p "\t\"%s/%s\"\n" go_module_path (go_pkg_name m)
    ) ext_modules;
    p ")\n\n"
  end;

  (* Messages *)
  List.iter (fun msg ->
    p "%s\n" (generate_go_msg ~local_module msg)
  ) cm.msgs;

  (* Service *)
  (match cm.service with
   | Some service ->
     p "%s\n" (generate_go_interface ~local_module service cm.msgs);
     p "%s" (generate_go_calls ~local_module cm service cm.msgs)
   | None -> ());

  (* rpc helper if service *)
  if has_service then begin
    p "func rpc(baseURL, service, method string, payload []any) (any, error) {\n";
    p "\tbody, err := json.Marshal(payload)\n";
    p "\tif err != nil {\n";
    p "\t\treturn nil, fmt.Errorf(\"marshal: %%w\", err)\n";
    p "\t}\n";
    p "\tresp, err := http.Post(baseURL+\"/rpc/\"+service+\"/\"+method, \"application/json\", bytes.NewReader(body))\n";
    p "\tif err != nil {\n";
    p "\t\treturn nil, fmt.Errorf(\"request: %%w\", err)\n";
    p "\t}\n";
    p "\tdefer resp.Body.Close()\n";
    p "\trespBody, err := io.ReadAll(resp.Body)\n";
    p "\tif err != nil {\n";
    p "\t\treturn nil, fmt.Errorf(\"read: %%w\", err)\n";
    p "\t}\n";
    p "\tif resp.StatusCode != 200 {\n";
    p "\t\treturn nil, fmt.Errorf(\"RPC %%s.%%s: %%d %%s\", service, method, resp.StatusCode, string(respBody))\n";
    p "\t}\n";
    p "\tvar result any\n";
    p "\tif err := json.Unmarshal(respBody, &result); err != nil {\n";
    p "\t\treturn nil, fmt.Errorf(\"unmarshal: %%w\", err)\n";
    p "\t}\n";
    p "\treturn result, nil\n";
    p "}\n"
  end;

  Buffer.contents buf

(* ══════════════════════════════════════════════════════════════════ *)
(* Dart codegen                                                      *)
(* ══════════════════════════════════════════════════════════════════ *)

(* ── Dart naming helpers ─────────────────────────────────────────── *)

let dart_keywords =
  [ "abstract"; "as"; "assert"; "async"; "await"; "break"; "case"; "catch";
    "class"; "const"; "continue"; "covariant"; "default"; "deferred"; "do";
    "dynamic"; "else"; "enum"; "export"; "extends"; "extension"; "external";
    "factory"; "false"; "final"; "finally"; "for"; "get"; "hide"; "if";
    "implements"; "import"; "in"; "interface"; "is"; "late"; "library";
    "mixin"; "new"; "null"; "on"; "operator"; "part"; "required"; "rethrow";
    "return"; "sealed"; "set"; "show"; "static"; "super"; "switch"; "sync";
    "this"; "throw"; "true"; "try"; "typedef"; "var"; "void"; "while";
    "with"; "yield" ]

let dart_camel_case name =
  let esc n = if List.mem n dart_keywords then "$" ^ n else n in
  if String.contains name '_' then
    let parts = String.split_on_char '_' name in
    match parts with
    | [] -> ""
    | first :: rest ->
      esc (first ^ String.concat ""
        (List.map (fun w ->
          if w = "" then "" else String.capitalize_ascii w) rest))
  else esc name

let dart_kebab_case name =
  let buf = Buffer.create (String.length name + 4) in
  String.iteri (fun i c ->
    if c >= 'A' && c <= 'Z' then begin
      if i > 0 then Buffer.add_char buf '-';
      Buffer.add_char buf (Char.lowercase_ascii c)
    end else if c = '_' then
      Buffer.add_char buf '-'
    else
      Buffer.add_char buf c
  ) name;
  Buffer.contents buf

(* ── Dart type string ────────────────────────────────────────────── *)

let rec dart_type ~local_module = function
  | Prim String -> "String"
  | Prim Int -> "int"
  | Prim Float -> "double"
  | Prim Bool -> "bool"
  | Prim Void -> "void"
  | Prim Date -> "String"
  | Prim Record -> "Map<String, dynamic>"
  | Prim Ctx -> "RpcCtx"
  | Custom { module_name; msg_name } ->
    if module_name = local_module then msg_name
    else module_name ^ "." ^ msg_name
  | List inner ->
    "List<" ^ dart_type ~local_module inner ^ ">"
  | Optional inner ->
    dart_type ~local_module inner ^ "?"

(* ── Dart toWire expression ──────────────────────────────────────── *)

let rec dart_to_wire ~local_module expr = function
  | Prim (String | Int | Float | Bool | Date | Record | Void) -> expr
  | Prim Ctx -> Printf.sprintf "%s.toWire()" expr
  | Custom _ -> Printf.sprintf "%s.toWire()" expr
  | List inner ->
    let needs_map = match inner with
      | Prim (String | Int | Float | Bool | Date) -> false
      | _ -> true
    in
    if needs_map then
      let item = dart_to_wire ~local_module "e" inner in
      Printf.sprintf "%s.map((e) => %s).toList()" expr item
    else expr
  | Optional inner ->
    let enc = dart_to_wire ~local_module (expr ^ "!") inner in
    if enc = expr ^ "!" then expr
    else Printf.sprintf "%s != null ? %s : null" expr enc

(* ── Dart fromWire expression ────────────────────────────────────── *)

let rec dart_from_wire ~local_module expr = function
  | Prim String -> Printf.sprintf "(%s as String)" expr
  | Prim Int -> Printf.sprintf "(%s as int)" expr
  | Prim Float -> Printf.sprintf "(%s as double)" expr
  | Prim Bool -> Printf.sprintf "(%s as bool)" expr
  | Prim Void -> "()"
  | Prim Date -> Printf.sprintf "(%s as String)" expr
  | Prim Record -> Printf.sprintf "Map<String, dynamic>.from(%s as Map)" expr
  | Prim Ctx -> Printf.sprintf "RpcCtx.fromWire(%s)" expr
  | Custom { module_name; msg_name } ->
    if module_name = local_module then
      Printf.sprintf "%s.fromWire(%s)" msg_name expr
    else
      Printf.sprintf "%s.%s.fromWire(%s)" module_name msg_name expr
  | List inner ->
    (match inner with
     | Prim String | Prim Date ->
       Printf.sprintf "(%s as List).cast<String>()" expr
     | Prim Int ->
       Printf.sprintf "(%s as List).cast<int>()" expr
     | Prim Bool ->
       Printf.sprintf "(%s as List).cast<bool>()" expr
     | Prim Float ->
       Printf.sprintf "(%s as List).cast<double>()" expr
     | _ ->
       let item = dart_from_wire ~local_module "e" inner in
       Printf.sprintf "(%s as List).map((e) => %s).toList()" expr item)
  | Optional inner ->
    let dec = dart_from_wire ~local_module expr inner in
    Printf.sprintf "%s == null ? null : %s" expr dec

(* ── Generate Dart struct class ──────────────────────────────────── *)

let generate_dart_struct ~local_module msg_name props =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in

  (* class *)
  p "class %s {\n" msg_name;
  List.iter (fun (prop : property) ->
    let ty = dart_type ~local_module prop.type_info in
    let nullable = if prop.optional then "?" else "" in
    p "  final %s%s %s;\n" ty nullable (dart_camel_case prop.name)
  ) props;
  p "\n";

  (* constructor *)
  p "  const %s({\n" msg_name;
  List.iter (fun (prop : property) ->
    if prop.optional then
      p "    this.%s,\n" (dart_camel_case prop.name)
    else
      p "    required this.%s,\n" (dart_camel_case prop.name)
  ) props;
  p "  });\n\n";

  (* fromWire factory *)
  p "  factory %s.fromWire(dynamic data) {\n" msg_name;
  p "    final arr = data as List;\n";
  p "    return %s(\n" msg_name;
  List.iteri (fun i (prop : property) ->
    let access = Printf.sprintf "arr[%d]" i in
    let expr =
      if prop.optional then
        dart_from_wire ~local_module access (Optional prop.type_info)
      else
        dart_from_wire ~local_module access prop.type_info
    in
    p "      %s: %s,\n" (dart_camel_case prop.name) expr
  ) props;
  p "    );\n";
  p "  }\n\n";

  (* toWire method *)
  p "  List<dynamic> toWire() {\n";
  p "    return [\n";
  List.iter (fun (prop : property) ->
    let field = dart_camel_case prop.name in
    let expr =
      if prop.optional then
        dart_to_wire ~local_module field (Optional prop.type_info)
      else
        dart_to_wire ~local_module field prop.type_info
    in
    p "      %s,\n" expr
  ) props;
  p "    ];\n";
  p "  }\n";
  p "}\n";
  Buffer.contents buf

(* ── Generate Dart variant (sealed class) ────────────────────────── *)

let generate_dart_variant ~local_module msg_name ctors =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in

  (* sealed base class *)
  p "sealed class %s {\n" msg_name;
  p "  const %s();\n\n" msg_name;

  (* fromWire factory *)
  p "  factory %s.fromWire(dynamic data) {\n" msg_name;
  p "    final arr = data as List;\n";
  p "    final tag = arr[0] as String;\n";
  p "    final payload = arr[1];\n";
  p "    switch (tag) {\n";
  List.iter (fun (ctor : constructor) ->
    match ctor.payload with
    | Prim Void ->
      p "      case '%s': return %s$%s();\n" ctor.name msg_name ctor.name
    | ti ->
      let expr = dart_from_wire ~local_module "payload" ti in
      p "      case '%s': return %s$%s(%s);\n" ctor.name msg_name ctor.name expr
  ) ctors;
  p "      default: throw Exception('Unknown variant: $tag');\n";
  p "    }\n";
  p "  }\n\n";

  (* toWire method *)
  p "  List<dynamic> toWire() {\n";
  p "    return switch (this) {\n";
  List.iter (fun (ctor : constructor) ->
    match ctor.payload with
    | Prim Void ->
      p "      %s$%s() => ['%s', null],\n" msg_name ctor.name ctor.name
    | ti ->
      let expr = dart_to_wire ~local_module "d" ti in
      p "      %s$%s(data: final d) => ['%s', %s],\n" msg_name ctor.name ctor.name expr
  ) ctors;
  p "    };\n";
  p "  }\n";
  p "}\n\n";

  (* Subclasses *)
  List.iter (fun (ctor : constructor) ->
    match ctor.payload with
    | Prim Void ->
      p "class %s$%s extends %s {\n" msg_name ctor.name msg_name;
      p "  const %s$%s();\n" msg_name ctor.name;
      p "}\n\n"
    | ti ->
      let ty = dart_type ~local_module ti in
      p "class %s$%s extends %s {\n" msg_name ctor.name msg_name;
      p "  final %s data;\n" ty;
      p "  const %s$%s(this.data);\n" msg_name ctor.name;
      p "}\n\n"
  ) ctors;
  Buffer.contents buf

(* ── Generate Dart msg ───────────────────────────────────────────── *)

let generate_dart_msg ~local_module (msg : msg) =
  match msg.kind with
  | Struct props -> generate_dart_struct ~local_module msg.name props
  | Variant ctors -> generate_dart_variant ~local_module msg.name ctors

(* ── Dart proxy client ───────────────────────────────────────────── *)

let generate_dart_proxy ~local_module cm service msgs =
  let buf = Buffer.create 512 in
  let p fmt = Printf.bprintf buf fmt in
  let resolve ref_ =
    if List.exists (fun (m : msg) -> m.name = ref_) msgs then ref_
    else
      match String.index_opt ref_ '.' with
      | Some i ->
        let m = String.sub ref_ 0 i in
        let n = String.sub ref_ (i + 1) (String.length ref_ - i - 1) in
        if m = local_module then n
        else m ^ "." ^ n
      | None -> ref_
  in
  p "class %sClient {\n" cm.name;
  p "  final http.Client _httpClient;\n";
  p "  final String _baseUrl;\n\n";
  p "  %sClient(this._httpClient, String baseUrl)\n" cm.name;
  p "      : _baseUrl = '$baseUrl/%s';\n" (dart_kebab_case cm.name);
  List.iter (fun (rpc : rpc) ->
    let req_type = resolve rpc.request_msg in
    let resp_type = resolve rpc.response_msg in
    p "\n  Future<%s> %s(%s request) async {\n" resp_type (dart_camel_case rpc.name) req_type;
    p "    final response = await _httpClient.post(\n";
    p "      Uri.parse('$_baseUrl/rpc/%s/%s'),\n" cm.name rpc.name;
    p "      headers: {\n";
    p "        'Content-Type': 'application/json',\n";
    p "        'Accept': 'application/json',\n";
    p "      },\n";
    p "      body: jsonEncode(request.toWire()),\n";
    p "    );\n";
    p "    if (response.statusCode != 200) {\n";
    p "      throw Exception('HTTP ${response.statusCode}: ${response.body}');\n";
    p "    }\n";
    p "    final decoded = jsonDecode(response.body);\n";
    p "    return %s.fromWire(decoded);\n" resp_type;
    p "  }\n"
  ) service.rpcs;
  p "}\n";
  Buffer.contents buf

(* ── Dart cross-module imports ───────────────────────────────────── *)

let dart_imports cm =
  (* Reuse the same scan logic as TS *)
  let modules = Hashtbl.create 4 in
  let rec scan_type = function
    | Prim _ -> ()
    | Custom { module_name; _ } ->
      if module_name <> cm.name then
        Hashtbl.replace modules module_name true
    | List inner -> scan_type inner
    | Optional inner -> scan_type inner
  in
  let scan_msg (msg : msg) =
    match msg.kind with
    | Struct props ->
      List.iter (fun (p : property) -> scan_type p.type_info) props
    | Variant ctors ->
      List.iter (fun (c : constructor) -> scan_type c.payload) ctors
  in
  List.iter scan_msg cm.msgs;
  (match cm.service with
   | Some service ->
     List.iter (fun (rpc : rpc) ->
       let check ref_ =
         match String.index_opt ref_ '.' with
         | Some i ->
           let m = String.sub ref_ 0 i in
           if m <> cm.name then Hashtbl.replace modules m true
         | None -> ()
       in
       check rpc.request_msg;
       check rpc.response_msg
     ) service.rpcs
   | None -> ());
  let result = Hashtbl.fold (fun k _ acc -> k :: acc) modules [] in
  List.sort String.compare result

(* ── Generate complete Dart module ───────────────────────────────── *)

let generate_dart_module cm =
  let buf = Buffer.create 2048 in
  let p fmt = Printf.bprintf buf fmt in
  let local_module = cm.name in

  (* Imports *)
  let imports = dart_imports cm in
  List.iter (fun m ->
    p "import '%s.dart' as %s;\n" m m
  ) imports;
  if cm.service <> None then begin
    p "import 'dart:convert';\n";
    p "import 'package:http/http.dart' as http;\n"
  end;
  if imports <> [] || cm.service <> None then p "\n";

  (* Messages *)
  List.iter (fun msg ->
    p "%s\n" (generate_dart_msg ~local_module msg)
  ) cm.msgs;

  (* Proxy client *)
  (match cm.service with
   | Some service ->
     p "%s" (generate_dart_proxy ~local_module cm service cm.msgs)
   | None -> ());

  Buffer.contents buf
