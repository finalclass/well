open Js_of_ocaml

let request ?(body = "") method_ url on_done =
  let xhr = XmlHttpRequest.create () in
  xhr##_open (Js.string method_) (Js.string url) Js._true ;
  xhr##setRequestHeader (Js.string "Accept") (Js.string "application/json") ;
  if method_ <> "GET"
  then begin
    xhr##setRequestHeader
      (Js.string "Content-Type")
      (Js.string "application/x-www-form-urlencoded") ;
    xhr##setRequestHeader
      (Js.string "X-Requested-With")
      (Js.string "XMLHttpRequest")
  end ;
  xhr##.onreadystatechange :=
    Js.wrap_callback (fun () ->
        if xhr##.readyState = XmlHttpRequest.DONE
        then
          if xhr##.status < 200 || xhr##.status >= 300
          then on_done (Error (Printf.sprintf "HTTP %d" xhr##.status))
          else
            let text =
              Js.Opt.case xhr##.responseText (fun () -> "") Js.to_string
            in
            try on_done (Ok (Yojson.Safe.from_string text)) with
            | _ -> on_done (Error "Nieprawidłowa odpowiedź serwera") ) ;
  xhr##send (if body = "" then Js.null else Js.some (Js.string body))

let encode fields =
  String.concat
    "&"
    (List.map
       (fun (k, v) ->
         Js.to_string (Js.encodeURIComponent (Js.string k))
         ^ "="
         ^ Js.to_string (Js.encodeURIComponent (Js.string v)) )
       fields )

let later dispatch msg =
  ignore
    (Dom_html.window##setTimeout
       (Js.wrap_callback (fun () -> dispatch msg))
       (Js.number_of_float 2000.) )

let member key = function
  | `Assoc fields -> Option.value (List.assoc_opt key fields) ~default:`Null
  | _ -> `Null

let string = function
  | `String s -> s
  | `Int n -> string_of_int n
  | `Float f -> string_of_float f
  | _ -> ""

let text key json = string (member key json)

let list = function
  | `List xs -> xs
  | _ -> []
