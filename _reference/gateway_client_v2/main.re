open! Base;
/* Gateway Client v2 - Proof of Concept */
/* Written in Reason with Blossom HTTP framework and JSX */

/* Custom request type with session/user context */
type request = {
  raw: Blossom.Raw.t,
  session: option(string),
  user: option(string),
  set_session_cookie: option(string),
};

let generate_session_id = (): string => {
  let data = Printf.sprintf("%f-%d", Unix.gettimeofday(), Stdlib.Random.bits());
  Digestif.SHA1.to_hex(Digestif.SHA1.digest_string(data));
};

let make_request = (raw: Blossom.Raw.t): request => {
  let cookies = Blossom.Raw.read_cookies(raw);
  switch (List.Assoc.find(cookies, "session_id", ~equal=String.equal)) {
  | Some(sid) => {
      raw,
      session: Some(sid),
      user: Some(sid),
      set_session_cookie: None,
    }
  | None =>
    let sid = generate_session_id();
    {
      raw,
      session: Some(sid),
      user: Some(sid),
      set_session_cookie: Some("session_id=" ++ sid ++ "; Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000"),
    }
  };
};

/* Add Set-Cookie header to response if a new session was created */
let set_cookie = (req: request, body) =>
  Blossom.headers(
    switch (req.set_session_cookie) {
    | Some(cookie) => [("Set-Cookie", cookie)]
    | None => []
    },
    body,
  );

let () = Liveview.register_view("/v2/live/counter", (module Counter));
let counter_render_ssr = Liveview.render_initial((module Counter));

let () = Liveview.register_view("/v2/live/todo", (module Todo));
let todo_render_ssr = Liveview.render_initial((module Todo));

