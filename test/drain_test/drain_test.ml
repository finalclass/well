let pass = ref 0
let fail = ref 0

let check name cond =
  if cond then incr pass
  else begin
    incr fail;
    Printf.eprintf "FAIL: %s\n%!" name
  end

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec search i =
    i + n <= h && (String.sub haystack i n = needle || search (i + 1))
  in
  search 0

let connect port =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  try
    Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
    Unix.setsockopt_float socket Unix.SO_RCVTIMEO 20.0;
    Some socket
  with Unix.Unix_error _ ->
    Unix.close socket;
    None

let send socket text =
  ignore (Unix.write_substring socket text 0 (String.length text))

let read_all socket =
  let buffer = Buffer.create 256 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match Unix.read socket chunk 0 (Bytes.length chunk) with
    | 0 -> ()
    | n ->
        Buffer.add_subbytes buffer chunk 0 n;
        loop ()
    | exception Unix.Unix_error _ -> ()
  in
  loop ();
  Unix.close socket;
  Buffer.contents buffer

let request path =
  Printf.sprintf "GET %s HTTP/1.1\r\nHost: localhost\r\n\r\n" path

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

let start server ~timeout =
  let directory = Filename.temp_dir "well-drain" "" in
  Unix.chdir directory;
  let port = free_port () in
  let log = Unix.openfile "server.log" [O_CREAT; O_WRONLY; O_TRUNC] 0o644 in
  let pid =
    Unix.create_process server
      [| server; string_of_int port; string_of_float timeout |]
      Unix.stdin log log
  in
  Unix.close log;
  let deadline = Unix.gettimeofday () +. 20.0 in
  let rec await () =
    match connect port with
    | Some socket -> Unix.close socket
    | None when Unix.gettimeofday () < deadline ->
        Unix.sleepf 0.05;
        await ()
    | None -> failwith "server did not start"
  in
  await ();
  (pid, port, directory)

let stopped pid =
  let started = Unix.gettimeofday () in
  let rec await () =
    match Unix.waitpid [Unix.WNOHANG] pid with
    | 0, _ when Unix.gettimeofday () -. started < 30.0 ->
        Unix.sleepf 0.02;
        await ()
    | 0, _ ->
        Unix.kill pid Sys.sigkill;
        snd (Unix.waitpid [] pid)
    | _, status -> status
  in
  let status = await () in
  (status, Unix.gettimeofday () -. started)

let lines directory wanted =
  let channel = open_in (Filename.concat directory "step.log") in
  let rec count n =
    match input_line channel with
    | line -> count (if line = wanted then n + 1 else n)
    | exception End_of_file -> n
  in
  let n = count 0 in
  close_in channel;
  n

let work_in_progress_finishes server =
  let pid, port, directory = start server ~timeout:20.0 in
  let idle = Option.get (connect port) in
  let slow = Option.get (connect port) in
  send slow (request "/slow/1.0");
  Unix.sleepf 0.3;
  Unix.kill pid Sys.sigterm;
  Unix.sleepf 0.4;
  check "a stopping server refuses new connections" (connect port = None);
  let response = read_all slow in
  check "a request in progress is answered"
    (contains ~needle:"200 OK" response && contains ~needle:"done" response);
  check "the answer closes the connection"
    (contains ~needle:"connection: close" (String.lowercase_ascii response));
  let status, seconds = stopped pid in
  Unix.close idle;
  check "the server exits cleanly" (status = Unix.WEXITED 0);
  check "an idle connection does not delay the exit" (seconds < 5.0);
  let started = lines directory "start" and finished = lines directory "end" in
  check "periodic work ran" (started > 0);
  check "no periodic step was cut" (started = finished);
  check "no periodic step started after the signal"
    (lines directory "late" = 0)

let drain_gives_up_after_the_timeout server =
  let pid, port, _ = start server ~timeout:0.5 in
  let slow = Option.get (connect port) in
  send slow (request "/slow/30.0");
  Unix.sleepf 0.3;
  Unix.kill pid Sys.sigterm;
  let status, seconds = stopped pid in
  Unix.close slow;
  check "a timed out drain exits cleanly" (status = Unix.WEXITED 0);
  check "a timed out drain does not wait for the request" (seconds < 5.0)

let repeated_signal_skips_the_drain server =
  let pid, port, _ = start server ~timeout:60.0 in
  let slow = Option.get (connect port) in
  send slow (request "/slow/30.0");
  Unix.sleepf 0.3;
  Unix.kill pid Sys.sigterm;
  Unix.sleepf 0.5;
  Unix.kill pid Sys.sigterm;
  let status, seconds = stopped pid in
  Unix.close slow;
  check "a forced stop exits cleanly" (status = Unix.WEXITED 0);
  check "a forced stop does not wait for the request" (seconds < 5.0)

let () =
  let server =
    let path = Sys.argv.(1) in
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
    else path
  in
  work_in_progress_finishes server;
  drain_gives_up_after_the_timeout server;
  repeated_signal_skips_the_drain server;
  Printf.printf "drain tests: %d passed, %d failed\n%!" !pass !fail;
  exit (if !fail > 0 then 1 else 0)
