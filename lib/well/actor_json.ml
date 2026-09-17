exception Parse of string

type src = { s : string; mutable i : int }

let peek p =
  if p.i >= String.length p.s then None else Some p.s.[p.i]

let next p =
  match peek p with
  | None -> raise (Parse "unexpected end of JSON")
  | Some c -> p.i <- p.i + 1; c

let rec skip_ws p =
  match peek p with
  | Some (' ' | '\t' | '\n' | '\r') -> ignore (next p); skip_ws p
  | _ -> ()

let is_digit c = c >= '0' && c <= '9'

let parse_string p =
  if next p <> '"' then raise (Parse "expected string");
  let buf = Buffer.create 16 in
  let rec loop () =
    match next p with
    | '"' -> Buffer.contents buf
    | '\\' ->
      (match next p with
       | '"' -> Buffer.add_char buf '"'
       | '\\' -> Buffer.add_char buf '\\'
       | '/' -> Buffer.add_char buf '/'
       | 'b' -> Buffer.add_char buf '\b'
       | 'f' -> Buffer.add_char buf '\012'
       | 'n' -> Buffer.add_char buf '\n'
       | 'r' -> Buffer.add_char buf '\r'
       | 't' -> Buffer.add_char buf '\t'
       | 'u' ->
         let hex n =
           match n with
           | '0' .. '9' -> Char.code n - Char.code '0'
           | 'a' .. 'f' -> 10 + Char.code n - Char.code 'a'
           | 'A' .. 'F' -> 10 + Char.code n - Char.code 'A'
           | _ -> raise (Parse "invalid hex in unicode escape")
         in
         let n =
           (hex (next p) lsl 12) lor (hex (next p) lsl 8)
           lor (hex (next p) lsl 4) lor hex (next p)
         in
         if n < 0x80 then Buffer.add_char buf (Char.chr n)
         else if n < 0x800 then begin
           Buffer.add_char buf (Char.chr (0xC0 lor (n lsr 6)));
           Buffer.add_char buf (Char.chr (0x80 lor (n land 0x3F)))
         end else begin
           Buffer.add_char buf (Char.chr (0xE0 lor (n lsr 12)));
           Buffer.add_char buf (Char.chr (0x80 lor ((n lsr 6) land 0x3F)));
           Buffer.add_char buf (Char.chr (0x80 lor (n land 0x3F)))
         end
       | _ -> raise (Parse "invalid string escape"));
      loop ()
    | c when Char.code c <= 0x1f -> raise (Parse "unescaped control in string")
    | c -> Buffer.add_char buf c; loop ()
  in
  loop ()

let parse_number p =
  let start = p.i in
  (match peek p with Some '-' -> ignore (next p) | _ -> ());
  (match peek p with
   | Some '0' -> ignore (next p)
   | Some c when is_digit c ->
     while match peek p with Some c when is_digit c -> true | _ -> false do
       ignore (next p)
     done
   | _ -> raise (Parse "invalid number"));
  (match peek p with
   | Some '.' ->
     ignore (next p);
     (match peek p with
      | Some c when is_digit c ->
        while match peek p with Some c when is_digit c -> true | _ -> false do
          ignore (next p)
        done
      | _ -> raise (Parse "invalid number"))
   | _ -> ());
  (match peek p with
   | Some ('e' | 'E') ->
     ignore (next p);
     (match peek p with Some ('+' | '-') -> ignore (next p) | _ -> ());
     (match peek p with
      | Some c when is_digit c ->
        while match peek p with Some c when is_digit c -> true | _ -> false do
          ignore (next p)
        done
      | _ -> raise (Parse "invalid number"))
   | _ -> ());
  let tok = String.sub p.s start (p.i - start) in
  if String.contains tok '.' || String.contains tok 'e' || String.contains tok 'E'
  then
    try `Float (float_of_string tok)
    with Failure _ -> raise (Parse "invalid number")
  else
    try `Int (int_of_string tok)
    with Failure _ -> `Intlit tok

let rec parse_value p =
  skip_ws p;
  match peek p with
  | Some 'n' -> expect p "null"; `Null
  | Some 't' -> expect p "true"; `Bool true
  | Some 'f' -> expect p "false"; `Bool false
  | Some '"' -> `String (parse_string p)
  | Some '{' -> parse_object p
  | Some '[' -> parse_array p
  | Some ('-' | '0' .. '9') -> parse_number p
  | Some c -> raise (Parse (Printf.sprintf "unexpected %C" c))
  | None -> raise (Parse "unexpected end of JSON")

and expect p word =
  String.iter (fun c -> if next p <> c then raise (Parse ("expected " ^ word))) word

and parse_object p =
  ignore (next p);
  skip_ws p;
  let acc = ref [] in
  let seen = Hashtbl.create 8 in
  if peek p = Some '}' then (ignore (next p); `Assoc [])
  else
    let rec loop () =
      skip_ws p;
      let k = parse_string p in
      if Hashtbl.mem seen k then raise (Parse ("duplicate key " ^ k));
      Hashtbl.add seen k ();
      skip_ws p;
      if next p <> ':' then raise (Parse "expected ':'");
      let v = parse_value p in
      acc := (k, v) :: !acc;
      skip_ws p;
      match next p with
      | '}' -> `Assoc (List.rev !acc)
      | ',' -> loop ()
      | _ -> raise (Parse "expected ',' or '}'")
    in
    loop ()

and parse_array p =
  ignore (next p);
  skip_ws p;
  if peek p = Some ']' then (ignore (next p); `List [])
  else
    let rec loop acc =
      let v = parse_value p in
      skip_ws p;
      match next p with
      | ']' -> `List (List.rev (v :: acc))
      | ',' -> loop (v :: acc)
      | _ -> raise (Parse "expected ',' or ']'")
    in
    loop []

let parse_string_json s =
  let p = { s; i = 0 } in
  try
    let v = parse_value p in
    skip_ws p;
    if p.i <> String.length s then Error "trailing JSON content"
    else Ok v
  with Parse msg -> Error msg

let parse_file path =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let s = really_input_string ic len in
  close_in ic;
  parse_string_json s

let to_string json = Yojson.Safe.to_string json

let member key = function
  | `Assoc xs -> List.assoc_opt key xs
  | _ -> None

let json_pointer_escape s =
  s |> String.split_on_char '~' |> String.concat "~0"
    |> String.split_on_char '/' |> String.concat "~1"
