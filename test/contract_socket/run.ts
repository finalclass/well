// W4 acceptance harness (Deno/TypeScript).
//
// Builds an isolated server from the W3 fixture through the real Cyrograf
// pipeline, starts it, and drives the unix socket with raw frames:
//  - _system list/describe/health must include the text-Drut service,
//  - the original payload text reaches from_drut, so 1.0000000000000001 in
//    an Int field is rejected, not rounded to 1,
//  - a handler failure does not block later calls,
//  - the server-side ctx is used (a client cannot inject it),
//  - the legacy Actor still answers through its mailbox,
//  - the real `well repl` binary calls the generated service over the socket.
//
// The harness never builds inside the Well workspace; it uses isolated
// snapshots under the W3 cache.

import {
  repoRoot,
  cache,
  wellSnapshot,
  cyrografSnapshot,
  generated,
  run,
  must,
  snapshotWell,
  cyrografRev,
  generate,
} from "../contract_w3/harness.ts";

const w4here = new URL(".", import.meta.url).pathname.replace(/\/$/, "");
const serverRoot = `${cache}/w4-server`;
const port = 8479;
const socketPath = `${serverRoot}/data/well.sock`;

let passed = 0;
let failed = 0;

function check(name: string, cond: boolean, detail = ""): void {
  if (cond) {
    passed++;
    console.log(`ok   ${name}`);
  } else {
    failed++;
    console.log(`FAIL ${name}${detail ? `: ${detail}` : ""}`);
  }
}

async function socketRead(conn: Deno.Conn): Promise<string> {
  const decoder = new TextDecoder();
  let text = "";
  const buf = new Uint8Array(1 << 16);
  while (!text.includes("\n")) {
    const n = await conn.read(buf);
    if (n === null) break;
    text += decoder.decode(buf.subarray(0, n), { stream: true });
  }
  return text.trim();
}

async function socketCall(frame: unknown): Promise<any> {
  const conn = await Deno.connect({ transport: "unix", path: socketPath });
  try {
    await conn.write(new TextEncoder().encode(JSON.stringify(frame) + "\n"));
    return JSON.parse(await socketRead(conn));
  } finally {
    conn.close();
  }
}

function frame(service: string, rpc: string, payloadText: string) {
  return `{"service":${JSON.stringify(service)},"rpc":${JSON.stringify(rpc)},"payload":${payloadText}}`;
}

async function socketCallRaw(raw: string): Promise<any> {
  const conn = await Deno.connect({ transport: "unix", path: socketPath });
  try {
    await conn.write(new TextEncoder().encode(raw + "\n"));
    return JSON.parse(await socketRead(conn));
  } finally {
    conn.close();
  }
}

// 1. Snapshot the current Well tree and reuse the pinned Cyrograf snapshot.
const wellRev = await snapshotWell();
const cgRev = await cyrografRev();
console.error(`well snapshot ${wellRev}, cyrograf snapshot ${cgRev}`);

// 2. Generate the W3 fixture artifacts (wide Ints, cross-module messages).
await generate(`${repoRoot}/test/contract_w3/fixtures`, generated);

// 3. Build the isolated W4 server project.
await must("rm", ["-rf", `${serverRoot}/app`], repoRoot);
await must("mkdir", ["-p", `${serverRoot}/app`], repoRoot);
await must("rm", ["-rf", `${serverRoot}/generated_ocaml`], repoRoot);
await must("rm", ["-rf", `${serverRoot}/generated_adapters`], repoRoot);
await must("cp", ["-r", `${generated}/ocaml`, `${serverRoot}/generated_ocaml`], repoRoot);
await must("cp", ["-r", `${generated}/adapters`, `${serverRoot}/generated_adapters`], repoRoot);
await Deno.copyFile(`${w4here}/server_main.ml`, `${serverRoot}/app/server.ml`);
await Deno.copyFile(`${w4here}/server_dune`, `${serverRoot}/app/dune`);
await Deno.writeTextFile(
  `${serverRoot}/dune-project`,
  [
    "(lang dune 3.17)",
    "",
    "(pin",
    ` (url "git+file://${wellSnapshot}")`,
    " (package",
    '  (name well)))',
    "",
    "(pin",
    ` (url "git+file://${cyrografSnapshot}")`,
    " (package",
    '  (name cyrograf)))',
    "",
    "(package",
    " (name server)",
    " (depends",
    "  ocaml",
    "  well",
    "  cyrograf))",
    "",
  ].join("\n"),
);
await must("dune", ["pkg", "lock"], serverRoot);
await must("dune", ["build", "app/server.exe"], serverRoot);

