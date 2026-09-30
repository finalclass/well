// W3 clients acceptance: the generated TS, Go and Dart proxies run real RPC
// against the W3 Well HTTP server. Each client compiles/executes its own
// language toolchain and uses only the public toDrut/fromDrut conversions.

import {
  buildServer,
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

const proxyPort = 8502;
const fixture = `${repoRoot}/test/contract_w3/fixtures`;
const toolchains = `${cache}/toolchains`;
const goDir = `${toolchains}/go/bin`;
const dartDir = `${toolchains}/dart-sdk/bin`;

const wellRev = await snapshotWell();
const cyroRev = await cyrografRev();
console.error(`well snapshot ${wellRev}, cyrograf snapshot ${cyroRev}`);

await generate(fixture, generated);
await buildServer();

await must("mkdir", ["-p", `${generated}/go/cmd/consumer`], repoRoot);
await must("mkdir", ["-p", `${generated}/dart/bin`], repoRoot);
await Deno.copyFile(`${here}/../contract_w3/consumer.ts`,
  `${generated}/typescript/consumer.ts`);
await Deno.copyFile(`${here}/../contract_w3/consumer.go`,
  `${generated}/go/cmd/consumer/main.go`);
await Deno.copyFile(`${here}/../contract_w3/consumer.dart`,
  `${generated}/dart/bin/consumer.dart`);

const child = await startServer();
const bootstrap = await fetch(`http://127.0.0.1:${serverPort}/csrf-token`);
const token = ((await bootstrap.json()) as { token: string }).token;
const setCookie = bootstrap.headers.get("set-cookie") ?? "";
const cookieHeader = setCookie.split(";")[0];

let pass = 0;
let fail = 0;
const check = (name: string, ok: boolean) => {
  if (ok) {
    pass++;
    console.log(`ok   ${name}`);
  } else {
    fail++;
    console.log(`FAIL ${name}`);
  }
};

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
        "upgrade", "keep-alive", "cookie"].includes(lk)) {
        continue;
      }
      headers.set(k, v);
    }
    headers.set("Cookie", cookieHeader);
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

const env = {
  ...Deno.env.toObject(),
  PATH: `${goDir}:${dartDir}:${Deno.env.get("PATH")}`,
  GOCACHE: `${cache}/gocache`,
  GOPATH: `${cache}/gopath`,
  GOMODCACHE: `${cache}/gomodcache`,
};

try {
  console.log("== TypeScript (Deno) ==");
  const ts = await runWith(
    "deno",
    ["run", "-A", "consumer.ts", `http://127.0.0.1:${proxyPort}`, token],
    `${generated}/typescript`,
    env,
  );
  printLog(ts);
  check("ts client executed", ts.code === 0);

  console.log("== Go ==");
  const go = await runWith(
    "go",
    ["run", "./cmd/consumer", `http://127.0.0.1:${proxyPort}`, token],
    `${generated}/go`,
    env,
  );
  printLog(go);
  check("go client executed", go.code === 0);

  console.log("== Dart ==");
  const dart = await runWith(
    "dart",
    ["bin/consumer.dart", `http://127.0.0.1:${proxyPort}`, token],
    `${generated}/dart`,
    env,
  );
  printLog(dart);
  check("dart client executed", dart.code === 0);
} finally {
  await server.shutdown();
  await stopServer(child);
}

console.log(`\nW3 clients: ${pass} passed, ${fail} failed`);
if (fail > 0) Deno.exit(1);

async function runWith(
  cmd: string,
  args: string[],
  cwd: string,
  environment: Record<string, string>,
) {
  const p = new Deno.Command(cmd, {
    args,
    cwd,
    env: environment,
    stdout: "piped",
    stderr: "piped",
  });
  const out = await p.output();
  return {
    code: out.code,
    stdout: new TextDecoder().decode(out.stdout),
    stderr: new TextDecoder().decode(out.stderr),
  };
}

function printLog(r: { code: number; stdout: string; stderr: string }) {
  console.log(r.stdout);
  if (r.stderr.trim() !== "") console.error(r.stderr);
  console.log(`exit ${r.code}`);
}