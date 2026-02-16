(* doc_parser — Extract documentation items from OCaml/MLX source files *)

type route_method = Get | Post | Put | Delete

type item_kind =
  | Function
  | Type
  | Module
  | Route of route_method * string  (* method, path *)
  | LiveView of string              (* path *)
  | Value

type doc_item = {
  name : string;
  kind : item_kind;
  doc : string;
  signature : string;
  line : int;
}

type module_doc = {
  name : string;
  path : string;
  doc : string;
  items : doc_item list;
}

(* Strip (** and *) delimiters from a doc comment block *)
let strip_doc_delimiters lines =
  match lines with
  | [] -> ""
  | _ ->
    let text = String.concat "\n" lines in
    (* Remove (** prefix *)
    let text =
      let len = String.length text in
      if len >= 3 && String.sub text 0 3 = "(**" then
        String.sub text 3 (len - 3)
      else text
    in
    (* Remove trailing *) *)
    let text =
      let len = String.length text in
      if len >= 2 && String.sub text (len - 2) 2 = "*)" then
        String.sub text 0 (len - 2)
      else text
    in
    String.trim text

(* Trim leading whitespace and optional * from doc comment lines *)
let trim_doc_line s =
  let s = String.trim s in
  if String.length s > 0 && s.[0] = '*' then
    String.trim (String.sub s 1 (String.length s - 1))
  else s

let extract_string_literal s start =
  (* Find opening quote at or after start *)
  let rec find_quote i =
    if i >= String.length s then None
    else if s.[i] = '"' then
      let rec find_end j =
        if j >= String.length s then None
        else if s.[j] = '\\' then find_end (j + 2)
        else if s.[j] = '"' then Some (String.sub s (i + 1) (j - i - 1))
        else find_end (j + 1)
      in
      find_end (i + 1)
    else find_quote (i + 1)
  in
  find_quote start

let route_method_of_string = function
  | "get" -> Some Get
  | "post" -> Some Post
  | "put" -> Some Put
  | "delete" -> Some Delete
  | _ -> None

let string_of_route_method = function
  | Get -> "GET"
  | Post -> "POST"
  | Put -> "PUT"
  | Delete -> "DELETE"

(* Check if line registers a route: Well.get "/path" ... *)
let parse_route line =
  let trimmed = String.trim line in
  (* Match: Well.get/post/put/delete "path" or Well.get ~middleware:... "path" *)
  let try_method meth_str =
    let prefix = "Well." ^ meth_str in
    let plen = String.length prefix in
    if String.length trimmed >= plen
       && String.sub trimmed 0 plen = prefix
       && (String.length trimmed = plen || trimmed.[plen] = ' ' || trimmed.[plen] = '~')
    then
      match route_method_of_string meth_str with
      | Some meth ->
        (match extract_string_literal trimmed plen with
         | Some path -> Some (meth, path)
         | None -> None)
      | None -> None
    else None
  in
  match try_method "get" with
  | Some _ as r -> r
  | None ->
    match try_method "post" with
    | Some _ as r -> r
    | None ->
      match try_method "put" with
      | Some _ as r -> r
      | None -> try_method "delete"

(* Check if line registers a LiveView: Well.live "/path" ... *)
let parse_liveview line =
  let trimmed = String.trim line in
  let prefix = "Well.live " in
  let plen = String.length prefix in
  if String.length trimmed >= plen && String.sub trimmed 0 plen = prefix then
    extract_string_literal trimmed plen
  else None

