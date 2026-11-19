let stopping = Atomic.make false
let forced = Atomic.make false
let sealed = Atomic.make false
let held = Atomic.make 0
let timeout = ref 20.0
let settle = 0.2
let poll = 0.02

let requested () = Atomic.get stopping

let request () =
  if Atomic.exchange stopping true then begin
    Atomic.set forced true;
    false
  end else true

let release () = Atomic.decr held

let hold f =
  Atomic.incr held;
  Fun.protect ~finally:release f

let unless refused f =
  Atomic.incr held;
  if Atomic.get refused then begin
    release ();
    None
  end else Some (Fun.protect ~finally:release f)

let admit f = unless stopping f
let enter f = unless sealed f

type outcome =
  | Drained of float
  | Forced of int
  | Timed_out of int

let wait ~sleep ~now () =
  let started = now () in
  let deadline = started +. !timeout in
  let settled = started +. Float.min settle !timeout in
  let seal () =
    Atomic.set sealed true;
    Atomic.get held
  in
  let rec loop () =
    let at = now () in
    if Atomic.get forced || at >= deadline then
      match seal () with
      | 0 -> Drained (at -. started)
      | in_flight when Atomic.get forced -> Forced in_flight
      | in_flight -> Timed_out in_flight
    else if at >= settled && Atomic.get held = 0 && seal () = 0 then
      Drained (at -. started)
    else begin
      sleep (Float.min poll (deadline -. at));
      loop ()
    end
  in
  loop ()
