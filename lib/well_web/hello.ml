(* Spike Fazy 0: hello-world custom element via js_of_ocaml.

   Cel: udowodnic, ze jsoo kompiluje OCaml do JS w build graph well
   i ze kod OCaml round-tripuje z DOM. *)

open Js_of_ocaml

let js_code =
  "customElements.define('hello-world', class extends HTMLElement { \
   connectedCallback() { this.textContent = 'Hello from OCaml!'; } });"

let () = Js.Unsafe.eval_string js_code


