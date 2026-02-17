(* Cap_hook — Forward references and log buffer for Cap admin panel *)
(* Lives in well.core to avoid circular dependency with well_cap *)

(* ── Cap response type ────────────────────────────────────────────── *)

type cap_response =
  | CRHtml of string
  | CRRedirect of string
  | CRJs of string

(* ── Forward refs (wired by well.ml before init) ─────────────────── *)

let _register_cap_get :
  (string -> (Types.request -> cap_response) -> unit) ref =
  ref (fun _ _ -> ())

let _register_cap_post :
  (string -> (Types.request -> cap_response) -> unit) ref =
  ref (fun _ _ -> ())

let _cap_log_hook :
  (string -> string -> int -> float -> unit) option ref = ref None

(* Cap init — filled by well_cap at module load time *)
let _cap_init : (unit -> unit) ref = ref (fun () -> ())

(* ── Cap password ────────────────────────────────────────────────── *)

let cap_password = ref ""

(* ── Log ring buffer ─────────────────────────────────────────────── *)

module Log_buffer = struct
  type entry = {
    id : int;
    meth : string;
    path : string;
    status : int;
    duration_ms : float;
    timestamp : float;
  }

  let max_size = 1000
  let buffer : entry array = Array.make max_size
    { id = 0; meth = ""; path = ""; status = 0;
      duration_ms = 0.0; timestamp = 0.0 }
  let head = ref 0
  let count = ref 0
  let next_id = ref 0
  let mu = Mutex.create ()

  (* Subscribers: id -> callback *)
  let subscribers : (int, entry -> unit) Hashtbl.t = Hashtbl.create 4
  let next_sub_id = ref 0

  let push ~meth ~path ~status ~duration_ms =
    Mutex.lock mu;
    let id = incr next_id; !next_id in
    let entry = { id; meth; path; status; duration_ms;
                  timestamp = Unix.gettimeofday () } in
    buffer.(!head) <- entry;
    head := (!head + 1) mod max_size;
    if !count < max_size then incr count;
    let subs = Hashtbl.fold (fun _ cb acc -> cb :: acc) subscribers [] in
    Mutex.unlock mu;
    (* Notify outside lock *)
    List.iter (fun cb -> (try cb entry with _ -> ())) subs

  let recent n =
    Mutex.lock mu;
    let n = min n !count in
    let result = ref [] in
    for i = 0 to n - 1 do
      let idx = ((!head - 1 - i) + max_size) mod max_size in
      result := buffer.(idx) :: !result
    done;
    Mutex.unlock mu;
    !result

  let subscribe cb =
    Mutex.lock mu;
    let id = incr next_sub_id; !next_sub_id in
    Hashtbl.replace subscribers id cb;
    Mutex.unlock mu;
    id

  let unsubscribe id =
    Mutex.lock mu;
    Hashtbl.remove subscribers id;
    Mutex.unlock mu
end