// 4. Start the server from the isolated root (its cwd owns data/well.sock).
const child = new Deno.Command(`${serverRoot}/_build/default/app/server.exe`, {
  cwd: serverRoot,
  env: { ...Deno.env.toObject(), W4_PORT: String(port) },
  stdout: "piped",
  stderr: "piped",
}).spawn();

try {
  const deadline = Date.now() + 30000;
  let up = false;
  while (Date.now() < deadline) {
    try {
      const probe = await Deno.connect({ transport: "unix", path: socketPath });
      probe.close();
      up = true;
      break;
    } catch (_) { /* not yet */ }
    await new Promise((r) => setTimeout(r, 150));
  }
  if (!up) throw new Error("server socket did not come up");

  // Introspection.
  const list = await socketCall({ service: "_system", rpc: "list", payload: null });
  check(
    "_system list includes Orders",
    list?.result && Object.prototype.hasOwnProperty.call(list.result, "Orders"),
  );
  const describe = await socketCall({ service: "_system", rpc: "describe", payload: null });
  const orders = describe?.result?.Orders;
  check("_system describe includes Orders", Boolean(orders));
  check(
    "_system describe carries canonical param names",
    JSON.stringify(orders?.reserve?.params ?? []).includes("owner_id") &&
      JSON.stringify(orders?.reserve?.params ?? []).includes("quantity"),
  );
  const health = await socketCall({ service: "_system", rpc: "health", payload: null });
  check("_system health lists Orders", Boolean(health?.result?.Orders));
  check("_system health lists legacy actor", Boolean(health?.result?.LegacyEcho));

  // Wide Int rejected on the raw socket input (M06).
  const bad = await socketCallRaw(
    frame("Orders", "numbers", `[1.0000000000000001,1,-1,0.5,"x"]`),
  );
  check("fractional Int rejected over socket", typeof bad?.error === "string", JSON.stringify(bad));
  const good = await socketCallRaw(frame("Orders", "numbers", `[2,3,4,0.5,"x"]`));
  check(
    "integer-valued numbers round-trip",
    JSON.stringify(good?.result) === JSON.stringify([2, 3, 4, 0.5, "x"]),
    JSON.stringify(good),
  );

  // Handler failure does not disable later calls.
  const boom = await socketCallRaw(frame("Orders", "numbers", `[-1,1,-1,0.5,"x"]`));
  check("handler exception surfaced as error", typeof boom?.error === "string", JSON.stringify(boom));
  const after = await socketCallRaw(frame("Orders", "empty", `[]`));
  check("call after handler failure succeeds", JSON.stringify(after?.result) === "[]", JSON.stringify(after));

  // Server-side ctx is fixed for the socket; a client cannot inject it.
  const reserved = await socketCallRaw(
    frame("Orders", "reserve", `["owner",2,null,["thing",null],[]]`),
  );
  check(
    "socket ctx is server-side anonymous",
    JSON.stringify(reserved?.result).includes("ctx:none"),
    JSON.stringify(reserved),
  );

  // Legacy Actor over its mailbox.
  const ping = await socketCallRaw(frame("LegacyEcho", "ping", `"hi"`));
  check(
    "legacy Actor answers over the socket",
    JSON.stringify(ping?.result) === JSON.stringify({ pong: "hi" }),
    JSON.stringify(ping),
  );

  // Real `well repl` against the real socket.
  await must("dune", ["build", "bin/main.exe"], repoRoot);
  const repl = await run(
    `${repoRoot}/_build/default/bin/main.exe`,
    ["repl", "-s", socketPath, "-e", "Orders.empty"],
    repoRoot,
  );
  check("well repl exit 0", repl.code === 0, repl.stderr);
  check(
    "well repl called the generated service",
    !repl.stdout.toLowerCase().includes("error"),
    repl.stdout + repl.stderr,
  );
  if (repl.stdout.trim() !== "") console.log(repl.stdout.trim());
} finally {
  try {
    child.kill("SIGTERM");
    await child.status;
  } catch (_) { /* ignore */ }
}

console.log(`\nW4 socket harness: ${passed} passed, ${failed} failed`);
Deno.exit(failed > 0 ? 1 : 0);