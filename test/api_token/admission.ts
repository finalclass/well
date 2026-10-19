let checks = 0;
function check(name: string, value: boolean) {
  if (!value) throw new Error(name);
  checks++;
  console.log(`ok ${name}`);
}

async function exercise(defaults: boolean) {
  const directory = await Deno.makeTempDir({ prefix: "well-admission-" });
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const port = (listener.addr as Deno.NetAddr).port;
  listener.close();
  const child = new Deno.Command(
    `${Deno.cwd()}/_build/default/test/api_token/admission_server.exe`,
    {
      cwd: directory,
      env: {
        ADMISSION_PORT: String(port),
        ADMISSION_DEFAULT: String(defaults),
      },
      stdout: "null",
      stderr: "null",
    },
  ).spawn();
  const url = `http://127.0.0.1:${port}`;
  async function request(
    path: string,
    method = "GET",
    token?: string,
    cookie?: string,
  ) {
    const headers = new Headers();
    if (token) headers.set("Authorization", `Bearer ${token}`);
    if (cookie) headers.set("Cookie", cookie);
    return await fetch(url + path, { method, headers, redirect: "manual" });
  }
  async function stats() {
    const response = await request("/stats");
    return await response.json() as { calls: number; authorizations: number };
  }
  try {
    const deadline = Date.now() + 30_000;
    while (true) {
      try {
        await stats();
        break;
      } catch (error) {
        if (Date.now() > deadline) throw error;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
    }
    const login = await fetch(url + "/login", {
      method: "POST",
      headers: { "X-Requested-With": "XMLHttpRequest" },
    });
    check("fixture login", login.status === 200);
    const cookie = login.headers.get("set-cookie")?.split(";")[0];
    check("fixture cookie", !!cookie);
    const paths = [
      ["/effect", "GET"],
      ["/effect", "POST"],
      ["/rpc/Admission/echo", "POST"],
      ["/_cap/admission", "GET"],
      ["/_cap/admission", "POST"],
      ["/_cap/repl", "GET"],
      ["/health", "GET"],
    ];
    for (const [path, method] of paths) {
      const accepted = await request(path, method, "allowed");
      check(`allowed ${method} ${path}`, accepted.status === 200);
      check(
        "accepted bearer has no cookie",
        !accepted.headers.has("set-cookie"),
      );
      await accepted.text();
      for (
        const [token, status] of [["denied", 403], ["failure", 503], [
          "invalid",
          401,
        ]] as const
      ) {
        const before = await stats();
        const response = await request(path, method, token, cookie);
        const body = await response.text();
        check(
          `${token} ${method} ${path}`,
          response.status === (defaults && token !== "invalid" ? 200 : status),
        );
        check(
          "no bearer cookie or diagnostics",
          !response.headers.has("set-cookie") &&
            !body.includes("private authorization diagnostic"),
        );
        const after = await stats();
        if (!defaults || token === "invalid") {
          check("denied handler has no effect", after.calls === before.calls);
        }
        if (token === "invalid" || defaults) {
          check(
            "callback skipped",
            after.authorizations === before.authorizations,
          );
        } else {check(
            "callback exactly once",
            after.authorizations === before.authorizations + 1,
          );}
      }
    }
    if (!defaults) {
      const before = await stats();
      const excluded = await request("/excluded", "GET", "invalid", cookie);
      check("excluded request unchanged", excluded.status === 200);
      await excluded.text();
      check(
        "excluded callback skipped",
        (await stats()).authorizations === before.authorizations,
      );
      const csrf = await request("/effect", "POST", undefined, cookie);
      check("cookie still requires CSRF", csrf.status === 403);
      await csrf.text();
      const parallel = await Promise.all(
        Array.from(
          { length: 20 },
          (_, i) => request("/effect", "GET", i % 2 ? "allowed" : "denied"),
        ),
      );
      for (const [i, response] of parallel.entries()) {
        check(
          "parallel callback context isolated",
          response.status === (i % 2 ? 200 : 403),
        );
        await response.text();
      }
    }
  } finally {
    child.kill("SIGTERM");
    await child.status;
    await Deno.remove(directory, { recursive: true });
  }
}
await exercise(false);
await exercise(true);
console.log(`API token HTTP admission: ${checks} checks passed`);
