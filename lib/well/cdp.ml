(** Chrome DevTools Protocol client for end-to-end browser testing.
    Launches headless Chrome, connects via CDP WebSocket, and provides a high-level API. *)

(** Raised when a CDP operation exceeds its timeout. *)
exception Timeout

(** Raised when no Chrome/Chromium binary is found on the system. *)
exception Chrome_not_found

(** Raised on CDP protocol errors (failed commands, connection issues). *)
exception Cdp_error of string

(** Raised when a click or fill target element cannot be found on the page. *)
exception Element_not_found of string

(* ── Types ────────────────────────────────────────────── *)

(** Handle to a launched Chrome process. *)
type browser = {
  pid : int;
  port : int;
  user_data_dir : string;
}

(** A CDP session connected to a browser tab via WebSocket. *)
type t = {
  browser : browser;
  mutable fd : Unix.file_descr;
  mutable next_id : int;
  mutable closed : bool;
  target_id : string;
}

(* ── Private helpers ──────────────────────────────────── *)
open struct

  let js_str s = Yojson.Safe.to_string (`String s)

  let debug = try ignore (Sys.getenv "CDP_DEBUG"); true with Not_found -> false

  (* ── Simple HTTP GET (localhost only) ──── *)

  let http_get port path =
    let addr = Unix.ADDR_INET (Unix.inet_addr_loopback, port) in
    let ic, oc = Unix.open_connection addr in
    Printf.fprintf oc "GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n\r\n" path port;
    flush oc;
    let _ = input_line ic in (* status *)
    let content_length = ref (-1) in
    let rec read_headers () =
      let line = String.trim (input_line ic) in
      if line <> "" then begin
        (let prefix = "content-length:" in
         let llow = String.lowercase_ascii line in
         let plen = String.length prefix in
         if String.length llow >= plen && String.sub llow 0 plen = prefix then
           content_length := int_of_string (String.trim (String.sub line plen (String.length line - plen))));
        read_headers ()
      end
    in
    read_headers ();
    let buf = Buffer.create 4096 in
    if !content_length >= 0 then begin
      let bytes = Bytes.create !content_length in
      really_input ic bytes 0 !content_length;
      Buffer.add_bytes buf bytes
    end else
      (try while true do Buffer.add_char buf (input_char ic) done
       with End_of_file -> ());
    close_in_noerr ic;
    Buffer.contents buf

  (* ── Buffered socket reader ──── *)

  (* Socket read buffer — accumulates data from large Unix.read calls *)
  type read_buf = {
    buf : bytes;
    mutable pos : int;     (* read position *)
    mutable len : int;     (* valid data end *)
    sock : Unix.file_descr;
  }

  let make_read_buf fd = {
    buf = Bytes.create 65536;
    pos = 0; len = 0; sock = fd;
  }

  (* Global read buffer — reassigned on reconnect *)
  let rbuf = ref (make_read_buf Unix.stdin)

  let ws_frame_timeout = ref 30.0

  let rbuf_available rb = rb.len - rb.pos

  (* Fill the buffer with more data from the socket *)
  let rbuf_fill rb =
    (* Compact if needed *)
    if rb.pos > 0 then begin
      let avail = rbuf_available rb in
      if avail > 0 then
        Bytes.blit rb.buf rb.pos rb.buf 0 avail;
      rb.pos <- 0;
      rb.len <- avail
    end;
    match Unix.select [rb.sock] [] [] !ws_frame_timeout with
    | _ :: _, _, _ ->
      let space = Bytes.length rb.buf - rb.len in
      let got = Unix.read rb.sock rb.buf rb.len space in
      if got = 0 then raise (Cdp_error "WebSocket connection closed");
      rb.len <- rb.len + got;
      got
    | _ -> raise Timeout

  (* Read exactly n bytes from the buffer, filling from socket as needed *)
  let rbuf_read rb n =
    let result = Bytes.create n in
    let rec loop off remaining =
      if remaining = 0 then result
      else begin
        let avail = rbuf_available rb in
        if avail > 0 then begin
          let take = min avail remaining in
          Bytes.blit rb.buf rb.pos result off take;
          rb.pos <- rb.pos + take;
          loop (off + take) (remaining - take)
        end else begin
          ignore (rbuf_fill rb);
          loop off remaining
        end
      end
    in
    loop 0 n

  let rbuf_read_byte rb =
    Char.code (Bytes.get (rbuf_read rb 1) 0)

  (** Check if data is available (buffered or on socket) *)
  let ws_has_data_buf rb timeout =
    if rbuf_available rb > 0 then true
    else match Unix.select [rb.sock] [] [] timeout with
      | _ :: _, _, _ -> true
      | _ -> false

  let raw_read_line _fd =
    let rb = !rbuf in
    let buf = Buffer.create 256 in
    let rec loop () =
      let c = Char.chr (rbuf_read_byte rb) in
      if c = '\n' then Buffer.contents buf
      else if c = '\r' then loop ()
      else (Buffer.add_char buf c; loop ())
    in
    loop ()

  (* ── WebSocket client (RFC 6455, client-side masking) ──── *)

  let raw_write_all fd data =
    let len = String.length data in
    let buf = Bytes.of_string data in
    let rec loop off remaining =
      if remaining > 0 then begin
        let n = Unix.write fd buf off remaining in
        loop (off + n) (remaining - n)
      end
    in
    loop 0 len

  let ws_connect port path =
    let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.connect fd (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
    let key_bytes = Bytes.create 16 in
    for i = 0 to 15 do Bytes.set key_bytes i (Char.chr (Random.int 256)) done;
    let key = Base64.encode_exn (Bytes.to_string key_bytes) in
    let req = Printf.sprintf
      "GET %s HTTP/1.1\r\n\
       Host: 127.0.0.1:%d\r\n\
       Upgrade: websocket\r\n\
       Connection: Upgrade\r\n\
       Sec-WebSocket-Key: %s\r\n\
       Sec-WebSocket-Version: 13\r\n\r\n"
      path port key in
    raw_write_all fd req;
    let status = raw_read_line fd in
    if String.length status < 12
       || String.sub status 9 3 <> "101" then
      raise (Cdp_error ("WebSocket upgrade failed: " ^ status));
    rbuf := make_read_buf fd;
    let rec skip () =
      let line = raw_read_line fd in
      if line <> "" then skip ()
    in
    skip ();
    fd

  let ws_send fd payload =
    let len = String.length payload in
    (* Build frame in a buffer to send atomically *)
    let buf = Buffer.create (len + 14) in
    Buffer.add_char buf (Char.chr (0x80 lor 1)); (* FIN + Text *)
    if len < 126 then
      Buffer.add_char buf (Char.chr (0x80 lor len))
    else if len < 65536 then begin
      Buffer.add_char buf (Char.chr (0x80 lor 126));
      Buffer.add_char buf (Char.chr ((len lsr 8) land 0xFF));
      Buffer.add_char buf (Char.chr (len land 0xFF))
    end else begin
      Buffer.add_char buf (Char.chr (0x80 lor 127));
      for i = 7 downto 0 do
        Buffer.add_char buf (Char.chr ((len lsr (i * 8)) land 0xFF))
      done
    end;
    let mask = Array.init 4 (fun _ -> Random.int 256) in
    Array.iter (fun m -> Buffer.add_char buf (Char.chr m)) mask;
    String.iteri (fun i c ->
      Buffer.add_char buf (Char.chr (Char.code c lxor mask.(i mod 4)))
    ) payload;
    raw_write_all fd (Buffer.contents buf)

  let ws_recv _fd =
    let rb = !rbuf in
    if debug then Printf.eprintf "[CDP ws_recv] reading first byte...\n%!";
    let first = rbuf_read_byte rb in
    if debug then Printf.eprintf "[CDP ws_recv] first=0x%02x\n%!" first;
    let _fin = first land 0x80 <> 0 in
    let opcode = first land 0x0F in
    let second = rbuf_read_byte rb in
    if debug then Printf.eprintf "[CDP ws_recv] second=0x%02x opcode=%d len_indicator=%d\n%!" second opcode (second land 0x7F);
    let masked = second land 0x80 <> 0 in
    let len = second land 0x7F in
    let len =
      if len = 126 then
        (rbuf_read_byte rb lsl 8) lor rbuf_read_byte rb
      else if len = 127 then
        let n = ref 0 in
        for _ = 0 to 7 do n := (!n lsl 8) lor rbuf_read_byte rb done;
        !n
      else len
    in
    let mask_key =
      if masked then Some (rbuf_read rb 4) else None
    in
    let data = rbuf_read rb len in
    (match mask_key with
     | Some key ->
       for i = 0 to len - 1 do
         Bytes.set data i
           (Char.chr (Char.code (Bytes.get data i)
                      lxor Char.code (Bytes.get key (i mod 4))))
       done
     | None -> ());
    (opcode, Bytes.to_string data)

  (* ── CDP command/response ──── *)

  let send t meth params =
    let id = t.next_id in
    t.next_id <- t.next_id + 1;
    let msg = `Assoc [
      ("id", `Int id);
      ("method", `String meth);
      ("params", params);
    ] in
    if debug then Printf.eprintf "[CDP] send id=%d method=%s\n%!" id meth;
    ws_send t.fd (Yojson.Safe.to_string msg);
    let rec loop () =
      let opcode, payload = ws_recv t.fd in
      if debug then begin
        let preview = if String.length payload > 200
          then String.sub payload 0 200 ^ "..." else payload in
        Printf.eprintf "[CDP] recv opcode=%d payload=%s\n%!" opcode preview
      end;
      match opcode with
      | 1 (* Text *) ->
        let json = Yojson.Safe.from_string payload in
        (match Yojson.Safe.Util.member "id" json with
         | `Int rid when rid = id ->
           (match Yojson.Safe.Util.member "error" json with
            | `Null -> Yojson.Safe.Util.member "result" json
            | err ->
              let msg =
                try Yojson.Safe.Util.(member "message" err |> to_string)
                with _ -> Yojson.Safe.to_string err
              in
              raise (Cdp_error msg))
         | _ -> loop ()) (* skip events and other responses *)
      | 8 (* Close *) ->
        t.closed <- true;
        raise (Cdp_error "WebSocket closed by Chrome")
      | 9 (* Ping *) ->
        ws_send t.fd payload; (* Pong *)
        loop ()
      | _ -> loop ()
    in
    loop ()

  let eval t js =
    let result = send t "Runtime.evaluate"
      (`Assoc [("expression", `String js);
               ("returnByValue", `Bool true)]) in
    Yojson.Safe.Util.(member "result" result |> member "value")

  (* ── Chrome process management ──── *)

  let find_chrome () =
    let candidates = [
      "chromium"; "chromium-browser";
      "google-chrome"; "google-chrome-stable";
    ] in
    match List.find_opt (fun cmd ->
      Sys.command (Printf.sprintf "which %s >/dev/null 2>&1"
        (Filename.quote cmd)) = 0
    ) candidates with
    | Some cmd -> cmd
    | None -> raise Chrome_not_found

  let read_line_with_timeout fd timeout =
    let buf = Buffer.create 256 in
    let deadline = Unix.gettimeofday () +. timeout in
    let b = Bytes.create 1 in
    let rec loop () =
      let remaining = deadline -. Unix.gettimeofday () in
      if remaining <= 0.0 then raise Timeout;
      match Unix.select [fd] [] [] (min remaining 0.5) with
      | _ :: _, _, _ ->
        let n = Unix.read fd b 0 1 in
        if n = 0 then Buffer.contents buf
        else if Bytes.get b 0 = '\n' then Buffer.contents buf
        else (Buffer.add_char buf (Bytes.get b 0); loop ())
      | _ -> loop ()
    in
    loop ()

  let extract_port_from_devtools_line line =
    let prefix = "DevTools listening on ws://127.0.0.1:" in
    let plen = String.length prefix in
    let rec find_prefix i =
      if i + plen > String.length line then None
      else if String.sub line i plen = prefix then
        let rest = String.sub line (i + plen) (String.length line - i - plen) in
        let port_str =
          match String.index_opt rest '/' with
          | Some j -> String.sub rest 0 j
          | None -> rest
        in
        (try Some (int_of_string (String.trim port_str))
         with _ -> None)
      else find_prefix (i + 1)
    in
    find_prefix 0

  let rec rm_rf path =
    if Sys.is_directory path then begin
      Array.iter (fun entry ->
        rm_rf (Filename.concat path entry)
      ) (Sys.readdir path);
      Unix.rmdir path
    end else
      Sys.remove path

end

(* ── Public API ───────────────────────────────────────── *)

(** Launch Chrome and connect via CDP. Returns a session for the initial tab. *)
let launch ?(headless = true) () =
  Random.self_init ();
  let chrome = find_chrome () in
  let user_data_dir = Filename.temp_dir "well_cdp_" "" in
  let args = Array.of_list ([chrome]
    @ (if headless then ["--headless=new"] else [])
    @ [
      "--no-sandbox"; "--disable-gpu"; "--disable-dev-shm-usage";
      "--disable-background-networking"; "--disable-extensions";
      "--no-first-run"; "--no-default-browser-check";
      Printf.sprintf "--user-data-dir=%s" user_data_dir;
      "--remote-debugging-port=0";
      "about:blank";
    ]) in
  let stderr_r, stderr_w = Unix.pipe () in
  let dev_null = Unix.openfile "/dev/null" [Unix.O_RDWR] 0 in
  let pid = Unix.create_process chrome args dev_null dev_null stderr_w in
  Unix.close dev_null;
  Unix.close stderr_w;
  (* Parse "DevTools listening on ws://127.0.0.1:PORT/..." from stderr *)
  let port =
    let rec try_lines n =
      if n > 50 then
        raise (Cdp_error "could not find DevTools URL in Chrome stderr");
      let line = read_line_with_timeout stderr_r 15.0 in
      match extract_port_from_devtools_line line with
      | Some p -> p
      | None -> try_lines (n + 1)
    in
    try_lines 0
  in
  Unix.close stderr_r;
  (* Give Chrome a moment to initialize *)
  Unix.sleepf 0.2;
  (* Get first target *)
  let json_str = http_get port "/json" in
  let targets = Yojson.Safe.from_string json_str in
  let target =
    let target_list = match targets with
      | `List l -> l
      | _ -> raise (Cdp_error "no targets found")
    in
    (* Prefer "page" type targets over extension background pages *)
    match List.find_opt (fun t ->
      match Yojson.Safe.Util.member "type" t with
      | `String "page" -> true | _ -> false
    ) target_list with
    | Some t -> t
    | None -> match target_list with
      | t :: _ -> t
      | [] -> raise (Cdp_error "no targets found")
  in
  let ws_url =
    Yojson.Safe.Util.(member "webSocketDebuggerUrl" target |> to_string)
  in
  (* Extract path from ws://127.0.0.1:PORT/path *)
  let ws_path =
    let s = ws_url in
    let i1 = String.index s '/' in
    let i2 = String.index_from s (i1 + 2) '/' in
    String.sub s i2 (String.length s - i2)
  in
  let target_id =
    Yojson.Safe.Util.(member "id" target |> to_string)
  in
  let fd = ws_connect port ws_path in
  let browser = { pid; port; user_data_dir } in
  let t = { browser; fd; next_id = 1; closed = false; target_id } in
  ignore (send t "Page.enable" (`Assoc []));
  t

