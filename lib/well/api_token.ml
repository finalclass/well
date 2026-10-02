open Types

type identity =
  { user_id: string
  ; session_data: (string * string) list }

let verifier : ((string -> identity option) * (request -> bool)) option Atomic.t
    =
  Atomic.make None

let configure ?(applies_to = fun _ -> true) ~verify () =
  Atomic.set verifier (Some (verify, applies_to))

let binding : (string * (string * string) list * bool Atomic.t) Eio.Fiber.key =
  Eio.Fiber.create_key ()

let session_data session_id =
  let current =
    try Eio.Fiber.get binding with
    | Effect.Unhandled _ -> None
  in
  match current with
  | Some (sid, data, active) when sid = session_id && Atomic.get active ->
      Some data
  | _ -> None

module Authenticated = Context (struct
  type t = bool

  let empty = false
end)

let authenticated req =
  Authenticated.get req && Option.is_some (session_data req.session_id)

let bearer headers =
  let values =
    List.filter_map
      (fun (key, value) ->
        if String.lowercase_ascii key = "authorization"
        then Some value
        else None )
      headers
  in
  match values with
  | [] -> None
  | [value] -> (
      let value = String.trim value in
      match String.index_opt value ' ' with
      | Some index
        when String.lowercase_ascii (String.sub value 0 index) = "bearer" ->
          let token =
            String.trim
              (String.sub value (index + 1) (String.length value - index - 1))
          in
          if token = "" || String.exists (fun c -> c <= ' ' || c = '\127') token
          then Some (Error ())
          else Some (Ok token)
      | None when String.lowercase_ascii value = "bearer" -> Some (Error ())
      | _
        when String.length value > 6
             && String.lowercase_ascii (String.sub value 0 6) = "bearer"
             && value.[6] <= ' ' ->
          Some (Error ())
      | _ -> None )
  | _ -> Some (Error ())

let reject () =
  json (`Assoc [("error", `String "Invalid API token")])
  |> status 401
  |> header "WWW-Authenticate" "Bearer"

let run ~fresh_session next req verify token =
  let result =
    try Ok (verify token) with
    | _ -> Error ()
  in
  match result with
  | Error () ->
      json (`Assoc [("error", `String "API token verification unavailable")])
      |> status 503
  | Ok None -> reject ()
  | Ok (Some identity) when String.trim identity.user_id = "" -> reject ()
  | Ok (Some identity) ->
      let session_id = fresh_session () in
      let data =
        ("user_id", identity.user_id)
        :: List.filter (fun (key, _) -> key <> "user_id") identity.session_data
      in
      let req = Authenticated.set true {req with session_id} in
      let active = Atomic.make true in
      Fun.protect
        ~finally:(fun () -> Atomic.set active false)
        (fun () ->
          Eio.Fiber.with_binding binding (session_id, data, active) (fun () ->
              next req ) )

let protect_mutation session_id =
  match session_data session_id with
  | None -> ()
  | Some _ ->
      invalid_arg
        "API-token identity is immutable; manage tokens through the application"
