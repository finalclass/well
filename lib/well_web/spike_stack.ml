(* Spike Fazy 0: sourcemap round-trip.

   Odkryliśmy: jsoo domyślnie NIE zachowuje OCaml backtrace w exception
   object. Sprawdzamy czy włączenie Printexc.record_backtrace + get_backtrace
   daje nazwy plików/funkcji OCaml (bo backtrace jest generowany przez
   compiler z debug info, który mamy przez -g). *)

open Js_of_ocaml

let explode_in_ocaml () = failwith "boom from spike_stack.ml"

let () =
  Printexc.record_backtrace true;
  let trigger _ =
    (try ignore (explode_in_ocaml () : 'a)
     with _ ->
       (* Pobierz OCaml backtrace jako string, wystaw globalnie *)
       let bt = Printexc.get_backtrace () in
       Js.Unsafe.set Js.Unsafe.global (Js.string "__spikeBacktrace")
         (Js.string bt));
    Js.undefined
  in
  Js.Unsafe.set Js.Unsafe.global (Js.string "__triggerSpikeBug")
    (Js.Unsafe.callback trigger)
