let sha256_hex s =
  Digestif.SHA256.to_hex (Digestif.SHA256.digest_string s)

let utf16_units s =
  let rec loop i acc =
    if i >= String.length s then List.rev acc
    else
      match String.get_utf_8_uchar s i with
      | d when Uchar.utf_decode_is_valid d ->
        let u = Uchar.utf_decode_uchar d in
        let i' = i + Uchar.utf_decode_length d in
        let cp = Uchar.to_int u in
        if cp <= 0xFFFF then loop i' (cp :: acc)
        else
          let cp' = cp - 0x10000 in
          let hi = 0xD800 + (cp' lsr 10) in
          let lo = 0xDC00 + (cp' land 0x3FF) in
          loop i' (lo :: hi :: acc)
      | _ -> loop (i + 1) (Char.code s.[i] :: acc)
  in
  loop 0 []

let cmp_utf16 a b = Stdlib.compare (utf16_units a) (utf16_units b)

let hex_digit n =
  if n < 10 then Char.chr (Char.code '0' + n)
  else Char.chr (Char.code 'a' + (n - 10))

let bits_eq a b = Int64.equal (Int64.bits_of_float a) (Int64.bits_of_float b)

let shortest_g f =
  let rec loop p =
    let s = Printf.sprintf "%.*g" p f in
    match float_of_string_opt s with
    | Some g when bits_eq g f -> s
    | _ -> if p >= 17 then Printf.sprintf "%.17g" f else loop (p + 1)
  in
  loop 1

let parse_sig s =
  let s = String.map (function 'E' -> 'e' | c -> c) s in
  let e_idx = String.index_opt s 'e' in
  let mant, exp0 =
    match e_idx with
    | None -> s, 0
    | Some i ->
      let rest = String.sub s (i + 1) (String.length s - i - 1) in
      let rest =
        if rest <> "" && rest.[0] = '+' then String.sub rest 1 (String.length rest - 1)
        else rest
      in
      String.sub s 0 i, int_of_string rest
  in
  let dot = String.index_opt mant '.' in
  let digits, frac =
    match dot with
    | None -> mant, 0
    | Some i ->
      let a = String.sub mant 0 i in
      let b = String.sub mant (i + 1) (String.length mant - i - 1) in
      a ^ b, String.length b
  in
  let digits =
    let rec strip_l k =
      if k < String.length digits - 1 && digits.[k] = '0' then strip_l (k + 1) else k
    in
    let rec strip_r k =
      if k > 0 && digits.[k] = '0' then strip_r (k - 1) else k
    in
    let l = strip_l 0 in
    let r = strip_r (String.length digits - 1) in
    if l > r then "0" else String.sub digits l (r - l + 1)
  in
  let exp = exp0 - frac + String.length digits - 1 in
  digits, exp

let es6_of_float f =
  if Float.is_nan f || Float.is_infinite f then
    invalid_arg "JCS: non-finite number";
  if f = 0. then "0"
  else
    let sign = if f < 0. then "-" else "" in
    let digits, exp = parse_sig (shortest_g (abs_float f)) in
    let k = String.length digits in
    let n = exp + 1 in
    let body =
      if n > 0 && n <= 21 then
        if k <= n then digits ^ String.make (n - k) '0'
        else String.sub digits 0 n ^ "." ^ String.sub digits n (k - n)
      else if n <= 0 && n > -6 then
        "0." ^ String.make (-n) '0' ^ digits
      else
        let exp_s = string_of_int (n - 1) in
        let mant =
          if k = 1 then digits
          else String.make 1 digits.[0] ^ "." ^ String.sub digits 1 (k - 1)
        in
        let exp_s = if n - 1 >= 0 then "+" ^ exp_s else exp_s in
        mant ^ "e" ^ exp_s
    in
    sign ^ body

let rec write buf (json : Yojson.Safe.t) =
  match json with
  | `Null -> Buffer.add_string buf "null"
  | `Bool true -> Buffer.add_string buf "true"
  | `Bool false -> Buffer.add_string buf "false"
  | `Int n -> Buffer.add_string buf (string_of_int n)
  | `Intlit s -> Buffer.add_string buf s
  | `Float f -> Buffer.add_string buf (es6_of_float f)
  | `String s -> write_string buf s
  | `Assoc pairs ->
    let pairs = List.sort (fun (a, _) (b, _) -> cmp_utf16 a b) pairs in
    Buffer.add_char buf '{';
    List.iteri (fun i (k, v) ->
      if i > 0 then Buffer.add_char buf ',';
      write_string buf k;
      Buffer.add_char buf ':';
      write buf v
    ) pairs;
    Buffer.add_char buf '}'
  | `List xs ->
    Buffer.add_char buf '[';
    List.iteri (fun i v ->
      if i > 0 then Buffer.add_char buf ',';
      write buf v
    ) xs;
    Buffer.add_char buf ']'

and write_string buf s =
  Buffer.add_char buf '"';
  String.iter (fun c ->
    match c with
    | '"' -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\b' -> Buffer.add_string buf "\\b"
    | '\012' -> Buffer.add_string buf "\\f"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | c when Char.code c <= 0x1f ->
      let n = Char.code c in
      Buffer.add_string buf "\\u00";
      Buffer.add_char buf (hex_digit (n lsr 4));
      Buffer.add_char buf (hex_digit (n land 15))
    | c -> Buffer.add_char buf c
  ) s;
  Buffer.add_char buf '"'

let canonicalize json =
  let buf = Buffer.create 256 in
  write buf json;
  Buffer.contents buf

let hash_json json = sha256_hex (canonicalize json)

let minus_zero_to_zero (json : Yojson.Safe.t) =
  let rec go = function
    | `Float f when f = 0. -> `Int 0
    | `Assoc xs -> `Assoc (List.map (fun (k, v) -> (k, go v)) xs)
    | `List xs -> `List (List.map go xs)
    | other -> other
  in
  go json
