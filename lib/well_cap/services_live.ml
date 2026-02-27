open Cap_helpers

type model = {
  services : Yojson.Safe.t;
  health : (string * string) list;
  open_menu : string;
  call_service : string;
  call_rpc : string;
  call_payload : string;
  call_result : string;
}

type msg =
  | ToggleMenu of string
  | SelectRPC of string * string
  | CallRPC of string

let persistence = Well.LiveView.Ephemeral

(* ── RPC metadata helpers ─────────────────────────────────────────── *)

type field_meta = { fname : string; ftype : string; foptional : bool }

let extract_fields key info =
  match info with
  | `Assoc fs ->
      (match List.assoc_opt key fs with
       | Some (`List ps) ->
           List.filter_map (fun p ->
             match p with
             | `Assoc pf ->
                 let name = match List.assoc_opt "name" pf with
                   | Some (`String s) -> s | _ -> "" in
                 let typ = match List.assoc_opt "type" pf with
                   | Some (`String s) -> s | _ -> "string" in
                 let optional = match List.assoc_opt "optional" pf with
                   | Some (`Bool b) -> b | _ -> false in
                 if name = "" then None
                 else Some { fname = name; ftype = typ; foptional = optional }
             | _ -> None
           ) ps
       | _ -> [])
  | _ -> []

let get_rpc_info services svc_name rpc_name =
  match services with
  | `Assoc svcs ->
      (match List.assoc_opt svc_name svcs with
       | Some (`Assoc rpcs) ->
           (match List.assoc_opt rpc_name rpcs with
            | Some info -> Some info
            | None -> None)
       | _ -> None)
  | _ -> None

(* ── Table schema lookup for nested type resolution ───────────────── *)

(* Try to find a registered table matching a type name.
   "Task.t" → look for table "tasks" (lowercase plural)
   "task" → look for table "tasks"
   Also tries exact match on type base name. *)
let find_table_schema type_name =
  let base =
    (* "Task.t" → "task", "Task.t list" → "task" *)
    let s = String.lowercase_ascii type_name in
    let s = if String.length s > 2 && String.sub s (String.length s - 2) 2 = ".t"
            then String.sub s 0 (String.length s - 2) else s in
    let s = let parts = String.split_on_char ' ' s in List.hd parts in
    s
  in
  let tables = !(Well.Db.registered_tables) in
  (* Try: "task" → "tasks", or exact match "tasks" *)
  let candidates = [base ^ "s"; base] in
  List.find_map (fun candidate ->
    List.find_opt (fun (t : Well.Db.table) ->
      String.lowercase_ascii t.name = candidate
    ) tables
  ) candidates

let table_to_fields (tbl : Well.Db.table) =
  List.map (fun (c : Well.Db.column) ->
    { fname = c.cname;
      ftype = (match String.uppercase_ascii c.sqlite_type with
        | "INTEGER" -> "int" | "REAL" -> "float" | "TEXT" -> "string"
        | _ -> "string");
      foptional = c.nullable }
  ) tbl.columns

let is_list_type t =
  let s = String.lowercase_ascii t in
  let has_suffix sfx =
    let sl = String.length sfx in
    String.length s >= sl && String.sub s (String.length s - sl) sl = sfx
  in
  has_suffix " list" || has_suffix " array"

(* ── Recursive wire ↔ named conversion ────────────────────────────── *)

