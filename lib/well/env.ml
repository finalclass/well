(** Env -- global EIO environment, set once by [Well.run].
    Provides access to network, clock, filesystem, and other capabilities. *)

let _env : Eio_unix.Stdenv.base option ref = ref None

(** Store the EIO environment (called once by [Well.run]). *)
let set env = _env := Some env

(** Get the EIO environment. Raises if called outside [Well.run]. *)
let get () =
  match !_env with
  | Some e -> e
  | None -> failwith "Well.env: must be called within Well.run"

(** Access the EIO network capability. *)
let net () = Eio.Stdenv.net (get ())

(** Access the EIO wall clock. *)
let clock () = Eio.Stdenv.clock (get ())
let mono_clock () = Eio.Stdenv.mono_clock (get ())
let cwd () = Eio.Stdenv.cwd (get ())
let fs () = Eio.Stdenv.fs (get ())
let domain_mgr () = Eio.Stdenv.domain_mgr (get ())

(** Sleep for the given number of seconds (EIO-aware, does not block other fibers). *)
let sleep seconds = Eio.Time.sleep (clock ()) seconds

(** Run [f] with a timeout in seconds. Raises on timeout. *)
let with_timeout duration f =
  Eio.Time.with_timeout_exn (clock ()) duration f
