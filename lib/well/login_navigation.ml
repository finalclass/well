open struct
  let is_control code = code <= 0x1f || (code >= 0x7f && code <= 0x9f)

  let is_whitespace code =
    (code >= 0x09 && code <= 0x0d)
    || (code >= 0x2000 && code <= 0x200a)
    ||
    match code with
    | 0x20
     |0x85
     |0xa0
     |0x1680
     |0x2028
     |0x2029
     |0x202f
     |0x205f
     |0x3000 ->
        true
    | _ -> false

  let valid_characters ~literal target =
    let rec scan index in_path =
      if index = String.length target
      then true
      else
        let decoded = String.get_utf_8_uchar target index in
        let code, length =
          if Uchar.utf_decode_is_valid decoded
          then
            ( Uchar.to_int (Uchar.utf_decode_uchar decoded)
            , Uchar.utf_decode_length decoded )
          else (Char.code target.[index], 1)
        in
        (not (is_control code || code = 0x5c))
        && (not ((literal || in_path) && is_whitespace code))
        && scan (index + length) (in_path && code <> 0x3f && code <> 0x23)
    in
    scan 0 true

  let has_local_prefix target =
    String.length target > 0
    && target.[0] = '/'
    && (String.length target = 1 || target.[1] <> '/')

  let hex_value = function
    | '0' .. '9' as c -> Char.code c - Char.code '0'
    | 'a' .. 'f' as c -> Char.code c - Char.code 'a' + 10
    | 'A' .. 'F' as c -> Char.code c - Char.code 'A' + 10
    | _ -> -1

  let decode_percent target =
    let length = String.length target in
    let buffer = Buffer.create length in
    let rec scan index =
      if index < length
      then
        if target.[index] = '%' && index + 2 < length
        then
          let high = hex_value target.[index + 1] in
          let low = hex_value target.[index + 2] in
          if high >= 0 && low >= 0
          then begin
            Buffer.add_char buffer (Char.chr ((high lsl 4) lor low)) ;
            scan (index + 3)
          end
          else begin
            Buffer.add_char buffer target.[index] ;
            scan (index + 1)
          end
        else begin
          Buffer.add_char buffer target.[index] ;
          scan (index + 1)
        end
    in
    scan 0 ;
    Buffer.contents buffer

  let valid_target target =
    let rec validate ~literal current =
      has_local_prefix current
      && valid_characters ~literal current
      &&
      let decoded = decode_percent current in
      decoded = current || validate ~literal:false decoded
    in
    validate ~literal:true target

  let split_at character value =
    match String.index_opt value character with
    | None -> (value, None)
    | Some index ->
        ( String.sub value 0 index
        , Some (String.sub value (index + 1) (String.length value - index - 1))
        )
end

let safe_target target = if valid_target target then target else "/"

let return_target (req : Types.request) =
  if req.meth <> "GET"
  then "/"
  else
    let query =
      req.query
      |> List.map (fun (name, value) ->
          Url.encode name ^ "=" ^ Url.encode value )
      |> String.concat "&"
    in
    safe_target (req.path ^ if query = "" then "" else "?" ^ query)

let login_url ?(login_path = "/login") ?(return_param = "return_to") target =
  if not (valid_target login_path)
  then invalid_arg "Login_navigation.login_url: unsafe login_path" ;
  if return_param = ""
  then invalid_arg "Login_navigation.login_url: empty return_param" ;
  let address, fragment = split_at '#' login_path in
  let path, query = split_at '?' address in
  let parameters =
    match query with
    | None
     |Some "" ->
        []
    | Some query ->
        String.split_on_char '&' query
        |> List.filter (fun pair ->
            let name, _ = split_at '=' pair in
            Url.decode name <> return_param )
  in
  let parameter =
    Url.encode return_param ^ "=" ^ Url.encode (safe_target target)
  in
  path
  ^ "?"
  ^ String.concat "&" (parameters @ [parameter])
  ^
  match fragment with
  | None -> ""
  | Some fragment -> "#" ^ fragment
