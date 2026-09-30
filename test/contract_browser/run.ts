// W3 browser acceptance: a real browser (agent-browser / Chrome for Testing)
// runs the js_of_ocaml browser Proxy against the W3 Well HTTP server. Same
// origin is provided by a small Deno proxy that also forwards the raw Drut
// body and injects the CSRF token, so CSRF/cookies behave as in an app.

import {
  buildServer,
  cyrografSnapshot,
  cache,
  cyrografRev,
  generated,
  generate,
  here,
  must,
  repoRoot,
  run,
  serverPort,
  snapshotWell,
  startServer,
  stopServer,
} from "../contract_w3/harness.ts";

const browserRoot = `${cache}/browser`;
const proxyPort = 8500;
const fixture = `${repoRoot}/test/contract_w3/fixtures`;
const checks: Array<[string, boolean]> = [];
const check = (name: string, ok: boolean) => checks.push([name, ok]);

const wellRev = await snapshotWell();
const cyroRev = await cyrografRev();
console.error(`well snapshot ${wellRev}, cyrograf snapshot ${cyroRev}`);

await generate(fixture, generated);
await buildServer();

await must("rm", ["-rf", browserRoot], repoRoot);
await must("mkdir", ["-p", `${browserRoot}/browser`], repoRoot);
await must("cp", ["-r", `${generated}/ocaml_js`, browserRoot], repoRoot);
await must("cp", ["-r", `${generated}/adapters_browser`, browserRoot], repoRoot);
await Deno.copyFile(`${here}/../contract_w3/browser_main.ml`,
  `${browserRoot}/browser/browser_main.ml`);
await Deno.copyFile(`${here}/../contract_w3/browser_dune`,
  `${browserRoot}/browser/dune`);
await Deno.writeTextFile(`${browserRoot}/dune-project`, [
  "(lang dune 3.17)",
  "",
  "(pin",
  ' (url "git+file://@CYROGRAF@")',
  " (package",
  '  (name cyrograf)))',
  "",
  "(package",
  " (name consumer)",
  " (depends",
  "  ocaml",
  "  cyrograf",
  "  js_of_ocaml",
  "  js_of_ocaml-ppx))",
  "",
].join("\n").replaceAll("@CYROGRAF@", cyrografSnapshot));
await must("dune", ["pkg", "lock"], browserRoot);
await must("dune", ["build", "browser/browser_main.bc.js"], browserRoot);
const jsPath = `${browserRoot}/_build/default/browser/browser_main.bc.js`;

const duneProjectText = await Deno.readTextFile(`${browserRoot}/dune-project`);
check("browser project has no well/core dependency",
  !/(^|\W)well(\W|$)/.test(duneProjectText));
const jsText = await Deno.readTextFile(jsPath);
check("js bundle excludes Eio, Sqlite3 and the Cyrograf compiler",
  !/\bEio\b/.test(jsText) && !/Sqlite3/.test(jsText) &&
    !/Cyrograf_compiler/.test(jsText));

const child = await startServer();
const bootstrap = await fetch(`http://127.0.0.1:${serverPort}/csrf-token`);
const token = ((await bootstrap.json()) as { token: string }).token;
const setCookie = bootstrap.headers.get("set-cookie") ?? "";
const cookieHeader = setCookie.split(";")[0];

const noXhr = await fetch(`http://127.0.0.1:${serverPort}/rpc/Orders/echo`, {
  method: "POST",
  headers: { "content-type": "application/json", cookie: cookieHeader },
  body: '["probe",null]',
});
check("csrf blocks non-XHR without token", noXhr.status === 403);
const withToken = await fetch(`http://127.0.0.1:${serverPort}/rpc/Orders/echo`, {
  method: "POST",
  headers: {
    "content-type": "application/json",
    cookie: cookieHeader,
    "x-csrf-token": token,
  },
  body: '["probe",null]',
});
check("csrf accepts session token", withToken.status === 200);