(** Close the browser, kill the process, and clean up the temp directory. *)
let close t =
  if not t.closed then begin
    t.closed <- true;
    (try ignore (send t "Browser.close" (`Assoc [])) with _ -> ());
    (try Unix.close t.fd with _ -> ());
    (try Unix.kill t.browser.pid Sys.sigterm with _ -> ());
    (try ignore (Unix.waitpid [] t.browser.pid) with _ -> ());
    (try rm_rf t.browser.user_data_dir with _ -> ())
  end

(** Open a new browser tab and return a CDP session for it. *)
let new_tab t =
  let result = send t "Target.createTarget"
    (`Assoc [("url", `String "about:blank")]) in
  let target_id =
    Yojson.Safe.Util.(member "targetId" result |> to_string)
  in
  let ws_path = Printf.sprintf "/devtools/page/%s" target_id in
  let fd = ws_connect t.browser.port ws_path in
  let tab = {
    browser = t.browser; fd;
    next_id = 1; closed = false; target_id;
  } in
  ignore (send tab "Page.enable" (`Assoc []));
  tab

(** Try to evaluate JS with a short timeout. Returns None if Chrome is
    unresponsive (e.g. during page navigation). Safe: never corrupts the
    WebSocket stream (only times out between frames, not mid-frame). *)
let try_eval ?(timeout = 2.0) t js =
  let id = t.next_id in
  t.next_id <- t.next_id + 1;
  let msg = `Assoc [
    ("id", `Int id);
    ("method", `String "Runtime.evaluate");
    ("params", `Assoc [("expression", `String js);
                        ("returnByValue", `Bool true)]);
  ] in
  if debug then Printf.eprintf "[CDP try_eval] send id=%d\n%!" id;
  ws_send t.fd (Yojson.Safe.to_string msg);
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    let remaining = deadline -. Unix.gettimeofday () in
    if remaining <= 0.0 then (
      if debug then Printf.eprintf "[CDP try_eval] deadline expired\n%!";
      None)
    else if ws_has_data_buf !rbuf (min remaining 0.5) then begin
      ws_frame_timeout := 30.0;
      let result =
        try
          let opcode, payload = ws_recv t.fd in
          if debug then begin
            let preview = if String.length payload > 120
              then String.sub payload 0 120 ^ "..." else payload in
            Printf.eprintf "[CDP try_eval] frame opcode=%d payload=%s\n%!" opcode preview
          end;
          match opcode with
          | 1 ->
            let json = Yojson.Safe.from_string payload in
            (match Yojson.Safe.Util.member "id" json with
             | `Int rid when rid = id ->
               (match Yojson.Safe.Util.member "error" json with
                | `Null ->
                  let r = Yojson.Safe.Util.member "result" json in
                  `Done (Some Yojson.Safe.Util.(member "result" r |> member "value"))
                | _ -> `Done None)
             | _ -> `Continue)
          | 8 -> t.closed <- true; `Done None
          | _ -> `Continue
        with exn ->
          ws_frame_timeout := 30.0;
          if debug then Printf.eprintf "[CDP try_eval] frame read error: %s\n%!" (Printexc.to_string exn);
          `Done None
      in
      match result with
      | `Done v -> v
      | `Continue -> loop ()
    end
    else (
      if debug then Printf.eprintf "[CDP try_eval] no data (remaining=%.1f)\n%!" remaining;
      loop ())
  in
  loop ()

(** Reconnect the WebSocket to the same target. Used after page navigation
    which may leave partial frames in the stream. *)
let reconnect t =
  (try Unix.close t.fd with _ -> ());
  let ws_path = Printf.sprintf "/devtools/page/%s" t.target_id in
  t.fd <- ws_connect t.browser.port ws_path;
  rbuf := make_read_buf t.fd

(** Navigate to a URL and wait for the page to fully load. *)
let goto t url =
  (* Fire-and-forget: trigger navigation via JS *)
  let id = t.next_id in
  t.next_id <- t.next_id + 1;
  let js = Printf.sprintf "window.location.href = %s" (js_str url) in
  let msg = `Assoc [
    ("id", `Int id);
    ("method", `String "Runtime.evaluate");
    ("params", `Assoc [("expression", `String js);
                        ("returnByValue", `Bool true)]);
  ] in
  if debug then Printf.eprintf "[CDP] goto: fire-and-forget id=%d\n%!" id;
  ws_send t.fd (Yojson.Safe.to_string msg);
  (* Wait for navigation to start, then reconnect WebSocket
     (Chrome sends partial frames during navigation which corrupt the stream) *)
  Unix.sleepf 0.5;
  let deadline = Unix.gettimeofday () +. 30.0 in
  let rec wait () =
    if Unix.gettimeofday () >= deadline then raise Timeout;
    (* Reconnect to get a clean WebSocket stream *)
    (try reconnect t with _ -> Unix.sleepf 0.5; reconnect t);
    (* Check if page is loaded *)
    match try_eval ~timeout:2.0 t "document.readyState" with
    | Some (`String "complete") -> ()
    | _ -> Unix.sleepf 0.3; wait ()
  in
  wait ()

(** Get the current page URL. *)
let get_url t =
  match eval t "window.location.href" with
  | `String url -> url
  | _ -> ""

(** Wait until the page body contains the given text.
    Resilient to navigation: reconnects WebSocket if stream is corrupted. *)
let wait_for_text ?(timeout = 10.0) t text =
  let deadline = Unix.gettimeofday () +. timeout in
  let js = Printf.sprintf
    "document.body && document.body.innerText.includes(%s)" (js_str text) in
  let fails = ref 0 in
  let rec loop () =
    if Unix.gettimeofday () >= deadline then
      raise (Cdp_error (Printf.sprintf "timeout waiting for text: %s" text));
    match try_eval ~timeout:2.0 t js with
    | Some (`Bool true) -> fails := 0
    | Some _ -> fails := 0; Unix.sleepf 0.1; loop ()
    | None ->
      incr fails;
      if !fails >= 3 then begin
        fails := 0;
        if debug then Printf.eprintf "[CDP] reconnecting after %d try_eval failures\n%!" 3;
        (try reconnect t with _ -> Unix.sleepf 0.5);
      end;
      Unix.sleepf 0.2; loop ()
  in
  loop ()

(** Wait until a CSS selector matches an element on the page.
    Resilient to navigation: reconnects WebSocket if stream is corrupted. *)
let wait_for_selector ?(timeout = 10.0) t selector =
  let deadline = Unix.gettimeofday () +. timeout in
  let js = Printf.sprintf "!!document.querySelector(%s)" (js_str selector) in
  let fails = ref 0 in
  let rec loop () =
    if Unix.gettimeofday () >= deadline then
      raise (Cdp_error (Printf.sprintf "timeout waiting for: %s" selector));
    match try_eval ~timeout:2.0 t js with
    | Some (`Bool true) -> fails := 0
    | Some _ -> fails := 0; Unix.sleepf 0.1; loop ()
    | None ->
      incr fails;
      if !fails >= 3 then begin
        fails := 0;
        if debug then Printf.eprintf "[CDP] reconnecting after %d try_eval failures\n%!" 3;
        (try reconnect t with _ -> Unix.sleepf 0.5);
      end;
      Unix.sleepf 0.2; loop ()
  in
  loop ()

(** Click an element by text content, ARIA role, or CSS selector. *)
let click t ?text ?role ?name ?selector () =
  let js = match text, role, name, selector with
    | Some txt, _, _, _ ->
      Printf.sprintf {|
        (function() {
          var target = %s;
          var els = document.querySelectorAll(
            'button, a, [role="button"], input[type="submit"], ' +
            'input[type="button"], [onclick], [data-lv-click], ' +
            'flt-semantics, [aria-label]');
          for (var el of els) {
            if ((el.innerText || el.value || '').trim() === target ||
                el.getAttribute('aria-label') === target) {
              el.scrollIntoView({block: 'center'});
              el.click();
              return true;
            }
          }
          var walker = document.createTreeWalker(
            document.body, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            if (walker.currentNode.textContent.trim() === target) {
              var parent = walker.currentNode.parentElement;
              parent.scrollIntoView({block: 'center'});
              parent.click();
              return true;
            }
          }
          return false;
        })()
      |} (js_str txt)
    | _, Some r, n_opt, _ ->
      let name_check = match n_opt with
        | Some nm ->
          Printf.sprintf
            {| && (el.getAttribute('aria-label') === %s ||
                   el.innerText.trim() === %s)|}
            (js_str nm) (js_str nm)
        | None -> ""
      in
      Printf.sprintf {|
        (function() {
          var els = document.querySelectorAll('[role=%s]');
          for (var el of els) {
            if (true%s) {
              el.scrollIntoView({block: 'center'});
              el.click();
              return true;
            }
          }
          return false;
        })()
      |} (js_str r) name_check
    | _, _, _, Some sel ->
      Printf.sprintf {|
        (function() {
          var el = document.querySelector(%s);
          if (el) {
            el.scrollIntoView({block: 'center'});
            el.click();
            return true;
          }
          return false;
        })()
      |} (js_str sel)
    | None, None, _, None ->
      raise (Cdp_error "click: provide ~text, ~role, or ~selector")
  in
  match eval t js with
  | `Bool true -> ()
  | _ ->
    let what = match text with
      | Some t -> t
      | None -> (match selector with Some s -> s | None -> "element")
    in
    raise (Element_not_found (Printf.sprintf "click: %s" what))

(** Fill an input field by label text or CSS selector. *)
let fill t ?label ?selector value =
  let js = match label, selector with
    | Some lbl, _ ->
      Printf.sprintf {|
        (function() {
          var target = %s;
          var value = %s;
          var labels = document.querySelectorAll('label');
          for (var lbl of labels) {
            if (lbl.innerText.trim() === target ||
                lbl.textContent.trim() === target) {
              var input = lbl.querySelector('input, textarea, select');
              if (!input && lbl.htmlFor)
                input = document.getElementById(lbl.htmlFor);
              if (input) {
                input.focus();
                input.value = value;
                input.dispatchEvent(new Event('input', {bubbles: true}));
                input.dispatchEvent(new Event('change', {bubbles: true}));
                return true;
              }
            }
          }
          var inputs = document.querySelectorAll('input, textarea');
          for (var input of inputs) {
            if (input.getAttribute('aria-label') === target ||
                input.getAttribute('placeholder') === target) {
              input.focus();
              input.value = value;
              input.dispatchEvent(new Event('input', {bubbles: true}));
              input.dispatchEvent(new Event('change', {bubbles: true}));
              return true;
            }
          }
          return false;
        })()
      |} (js_str lbl) (js_str value)
    | _, Some sel ->
      Printf.sprintf {|
        (function() {
          var el = document.querySelector(%s);
          if (el) {
            el.focus();
            el.value = %s;
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return true;
          }
          return false;
        })()
      |} (js_str sel) (js_str value)
    | None, None ->
      raise (Cdp_error "fill: provide ~label or ~selector")
  in
  match eval t js with
  | `Bool true -> ()
  | _ ->
    let what = match label with
      | Some l -> l | None -> Option.value ~default:"element" selector
    in
    raise (Element_not_found (Printf.sprintf "fill: %s" what))

(** Dump the accessibility tree as a text string of "role: name" lines. *)
let accessibility_tree t =
  let result = send t "Accessibility.getFullAXTree" (`Assoc []) in
  let nodes = Yojson.Safe.Util.(member "nodes" result |> to_list) in
  let buf = Buffer.create 1024 in
  List.iter (fun node ->
    let role =
      try Yojson.Safe.Util.(member "role" node |> member "value" |> to_string)
      with _ -> ""
    in
    let name =
      try Yojson.Safe.Util.(member "name" node |> member "value" |> to_string)
      with _ -> ""
    in
    if role <> "" && role <> "none" && name <> "" then
      Buffer.add_string buf (Printf.sprintf "%s: %s\n" role name)
  ) nodes;
  Buffer.contents buf

(** Set a cookie in the browser. *)
let set_cookie t ~name ~value ?(domain = "") ?(path = "/") () =
  let url =
    if domain = "" then
      match eval t "window.location.href" with
      | `String u -> u | _ -> ""
    else ""
  in
  let params = [
    ("name", `String name);
    ("value", `String value);
    ("path", `String path);
  ] @ (if domain <> "" then [("domain", `String domain)]
       else [("url", `String url)])
  in
  ignore (send t "Network.setCookie" (`Assoc params))

(** Clear all browser cookies. *)
let clear_cookies t =
  ignore (send t "Network.clearBrowserCookies" (`Assoc []))

(** Evaluate arbitrary JavaScript and return the result as JSON. *)
let eval_js t js = eval t js

(** Capture a screenshot as base64 PNG. Optionally saves to disk at [path]. *)
let screenshot t ?(path = "") () =
  let result = send t "Page.captureScreenshot"
    (`Assoc [("format", `String "png")]) in
  let data = Yojson.Safe.Util.(member "data" result |> to_string) in
  if path <> "" then begin
    let decoded = Base64.decode_exn data in
    let oc = open_out_bin path in
    output_string oc decoded;
    close_out oc
  end;
  data
