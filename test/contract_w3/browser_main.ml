(* W3 browser consumer: runs in a real browser over js_of_ocaml and calls the
   W3 HTTP server through the generated callback Proxy. Results are collected
   into [window.__W3_RESULT] so the harness can read them. *)

open Js_of_ocaml

let results : (string * string) list ref = ref []

let add name value = results := !results @ [ (name, value) ]

let json_string s = Yojson.Safe.to_string (`String s)

let emit () =
  let body =
    List.map
      (fun (name, value) ->
        Printf.sprintf "[%s,%s]" (json_string name) (json_string value))
      !results
    |> String.concat ","
  in
  Js.Unsafe.set Js.Unsafe.global (Js.string "__W3_RESULT")
    (Js.string ("[" ^ body ^ "]"))

let outcome = function Ok v -> v | Error e -> "error:" ^ e

let show_response (r : Contract_data_browser.Orders.ReserveResponse.t) =
  match r with
  | Contract_data_browser.Orders.ReserveResponse.Reserved res ->
    Printf.sprintf "Reserved(%s,%Ld)" res.id res.count
  | Contract_data_browser.Orders.ReserveResponse.Rejected p ->
    "Rejected(" ^ p.code ^ ")"
  | Contract_data_browser.Orders.ReserveResponse.Unavailable -> "Unavailable"

let meta_token () =
  match
    Js.Opt.to_option
      (Dom_html.document##querySelector (Js.string "meta[name='csrf-token']"))
  with
  | Some el ->
    (try Js.to_string (Js.Unsafe.get el (Js.string "content")) with _ -> "")
  | None -> ""

let rec seq = function
  | [] -> emit ()
  | (name, action) :: rest -> action (fun value -> add name value; seq rest)

module D = Contract_data_browser

let () =
  let module P = Orders.Proxy in
  let cookie = Js.to_string Dom_html.document##.cookie in
  let tests =
    [
      ( "cookie",
        fun k -> k (if String.length cookie > 0 then "present" else "absent") );
      ( "csrf_meta",
        fun k -> k (if meta_token () <> "" then "present" else "absent") );
      ( "reserve_big",
        fun k ->
          P.reserve
            (D.Orders.ReserveRequest.make ~owner_id:"owner-1"
               ~quantity:9007199254740991L
               ~thing:(D.Common.Thing.make ~id:"t-1" ())
               ~tags:[ "a"; "b" ] ())
            ~on_done:(fun r -> k (outcome (Result.map show_response r))) );
      ( "echo_cross_module",
        fun k ->
          P.echo
            (D.Common.Thing.make ~id:"cross-module" ())
            ~on_done:(fun r ->
              k (outcome (Result.map (fun (t : D.Common.Thing.t) -> t.id) r))) );
      ( "numbers",
        fun k ->
          P.numbers
            (D.Common.Numbers.make ~small:7L ~big:9007199254740991L
               ~negative:(-9007199254740991L) ~ratio:1.5
               ~unicode:"Zażółć gęślą jaźń" ())
            ~on_done:(fun r ->
              k
                (outcome
                   (Result.map
                      (fun (n : D.Common.Numbers.t) ->
                        Printf.sprintf "%Ld/%Ld/%s" n.big n.negative n.unicode)
                      r))) );
      ( "empty",
        fun k ->
          P.empty (D.Common.Empty.make ()) ~on_done:(fun r ->
              k (match r with Ok _ -> "ok" | Error e -> "error:" ^ e)) );
      ( "http_404",
        fun k ->
          Rpc.post ~service:"Orders" ~method_:"unknown_xyz" ~payload:"null"
            ~on_done:(fun r -> k (outcome r)) );
      ( "http_2xx_error",
        fun k ->
          P.echo (D.Common.Thing.make ~id:"legacy-error" ()) ~on_done:(fun r ->
              k (outcome (Result.map (fun (_ : D.Common.Thing.t) -> "ok") r))) );
      ( "http_bad_response",
        fun k ->
          P.echo (D.Common.Thing.make ~id:"bad-response" ()) ~on_done:(fun r ->
              k (outcome (Result.map (fun (_ : D.Common.Thing.t) -> "ok") r))) );
    ]
  in
  seq tests