open Js_of_ocaml
open Well_web
open Cap_http

type entry =
  { input: string
  ; output: string
  ; type_: string
  ; error: bool }

type state =
  { input: string
  ; history: entry list
  ; cursor: int
  ; suggestions: string list
  ; schema: string list
  ; vars: string list
  ; busy: bool
  ; help: bool
  ; error: string }

type msg =
  | Input of string
  | Submit of Html.form_data
  | Loaded of (Yojson.Safe.t, string) result
  | Schema of string
  | Key of string
  | Complete of string
  | Clear
  | Help

type emits = unit

let schema_names json =
  match json with
  | `Assoc services ->
      List.concat_map
        (fun (name, methods) ->
          match methods with
          | `Assoc xs -> List.map (fun (method_, _) -> name ^ "." ^ method_) xs
          | _ -> [] )
        services
  | _ -> []

let props = [Props.string "schema" ~on:(fun s -> Schema s) ()]

let init ~dispatch:_ =
  ( { input= ""
    ; history= []
    ; cursor= 0
    ; suggestions= []
    ; schema= []
    ; vars= []
    ; busy= false
    ; help= false
    ; error= "" }
  , Cmd.none )

let suggest state input =
  let prefix = String.trim input in
  if prefix = "" || String.contains prefix ' '
  then []
  else
    List.filter
      (fun candidate -> String.starts_with ~prefix candidate)
      (state.schema @ state.vars)

