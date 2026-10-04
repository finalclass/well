import { buildServer, cyrografRev, generate, generated, repoRoot, serverPort, snapshotWell, startServer, stopServer } from "../contract_w3/harness.ts";
let checks = 0;
function check(name: string, condition: boolean) {
  if (!condition) throw new Error(name);
  checks++;
  console.log("ok " + name);
}
await snapshotWell();
await cyrografRev();
await generate(repoRoot + "/test/contract_w3/fixtures", generated);
await buildServer(repoRoot + "/test/api_token/server_main.ml");
const child = await startServer();
try {
  const Orders = await import("file://" + generated + "/typescript/orders.ts");
  const { createClient, RpcError } = await import("file://" + generated + "/typescript/well_transport.ts");
  const baseUrl = "http://127.0.0.1:" + serverPort;
  const alice = createClient({ baseUrl, bearerToken: "alice" });
  const bob = createClient({ baseUrl, bearerToken: async () => "bob" });
  const [a, b] = await Promise.all([Orders.echo(alice, { id: "ignored" }), Orders.echo(bob, { id: "ignored" })]);
  check("alice trusted identity", a.id === "alice" && a.label === "alice");
  check("bob trusted identity", b.id === "bob" && b.label === "bob");
  try { await Orders.echo(createClient({ baseUrl, bearerToken: "bad" }), { id: "ignored" }); throw new Error("Invalid token admitted"); }
  catch (error) { check("invalid token preserves HTTP 401", error instanceof RpcError && error.status === 401); }
  const stub = (body: string, status = 200) => async () => new Response(body, { status });
  for (const [body, status, kind] of [["unavailable", 503, "http"], ['{"error":"secret diagnostic"}', 200, "protocol"]] as const) {
    try { await Orders.echo(createClient({ fetch: stub(body, status) }), { id: "ignored" }); throw new Error("Failure admitted"); }
    catch (error) { check("HTTP/protocol failure", error instanceof RpcError && error.status === status && error.kind === kind && !error.message.includes("secret")); }
  }
  try { await Orders.echo(createClient({ fetch: stub("not Drut") }), { id: "ignored" }); throw new Error("Malformed response admitted"); }
  catch (error) { check("response decoded by generated codec", !(error instanceof RpcError)); }
  try { await Orders.echo(createClient({ bearerToken: "secret", fetch() { throw new Error("secret"); } }), { id: "ignored" }); throw new Error("Failure admitted"); }
  catch (error) { check("transport redacts secrets", error instanceof RpcError && error.message === "RPC transport failed"); }
  for (const options of [
    { timeoutMs: 10, bearerToken: () => new Promise<string>(() => {}) },
    { timeoutMs: 10, fetch: (_url: unknown, init?: RequestInit) => new Promise<Response>((_resolve, reject) => init?.signal?.addEventListener("abort", () => reject(new Error("secret")), { once: true })) },
  ]) {
    try { await Orders.echo(createClient(options), { id: "ignored" }); throw new Error("Timeout admitted"); }
    catch (error) { check("timeout bounded", error instanceof RpcError && error.message === "RPC transport timed out"); }
  }
  (globalThis as Record<string, unknown>).__WELL_CSRF = "csrf-test";
  const browser = createClient({ baseUrl, fetch: async (url: string, options: RequestInit) => {
    const headers = new Headers(options.headers);
    check("browser base and cookies", url === baseUrl + "/rpc/Orders/echo" && options.credentials === "include");
    check("browser CSRF/XHR", headers.get("X-CSRF-Token") === "csrf-test" && headers.get("X-Requested-With") === "XMLHttpRequest");
    return new Response('["browser",null]');
  } });
  check("browser response", (await Orders.echo(browser, { id: "ignored" })).id === "browser");
  await Orders.echo(createClient({ bearerToken: "alice", fetch: async (_url: string, options: RequestInit) => {
    const headers = new Headers(options.headers);
    check("bearer header", headers.get("Authorization") === "Bearer alice");
    check("bearer excludes cookies and browser headers", options.credentials === "omit" && !headers.has("X-CSRF-Token") && !headers.has("X-Requested-With"));
    check("bearer refuses redirects", options.redirect === "error");
    return new Response('["alice",null]');
  } }), { id: "ignored" });
  console.log("API token Promise clients: " + checks + " checks passed");
} finally { await stopServer(child); }
