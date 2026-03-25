(* cdp.ml — Chrome DevTools Protocol client for e2e testing *)

exception Timeout
exception Chrome_not_found
exception Cdp_error of string
exception Element_not_found of string

(* ── Types ────────────────────────────────────────────── *)

type browser = {
  pid : int;
  port : int;
  user_data_dir : string;
}

type t = {
  browser : browser;
  ic : in_channel;
  oc : out_channel;
  mutable next_id : int;
  mutable closed : bool;
  target_id : string;
}

(* ── Private helpers ──────────────────────────────────── *)
open struct

  let js_str s = Yojson.Safe.to_string (`String s)

  (* ── Simple HTTP GET (localhost only) ──── *)

  let http_get port path =
    let addr = Unix.ADDR_INET (Unix.inet_addr_loopback, port) in
    let ic, oc = Unix.open_connection addr in
    Printf.fprintf oc "GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n\r\n" path port;
    flush oc;
    let _ = input_line ic in (* status *)
    let rec skip_headers () =
      if String.trim (input_line ic) <> "" then skip_headers ()
    in
    skip_headers ();
    let buf = Buffer.create 4096 in
    (try while true do Buffer.add_char buf (input_char ic) done
     with End_of_file -> ());
    close_in_noerr ic;
    Buffer.contents buf

  (* ── WebSocket client (RFC 6455, client-side masking) ──── *)

  let ws_connect port path =
    let addr = Unix.ADDR_INET (Unix.inet_addr_loopback, port) in
    let ic, oc = Unix.open_connection addr in
    let key_bytes = Bytes.create 16 in
    for i = 0 to 15 do Bytes.set key_bytes i (Char.chr (Random.int 256)) done;
    let key = Base64.encode_exn (Bytes.to_string key_bytes) in
    Printf.fprintf oc
      "GET %s HTTP/1.1\r\n\
       Host: 127.0.0.1:%d\r\n\
       Upgrade: websocket\r\n\
       Connection: Upgrade\r\n\
       Sec-WebSocket-Key: %s\r\n\
       Sec-WebSocket-Version: 13\r\n\r\n"
      path port key;
    flush oc;
    let status = input_line ic in
    let status_trimmed = String.trim status in
    if String.length status_trimmed < 12
       || String.sub status_trimmed 9 3 <> "101" then
      raise (Cdp_error ("WebSocket upgrade failed: " ^ status_trimmed));
    let rec skip () =
      if String.trim (input_line ic) <> "" then skip ()
    in
    skip ();
    (ic, oc)

  let ws_send oc payload =
    let len = String.length payload in
    output_byte oc (0x80 lor 1); (* FIN + Text *)
    if len < 126 then
      output_byte oc (0x80 lor len)
    else if len < 65536 then begin
      output_byte oc (0x80 lor 126);
      output_byte oc ((len lsr 8) land 0xFF);
      output_byte oc (len land 0xFF)
    end else begin
      output_byte oc (0x80 lor 127);
      for i = 7 downto 0 do
        output_byte oc ((len lsr (i * 8)) land 0xFF)
      done
    end;
    let mask = Array.init 4 (fun _ -> Random.int 256) in
    Array.iter (output_byte oc) mask;
    String.iteri (fun i c ->
      output_byte oc (Char.code c lxor mask.(i mod 4))
    ) payload;
    flush oc

  let ws_recv ic =
    let first = input_byte ic in
    let _fin = first land 0x80 <> 0 in
    let opcode = first land 0x0F in
    let second = input_byte ic in
    let masked = second land 0x80 <> 0 in
    let len = second land 0x7F in
    let len =
      if len = 126 then
        (input_byte ic lsl 8) lor input_byte ic
      else if len = 127 then
        let n = ref 0 in
        for _ = 0 to 7 do n := (!n lsl 8) lor input_byte ic done;
        !n
      else len
    in
    let mask_key =
      if masked then begin
        let m = Bytes.create 4 in
        really_input ic m 0 4;
        Some m
      end else None
    in
    let data = Bytes.create len in
    really_input ic data 0 len;
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
    ws_send t.oc (Yojson.Safe.to_string msg);
    let rec loop () =
      let opcode, payload = ws_recv t.ic in
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
        ws_send t.oc payload; (* Pong *)
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
  let pid = Unix.create_process chrome args Unix.stdin Unix.stdout stderr_w in
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
  let target = match targets with
    | `List (t :: _) -> t
    | _ -> raise (Cdp_error "no targets found")
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
  let ic, oc = ws_connect port ws_path in
  let browser = { pid; port; user_data_dir } in
  let t = { browser; ic; oc; next_id = 1; closed = false; target_id } in
  ignore (send t "Page.enable" (`Assoc []));
  ignore (send t "Runtime.enable" (`Assoc []));
  t

let close t =
  if not t.closed then begin
    t.closed <- true;
    (try ignore (send t "Browser.close" (`Assoc [])) with _ -> ());
    close_out_noerr t.oc;
    close_in_noerr t.ic;
    (try Unix.kill t.browser.pid Sys.sigterm with _ -> ());
    (try ignore (Unix.waitpid [] t.browser.pid) with _ -> ());
    (try rm_rf t.browser.user_data_dir with _ -> ())
  end

let new_tab t =
  let result = send t "Target.createTarget"
    (`Assoc [("url", `String "about:blank")]) in
  let target_id =
    Yojson.Safe.Util.(member "targetId" result |> to_string)
  in
  let ws_path = Printf.sprintf "/devtools/page/%s" target_id in
  let ic, oc = ws_connect t.browser.port ws_path in
  let tab = {
    browser = t.browser; ic; oc;
    next_id = 1; closed = false; target_id;
  } in
  ignore (send tab "Page.enable" (`Assoc []));
  ignore (send tab "Runtime.enable" (`Assoc []));
  tab

let goto t url =
  let result = send t "Page.navigate" (`Assoc [("url", `String url)]) in
  (match Yojson.Safe.Util.member "errorText" result with
   | `String err ->
     raise (Cdp_error (Printf.sprintf "navigation error: %s" err))
   | _ -> ());
  Unix.sleepf 0.05;
  let rec wait n =
    if n > 200 then raise Timeout; (* 200 * 50ms = 10s *)
    match eval t "document.readyState" with
    | `String "complete" -> ()
    | _ -> Unix.sleepf 0.05; wait (n + 1)
  in
  wait 0

let get_url t =
  match eval t "window.location.href" with
  | `String url -> url
  | _ -> ""

let wait_for_text ?(timeout = 10.0) t text =
  let deadline = Unix.gettimeofday () +. timeout in
  let js = Printf.sprintf
    "document.body && document.body.innerText.includes(%s)" (js_str text) in
  let rec loop () =
    if Unix.gettimeofday () >= deadline then
      raise (Cdp_error (Printf.sprintf "timeout waiting for text: %s" text));
    match eval t js with
    | `Bool true -> ()
    | _ -> Unix.sleepf 0.1; loop ()
  in
  loop ()

let wait_for_selector ?(timeout = 10.0) t selector =
  let deadline = Unix.gettimeofday () +. timeout in
  let js = Printf.sprintf "!!document.querySelector(%s)" (js_str selector) in
  let rec loop () =
    if Unix.gettimeofday () >= deadline then
      raise (Cdp_error (Printf.sprintf "timeout waiting for: %s" selector));
    match eval t js with
    | `Bool true -> ()
    | _ -> Unix.sleepf 0.1; loop ()
  in
  loop ()

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

let clear_cookies t =
  ignore (send t "Network.clearBrowserCookies" (`Assoc []))

let eval_js t js = eval t js

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