(* Named JSON → wire array, recursing into nested record types *)
let rec named_to_wire fields (named : Yojson.Safe.t) =
  match named with
  | `Assoc kvs ->
      `List (List.map (fun f ->
        let v = match List.assoc_opt f.fname kvs with
          | Some v -> v | None -> `Null in
        if is_list_type f.ftype then
          match v, find_table_schema f.ftype with
          | `List items, Some tbl ->
              `List (List.map (named_to_wire (table_to_fields tbl)) items)
          | _ -> v
        else
          match find_table_schema f.ftype with
          | Some tbl -> named_to_wire (table_to_fields tbl) v
          | None -> v
      ) fields)
  | other -> other

(* Wire array → named JSON, recursing into nested record types *)
let rec wire_to_named fields (wire : Yojson.Safe.t) =
  match wire with
  | `List arr ->
      let pairs = List.mapi (fun i v ->
        let field =
          if i < List.length fields then Some (List.nth fields i)
          else None
        in
        let name = match field with
          | Some f -> f.fname
          | None -> Printf.sprintf "_%d" i
        in
        let converted = match field with
          | Some f when is_list_type f.ftype ->
              (match v, find_table_schema f.ftype with
               | `List items, Some tbl ->
                   `List (List.map (wire_to_named (table_to_fields tbl)) items)
               | _ -> v)
          | Some f ->
              (match find_table_schema f.ftype with
               | Some tbl -> wire_to_named (table_to_fields tbl) v
               | None -> v)
          | None -> v
        in
        (name, converted)
      ) arr in
      `Assoc pairs
  | other -> other

(* Generate a named JSON stub from param metadata *)
let stub_payload_named fields =
  let pairs = List.map (fun f ->
    let v =
      if f.foptional then `Null
      else match String.lowercase_ascii f.ftype with
        | "int" | "integer" -> `Int 0
        | "float" | "real" -> `Float 0.0
        | "bool" | "boolean" -> `Bool false
        | _ -> `String ""
    in
    (f.fname, v)
  ) fields in
  if pairs = [] then "{}"
  else Yojson.Safe.pretty_to_string (`Assoc pairs)

let get_rpc_names services svc_name =
  match services with
  | `Assoc svcs ->
      (match List.assoc_opt svc_name svcs with
       | Some (`Assoc rpcs) -> List.map fst rpcs
       | _ -> [])
  | _ -> []

(* ── LiveView ─────────────────────────────────────────────────────── *)

let init _req _props =
  ({ services = Well.Service.describe_services ();
     health = Well.Service.health ();
     open_menu = "";
     call_service = ""; call_rpc = "";
     call_payload = "{}"; call_result = "" }, [])

let update _req model msg =
  match msg with
  | ToggleMenu svc ->
      if model.open_menu = svc then { model with open_menu = "" }
      else { model with open_menu = svc }
  | SelectRPC (svc, rpc) ->
      let payload =
        match get_rpc_info model.services svc rpc with
        | Some info -> stub_payload_named (extract_fields "params" info)
        | None -> "{}"
      in
      { model with open_menu = ""; call_service = svc; call_rpc = rpc;
        call_payload = payload; call_result = "" }
  | CallRPC payload ->
      if model.call_service = "" || model.call_rpc = "" then
        { model with call_result = "Select a service and RPC first" }
      else begin
        try
          let payload_json = Yojson.Safe.from_string
            (if payload = "" then "{}" else payload) in
          let rpc_info = get_rpc_info model.services
            model.call_service model.call_rpc in
          let wire_payload = match rpc_info with
            | Some info ->
                named_to_wire (extract_fields "params" info) payload_json
            | None -> payload_json
          in
          let wire_result = Well.Service.dispatch_by_name
            model.call_service model.call_rpc `Null wire_payload in
          let named_result = match rpc_info with
            | Some info ->
                wire_to_named (extract_fields "returns" info) wire_result
            | None -> wire_result
          in
          { model with
            call_result = Yojson.Safe.pretty_to_string named_result;
            call_payload = payload }
        with exn ->
          { model with call_result = "Error: " ^ Printexc.to_string exn;
            call_payload = payload }
      end

let handle_params _req model = model
let temporary_assigns model = model

let view model =
  let health_map = model.health in
  (* Navbar with dropdown menus *)
  let navbar_html =
    match model.services with
    | `Assoc services when services <> [] ->
        String.concat ""
          (List.map (fun (name, _) ->
            let st = match List.assoc_opt name health_map with
              | Some s -> s | None -> "unknown" in
            let dot = if st = "running" then status_dot "green"
                      else status_dot "red" in
            let is_open = model.open_menu = name in
            let is_active = model.call_service = name in
            let dropdown =
              if not is_open then ""
              else
                let rpcs = get_rpc_names model.services name in
                let items = String.concat ""
                  (List.map (fun rpc ->
                    let selected = model.call_service = name
                      && model.call_rpc = rpc in
                    Printf.sprintf
                      {|<a class="svc-dropdown-item%s" data-lv-click="%s">%s</a>|}
                      (if selected then " active" else "")
                      (esc (Printf.sprintf "[\"SelectRPC\",\"%s\",\"%s\"]" name rpc))
                      (esc rpc)
                  ) rpcs)
                in
                Printf.sprintf
                  {|<div class="svc-dropdown">%s</div>|} items
            in
            Printf.sprintf
              {|<div class="svc-nav-item" style="position:relative">
                <a class="svc-nav-link%s%s" data-lv-click="%s">%s%s &#9662;</a>
                %s
              </div>|}
              (if is_active then " active" else "")
              (if is_open then " open" else "")
              (esc (Printf.sprintf "[\"ToggleMenu\",\"%s\"]" name))
              dot (esc name) dropdown
          ) services)
    | _ -> {|<span style="color:var(--text-muted)">No services registered</span>|}
  in
  (* Selected method label *)
  let method_label =
    if model.call_service = "" || model.call_rpc = "" then ""
    else
      let params_hint =
        match get_rpc_info model.services model.call_service model.call_rpc with
        | Some info ->
            let fields = extract_fields "params" info in
            if fields = [] then "()"
            else
              let parts = List.map (fun f ->
                let opt = if f.foptional then "?" else "" in
                f.fname ^ opt ^ ": " ^ f.ftype
              ) fields in
              "(" ^ String.concat ", " parts ^ ")"
        | None -> ""
      in
      Printf.sprintf
        {|<div style="font-family:var(--mono);font-size:13px;color:var(--accent);margin:12px 0 4px">%s.%s <span style="color:var(--text-muted)">%s</span></div>|}
        (esc model.call_service) (esc model.call_rpc) (esc params_hint)
  in
  (* Request editor *)
  let request_html =
    if model.call_service = "" || model.call_rpc = "" then
      {|<div class="empty-state" style="margin-top:16px"><p>Select a service and method above</p></div>|}
    else
      Printf.sprintf
        {|<div style="margin-top:8px">
          %s
          <form data-lv-submit="call_rpc">
            <div class="sql-editor">
              <textarea name="payload" class="input" rows="5">%s</textarea>
            </div>
            <button type="submit" class="btn btn-accent btn-sm" style="margin-top:8px">Call</button>
          </form>
        </div>|}
        method_label
        (esc model.call_payload)
  in
  (* Response *)
  let response_html =
    if model.call_result = "" then ""
    else
      Printf.sprintf
        {|<div style="margin-top:16px">
          <div style="font-size:11px;text-transform:uppercase;letter-spacing:0.05em;color:var(--text-muted);margin-bottom:6px">Response</div>
          <pre class="code-block" style="white-space:pre;overflow-x:auto;margin:0">%s</pre>
        </div>|}
        (esc model.call_result)
  in
  `Html (Printf.sprintf
    {|<style>
      .svc-navbar { display:flex; gap:0; border-bottom:1px solid var(--border); margin-bottom:0 }
      .svc-nav-item { position:relative }
      .svc-nav-link { display:inline-flex; align-items:center; gap:6px; padding:8px 14px;
        cursor:pointer; font-weight:600; font-size:13px; color:var(--text-secondary);
        border-bottom:2px solid transparent; transition:color .15s }
      .svc-nav-link:hover, .svc-nav-link.open { color:var(--text-primary) }
      .svc-nav-link.active { color:var(--accent); border-bottom-color:var(--accent) }
      .svc-dropdown { position:absolute; top:100%%; left:0; z-index:10; min-width:180px;
        background:var(--bg-card); border:1px solid var(--border); border-radius:6px;
        box-shadow:0 4px 12px rgba(0,0,0,.5); padding:4px 0; margin-top:4px }
      .svc-dropdown-item { display:block; padding:6px 14px; font-size:13px; cursor:pointer;
        font-family:var(--mono); color:var(--text-primary) }
      .svc-dropdown-item:hover { background:var(--bg-card-hover) }
      .svc-dropdown-item.active { color:var(--accent) }
    </style>
    <div>
      <div class="card" style="overflow:visible">
        <div data-lv="svc-nav" class="svc-navbar">%s</div>
        <div data-lv="svc-call">%s</div>
        <div data-lv="svc-result">%s</div>
      </div>
    </div>|}
    navbar_html request_html response_html)

let model_to_yojson _m = `Null
let model_of_yojson _j = Error "ephemeral"

let msg_of_yojson j =
  match j with
  | `List [`String "ToggleMenu"; `String svc] -> Ok (ToggleMenu svc)
  | `List [`String "SelectRPC"; `String svc; `String rpc] ->
      Ok (SelectRPC (svc, rpc))
  | `List [`String "call_rpc"; `Assoc kvs] ->
      let p = match List.assoc_opt "payload" kvs with
        | Some (`String s) -> s | _ -> "{}" in
      Ok (CallRPC p)
  | _ -> Error "unknown msg"
