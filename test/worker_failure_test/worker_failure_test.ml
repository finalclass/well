let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then incr pass
  else begin
    incr fail;
    Printf.eprintf "FAIL: %s\n%!" name
  end

let run_concurrently n f =
  let arrived = Atomic.make 0 in
  let go = Atomic.make false in
  let domains =
    Array.init n (fun i ->
      Domain.spawn (fun () ->
        ignore (Atomic.fetch_and_add arrived 1);
        while not (Atomic.get go) do
          Domain.cpu_relax ()
        done;
        f i))
  in
  while Atomic.get arrived < n do
    Domain.cpu_relax ()
  done;
  Atomic.set go true;
  Array.iter Domain.join domains

let raw_of_groups ~width groups =
  let bytes = Bytes.create (List.length groups * width) in
  List.iteri
    (fun i g ->
      for b = 0 to width - 1 do
        Bytes.set bytes ((i * width) + b)
          (Char.chr ((g lsr (8 * (width - 1 - b))) land 255))
      done)
    groups;
  Bytes.to_string bytes

let address index =
  if index mod 2 = 0 then
    let groups =
      [10; (index lsr 16) land 255; (index lsr 8) land 255; index land 255]
    in
    ( String.concat "." (List.map string_of_int groups),
      Eio.Net.Ipaddr.of_raw (raw_of_groups ~width:1 groups) )
  else
    let groups =
      [0x2001; 0xdb8; 1; 2; 3; 4; 1 + (index lsr 16); 1 + (index land 0xffff)]
    in
    ( String.concat ":" (List.map (Printf.sprintf "%x") groups),
      Eio.Net.Ipaddr.of_raw (raw_of_groups ~width:2 groups) )

let addresses_format_concurrently () =
  let domains = 8 and per_domain = 4000 in
  let wrong = Atomic.make 0 in
  let raised = Atomic.make 0 in
  let sample = Atomic.make None in
  run_concurrently domains (fun d ->
    for k = 0 to per_domain - 1 do
      let expected, ip = address ((d * per_domain) + k) in
      match Well.ip_of_addr (`Tcp (ip, 443)) with
      | text when text = expected -> ()
      | text ->
          Atomic.incr wrong;
          ignore
            (Atomic.compare_and_set sample None
               (Some (Printf.sprintf "%S for %s" text expected)))
      | exception exn ->
          Atomic.incr raised;
          ignore
            (Atomic.compare_and_set sample None
               (Some (Printexc.to_string exn)))
    done);
  Option.iter
    (fun s -> Printf.eprintf "first wrong address: %s\n%!" s)
    (Atomic.get sample);
  check "address formatting never raises across domains" (Atomic.get raised = 0);
  check "every domain gets the address it formatted" (Atomic.get wrong = 0);
  check "a non-TCP address is unknown" (Well.ip_of_addr (`Unix "x") = "unknown")

let connect port =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  try
    Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
    Unix.setsockopt_float socket Unix.SO_RCVTIMEO 10.0;
    Some socket
  with Unix.Unix_error _ ->
    Unix.close socket;
    None

let free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | _ -> failwith "no port"
  in
  Unix.close socket;
  port

let start server =
  let directory = Filename.temp_dir "well-worker-failure" "" in
  Unix.chdir directory;
  let port = free_port () in
  let log = Unix.openfile "server.log" [O_CREAT; O_WRONLY; O_TRUNC] 0o644 in
  let pid =
    Unix.create_process server [| server; string_of_int port |] Unix.stdin
      log log
  in
  Unix.close log;
  let deadline = Unix.gettimeofday () +. 30.0 in
  let rec await () =
    match connect port with
    | Some socket -> Unix.close socket
    | None when Unix.gettimeofday () < deadline ->
        Unix.sleepf 0.05;
        await ()
    | None -> failwith "server did not start"
  in
  await ();
  Unix.sleepf 0.3;
  (pid, port)

type ending = Closed of string | Hung

let read_until_closed socket =
  let buffer = Buffer.create 256 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match Unix.read socket chunk 0 (Bytes.length chunk) with
    | 0 -> Closed (Buffer.contents buffer)
    | n ->
        Buffer.add_subbytes buffer chunk 0 n;
        loop ()
    | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> Hung
    | exception Unix.Unix_error _ -> Closed (Buffer.contents buffer)
  in
  let ending = loop () in
  Unix.close socket;
  ending

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let abandoned_handshake port =
  let socket = Option.get (connect port) in
  Unix.shutdown socket Unix.SHUTDOWN_SEND;
  read_until_closed socket

let failing_worker_closes_the_connection server =
  let pid, port = start server in
  let started = Unix.gettimeofday () in
  let endings = List.init 3 (fun _ -> abandoned_handshake port) in
  check "a connection whose worker fails is closed"
    (List.for_all (function Closed _ -> true | Hung -> false) endings);
  check "the failing connections are closed promptly"
    (Unix.gettimeofday () -. started < 5.0);
  let after = abandoned_handshake port in
  check "failed connections release their per-IP slot"
    (match after with
     | Closed reply -> not (starts_with ~prefix:"HTTP/1.1 503" reply)
     | Hung -> false);
  Unix.kill pid Sys.sigterm;
  ignore (Unix.waitpid [] pid);
  if !fail > 0 then begin
    let channel = open_in_bin "server.log" in
    prerr_string (In_channel.input_all channel);
    close_in channel;
    (match after with
     | Closed reply -> Printf.eprintf "reply after failures: %S\n%!" reply
     | Hung -> prerr_endline "reply after failures: none")
  end

let () =
  let server =
    let path = Sys.argv.(1) in
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
    else path
  in
  addresses_format_concurrently ();
  failing_worker_closes_the_connection server;
  Printf.printf "worker failure tests: %d passed, %d failed\n%!" !pass !fail;
  exit (if !fail > 0 then 1 else 0)
