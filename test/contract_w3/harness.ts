// Shared W3 harness: snapshots, generation and the real native server used by
// the browser and client acceptance runs. Deno/TypeScript only, per common.md.

export const home = Deno.env.get("HOME")!;
export const here = new URL(".", import.meta.url).pathname.replace(/\/$/, "");
export const repoRoot = `${here}/../..`;
export const cache = `${home}/.cache/well-w3`;
export const wellSnapshot = `${cache}/snapshot`;
export const cyrografSource = `${home}/ocaml-contract`;
export const cyrografSnapshot = `${home}/.cache/cyrograf-w2/snapshot`;
export const generated = `${cache}/generated`;
export const serverRoot = `${cache}/server`;
export const serverPort = 8478;

export async function run(cmd: string, args: string[], cwd: string) {
  const p = new Deno.Command(cmd, {
    args,
    cwd,
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

export async function must(cmd: string, args: string[], cwd: string) {
  const r = await run(cmd, args, cwd);
  if (r.code !== 0) {
    console.error(`FAILED: ${cmd} ${args.join(" ")} (cwd ${cwd})`);
    console.error(r.stdout);
    console.error(r.stderr);
    Deno.exit(1);
  }
  return r;
}

async function snapshot(
  source: string,
  target: string,
  opamName: string,
  opam: string,
) {
  await must("rm", ["-rf", target], repoRoot);
  await must("mkdir", ["-p", target], repoRoot);
  const excludes = "--exclude=_build --exclude=.git --exclude=vendor " +
    "--exclude=data --exclude=dune.lock --exclude=.axe --exclude=_release";
  await must("bash", [
    "-c",
    `tar -cf - ${excludes} -C '${source}' . | tar -xf - -C '${target}'`,
  ], repoRoot);
  await Deno.writeTextFile(`${target}/${opamName}.opam`, opam);
  await must("git", ["init", "-q"], target);
  await must("git", ["add", "-A"], target);
  await must("git", [
    "-c", "user.email=w3@snapshot", "-c", "user.name=W3 snapshot",
    "commit", "-qm", "W3 isolated snapshot",
  ], target);
  return (await must("git", ["rev-parse", "HEAD"], target)).stdout.trim();
}

export async function snapshotWell() {
  return await snapshot(
    repoRoot, wellSnapshot, "well",
    [
      'opam-version: "2.0"',
      'synopsis: "Well W3 snapshot"',
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
    ].join("\n"),
  );
}

export async function cyrografRev() {
  try {
    const r = await run("git", ["rev-parse", "HEAD"], cyrografSnapshot);
    if (r.code === 0) return r.stdout.trim();
  } catch (_) { /* fall through */ }
  return await snapshot(
    cyrografSource, cyrografSnapshot, "cyrograf",
    'opam-version: "2.0"\nsynopsis: "Cyrograf W3 snapshot"\ndepends: [ "ocaml" "dune" "yojson" "otoml" ]\nbuild: [ ["dune" "build" "-p" name "-j" jobs] ]\n',
  );
}

export async function generate(fixture: string, output: string) {
  await must("dune", ["build", "test/contract_build/gen.exe"], repoRoot);
  await must("rm", ["-rf", output], repoRoot);
  await must("mkdir", ["-p", output], repoRoot);
  await must(
    `${repoRoot}/_build/default/test/contract_build/gen.exe`,
    [fixture, output],
    repoRoot,
  );
}

export async function buildServer() {
  await must("rm", ["-rf", `${serverRoot}/app`], repoRoot);
  await must("mkdir", ["-p", `${serverRoot}/app`], repoRoot);
  await must("rm", ["-rf", `${serverRoot}/generated_ocaml`], repoRoot);
  await must("rm", ["-rf", `${serverRoot}/generated_adapters`], repoRoot);
  await must("cp", ["-r", `${generated}/ocaml`, `${serverRoot}/generated_ocaml`], repoRoot);
  await must("cp", ["-r", `${generated}/adapters`, `${serverRoot}/generated_adapters`], repoRoot);
  await Deno.copyFile(`${here}/server_main.ml`, `${serverRoot}/app/server.ml`);
  await Deno.copyFile(`${here}/server_dune`, `${serverRoot}/app/dune`);
  await Deno.writeTextFile(`${serverRoot}/dune-project`, [
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
  ].join("\n"));
  await must("dune", ["pkg", "lock"], serverRoot);
  await must("dune", ["build", "app/server.exe"], serverRoot);
}

export async function startServer() {
  const cmd = new Deno.Command(`${serverRoot}/_build/default/app/server.exe`, {
    cwd: serverRoot,
    env: { ...Deno.env.toObject(), W3_PORT: String(serverPort) },
    stdout: "piped",
    stderr: "piped",
  });
  const child = cmd.spawn();
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    try {
      const conn = await Deno.connect({ hostname: "127.0.0.1", port: serverPort });
      conn.close();
      return child;
    } catch (_) {
      await new Promise((r) => setTimeout(r, 150));
    }
  }
  child.kill("SIGKILL");
  throw new Error("server did not come up");
}

export async function stopServer(child: Deno.ChildProcess) {
  try {
    child.kill("SIGTERM");
    await child.status;
  } catch (_) { /* ignore */ }
}