/* LiveView - Server-side reactive components for Reason */
/* Type-safe Elm architecture with automatic JSON serialization */
open Base;

/* EIO environment - set once at startup via set_env */
let env_ref: ref(option(Eio_unix.Stdenv.base)) = ref(None);
let set_env = (env: Eio_unix.Stdenv.base): unit => env_ref := Some(env);
let get_env = (): Eio_unix.Stdenv.base =>
  switch (env_ref^) {
  | Some(env) => env
  | None => failwith("LiveView: env not initialized, call Liveview.set_env first")
  };

/* Context passed to init and update */
type ctx = {
  session_id: option(string),
  user_id: option(string),
  env: Eio_unix.Stdenv.base,
};

/* Persistence mode for LiveView components */
type persistence =
  | Ephemeral   /* No persistence - fresh state on each connection */
  | Session     /* In-memory per session - survives reconnect */
  | User;       /* SQLite per user - survives restart, syncs across devices */

/* LiveView module signature */
module type VIEW = {
  type model;
  type msg;

  /* Persistence mode */
  let persistence: persistence;

  /* Core Elm architecture */
  let init: (ctx, Yojson.Safe.t) => model;  /* init_args from client */
  let update: (ctx, model, msg) => model;
  let render: model => Html.element;

  /* Serialization - use [@deriving yojson] */
  let model_to_yojson: model => Yojson.Safe.t;
  let model_of_yojson: Yojson.Safe.t => Result.t(model, string);
  let msg_of_yojson: Yojson.Safe.t => Result.t(msg, string);
};

/* === Keyed list diffing types === */

/* Operations for a single keyed list */
type list_ops_entry = {
  order: list(string),
  inserts: list((string, string)),  /* key -> html */
};

/* Keyed list state: list_id -> ordered keys + html per key */
type list_state = list((string, list(Html.keyed_item)));

/* Session state - stored for recovery */
type session_state = {
  endpoint: string,
  model_json: Yojson.Safe.t,
  dynamics: list((string, string)),
  lists: list_state,
  last_active: float,
};

/* Session store - global mutable state for session recovery */
let sessions: Hashtbl.M(String).t(session_state) = Hashtbl.create((module String));
let session_timeout = 300.0;  /* 5 minutes */

/* Connection registry for User persistence broadcast */
type connection = {
  ws: Websocket.t,
  topics: Hashtbl.M(String).t(unit),  /* topic -> () */
};
let user_connections: Hashtbl.M(String).t(list(connection)) = Hashtbl.create((module String));

let register_connection = (user_id: string, conn: connection): unit => {
  let conns = Option.value(Hashtbl.find(user_connections, user_id), ~default=[]);
  Hashtbl.set(user_connections, ~key=user_id, ~data=[conn, ...conns]);
};

let unregister_connection = (user_id: string, ws: Websocket.t): unit => {
  switch (Hashtbl.find(user_connections, user_id)) {
  | Some(conns) =>
    let filtered = List.filter(conns, ~f=(c) => if (phys_equal(c.ws, ws)) { false } else { true });
    if (List.is_empty(filtered)) {
      Hashtbl.remove(user_connections, user_id);
    } else {
      Hashtbl.set(user_connections, ~key=user_id, ~data=filtered);
    };
  | None => ()
  };
};

/* Broadcast patch to all other connections of the same user */
let broadcast_to_user = (user_id: string, topic: string, exclude_ws: Websocket.t, msg: Yojson.Safe.t): unit => {
  switch (Hashtbl.find(user_connections, user_id)) {
  | Some(conns) =>
    List.iter(conns, ~f=(conn) => {
      if ((if (phys_equal(conn.ws, exclude_ws)) { false } else { true }) && Hashtbl.mem(conn.topics, topic)) {
        try (Websocket.send_json(conn.ws, msg)) { | _ => () };
      };
    });
  | None => ()
  };
};

/* Cleanup old sessions periodically */
let cleanup_sessions = () => {
  let now = Unix.gettimeofday();
  let to_remove = Hashtbl.fold(sessions, ~init=[], ~f=(~key, ~data, acc) =>
    if (Float.(now - data.last_active > session_timeout)) {
      [key, ...acc];
    } else {
      acc;
    }
  );
  List.iter(to_remove, ~f=(key) => Hashtbl.remove(sessions, key));
};

