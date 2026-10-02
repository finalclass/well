import {
  buildServer,
  cyrografRev,
  generate,
  generated,
  here,
  repoRoot,
  serverPort,
  snapshotWell,
  startServer,
  stopServer,
} from "../contract_w3/harness.ts";

let checks = 0;
function check(name: string, condition: boolean) {
  if (!condition) throw new Error(name);
  checks++;
  console.log(`ok ${name}`);
}

await snapshotWell();
await cyrografRev();
await generate(`${repoRoot}/test/contract_w3/fixtures`, generated);
const typecheck = await new Deno.Command("deno", {
  args: ["check", `${generated}/typescript/proxy_orders.ts`],
}).output();
if (!typecheck.success) {
  throw new Error(new TextDecoder().decode(typecheck.stderr));
}
await buildServer(`${here}/../api_token/server_main.ml`);
const child = await startServer();
type Result = {
  ok: boolean;
  value?: { id: string; label?: string };
  error?: string;
  status?: number;
};
try {
  const { createProxy, Proxy } = await import(
    `file://${generated}/typescript/proxy_orders.ts`
  );
  const baseUrl = `http://127.0.0.1:${serverPort}`;
  const invoke = (proxy: ReturnType<typeof createProxy>) =>
    new Promise<Result>((resolve) => proxy.echo({ id: "ignored" }, resolve));
  const alice = createProxy({ baseUrl, bearerToken: "alice" });
  const bob = createProxy({ baseUrl, bearerToken: async () => "bob" });
  const [a, b] = await Promise.all([invoke(alice), invoke(bob)]);
  check(
    "real HTTP RPC alice trusted identity",
    a.ok && a.value?.id === "alice" && a.value?.label === "alice",
  );
  check(
    "real HTTP RPC bob trusted identity",
    b.ok && b.value?.id === "bob" && b.value?.label === "bob",
  );
  const denied = await invoke(createProxy({ baseUrl, bearerToken: "bad" }));
  check(
    "invalid token preserves HTTP 401",
    !denied.ok && denied.status === 401,
  );
  const response = await fetch(`${baseUrl}/rpc/Orders/echo`, {
    method: "POST",
    body: '["ignored",null]',
    headers: {
      Authorization: "Bearer alice",
      "Content-Type": "application/json",
    },
  });
  check(
    "bearer does not create browser cookie",
    response.status === 200 && !response.headers.has("set-cookie"),
  );
  await response.text();
  const stub = (body: string, status = 200) => async () =>
    new Response(body, { status });
  const httpFailure = await invoke(
    createProxy({
      baseUrl,
      bearerToken: "alice",
      fetch: stub("unavailable", 503),
    }),
  );
  check(
    "HTTP failure classified",
    !httpFailure.ok && httpFailure.status === 503,
  );
  const legacy = await invoke(
    createProxy({ fetch: stub('{"error":"domain failure"}') }),
  );
  check(
    "2xx error remains failure",
    !legacy.ok && legacy.error === "domain failure" && legacy.status === 200,
  );
  const malformed = await invoke(createProxy({ fetch: stub("not Drut") }));
  check(
    "response decoded by generated codec",
    !malformed.ok && malformed.error?.startsWith("RPC decode:") === true,
  );
  const leaking = await invoke(createProxy({
    bearerToken: "secret",
    fetch: () => {
      throw new Error("secret");
    },
  }));
  check(
    "transport exceptions redact secrets",
    !leaking.ok && leaking.error === "RPC transport failed",
  );
  const timedOut = await invoke(
    createProxy({
      timeoutMs: 10,
      fetch: (_url: unknown, options?: RequestInit) =>
        new Promise<Response>((_resolve, reject) =>
          options?.signal?.addEventListener(
            "abort",
            () => reject(new Error("aborted")),
            { once: true },
          )
        ),
    }),
  );
  check(
    "timeout returns diagnostic",
    !timedOut.ok && timedOut.error === "RPC transport timed out",
  );
  const stalledToken = await invoke(createProxy({
    timeoutMs: 10,
    bearerToken: () => new Promise<string>(() => {}),
  }));
  check(
    "token provider observes timeout",
    !stalledToken.ok && stalledToken.error === "RPC transport timed out",
  );
  const runtime = await import(
    `file://${generated}/typescript/well_transport.ts`
  );
  let callbacks = 0;
  await runtime.createTransport({ fetch: stub('["ok",null]') })(
    "Orders",
    "echo",
    '["probe",null]',
    () => callbacks++,
  );
  check("callback called once", callbacks === 1);
  const globals = globalThis as unknown as {
    __WELL_CSRF?: string;
    __WELL_BASE?: string;
  };
  globals.__WELL_CSRF = "csrf-test";
  globals.__WELL_BASE = baseUrl;
  const browser = await invoke(
    createProxy({
      fetch: async (url: string, options: RequestInit) => {
        check("default base preserved", url === `${baseUrl}/rpc/Orders/echo`);
        const headers = new Headers(options.headers);
        check("browser cookies retained", options.credentials === "include");
        check(
          "browser CSRF retained",
          headers.get("X-CSRF-Token") === "csrf-test",
        );
        check(
          "browser XHR retained",
          headers.get("X-Requested-With") === "XMLHttpRequest",
        );
        return new Response('["browser",null]');
      },
    }),
  );
  check(
    "browser client decoded",
    browser.ok && browser.value?.id === "browser",
  );
  check("default Proxy API retained", typeof Proxy.echo === "function");
  await invoke(
    createProxy({
      bearerToken: "alice",
      fetch: async (_url: string, options: RequestInit) => {
        const headers = new Headers(options.headers);
        check(
          "bearer credential transport",
          headers.get("Authorization") === "Bearer alice",
        );
        check("bearer omits cookies", options.credentials === "omit");
        check(
          "bearer omits CSRF and XHR",
          !headers.has("X-CSRF-Token") && !headers.has("X-Requested-With"),
        );
        check("bearer refuses redirects", options.redirect === "error");
        return new Response('["alice",null]');
      },
    }),
  );
  console.log(`API token generated clients: ${checks} checks passed`);
} finally {
  await stopServer(child);
}
