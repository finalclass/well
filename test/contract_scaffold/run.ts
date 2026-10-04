// W6 scaffold acceptance (M12).
//
// Materializes `well init` outside the repository, pins the scaffold to an
// isolated snapshot of this Well working tree, locks dependencies (Cyrograf
// from its published reachable revision), generates the contracts through the
// same mechanism as `well contract build`, builds/checks, exercises real RPC
// and the generated browser Proxy in a real browser, then deletes only the
// generated results and rebuilds deterministically.
//
// The scaffold never depends on a local Cyrograf checkout or on a separately
// installed cyrograf binary: Cyrograf is only a pinned library dependency.

const home = Deno.env.get("HOME")!;
const here = new URL(".", import.meta.url).pathname.replace(/\/$/, "");
const repoRoot = `${here}/../..`;
const cache = `${home}/.cache/well-w6`;
const snapshotDir = `${cache}/snapshot`;
const scaffoldRoot = `${cache}/scaffold`;
const project = `${scaffoldRoot}/demoapp`;
const port = 8612;

async function run(cmd: string, args: string[], cwd: string, env?: Record<string, string>) {
  const p = new Deno.Command(cmd, {
    args, cwd, stdout: "piped", stderr: "piped",
    env: env === undefined ? undefined : { ...Deno.env.toObject(), ...env },
  });
  const out = await p.output();
  return {
    code: out.code,
    stdout: new TextDecoder().decode(out.stdout),
    stderr: new TextDecoder().decode(out.stderr),
  };
}

async function must(cmd: string, args: string[], cwd: string, env?: Record<string, string>) {
  const r = await run(cmd, args, cwd, env);
  if (r.code !== 0) {
    console.error(`FAILED: ${cmd} ${args.join(" ")} (cwd ${cwd})`);
    console.error(r.stdout);
    console.error(r.stderr);
    Deno.exit(1);
  }
  return r;
}

async function sha256Dir(dir: string): Promise<string> {
  const r = await must(
    "bash",
    ["-c",
      `find '${dir}' -type f \\( -name '*.ml' -o -name '*.mli' -o -name '*.ts' ` +
      `-o -name 'manifest.json' -o -name 'schema.json' \\) | sort | xargs sha256sum`],
    repoRoot,
  );
  return r.stdout;
}

async function stopServer(child: Deno.ChildProcess): Promise<void> {
  try { child.kill("SIGTERM"); } catch (_) { /* already gone */ }
  await new Promise((res) => setTimeout(res, 2000));
  try { child.kill("SIGKILL"); } catch (_) { /* already gone */ }
  // The server may be reparented if the wrapper exited first; free the port
  // explicitly so a rerun never sees a stale listener.
  await run("bash", ["-c", `fuser -k ${port}/tcp 2>/dev/null; true`], repoRoot);
  await Promise.race([
    child.status.catch(() => {}),
    new Promise((res) => setTimeout(res, 3000)),
  ]);
}

async function waitForPort(p: number): Promise<boolean> {
  for (let i = 0; i < 120; i++) {
    try {
      const s = await Deno.connect({ hostname: "127.0.0.1", port: p });
      s.close();
      return true;
    } catch (_) {
      await new Promise((res) => setTimeout(res, 250));
    }
  }
  return false;
}

const checks: Array<[string, boolean]> = [];
const check = (name: string, ok: boolean) => checks.push([name, ok]);

// 0. Free the ports so an aborted earlier run cannot leak a stale server.
await run("bash", ["-c",
  `fuser -k ${port}/tcp ${port + 1}/tcp 2>/dev/null; true`], repoRoot);

// 1. Snapshot this Well working tree and build the framework binary.
await must("dune", ["build", "bin/main.exe"], repoRoot);
await must("rm", ["-rf", snapshotDir], repoRoot);
await must("mkdir", ["-p", snapshotDir], repoRoot);
await must("bash", ["-c",
  "tar --exclude=_build --exclude=.git --exclude=vendor --exclude=data " +
  "--exclude=dune.lock --exclude=.axe --exclude=_release --exclude=.local --exclude=.agents " +
  `-cf - -C '${repoRoot}' . | tar -xf - -C '${snapshotDir}'`], repoRoot);