let update state = function
  | Schema json -> (
    try
      ( {state with schema= schema_names (Yojson.Safe.from_string json)}
      , Cmd.none )
    with
    | _ -> (state, Cmd.none) )
  | Input input ->
      ( { state with
          input
        ; suggestions= suggest state input
        ; cursor= List.length state.history }
      , Cmd.none )
  | Submit fields ->
      let input =
        Option.value (List.assoc_opt "expr" fields) ~default:state.input
        |> String.trim
      in
      if state.busy || input = ""
      then (state, Cmd.none)
      else
        ( {state with input; busy= true; error= ""; suggestions= []}
        , Cmd.perform (fun ~dispatch ->
              request
                ~body:(encode [("expr", input)])
                "POST"
                "/_cap/api/repl"
                (fun result -> dispatch (Loaded result)) ) )
  | Loaded (Error error) ->
      ({state with busy= false; error}, Cmd.focus ".repl-input-field")
  | Loaded (Ok json) ->
      let entry =
        { input= state.input
        ; output= text "output" json
        ; type_= text "type" json
        ; error= member "error" json = `Bool true }
      in
      let history = state.history @ [entry] in
      let vars = List.map string (list (member "vars" json)) in
      ( { state with
          input= ""
        ; history
        ; cursor= List.length history
        ; vars
        ; busy= false
        ; error= "" }
      , Cmd.focus ".repl-input-field" )
  | Complete input ->
      ( {state with input= input ^ " "; suggestions= []}
      , Cmd.focus ".repl-input-field" )
  | Key "Tab" -> (
    match state.suggestions with
    | first :: _ ->
        ( {state with input= first ^ " "; suggestions= []}
        , Cmd.focus ".repl-input-field" )
    | [] -> (state, Cmd.none) )
  | Key (("ArrowUp" | "ArrowDown") as key) ->
      let cursor =
        max
          0
          (min
             (List.length state.history)
             (state.cursor + if key = "ArrowUp" then -1 else 1) )
      in
      let input =
        if cursor >= List.length state.history
        then ""
        else (List.nth state.history cursor).input
      in
      ({state with cursor; input; suggestions= []}, Cmd.none)
  | Key "ControlL"
   |Clear ->
      ( { state with
          history= []
        ; cursor= 0
        ; input= ""
        ; suggestions= []
        ; error= "" }
      , Cmd.focus ".repl-input-field" )
  | Key _ -> (state, Cmd.none)
  | Help -> ({state with help= not state.help}, Cmd.none)

let key_event obj =
  let event : Dom_html.keyboardEvent Js.t = Obj.magic obj in
  let key = Js.Optdef.case event##.key (fun () -> "") Js.to_string in
  let key =
    if key = "l" && Js.to_bool event##.ctrlKey then "ControlL" else key
  in
  if List.mem key ["Tab"; "ArrowUp"; "ArrowDown"; "ControlL"]
  then begin
    Dom.preventDefault event ;
    Some (Key key)
  end
  else None

let node ?(class_ = "") ?(children = []) ?(text = "") tag =
  Html.element tag ~attrs:[("class", class_)] ~children ~text ()

let button msg label =
  Html.element
    "button"
    ~attrs:[("type", "button"); ("class", "btn btn-sm")]
    ~handlers:[("click", Html.Msg msg)]
    ~text:label
    ()

let rec json_nodes indent json =
  let scalar class_ =
    [node ~class_ ~text:(Yojson.Safe.to_string json) "span"]
  in
  let group open_ close entries =
    if entries = []
    then [Html.txt (open_ ^ close)]
    else
      let padding = String.make ((indent + 1) * 2) ' ' in
      let contents =
        List.mapi
          (fun i entry ->
            [Html.txt ((if i = 0 then "" else ",\n") ^ padding)] @ entry )
          entries
        |> List.concat
      in
      [Html.txt (open_ ^ "\n")]
      @ contents
      @ [Html.txt ("\n" ^ String.make (indent * 2) ' ' ^ close)]
  in
  match json with
  | `String _ -> scalar "j-str"
  | `Int _
   |`Intlit _
   |`Float _ ->
      scalar "j-num"
  | `Bool _ -> scalar "j-bool"
  | `Null -> scalar "j-null"
  | `List items -> group "[" "]" (List.map (json_nodes (indent + 1)) items)
  | `Assoc fields ->
      group
        "{"
        "}"
        (List.map
           (fun (key, value) ->
             [node ~class_:"j-key" ~text:key "span"; Html.txt ": "]
             @ json_nodes (indent + 1) value )
           fields )

let output_nodes (entry : entry) =
  if entry.error
  then [node ~text:entry.output "span"]
  else
    try json_nodes 0 (Yojson.Safe.from_string entry.output) with
    | _ -> [node ~text:entry.output "span"]

let view state _dispatch _children =
  let history =
    List.map
      (fun (entry : entry) ->
        node
          ~class_:"repl-entry"
          ~children:
            [ node ~class_:"repl-entry-input" ~text:("> " ^ entry.input) "div"
            ; node
                ~class_:"repl-entry-type"
                ~text:(if entry.error then "" else ": " ^ entry.type_)
                "div"
            ; node
                ~class_:
                  ( "repl-entry-output"
                  ^ if entry.error then " repl-error" else "" )
                ~children:(output_nodes entry)
                "pre" ]
          "div" )
      state.history
  in
  node
    ~class_:"repl-wrap"
    ~children:
      [ node
          ~class_:"repl-toolbar"
          ~children:
            [ button Help (if state.help then "Ukryj pomoc" else "Pomoc")
            ; button Clear "Wyczyść" ]
          "div"
      ; ( if state.help
          then
            node
              ~class_:"repl-help"
              ~children:
                [ node
                    ~class_:"repl-help-pre"
                    ~text:
                      "Service.method param:value\n\
                       let x = Service.method()\n\
                       x.field\n\
                       expr | map .field\n\
                       expr | filter .field:value\n\
                       expr | pick .f1 .f2\n\
                       expr | count\n\
                       expr | first\n\
                       expr | sort .field\n\
                       (2 + 3) * 4\n\
                       Tab: podpowiedź · ↑/↓: historia · Ctrl+L: wyczyść"
                    "pre" ]
              "div"
          else Html.txt "" )
      ; node
          ~class_:"repl-output-area"
          ~children:
            ( if history = []
              then
                [ node
                    ~class_:"empty-state"
                    ~text:"Wpisz wyrażenie, aby wywołać usługę"
                    "div" ]
              else history )
          "div"
      ; ( if state.error = ""
          then Html.txt ""
          else node ~class_:"login-error" ~text:state.error "div" )
      ; Html.element
          "form"
          ~attrs:[("class", "repl-input-line")]
          ~handlers:[("submit", Html.On_form (fun fields -> Submit fields))]
          ~children:
            [ node ~class_:"repl-prompt" ~text:"well>" "span"
            ; Html.void_element
                "input"
                ~attrs:
                  [ ("class", "repl-input-field")
                  ; ("name", "expr")
                  ; ("type", "text")
                  ; ("value", state.input)
                  ; ("autocomplete", "off")
                  ; ("spellcheck", "false")
                  ; ("placeholder", "Tasks.list | count") ]
                ~bool_attrs:(if state.busy then ["disabled"] else [])
                ~handlers:
                  [ ("input", Html.On_value (fun s -> Input s))
                  ; ("keydown", Html.On_event key_event) ]
                ()
            ; node
                ~class_:"repl-hint"
                ~text:
                  ( if state.busy
                    then "Wykonywanie…"
                    else String.concat " · " state.suggestions )
                "span" ]
          ()
      ; ( if state.suggestions = []
          then Html.txt ""
          else
            node
              ~class_:"repl-completions"
              ~children:
                (List.map
                   (fun candidate ->
                     Html.element
                       "button"
                       ~attrs:
                         [ ("type", "button")
                         ; ("class", "repl-comp-item")
                         ; ( "style"
                           , "display:block;width:100%;text-align:left;background:transparent;border:0;font:inherit"
                           ) ]
                       ~handlers:[("click", Html.Msg (Complete candidate))]
                       ~text:candidate
                       () )
                   state.suggestions )
              "div" ) ]
    "div"