/* Internal: collect dynamic values from rendered HTML */
let collect_dynamics = (html: string): list((string, string)) => {
  let pattern = Str.regexp({|data-lv="\([^"]*\)">\([^<]*\)<|});
  let rec find_all = (pos, acc) =>
    try({
      let _ = Str.search_forward(pattern, html, pos);
      let id = Str.matched_group(1, html);
      let value = Str.matched_group(2, html);
      find_all(Str.match_end(), [(id, value), ...acc]);
    }) {
    | Stdlib.Not_found => List.rev(acc)
    };
  find_all(0, []);
};

/* Compute diff between old and new dynamics */
let diff_dynamics =
    (old_dynamics: list((string, string)), new_dynamics: list((string, string)))
    : list((string, string)) => {
  List.filter_map(new_dynamics, ~f=((id, new_value)) =>
    switch (List.Assoc.find(old_dynamics, id, ~equal=String.equal)) {
    | Some(old_value) when String.equal(old_value, new_value) => None
    | _ => Some((id, new_value))
    }
  );
};

/* Encode server message to JSON with topic */
let encode_msg = (topic: string, type_: string, data: list((string, Yojson.Safe.t))): Yojson.Safe.t =>
  `Assoc([("topic", `String(topic)), ("type", `String(type_)), ...data]);

let encode_full = (topic: string, html: string): Yojson.Safe.t =>
  encode_msg(topic, "full", [("html", `String(html))]);

let encode_patch = (topic: string, changes: list((string, string))): Yojson.Safe.t =>
  encode_msg(topic, "patch", [
    ("changes", `Assoc(List.map(changes, ~f=((id, value)) => (id, `String(value)))))
  ]);