await Deno.writeTextFile(`${snapshotDir}/well.opam`, [
  'opam-version: "2.0"',
  'synopsis: "Well W6 snapshot"',
  "depends: [",
  '  "ocaml" {>= "5.4"} "dune" "yojson" "sqlite3" "eio" "eio_main"',
  '  "tls-eio" "x509" "mirage-crypto-pk" "digestif" "base64" "zarith"',
  '  "ppxlib" "ppx_deriving" "ppx_deriving_yojson" "otoml" "camlzip"',
  '  "js_of_ocaml" "js_of_ocaml-compiler" "js_of_ocaml-ppx" "mlx"',
  '  "menhir" "menhirLib" "merlin-extend" "domain-name" "ptime" "str"',
  '  "cyrograf"',
  "]",
  'build: [ ["dune" "build" "-p" name "-j" jobs] ]',
  "",
].join("\n"));
await must("git", ["init", "-q"], snapshotDir);
await must("git", ["add", "-A"], snapshotDir);
await must("git", ["-c", "user.email=w6@snapshot", "-c", "user.name=W6 snapshot",
  "commit", "-qm", "W6 snapshot"], snapshotDir);
const wellRev = (await must("git", ["rev-parse", "HEAD"], snapshotDir)).stdout.trim();
console.error(`well snapshot ${wellRev}`);

// 2. Materialize the scaffold without the init-time lock/build (dune is hidden
//    from PATH so only files are written), then pin Well to the snapshot.
await must("rm", ["-rf", scaffoldRoot], repoRoot);
await must("mkdir", ["-p", scaffoldRoot], repoRoot);
await must(`${repoRoot}/_build/default/bin/main.exe`, ["init", "demoapp"], scaffoldRoot, {
  PATH: "/usr/bin:/bin",
});
const duneProject = await Deno.readTextFile(`${project}/dune-project`);
await Deno.writeTextFile(
  `${project}/dune-project`,
  duneProject.replace(
    "git+ssh://git@github.com/finalclass/well.git",
    `git+file://${snapshotDir}`,
  ),
);
const wellToml = await Deno.readTextFile(`${project}/well.toml`);
await Deno.writeTextFile(`${project}/well.toml`,
  wellToml.replace("port = 4000", `port = ${port}`));

// 3. Lock, generate, build and check.
await must("rm", ["-rf", `${project}/dune.lock`], repoRoot);
await must("dune", ["pkg", "lock"], project);
const lock = await Deno.readTextFile(`${project}/dune.lock/cyrograf.dev.pkg`);
check("cyrograf lock is a reachable github revision",
  lock.includes("git+https://github.com/finalclass/cyrograf#") &&
  !lock.includes("/home/"));
await must("dune", ["build"], project);
await must("dune", ["build", "@check"], project);
await must("dune", ["build",
  "lib/contract_generated/adapters_browser/contract_browser.cma"], project);
const generatedDir = `${project}/lib/contract_generated`;
const before = await sha256Dir(generatedDir);
check("generation produced the expected artifacts",
  before.includes("ocaml/task_manager.ml") &&
  before.includes("adapters_browser/task_manager.ml") &&
  before.includes("typescript/proxy_taskmanager.ts") &&
  before.includes("manifest.json"));

