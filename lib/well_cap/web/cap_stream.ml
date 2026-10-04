open Well_web
open Cap_http

type state =
  { endpoint: string
  ; kind: string
  ; data: Yojson.Safe.t
  ; error: string
  ; paused: bool
  ; cleared: bool }

type msg =
  | Endpoint of string
  | Kind of string
  | Initial of string
  | Tick
  | Loaded of (Yojson.Safe.t, string) result
  | Toggle
  | Clear

type emits = unit

let props =
  [ Props.string "endpoint" ~on:(fun s -> Endpoint s) ()
  ; Props.string "kind" ~on:(fun s -> Kind s) ()
  ; Props.string "initial" ~on:(fun s -> Initial s) () ]

let load endpoint =
  Cmd.perform (fun ~dispatch ->
      request "GET" endpoint (fun result -> dispatch (Loaded result)) )

let timer : (msg, emits) Cmd.t =
  Cmd.perform (fun ~dispatch -> later dispatch Tick)

let init ~dispatch:_ =
  ( { endpoint= ""
    ; kind= ""
    ; data= `Null
    ; error= ""
    ; paused= false
    ; cleared= false }
  , Cmd.msg Tick )

let update state = function
  | Endpoint endpoint -> ({state with endpoint}, Cmd.none)
  | Kind kind -> ({state with kind}, Cmd.none)
  | Initial json -> (
    try ({state with data= Yojson.Safe.from_string json}, Cmd.none) with
    | _ -> (state, Cmd.none) )
  | Tick ->
      ( state
      , if state.paused || state.endpoint = ""
        then timer
        else load state.endpoint )
  | Loaded (Ok data) -> ({state with data; error= ""}, timer)
  | Loaded (Error error) -> ({state with error; paused= true}, Cmd.none)
  | Toggle ->
      ( {state with paused= not state.paused; cleared= false}
      , if state.paused && state.error <> "" then Cmd.msg Tick else Cmd.none )
  | Clear -> ({state with cleared= true; paused= true}, Cmd.none)

let node ?(class_ = "") ?(children = []) ?(text = "") tag =
  Html.element
    tag
    ~attrs:(if class_ = "" then [] else [("class", class_)])
    ~children
    ~text
    ()

let stream_entry kind json =
  if kind = "messages"
  then
    node
      ~class_:"msg-entry"
      ~children:
        [ node
            ~class_:"flex items-center justify-between"
            ~children:
              [ node ~class_:"msg-channel" ~text:(text "channel" json) "span"
              ; node ~class_:"log-time" ~text:(text "time" json) "span" ]
            "div"
        ; node ~class_:"msg-payload" ~text:(text "payload" json) "div" ]
      "div"
  else
    let level = text "level" json in
    let badge =
      if level = "error"
      then "badge-delete"
      else if level = "warn"
      then "badge-put"
      else "badge-get"
    in
    let ctx =
      match member "ctx" json with
      | `Assoc xs ->
          List.map
            (fun (k, v) ->
              node
                ~class_:"log-ctx"
                ~children:
                  [ node ~class_:"log-ctx-key" ~text:k "span"
                  ; Html.txt "="
                  ; node ~class_:"log-ctx-val" ~text:(string v) "span"
                  ; Html.txt " " ]
                "span" )
            xs
      | _ -> []
    in
    Html.element
      "div"
      ~attrs:
        [ ( "class"
          , "log-entry"
            ^ if text "highlight" json = "true" then " log-jump-target" else ""
          )
        ; ("data-id", text "id" json) ]
      ~children:
        ( [ node ~class_:"log-time" ~text:(text "time" json) "span"
          ; node ~class_:("badge " ^ badge) ~text:level "span" ]
        @ ctx
        @ [node ~class_:"log-msg" ~text:(text "message" json) "span"] )
      ()

let view state _dispatch _children =
  let controls =
    node
      ~class_:
        ( if state.kind = "logs"
          then "log-header"
          else "flex items-center justify-between mb-3" )
      ~children:
        [ node
            ~class_:"card-title"
            ~text:
              ( if state.kind = "messages"
                then "MessageBus"
                else if state.kind = "logs"
                then "Logi"
                else "Telemetria" )
            "div"
        ; node
            ~children:
              [ Html.element
                  "button"
                  ~attrs:[("class", "btn btn-sm"); ("type", "button")]
                  ~handlers:[("click", Html.Msg Toggle)]
                  ~text:(if state.paused then "Wznów" else "Pauza")
                  ()
              ; ( if state.kind = "telemetry"
                  then Html.txt ""
                  else
                    Html.element
                      "button"
                      ~attrs:[("class", "btn btn-sm"); ("type", "button")]
                      ~handlers:[("click", Html.Msg Clear)]
                      ~text:"Wyczyść widok"
                      () ) ]
            "div" ]
      "div"
  in
  let content =
    if state.cleared
    then node ~class_:"empty-state" ~text:"Widok wyczyszczony" "div"
    else if state.kind = "telemetry"
    then
      node
        ~children:
          (List.map
             (fun group ->
               node
                 ~class_:"card"
                 ~children:
                   [ node ~class_:"card-title" ~text:(text "title" group) "div"
                   ; node
                       ~class_:"stat-grid"
                       ~children:
                         (List.map
                            (fun stat ->
                              node
                                ~class_:"stat-card"
                                ~children:
                                  [ node
                                      ~class_:"stat-label"
                                      ~text:(text "label" stat)
                                      "div"
                                  ; Html.element
                                      "div"
                                      ~attrs:
                                        [ ( "class"
                                          , "stat-value " ^ text "class" stat )
                                        ; ("style", text "style" stat) ]
                                      ~text:(text "value" stat)
                                      () ]
                                "div" )
                            (list (member "stats" group)) )
                       "div" ]
                 "div" )
             (list state.data) )
        "div"
    else
      Html.element
        "div"
        ~attrs:
          [ ("class", "log-stream")
          ; ("style", if state.kind = "logs" then "" else "max-height:600px") ]
        ~children:
          ( match list state.data with
          | [] -> [node ~class_:"empty-state" ~text:"Brak wpisów" "div"]
          | entries -> List.map (stream_entry state.kind) entries )
        ()
  in
  node
    ~class_:
      ( if state.kind = "telemetry"
        then ""
        else if state.kind = "logs"
        then "log-viewer"
        else "card" )
    ~children:
      [ controls
      ; ( if state.error = ""
          then Html.txt ""
          else node ~class_:"login-error" ~text:state.error "div" )
      ; content ]
    "div"