let encode_restored = (topic: string, html: string): Yojson.Safe.t =>
  encode_msg(topic, "restored", [("html", `String(html))]);

/* Diff two list states, returning ops only when keys/order changed */
let diff_lists = (old_lists: list_state, new_lists: list_state): list((string, list_ops_entry)) => {
  List.filter_map(new_lists, ~f=((list_id, new_items)) => {
    let old_items = switch (List.Assoc.find(old_lists, list_id, ~equal=String.equal)) {
    | Some(items) => items
    | None => []
    };
    let old_keys = List.map(old_items, ~f=(ki: Html.keyed_item) => ki.key);
    let new_keys = List.map(new_items, ~f=(ki: Html.keyed_item) => ki.key);

    /* Build map from old items for quick lookup */
    let old_html_map = List.map(old_items, ~f=(ki: Html.keyed_item) => (ki.key, ki.html));

    /* Find inserts: new keys not in old, or keys whose HTML changed */
    let inserts = List.filter_map(new_items, ~f=(ki: Html.keyed_item) =>
      switch (List.Assoc.find(old_html_map, ki.key, ~equal=String.equal)) {
      | Some(old_html) when String.equal(old_html, ki.html) => None
      | _ => Some((ki.key, ki.html))
      }
    );

    /* Only emit ops if keys/order changed or there are inserts */
    if (List.equal(String.equal, old_keys, new_keys) && List.is_empty(inserts)) {
      None;
    } else {
      Some((list_id, { order: new_keys, inserts }));
    };
  });
};

/* Encode patch message with optional list_ops */
let encode_patch_with_lists = (
  topic: string,
  changes: list((string, string)),
  list_ops: list((string, list_ops_entry)),
): Yojson.Safe.t => {
  let base = [
    ("changes", `Assoc(List.map(changes, ~f=((id, value)) => (id, `String(value))))),
  ];
  let with_lists = if (List.is_empty(list_ops)) {
    base;
  } else {
    let ops_json = `Assoc(List.map(list_ops, ~f=((list_id, ops)) =>
      (list_id, `Assoc([
        ("order", `List(List.map(ops.order, ~f=(k) => `String(k)))),
        ("inserts", `Assoc(List.map(ops.inserts, ~f=((k, html)) => (k, `String(html))))),
      ]))
    ));
    [("list_ops", ops_json), ...base];
  };
  encode_msg(topic, "patch", with_lists);
};

/* Result of handling a message - dynamics changes + optional list ops */
type handle_result = {
  changes: list((string, string)),
  list_ops: list((string, list_ops_entry)),
};

/* View instance - holds typed state and handlers */
type view_instance = {
  get_html: unit => string,
  handle_msg: Yojson.Safe.t => option(handle_result),
  get_model_json: unit => Yojson.Safe.t,
  /* Reload model from JSON (e.g. from DB). Updates state only, not baselines. */
  load_model: Yojson.Safe.t => unit,
};

/* Registry entry with factory and persistence mode */
type view_entry = {
  factory: (ctx, Yojson.Safe.t) => view_instance,
  persistence: persistence,
};

let view_registry: Hashtbl.M(String).t(view_entry) = Hashtbl.create((module String));

/* Register a VIEW module */
let register_view =
    (type m, type msg, endpoint: string, module View: VIEW with type model = m and type msg = msg) => {
  let factory = (ctx: ctx, props_or_saved: Yojson.Safe.t) => {
    /* Try to restore from saved state, otherwise init fresh */
    let initial_model = switch (View.model_of_yojson(props_or_saved)) {
    | Ok(model) => model
    | Error(_) => View.init(ctx, props_or_saved)
    };

    let state = ref(initial_model);
    /* Initial render to capture dynamics and lists */
    let initial_html = View.render(state^) |> Html.element_to_string;
    let dynamics = ref(collect_dynamics(initial_html));
    let lists: ref(list_state) = ref(Html.collect_and_clear_lists());

    let get_html = () => {
      let html = View.render(state^) |> Html.element_to_string;
      /* Clear list registry to prevent stale accumulation (join handler path) */
      let _ = Html.collect_and_clear_lists();
      html;
    };

    let handle_msg = (msg_json: Yojson.Safe.t): option(handle_result) => {
      switch (View.msg_of_yojson(msg_json)) {
      | Ok(msg) =>
        state := View.update(ctx, state^, msg);
        /* Render directly (not via get_html) so we can capture list state */
        let new_html = View.render(state^) |> Html.element_to_string;
        let new_dynamics = collect_dynamics(new_html);
        let new_lists = Html.collect_and_clear_lists();
        let changes = diff_dynamics(dynamics^, new_dynamics);
        let lops = diff_lists(lists^, new_lists);
        dynamics := new_dynamics;
        lists := new_lists;

        if (List.length(changes) > 0 || List.length(lops) > 0) {
          Some({ changes, list_ops: lops });
        } else {
          None;
        };
      | Error(_) => None
      };
    };

    let get_model_json = () => View.model_to_yojson(state^);

    let load_model = (model_json: Yojson.Safe.t): unit => {
      switch (View.model_of_yojson(model_json)) {
      | Ok(new_model) => state := new_model
      | Error(_) => ()
      };
    };

    { get_html, handle_msg, get_model_json, load_model };
  };
  Hashtbl.set(view_registry, ~key=endpoint, ~data={ factory, persistence: View.persistence });
};

/* Active topic state within a connection */
type topic_state = {
  endpoint: string,
  topic: string,
  persistence: persistence,
  instance: view_instance,
};

/* Helper: load state based on persistence mode */
let load_state = (persistence: persistence, session_id: option(string), topic: string, endpoint: string)
    : option(Yojson.Safe.t) =>
  switch (persistence) {
  | Ephemeral => None
  | Session =>
    switch (session_id) {
    | Some(sid) =>
      let key = sid ++ ":" ++ topic;
      switch (Hashtbl.find(sessions, key)) {
      | Some(saved) when String.equal(saved.endpoint, endpoint) => Some(saved.model_json)
      | _ => None
      };
    | None => None
    };
  | User =>
    switch (session_id) {
    | Some(user_id) =>
      switch (Liveview_store.load(~user_id, ~topic)) {
      | Some((ep, model_json)) when String.equal(ep, endpoint) => Some(model_json)
      | _ => None
      };
    | None => None
    };
  };

/* Helper: save state based on persistence mode */
let save_state = (persistence: persistence, session_id: option(string), topic: string, endpoint: string, model_json: Yojson.Safe.t): unit =>
  switch (persistence, session_id) {
  | (Ephemeral, _) => ()
  | (Session, Some(sid)) =>
    let key = sid ++ ":" ++ topic;
    Hashtbl.set(sessions, ~key, ~data={
      endpoint,
      model_json,
      dynamics: [],
      lists: [],
      last_active: Unix.gettimeofday(),
    });
  | (Session, None) => ()
  | (User, Some(user_id)) =>
    Liveview_store.save(~user_id, ~topic, ~endpoint, ~model_json);
  | (User, None) => ()
  };

/* Multiplexed WebSocket handler */
let multiplexed_handler =
    (~path as _: string, ~session_id: option(string), _ctx: unit, ws: Websocket.t): unit => {
  let topics: Hashtbl.M(String).t(topic_state) = Hashtbl.create((module String));
  /* For now, user_id = session_id. In real app, resolve from session. */
  let ctx = { session_id, user_id: session_id, env: get_env() };

  /* Register this connection for broadcast */
  let conn_topics: Hashtbl.M(String).t(unit) = Hashtbl.create((module String));
  let conn = { ws, topics: conn_topics };
  switch (session_id) {
  | Some(uid) => register_connection(uid, conn);
  | None => ()
  };

  cleanup_sessions();

  let rec loop = () => {
    switch (Websocket.receive_json(ws)) {
    | None => ()
    | Some(json) =>
      open Yojson.Safe.Util;
      let type_ = try(json |> member("type") |> to_string) { | _ => "" };
      let topic = try(json |> member("topic") |> to_string) { | _ => "" };

      switch (type_) {
      | "join" =>
        let endpoint = try(json |> member("endpoint") |> to_string) { | _ => "" };
        let init_args = try(json |> member("props")) { | _ => `Null };

        switch (Hashtbl.find(view_registry, endpoint)) {
        | Some({ factory, persistence }) =>
          let saved_state = load_state(persistence, session_id, topic, endpoint);
          let (instance, msg_type) = switch (saved_state) {
          | Some(model_json) => (factory(ctx, model_json), "restored")
          | None => (factory(ctx, init_args), "full")
          };
          let html = instance.get_html();
          Hashtbl.set(topics, ~key=topic, ~data={ endpoint, topic, persistence, instance });
          /* Track topic for broadcast */
          Hashtbl.set(conn_topics, ~key=topic, ~data=());
          let msg = if (String.equal(msg_type, "restored")) {
            encode_restored(topic, html);
          } else {
            encode_full(topic, html);
          };
          Websocket.send_json(ws, msg);
        | None => ()
        };
        loop();

      | "leave" =>
        switch (Hashtbl.find(topics, topic)) {
        | Some(ts) =>
          save_state(ts.persistence, session_id, ts.topic, ts.endpoint, ts.instance.get_model_json());
          Hashtbl.remove(topics, topic);
          Hashtbl.remove(conn_topics, topic);
        | None => ()
        };
        loop();

      | "msg" =>
        let msg_json = try(json |> member("msg")) { | _ => `Null };

        switch (Hashtbl.find(topics, topic)) {
        | Some(ts) =>
          /* For User persistence, reload model from DB before processing.
             Only state is updated — baselines stay as-is so the diff captures
             both cross-tab changes and this message's changes in one patch. */
          switch (ts.persistence, session_id) {
          | (User, Some(user_id)) =>
            switch (Liveview_store.load(~user_id, ~topic)) {
            | Some((_, model_json)) => ts.instance.load_model(model_json)
            | None => ()
            };
          | _ => ()
          };

          switch (ts.instance.handle_msg(msg_json)) {
          | Some({ changes, list_ops }) =>
            let patch_msg = encode_patch_with_lists(topic, changes, list_ops);
            Websocket.send_json(ws, patch_msg);
            /* Save after each change */
            save_state(ts.persistence, session_id, ts.topic, ts.endpoint, ts.instance.get_model_json());
            /* Broadcast same patch to other devices for User persistence */
            switch (ts.persistence, session_id) {
            | (User, Some(uid)) => broadcast_to_user(uid, topic, ws, patch_msg);
            | _ => ()
            };
          | None => ()
          };
        | None => ()
        };
        loop();

      | _ => loop()
      };
    };
  };

  loop();

  /* Unregister connection on disconnect */
  switch (session_id) {
  | Some(uid) => unregister_connection(uid, ws);
  | None => ()
  };
};

/* Create handler with initial render for SSR */
let render_initial =
    (type m, type msg, module View: VIEW with type model = m and type msg = msg) => {
  (~session_id: option(string), ~topic: string, init_args: Yojson.Safe.t): Html.element => {
    let ctx = { session_id, user_id: session_id, env: get_env() };
    /* Try to load saved state for User persistence */
    let model = switch (View.persistence, session_id) {
    | (User, Some(user_id)) =>
      switch (Liveview_store.load(~user_id, ~topic)) {
      | Some((_, model_json)) =>
        switch (View.model_of_yojson(model_json)) {
        | Ok(m) => m
        | Error(_) => View.init(ctx, init_args)
        };
      | None => View.init(ctx, init_args)
      };
    | _ => View.init(ctx, init_args)
    };
    let el = View.render(model);
    /* Clear list registry from SSR render (will be re-captured on WS join) */
    let _ = Html.collect_and_clear_lists();
    el;
  };
};