// 4. Real RPC against the scaffold server.
const server = new Deno.Command("/bin/sh", {
  args: ["-c", `exec '${project}/_build/default/bin/main.exe' > server.log 2>&1`],
  cwd: project, stdout: "null", stderr: "null",
}).spawn();
const up = await waitForPort(port);
check("scaffold server started", up);
if (up) {
  const base = `http://127.0.0.1:${port}`;
  const xhr = { "content-type": "application/json", "x-requested-with": "XMLHttpRequest" };
  const addRes = await fetch(`${base}/rpc/TaskManager/add`, {
    method: "POST", headers: xhr, body: '["from-scaffold"]',
  });
  const addText = await addRes.text();
  check("RPC add -> 200 with Drut response",
    addRes.status === 200 && /^\[\[\d+,"from-scaffold",false\]\]$/.test(addText));
  const listRes = await fetch(`${base}/rpc/TaskManager/list`, {
    method: "POST", headers: xhr, body: "[100]",
  });
  const listText = await listRes.text();
  check("RPC list returns the added task",
    listRes.status === 200 && listText.includes("from-scaffold"));
  const badRes = await fetch(`${base}/rpc/TaskManager/add`, {
    method: "POST", headers: xhr, body: '["x","extra"]',
  });
  check("bad Drut request -> 400", badRes.status === 400);

  // 5. Browser Proxy in a real browser, same origin via a small proxy that
  //    forwards raw Drut bodies to the scaffold server.
  await Deno.mkdir(`${project}/web_browser`, { recursive: true });
  await Deno.copyFile(`${here}/browser_main.ml`, `${project}/web_browser/browser_main.ml`);
  await Deno.copyFile(`${here}/browser_dune`, `${project}/web_browser/dune`);
  await must("dune", ["build", "web_browser/browser_main.bc.js"], project);
  const jsPath = `${project}/_build/default/web_browser/browser_main.bc.js`;
  const jsText = await Deno.readTextFile(jsPath);
  check("browser bundle links neither Eio, Sqlite3 nor the Cyrograf compiler",
    !/\bEio\b/.test(jsText) && !/Sqlite3/.test(jsText) &&
    !/Cyrograf_compiler/.test(jsText));

  const proxyPort = port + 1;
  const browser = Deno.serve({ port: proxyPort, hostname: "127.0.0.1" }, async (req) => {
    const url = new URL(req.url);
    if (url.pathname === "/") {
      return new Response(
        `<!doctype html><html><head><meta charset="utf-8"></head>` +
        `<body><script src="/browser_main.bc.js"></script></body></html>`,
        { headers: { "content-type": "text/html" } },
      );
    }
    if (url.pathname === "/browser_main.bc.js") {
      return new Response(await Deno.readTextFile(jsPath),
        { headers: { "content-type": "text/javascript" } });
    }
    if (url.pathname.startsWith("/rpc/")) {
      const body = await req.text();
      const forwarded = new Headers();
      for (const [k, v] of req.headers) {
        const lk = k.toLowerCase();
        if (["origin", "sec-fetch-site", "host", "connection",
          "content-length", "transfer-encoding"].includes(lk)) continue;
        forwarded.set(k, v);
      }
      const response = await fetch(`${base}${url.pathname}`,
        { method: "POST", headers: forwarded, body });
      return new Response(await response.text(),
        { status: response.status, headers: { "content-type": "application/json" } });
    }
    return new Response("not found", { status: 404 });
  });
  const ab = (args: string[]) =>
    run("timeout", ["30", "agent-browser", "--session", "w6-browser", ...args], repoRoot);
  const listHits = async () => {
    const log = await Deno.readTextFile(`${project}/server.log`);
    return log.split("path=/rpc/TaskManager/list").length - 1;
  };
  try {
    await ab(["close", "--all"]);
    const hitsBefore = await listHits();
    const opened = await ab(["open", `http://127.0.0.1:${proxyPort}/`]);
    check("browser opened the scaffold page", opened.code === 0);
    let hitsAfter = hitsBefore;
    for (let i = 0; i < 60 && hitsAfter <= hitsBefore; i++) {
      await new Promise((res) => setTimeout(res, 500));
      hitsAfter = await listHits();
    }
    check("browser Proxy ran a real RPC list against the scaffold server",
      hitsAfter > hitsBefore);
  } finally {
    await ab(["close", "--all"]);
    await Promise.race([
      browser.shutdown(),
      new Promise((res) => setTimeout(res, 5000)),
    ]);
  }
  await stopServer(server);
  const serverLog = `${project}/server.log`;
  try {
    const log = await Deno.readTextFile(serverLog);
    if (log.includes("Fatal") || log.includes("Exception")) {
      console.error(log);
      check("scaffold server logged no fatal error",
        !log.includes("Fatal") && !log.includes("Exception"));
    }
  } catch (_) { /* no log */ }
} else {
  await stopServer(server);
}

// 6. Delete only the generated results and rebuild deterministically.
await must("bash", ["-c",
  `find '${generatedDir}' -type f \\( -name '*.ml' -o -name '*.mli' -o -name '*.ts' ` +
  `-o -name 'manifest.json' -o -name 'schema.json' \\) -delete`], repoRoot);
await must("dune", ["build"], project);
const after = await sha256Dir(generatedDir);
check("regeneration after deletion is byte-identical", after === before);

for (const [name, ok] of checks) {
  console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
}
const failed = checks.filter(([, ok]) => !ok).length;
console.log(`\nW6 scaffold: ${checks.length - failed} passed, ${failed} failed`);
Deno.exit(failed > 0 ? 1 : 0);