(* Check for [@@deriving table ~name:"..."] *)
let parse_deriving_table line =
  let trimmed = String.trim line in
  try
    let idx = Str.search_forward (Str.regexp {|deriving table|}) trimmed 0 in
    (* Look for ~name:"..." *)
    (try
       let _ = Str.search_forward (Str.regexp {|~name:"|}) trimmed idx in
       extract_string_literal trimmed idx
     with Not_found -> None)
  with Not_found -> None

(* Check for let binding: let name ... = *)
let parse_let line =
  let trimmed = String.trim line in
  if String.length trimmed > 4
     && String.sub trimmed 0 4 = "let "
     && (String.length trimmed < 5 || trimmed.[4] <> '(')
  then begin
    let rest = String.trim (String.sub trimmed 4 (String.length trimmed - 4)) in
    (* Skip let%query, let%... *)
    if String.length rest > 0 && rest.[0] = '%' then None
    else begin
      (* Extract the name (first word) *)
      let name_end =
        let rec find i =
          if i >= String.length rest then i
          else match rest.[i] with
            | ' ' | '\t' | ':' | '=' | '(' -> i
            | _ -> find (i + 1)
        in
        find 0
      in
      if name_end > 0 then begin
        let name = String.sub rest 0 name_end in
        (* Skip _ prefixed private names and operators *)
        if String.length name > 0 && name.[0] <> '_' && name.[0] <> '(' then
          Some name
        else None
      end else None
    end
  end else None

(* Check for type declaration: type name = ... *)
let parse_type line =
  let trimmed = String.trim line in
  if String.length trimmed > 5
     && (String.sub trimmed 0 5 = "type "
         || (String.length trimmed > 8 && String.sub trimmed 0 8 = "and type"))
  then begin
    let rest =
      if String.sub trimmed 0 4 = "type" then
        String.trim (String.sub trimmed 5 (String.length trimmed - 5))
      else
        String.trim (String.sub trimmed 8 (String.length trimmed - 8))
    in
    let name_end =
      let rec find i =
        if i >= String.length rest then i
        else match rest.[i] with
          | ' ' | '\t' | '=' | '{' | '(' -> i
          | _ -> find (i + 1)
      in
      find 0
    in
    if name_end > 0 then
      Some (String.sub rest 0 name_end)
    else None
  end else None

(* Check for module declaration *)
let parse_module line =
  let trimmed = String.trim line in
  if String.length trimmed > 7 && String.sub trimmed 0 7 = "module " then begin
    let rest = String.trim (String.sub trimmed 7 (String.length trimmed - 7)) in
    (* Skip "type" — module type declarations *)
    if String.length rest > 5 && String.sub rest 0 5 = "type " then None
    else begin
      let name_end =
        let rec find i =
          if i >= String.length rest then i
          else match rest.[i] with
            | ' ' | '\t' | '=' | ':' | '(' -> i
            | _ -> find (i + 1)
        in
        find 0
      in
      if name_end > 0 then
        Some (String.sub rest 0 name_end)
      else None
    end
  end else None

(* Extract signature for a let binding — everything from 'let' to '=' *)
let extract_let_signature line =
  let trimmed = String.trim line in
  match String.index_opt trimmed '=' with
  | Some idx -> String.trim (String.sub trimmed 0 idx)
  | None -> trimmed

(* Extract type signature — the full type ... = line *)
let extract_type_signature lines start_line =
  (* Collect lines until we see the first '=' or '{' *)
  let buf = Buffer.create 128 in
  let rec collect i =
    if i >= Array.length lines then ()
    else begin
      let line = lines.(i) in
      Buffer.add_string buf (String.trim line);
      if String.contains line '=' || String.contains line '{' then ()
      else begin
        Buffer.add_char buf ' ';
        collect (i + 1)
      end
    end
  in
  collect start_line;
  let s = Buffer.contents buf in
  match String.index_opt s '=' with
  | Some idx -> String.trim (String.sub s 0 idx)
  | None -> String.trim s

(* Parse a single file *)
let parse_file path =
  let ic = open_in path in
  let lines = ref [] in
  (try while true do
     lines := input_line ic :: !lines
   done with End_of_file -> ());
  close_in ic;
  let lines_list = List.rev !lines in
  let lines_arr = Array.of_list lines_list in
  let n = Array.length lines_arr in

  let items = ref [] in
  let module_doc_text = ref "" in
  let pending_doc = ref [] in
  let in_doc_comment = ref false in
  let found_first_decl = ref false in

  for i = 0 to n - 1 do
    let line = lines_arr.(i) in
    let trimmed = String.trim line in

    if !in_doc_comment then begin
      (* Inside a multi-line doc comment *)
      pending_doc := trimmed :: !pending_doc;
      if String.length trimmed >= 2
         && String.sub trimmed (String.length trimmed - 2) 2 = "*)"
      then
        in_doc_comment := false
    end
    else if String.length trimmed >= 3 && String.sub trimmed 0 3 = "(**" then begin
      (* Start of doc comment *)
      pending_doc := [ trimmed ];
      (* Check if single-line doc comment *)
      if String.length trimmed >= 5
         && String.sub trimmed (String.length trimmed - 2) 2 = "*)"
      then
        in_doc_comment := false
      else
        in_doc_comment := true
    end
    else begin
      (* Not a doc comment line — check for declarations *)
      let doc_text =
        if !pending_doc <> [] then begin
          let raw = List.rev !pending_doc in
          let text = strip_doc_delimiters raw in
          (* Trim each internal line *)
          let lines_split = String.split_on_char '\n' text in
          let cleaned = List.map trim_doc_line lines_split in
          let result = String.concat "\n" cleaned in
          String.trim result
        end else ""
      in
      let consumed = ref false in

      (* Check for route *)
      (match parse_route trimmed with
       | Some (meth, path_str) ->
         found_first_decl := true;
         (* Try to extract handler name from "fun req ->" or "fun _req ->" *)
         let handler_name =
           Printf.sprintf "%s %s" (string_of_route_method meth) path_str
         in
         items := {
           name = handler_name;
           kind = Route (meth, path_str);
           doc = doc_text;
           signature = trimmed;
           line = i + 1;
         } :: !items;
         consumed := true
       | None -> ());

      (* Check for LiveView *)
      if not !consumed then
        (match parse_liveview trimmed with
         | Some path_str ->
           found_first_decl := true;
           items := {
             name = path_str;
             kind = LiveView path_str;
             doc = doc_text;
             signature = trimmed;
             line = i + 1;
           } :: !items;
           consumed := true
         | None -> ());

      (* Check for type *)
      if not !consumed then
        (match parse_type trimmed with
         | Some name ->
           found_first_decl := true;
           let sig_text = extract_type_signature lines_arr i in
           (* Check for [@@deriving table] on this or next few lines *)
           let is_model = ref false in
           let table_name = ref "" in
           for j = i to min (i + 20) (n - 1) do
             match parse_deriving_table lines_arr.(j) with
             | Some tbl ->
               is_model := true;
               table_name := tbl
             | None -> ()
           done;
           let doc_text =
             if !is_model && doc_text = "" then
               Printf.sprintf "Model (table: %s)" !table_name
             else if !is_model then
               Printf.sprintf "%s\n\nModel (table: %s)" doc_text !table_name
             else doc_text
           in
           items := {
             name;
             kind = Type;
             doc = doc_text;
             signature = sig_text;
             line = i + 1;
           } :: !items;
           consumed := true
         | None -> ());

      (* Check for module *)
      if not !consumed then
        (match parse_module trimmed with
         | Some name ->
           found_first_decl := true;
           items := {
             name;
             kind = Module;
             doc = doc_text;
             signature = trimmed;
             line = i + 1;
           } :: !items;
           consumed := true
         | None -> ());

      (* Check for let binding *)
      if not !consumed then
        (match parse_let trimmed with
         | Some name ->
           if not !found_first_decl && doc_text <> "" then begin
             (* First doc comment before any declaration = module doc *)
             module_doc_text := doc_text;
           end;
           found_first_decl := true;
           (* Only include items that have doc comments or are public-looking *)
           if doc_text <> "" then begin
             let sig_text = extract_let_signature trimmed in
             items := {
               name;
               kind = Function;
               doc = doc_text;
               signature = sig_text;
               line = i + 1;
             } :: !items
           end;
           consumed := true
         | None -> ());

      (* If we have a pending doc and nothing consumed it, check if it's module-level *)
      if not !consumed && doc_text <> "" && not !found_first_decl then
        module_doc_text := doc_text;

      (* Clear pending doc if we hit a non-blank, non-doc line *)
      if trimmed <> "" then
        pending_doc := []
    end
  done;

  let module_name =
    let base = Filename.basename path in
    let base =
      if Filename.check_suffix base ".mlx" then Filename.chop_suffix base ".mlx"
      else if Filename.check_suffix base ".ml" then Filename.chop_suffix base ".ml"
      else base
    in
    String.capitalize_ascii base
  in
  {
    name = module_name;
    path;
    doc = !module_doc_text;
    items = List.rev !items;
  }