const server = Deno.serve({ port: proxyPort, hostname: "127.0.0.1" }, async (req) => {
  const url = new URL(req.url);
  if (url.pathname === "/") {
    const html = `<!doctype html><html><head><meta charset="utf-8">` +
      `<meta name="csrf-token" content="${token}">` +
      `<title>W3 browser</title></head><body>` +
      `<script src="/browser_main.bc.js"></script></body></html>`;
    const headers: Record<string, string> = { "content-type": "text/html" };
    if (setCookie !== "") headers["set-cookie"] = setCookie;
    return new Response(html, { headers });
  }
  if (url.pathname === "/browser_main.bc.js") {
    return new Response(await Deno.readTextFile(jsPath), {
      headers: { "content-type": "text/javascript" },
    });
  }
  if (url.pathname.startsWith("/rpc/")) {
    const body = await req.text();
    if (url.pathname === "/rpc/Orders/echo") {
      if (body.includes("legacy-error")) {
        return new Response(JSON.stringify({ error: "legacy failure" }), {
          status: 200, headers: { "content-type": "application/json" },
        });
      }
      if (body.includes("bad-response")) {
        return new Response("[not-valid-drut", {
          status: 200, headers: { "content-type": "application/json" },
        });
      }
    }
    const headers = new Headers();
    for (const [k, v] of req.headers) {
      const lk = k.toLowerCase();
      if (["origin", "sec-fetch-site", "host", "connection",
        "content-length", "transfer-encoding", "expect", "te", "trailer",
        "upgrade", "keep-alive"].includes(lk)) continue;
      headers.set(k, v);
    }
    const response = await fetch(
      `http://127.0.0.1:${serverPort}${url.pathname}`,
      { method: "POST", headers, body },
    );
    return new Response(await response.text(), {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }
  return new Response("not found", { status: 404 });
});

try {
  await run("agent-browser", ["--session", "w3-browser", "close", "--all"], repoRoot);
  await must("agent-browser", [
    "--session", "w3-browser", "open", `http://127.0.0.1:${proxyPort}/`,
  ], repoRoot);
  let raw = "";
  for (let i = 0; i < 40; i++) {
    const r = await run("agent-browser", [
      "--session", "w3-browser", "eval",
      "JSON.stringify(window.__W3_RESULT ?? null)",
    ], repoRoot);
    raw = r.stdout.trim();
    if (raw.includes("[[") || raw.includes("[\"")) break;
    await new Promise((res) => setTimeout(res, 250));
  }
  const text = extractJson(raw);
  const results: Record<string, string> = {};
  let cur: unknown = raw;
  for (let i = 0; i < 4 && typeof cur === "string"; i++) {
    const s = cur as string;
    try {
      cur = JSON.parse(s);
    } catch (_) {
      const extracted = extractJson(s);
      if (extracted === null) break;
      try {
        cur = JSON.parse(extracted);
      } catch (_) {
        break;
      }
    }
  }
  const parsed = Array.isArray(cur) ? cur as Array<[string, string]> : null;
  if (parsed) {
    for (const [name, value] of parsed) results[name] = value;
  }
  const cookieList = await run("agent-browser", [
    "--session", "w3-browser", "cookies",
  ], repoRoot);
  const hasSessionCookie = cookieList.stdout.includes("well_session");
  console.error(`browser results: ${raw}`);
  check("browser loaded results", parsed !== null && text !== null);
  check("session cookie set and HttpOnly", hasSessionCookie &&
    results.cookie === "absent");
  check("csrf meta present", results.csrf_meta === "present");
  check("wide reserve",
    results.reserve_big === "Reserved(owner-1,9007199254740991)");
  check("cross-module echo", results.echo_cross_module === "cross-module");
  check("wide numbers and unicode",
    results.numbers === "9007199254740991/-9007199254740991/Zażółć gęślą jaźń");
  check("empty struct", results.empty === "ok");
  check("unknown method -> http error",
    (results.http_404 ?? "").startsWith("error:"));
  check("2xx with error body -> error",
    (results.http_2xx_error ?? "").includes("legacy failure"));
  check("invalid response -> decode error",
    (results.http_bad_response ?? "").startsWith("error:"));
} finally {
  await run("agent-browser", ["--session", "w3-browser", "close", "--all"], repoRoot);
  await server.shutdown();
  await stopServer(child);
}

for (const [name, ok] of checks) {
  console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
}
const failed = checks.filter(([, ok]) => !ok).length;
console.log(`\nW3 browser: ${checks.length - failed} passed, ${failed} failed`);
if (failed > 0) Deno.exit(1);

function extractJson(raw: string): string | null {
  const start = raw.indexOf("[[");
  const end = raw.lastIndexOf("]");
  if (start === -1 || end === -1 || end < start) return null;
  return raw.slice(start, end + 1);
}