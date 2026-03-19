(* Env — Global EIO environment, set once by Well.run *)

let _env : Eio_unix.Stdenv.base option ref = ref None

let set env = _env := Some env

let get () =
  match !_env with
  | Some e -> e
  | None -> failwith "Well.env: must be called within Well.run"

let net () = Eio.Stdenv.net (get ())
let clock () = Eio.Stdenv.clock (get ())
let mono_clock () = Eio.Stdenv.mono_clock (get ())
let cwd () = Eio.Stdenv.cwd (get ())
let fs () = Eio.Stdenv.fs (get ())
let domain_mgr () = Eio.Stdenv.domain_mgr (get ())

let sleep seconds = Eio.Time.sleep (clock ()) seconds

let with_timeout duration f =
  Eio.Time.with_timeout_exn (clock ()) duration f
