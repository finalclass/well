(* Spike S7: czy typowane FFI jsoo działa pod dune pkg?

   Testujemy wszystkie constructy, których runtime TEA będzie potrzebował:
   1. Js.t < ... > typed interface (object types)
   2. ## operator (method call, property access, write prop)
   3. Js.global, Js.string, Js.number
   4. customElements.define + connectedCallback (lifecycle)
   5. dispatchEvent + CustomEvent (event-w-górę, D9)
   6. requestAnimationFrame (D8 Cmd.focus)

   Jeśli ##/Js.t działają, to S5 ({js|...|js}) był lexer-isolated problem
   i typowane FFI jest OK dla runtime'u. *)

open Js_of_ocaml

(* ── 1. Typed interfaces dla DOM/customElements/CustomEvent/rAF ── *)

class type ['a] html_element = object
  method textContent : Js.js_string Js.t Js.prop
  method dispatchEvent : 'a Js.t -> bool Js.meth
end

class type custom_elements = object
  method define : Js.js_string Js.t -> 'a Js.t -> unit Js.meth
end

class type document = object
  method querySelector : Js.js_string Js.t -> 'a Js.t Js.opt Js.meth
  method createElement : Js.js_string Js.t -> 'a Js.t Js.meth
end

class type ['a] window = object
  method document : document Js.t Js.readonly_prop
  method customElements : custom_elements Js.t Js.readonly_prop
  method requestAnimationFrame : (float -> unit) Js.callback -> int Js.meth
end

(* ── 2. Globals (typed) ── *)

let window : [> ] window Js.t = Js.Unsafe.(global)
let document = window##.document

(* ── 3. CustomEvent constructor ──

   new CustomEvent(name, {detail: ...}). Przez Js.Unsafe.new' —
   typed constructor jest trudny, bo CustomEvent nie jest prostym obj. *)

let make_custom_event (name : string) (detail : Yojson.t) : Js.Unsafe.top =
  let opts = Js.Unsafe.obj [| "detail", Js.Unsafe.inject detail |] in
  Js.Unsafe.new_obj (Js.Unsafe.global##.CustomEvent)
    [| Js.Unsafe.inject (Js.string name); Js.Unsafe.inject opts |]

(* ── 4. customElements.define + lifecycle callback ──

   Klasa JS musi dziedziczyć HTMLElement. Najczystszym przez jsoo jest
   subclassing przez Object.create(HTMLElement.prototype) + connectedCallback.
   Robimy to przez eval_string (jak w hello.ml), ale only dla definicji klasy;
   connectedCallback woła OCaml callback — to test ## i Js.callback. *)

(* mutable ref na nasz lifecycle callback (OCaml closure) *)
let on_connect_cb : (unit -> unit) ref = ref (fun () -> ())

let register_element ~(tag_name : string) : unit =
  let code =
    "customElements.define('" ^ tag_name ^
    "', class extends HTMLElement { connectedCallback() { window.__spikeOnConnect(); } });"
  in
  Js.Unsafe.eval_string code

(* ── 5. requestAnimationFrame test (D8 Cmd.focus potrzebuje) ── *)

let raf_once (f : float -> unit) : unit =
  ignore (window##requestAnimationFrame (Js.wrap_callback f))

(* ── 6. Główna rejestracja <ffi-test> ──

   Kolejność: NAJPIERW wystaw __spikeOnConnect (bo connectedCallback
   elementów już w DOM zostanie wywołane natychmiast przy define), POTEM
   register_element. *)

let on_connect_for_ffi_test el =
  el##.textContent := Js.string "FFI typed works!";
  let ev = make_custom_event "ffi-ready" (`Assoc [("ok", `Bool true)]) in
  let (el' : _ html_element Js.t) = Js.Unsafe.coerce el in
  ignore (Js.Unsafe.meth_call el' "dispatchEvent" [| Js.Unsafe.inject ev |])

let () =
  (* 1. Wystaw lifecycle callback globalnie ZANIM element się zarejestruje. *)
  on_connect_cb := (fun () ->
    match Js.Opt.to_option (document##querySelector (Js.string "ffi-test")) with
    | Some el_raw ->
        let (el : < textContent : Js.js_string Js.t Js.prop > Js.t) =
          Js.Unsafe.coerce el_raw in
        on_connect_for_ffi_test el
    | None -> ());
  Js.Unsafe.set Js.Unsafe.global (Js.string "__spikeOnConnect")
    (Js.Unsafe.inject (Js.wrap_callback (fun () -> !on_connect_cb ())))

let () =
  (* 2. Dopiero teraz rejestruj — connectedCallback woła __spikeOnConnect. *)
  register_element ~tag_name:"ffi-test"

(* Wystaw raf_once do testu z HTML. *)
let () =
  Js.Unsafe.set Js.Unsafe.global (Js.string "__spikeRaf")
    (Js.Unsafe.inject (Js.wrap_callback (fun () -> raf_once (fun t -> ignore t))))
