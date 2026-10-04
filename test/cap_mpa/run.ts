const root = Deno.cwd();
const runtime = await Deno.makeTempDir({ prefix: "well-cap-mpa-" });
const port = 8494;
const server = new Deno.Command(
  `${root}/_build/default/test/cap_mpa/server.exe`,
  {
    cwd: runtime,
    env: { CAP_PORT: String(port) },
    stdout: "null",
    stderr: "null",
  },
).spawn();
const base = `http://127.0.0.1:${port}`;
let cookie = "";
let passed = 0;
function check(name: string, condition: boolean) {
  if (!condition) throw new Error(name);
  passed++;
  console.log(`ok ${name}`);
}
async function request(
  path: string,
  fields?: Record<string, string>,
  headers: Record<string, string> = {},
) {
  const response = await fetch(base + path, {
    method: fields ? "POST" : "GET",
    redirect: "manual",
    headers: { ...(cookie ? { Cookie: cookie } : {}), ...headers },
    body: fields ? new URLSearchParams(fields) : undefined,
  });
  for (const value of response.headers.getSetCookie()) {
    if (value.startsWith("well_session=")) cookie = value.split(";")[0];
  }
  return {
    status: response.status,
    location: response.headers.get("location"),
    text: await response.text(),
  };
}
function token(html: string) {
  const match = html.match(/name="_csrf_token" value="([^"]+)"/);
  if (!match) throw new Error("Missing CSRF token");
  return match[1];
}
try {
  for (let attempt = 0;; attempt++) {
    try {
      const ready = await fetch(base + "/_cap/login");
      await ready.arrayBuffer();
      break;
    } catch (error) {
      if (attempt > 100) throw error;
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  const paths = [
    "",
    "routes",
    "connections",
    "db",
    "services",
    "messages",
    "logs",
    "telemetry",
    "repl",
    "users",
    "users/new",
    "users/1",
  ];
  for (const path of paths) {
    check(
      `auth ${path || "overview"}`,
      (await request("/_cap/" + path)).location === "/_cap/login",
    );
  }
  for (const path of ["logs", "messages", "telemetry"]) {
    check(
      `API auth ${path}`,
      (await request("/_cap/api/" + path)).status === 401,
    );
  }
  check(
    "REPL requires auth",
    (await request("/_cap/api/repl", { expr: "2+3" }, {
      "X-Requested-With": "XMLHttpRequest",
    })).status === 401,
  );
  let page = await request("/_cap/login");
  check(
    "login CSRF rejection",
    (await request("/_cap/login", { email: "cap", password: "admin" }))
      .status === 403,
  );
  const login = await request("/_cap/login", {
    email: "cap",
    password: "admin",
    _csrf_token: token(page.text),
  });
  check("login PRG", login.status === 303 && login.location === "/_cap/");
  for (const path of paths) {
    const response = await request("/_cap/" + path);
    check(
      `SSR ${path || "overview"}`,
      response.status === 200 && response.text.includes("<!DOCTYPE html>") &&
        !/live-view|data-lv|\/live\//.test(response.text),
    );
  }
  page = await request("/_cap/users/1");
  const csrf = token(page.text);
  check(
    "direct user card",
    page.text.includes("Użytkownik #1") && page.text.includes('value="cap"'),
  );
  check(
    "missing user 404",
    (await request("/_cap/users/987654")).status === 404,
  );
  check(
    "invalid user 404",
    (await request("/_cap/users/not-an-id")).status === 404,
  );
  check(
    "mutation CSRF",
    (await request("/_cap/users/1/email", { email: "hijacked" })).status ===
      403,
  );
  let result = await request("/_cap/users/1/revoke", {
    grant_name: "cap",
    _csrf_token: csrf,
  });
  check("last cap grant protected", result.text.includes("Cannot revoke cap"));
  result = await request("/_cap/users/1/delete", { _csrf_token: csrf });
  check(
    "last cap user protected",
    result.text.includes("Cannot delete the last cap"),
  );
  result = await request("/_cap/users/new", {
    email: "mpa@example.com",
    password: "TestPassword1",
    _csrf_token: csrf,
  });
  check(
    "create PRG",
    result.status === 303 && result.location === "/_cap/users",
  );
  page = await request("/_cap/users");
  const userId = page.text.match(/href="\/_cap\/users\/(\d+)">mpa@example.com/)
    ?.[1];
  check("created user in SSR", !!userId);
  const user = `/_cap/users/${userId}`;
  result = await request("/_cap/users/new", {
    email: "mpa@example.com",
    password: "TestPassword1",
    _csrf_token: csrf,
  });
  check(
    "duplicate create error",
    result.status === 200 && result.text.includes("login-error") &&
      !result.text.includes('value="TestPassword1"'),
  );
  result = await request(user + "/email", {
    email: "renamed@example.com",
    _csrf_token: csrf,
  });
  check("email PRG", result.status === 303 && result.location === user);
  page = await request(user);
  check(
    "changed email persists",
    page.text.includes('value="renamed@example.com"'),
  );
  result = await request(user + "/password", {
    password: "NewPassword1",
    _csrf_token: csrf,
  });
  check("password PRG", result.status === 303);
  page = await request(user);
  check("password omitted from HTML", !page.text.includes("NewPassword1"));
  result = await request(user + "/grant", {
    grant_name: "reviewer",
    _csrf_token: csrf,
  });
  check("grant PRG", result.status === 303);
  page = await request(user);
  check("grant visible", page.text.includes("reviewer"));
  result = await request(user + "/revoke", {
    grant_name: "reviewer",
    _csrf_token: csrf,
  });
  check("revoke PRG", result.status === 303);
  page = await request("/_cap/users?q=renamed");
  check(
    "search in URL",
    page.text.includes("renamed@example.com") &&
      !page.text.includes(">cap</a>"),
  );
  page = await request("/_cap/users?q=does-not-exist");
  check("empty search", page.text.includes("Brak użytkowników"));
  result = await request(user + "/delete", { _csrf_token: csrf });
  check(
    "delete PRG",
    result.status === 303 && (await request(user)).status === 404,
  );
  const db = "/_cap/db?source=app&table=cap_items";
  page = await request(db);
  check(
    "db SSR first page",
    page.text.includes("Pozycja 1") && page.text.includes("Next"),
  );
  page = await request(db + "&page=1");
  check(
    "db pagination URL",
    page.text.includes("Pozycja 25") && !page.text.includes(">Pozycja 1</a>"),
  );
  check(
    "unknown table rejected",
    (await request("/_cap/db?source=app&table=missing")).status === 400,
  );
  page = await request(db + "&row=1&column=name");
  check(
    "cell edit GET",
    page.text.includes('name="value"') &&
      page.text.includes('value="Pozycja 1"'),
  );
  result = await request(db, {
    action: "save_cell",
    row: "1",
    column: "name",
    value: "Zmieniona pozycja",
    _csrf_token: csrf,
  });
  check(
    "cell update result",
    result.status === 200 && result.text.includes("Zmieniona pozycja"),
  );
  page = await request(db);
  check("cell update persisted", page.text.includes("Zmieniona pozycja"));
  result = await request(db, {
    action: "run_sql",
    sql: "SELECT name FROM cap_items WHERE id=1",
    _csrf_token: csrf,
  });
  check("SQL result", result.text.includes("Zmieniona pozycja"));
  result = await request(db, {
    action: "run_sql",
    sql: "THIS IS INVALID SQL",
    _csrf_token: csrf,
  });
  check(
    "SQL error",
    result.status === 200 && result.text.includes("login-error"),
  );
  page = await request(db + "&sql=DELETE%20FROM%20cap_items&action=run_sql");
  check("GET does not execute SQL", page.text.includes("Zmieniona pozycja"));
  const service = "/_cap/services?service=CapDemo&rpc=echoInt";
  page = await request(service);
  check(
    "RPC choice in URL",
    page.text.includes("CapDemo.echoInt") &&
      page.text.includes('name="payload"'),
  );
  result = await request(service, {
    payload: '{"value":7}',
    _csrf_token: csrf,
  });
  check(
    "RPC result",
    result.status === 200 && result.text.includes("Response") &&
      result.text.includes("7"),
  );
  result = await request(service, { payload: "{broken", _csrf_token: csrf });
  check("RPC invalid input", result.text.includes("Error:"));
  check(
    "REPL CSRF rejection",
    (await request("/_cap/api/repl", { expr: "2+3" })).status === 403,
  );
  result = await request("/_cap/api/repl", { expr: "2+3", _csrf_token: csrf });
  check("REPL arithmetic", JSON.parse(result.text).output === "5");
  result = await request("/_cap/api/repl", {
    expr: "let x = CapDemo.echoInt value:8",
    _csrf_token: csrf,
  });
  check(
    "REPL RPC binding",
    !JSON.parse(result.text).error &&
      JSON.parse(result.text).vars.includes("x"),
  );
  result = await request("/_cap/api/repl", {
    expr: "x.value",
    _csrf_token: csrf,
  });
  check("REPL variables persist", JSON.parse(result.text).output === "8");
  result = await request("/_cap/api/repl", {
    expr: "missingVariable",
    _csrf_token: csrf,
  });
  check("REPL error", JSON.parse(result.text).error === true);
  await request("/acceptance-event");
  check(
    "log stream data",
    (await request("/_cap/api/logs?q=Log%20testowy")).text.includes(
      "Log testowy CAP",
    ),
  );
  check(
    "message stream data",
    (await request("/_cap/api/messages")).text.includes("Wiadomość testowa"),
  );
  check(
    "telemetry data",
    Array.isArray(JSON.parse((await request("/_cap/api/telemetry")).text)),
  );
  check("removed transport", (await request("/live")).status === 404);
  check(
    "GET logout is inert",
    (await request("/_cap/logout")).status >= 400 &&
      (await request("/_cap/users")).status === 200,
  );
  check(
    "cross-origin rejected",
    (await request("/_cap/api/repl", { expr: "2+3" }, {
      Origin: "https://foreign.example",
      "X-Requested-With": "XMLHttpRequest",
    })).status === 403,
  );
  check("logout CSRF", (await request("/_cap/logout", {})).status === 403);
  result = await request("/_cap/logout", { _csrf_token: csrf });
  check(
    "logout PRG",
    result.status === 303 && result.location === "/_cap/login",
  );
  check(
    "logout ends access",
    (await request("/_cap/users")).location === "/_cap/login",
  );
  console.log(`CAP MPA: ${passed} passed`);
} finally {
  server.kill("SIGTERM");
  await server.status;
  await Deno.remove(runtime, { recursive: true });
}