/* CSS styles */
let styles = {|
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; }
  h1 { color: #333; }
  h2 { color: #555; margin-top: 2rem; }
  .container-xs { max-width: 400px; margin: 100px auto; }
  .form { display: flex; flex-direction: column; gap: 16px; }
  input { padding: 8px; font-size: 16px; }
  button { padding: 12px; font-size: 16px; background: #007bff; color: white; border: none; cursor: pointer; border-radius: 4px; }
  button:hover { background: #0056b3; }
  .info { color: #666; font-size: 14px; margin-top: 20px; }
  .card { background: #f5f5f5; padding: 20px; border-radius: 8px; margin: 20px 0; }
  .tech { color: #007bff; font-weight: bold; }
  code { background: #e9e9e9; padding: 2px 6px; border-radius: 4px; }
  .error { color: #dc3545; margin-top: 16px; }

  /* LiveView Counter styles */
  .counter { text-align: center; padding: 2rem; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); border-radius: 12px; color: white; }
  .counter-display { font-size: 4rem; font-weight: bold; margin: 1rem 0; }
  .counter-controls { display: flex; gap: 1rem; justify-content: center; margin: 1rem 0; }
  .counter-btn { padding: 1rem 2rem; font-size: 1.5rem; min-width: 60px; background: rgba(255,255,255,0.2); border: 2px solid white; color: white; }
  .counter-btn:hover { background: rgba(255,255,255,0.3); }
  .counter-btn.secondary { background: transparent; font-size: 1rem; padding: 0.5rem 1rem; }
  .counter-step { font-size: 0.9rem; opacity: 0.8; }

  /* LiveView indicator */
  live-view { display: block; position: relative; }
  live-view::before { content: ''; display: block; height: 3px; background: #28a745; margin-bottom: 1rem; border-radius: 2px; }
  live-view.lv-loading { pointer-events: none; opacity: 0.5; }
  live-view.lv-loading::after { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 3px; background: #007bff; border-radius: 2px; animation: lv-loading-bar 1s ease-in-out infinite; }
  @keyframes lv-loading-bar { 0% { transform: scaleX(0); transform-origin: left; } 50% { transform: scaleX(1); transform-origin: left; } 50.1% { transform-origin: right; } 100% { transform: scaleX(0); transform-origin: right; } }

  /* Todo app styles */
  .todo-app { max-width: 500px; margin: 0 auto; }
  .todo-input-row { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
  .todo-input-row input { flex: 1; padding: 0.75rem; font-size: 1rem; border: 2px solid #ddd; border-radius: 6px; }
  .todo-input-row input:focus { border-color: #007bff; outline: none; }
  .todo-input-row button { padding: 0.75rem 1.5rem; }
  [data-lv-each="todos"] { list-style: none; padding: 0; margin: 0; }
  .todo-item { display: flex; align-items: center; padding: 0.75rem 1rem; border-bottom: 1px solid #eee; gap: 0.75rem; transition: background 0.15s; }
  .todo-item:hover { background: #f8f9fa; }
  .todo-item.done .todo-text { text-decoration: line-through; color: #999; }
  .todo-text { flex: 1; cursor: pointer; font-size: 1rem; }
  .todo-checkbox { cursor: pointer; font-size: 1.1rem; user-select: none; }
  .todo-remove { background: none; border: none; color: #dc3545; font-size: 1.4rem; cursor: pointer; padding: 0 0.5rem; min-width: auto; line-height: 1; }
  .todo-remove:hover { color: #a71d2a; background: none; }
  .todo-edit-form { display: flex; gap: 0.5rem; flex: 1; }
  .todo-edit-input { flex: 1; padding: 0.3rem 0.5rem; font-size: 1rem; border: 2px solid #007bff; border-radius: 4px; outline: none; }
  .todo-edit-save, .todo-edit-cancel { background: none; border: none; font-size: 1.2rem; cursor: pointer; padding: 0 0.3rem; min-width: auto; line-height: 1; }
  .todo-edit-save { color: #28a745; }
  .todo-edit-save:hover { color: #1e7e34; }
  .todo-edit-cancel { color: #6c757d; }
  .todo-edit-cancel:hover { color: #495057; }
  .todo-item.editing { background: #fff8e1; }
  .todo-footer { display: flex; align-items: center; justify-content: space-between; padding: 0.75rem 0; margin-top: 0.5rem; color: #666; font-size: 0.9rem; }
  .clear-btn { background: none; border: 1px solid #dc3545; color: #dc3545; padding: 0.4rem 0.8rem; font-size: 0.85rem; min-width: auto; }
  .clear-btn:hover { background: #dc3545; color: white; }
|};

/* Routes */
module Routes = {
  open Html;

  /* Login page with JSX - returns HTML automatically */
  let login_page = (req: request) =>
    <html>
      <head>
        <title> {txt("Gateway v2 - Login")} </title>
        <style> {txt(styles)} </style>
      </head>
      <body className="container-xs">
        <h1> {txt("Gateway Client v2")} </h1>
        <p className="info">
          {txt("Proof of Concept - Written in Reason with JSX")}
        </p>
        <form method_="post" action="/v2/gateway/login" className="form">
          <input
            type_="email"
            name="email"
            placeholder="Email"
            required=true
          />
          <input
            type_="password"
            name="password"
            placeholder="Hasło"
            required=true
          />
          <button> {txt("Zaloguj")} </button>
        </form>
      </body>
    </html>
    |> set_cookie(req);

  /* Login POST handler */
  let login_post = (req: request) => {
    let reqBody = Blossom.Body.parse_body(req.raw);
    let email = Blossom.Body.get_string(reqBody, "email");
    let password = Blossom.Body.get_string(reqBody, "password");

    if (String.length(email) == 0 || String.length(password) == 0) {
      <html>
        <head>
          <title> {txt("Błąd")} </title>
          <style> {txt(styles)} </style>
        </head>
        <body>
          <h1> {txt("Błąd")} </h1>
          <p> {txt("Email i hasło są wymagane")} </p>
          <a href="/v2/gateway/login"> {txt("Powrót do logowania")} </a>
        </body>
      </html>
      |> Blossom.status(400);
    } else {
      `Assoc
        ([
          ("status", `String("ok")),
          (
            "message",
            `String(
              "Login endpoint called (POC - not connected to Security service)",
            ),
          ),
          ("email", `String(email)),
        ]);
        /* In real implementation, call Security.login here */
    };
  };

  /* Dashboard with JSX - returns HTML automatically */
  let dashboard = (req: request) =>
    <html>
      <head>
        <title> {txt("Gateway v2 - Dashboard")} </title>
        <style> {txt(styles)} </style>
      </head>
      <body>
        <h1> {txt("Gateway Client v2 - Dashboard")} </h1>
        <div className="card">
          <h2> {txt("Tech Stack")} </h2>
          <ul>
            <li>
              <span className="tech"> {txt("Reason")} </span>
              {txt(" - OCaml alternative syntax")}
            </li>
            <li>
              <span className="tech"> {txt("JSX")} </span>
              {txt(" - Built-in Reason JSX support")}
            </li>
            <li>
              <span className="tech"> {txt("Blossom")} </span>
              {txt(" - EIO-based HTTP framework")}
            </li>
            <li>
              <span className="tech"> {txt("EIO")} </span>
              {txt(" - Effect-based concurrency")}
            </li>
          </ul>
        </div>
        <div className="card">
          <h2> {txt("Endpoints")} </h2>
          <ul>
            <li>
              <code> {txt("GET /v2/health")} </code>
              {txt(" - Health check (JSON)")}
            </li>
            <li>
              <code> {txt("GET /v2/gateway/login")} </code>
              {txt(" - Login page")}
            </li>
            <li>
              <code> {txt("POST /v2/gateway/login")} </code>
              {txt(" - Login handler")}
            </li>
            <li>
              <code> {txt("GET /v2")} </code>
              {txt(" - This dashboard")}
            </li>
            <li>
              <code>
                <a href="/v2/liveview"> {txt("GET /v2/liveview")} </a>
              </code>
              {txt(" - LiveView demo")}
            </li>
            <li>
              <code>
                <a href="/v2/todo"> {txt("GET /v2/todo")} </a>
              </code>
              {txt(" - Todo list (keyed list demo)")}
            </li>
          </ul>
        </div>
      </body>
    </html>
    |> set_cookie(req);

  /* LiveView Demo Page */
  let liveview_demo = (req: request) => {
    /* Render initial counter state for SSR */
    let initial_props = `Assoc([("initial", `Int(0)), ("step", `Int(1))]);
    let counter_html =
      counter_render_ssr(
        ~session_id=req.session,
        ~topic="counter",
        initial_props,
      );

    <html>
      <head>
        <title> {txt("Gateway v2 - LiveView Demo")} </title>
        <style> {txt(styles)} </style>
        {liveViewScript()}
      </head>
      <body>
        <h1> {txt("LiveView Demo")} </h1>
        <p className="info">
          {txt(
             "This counter is powered by LiveView - server-side state with real-time WebSocket updates.",
           )}
        </p>
        <h2> {txt("Counter Component")} </h2>
        <liveView
          endpoint="/v2/live/counter"
          props=[("initial", "0"), ("step", "1")]>
          counter_html
        </liveView>
        <div className="card">
          <h2> {txt("How it works")} </h2>
          <ul>
            <li> {txt("Initial HTML is rendered on the server (SSR)")} </li>
            <li>
              {txt("WebSocket connection is established on page load")}
            </li>
            <li> {txt("Click events are sent to the server")} </li>
            <li>
              {txt("Server updates state and sends back only changed values")}
            </li>
            <li> {txt("Client patches the DOM with new values")} </li>
          </ul>
        </div>
        <p> <a href="/v2"> {txt("<< Back to Dashboard")} </a> </p>
      </body>
    </html>
    |> set_cookie(req);
  };

  /* Todo Demo Page */
  let todo_demo = (req: request) => {
    let initial_html =
      todo_render_ssr(
        ~session_id=req.session,
        ~topic="todo",
        `Null,
      );

    <html>
      <head>
        <title> {txt("Gateway v2 - Todo Demo")} </title>
        <style> {txt(styles)} </style>
        {liveViewScript()}
      </head>
      <body>
        <h1> {txt("Todo - Keyed List Demo")} </h1>
        <p className="info">
          {txt(
             "This todo list demonstrates keyed list diffing - items are added, removed, and toggled via efficient DOM reconciliation.",
           )}
        </p>
        <liveView
          endpoint="/v2/live/todo"
          props=[]>
          initial_html
        </liveView>
        <div className="card">
          <h2> {txt("How it works")} </h2>
          <ul>
            <li> {txt("Each item has a unique key (data-lv-key)")} </li>
            <li> {txt("Server tracks key order and detects structural changes")} </li>
            <li> {txt("Only list_ops (order + inserts) are sent for add/remove/reorder")} </li>
            <li> {txt("Regular patch handles text-only changes within items")} </li>
            <li> {txt("State persists across page refreshes (User persistence)")} </li>
          </ul>
        </div>
        <p> <a href="/v2"> {txt("<< Back to Dashboard")} </a> </p>
      </body>
    </html>
    |> set_cookie(req);
  };

  /* Register all routes */
  let register = app => {
    app
    |> Blossom.get("/v2/health", _ =>
         `Assoc([
           ("status", `String("ok")),
           ("service", `String("gateway-client-v2")),
           ("language", `String("Reason")),
         ])
       )
    |> Blossom.get("/v2/gateway/login", login_page)
    |> Blossom.post("/v2/gateway/login", login_post)
    |> Blossom.get("/v2", dashboard)
    |> Blossom.get("/v2/liveview", liveview_demo)
    |> Blossom.get("/v2/todo", todo_demo);
  };
};

/* WebSocket routes for LiveView - multiplexed */
module WsRoutes = {
  /* Single multiplexed endpoint for all LiveView components */
  let handlers = [("/v2/live", Liveview.multiplexed_handler)];

  let make_ctx = () => ();
};

/* Main entry point - called by dg-services */
let run = () => {
  Stdlib.print_endline(
    "Gateway Client v2 - Reason + JSX + Blossom + EIO + LiveView",
  );

  Eio_main.run(env =>
    Eio.Switch.run(sw => {
      Infra.init(env);
      Liveview.set_env(env);
      let http_socket = Infra.Config.gateway_client_v2_socket;
      let ws_socket = http_socket ++ ".ws";

      /* Start WebSocket server in background fiber */
      Stdlib.print_endline("Starting WebSocket server...");
      Stdlib.flush(Stdlib.stdout);
      Eio.Fiber.fork(
        ~sw,
        () => {
          let ws_server =
            Websocket.create_server(
              ~make_ctx=WsRoutes.make_ctx,
              WsRoutes.handlers,
            );
          Websocket.listen(~env, ~sw, ~socket_path=ws_socket, ws_server);
        },
      );

      /* Start HTTP server */
      let app = Blossom.create(make_request) |> Routes.register;
      Blossom.listen_unix(~socket_path=http_socket, ~env, ~sw, app);
    })
  );
};

/* Render initial HTML for SSR */
