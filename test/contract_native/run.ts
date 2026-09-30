// W2 outside-repo consumer harness (Deno).
//
// Materializes an isolated dune project that compiles the generated contract
// libraries and the generated Well adapters and runs local and HTTP RPC. The
// project pins an isolated snapshot of this Well working tree and of the
// Cyrograf working tree; it is never built inside the Well workspace.

const home = Deno.env.get("HOME")!;
const here = new URL(".", import.meta.url).pathname.replace(/\/$/, "");
const repoRoot = `${here}/../..`;
const cache = `${home}/.cache/well-w2`;
const consumer = `${cache}/consumer`;
const wellSnapshot = `${cache}/snapshot`;
const cyrografSource = `${home}/ocaml-contract`;
const cyrografSnapshot = `${home}/.cache/cyrograf-w2/snapshot`;

async function run(cmd: string, args: string[], cwd: string) {
  const p = new Deno.Command(cmd, { args, cwd, stdout: "piped", stderr: "piped" });
  const out = await p.output();
  return {
    code: out.code,
    stdout: new TextDecoder().decode(out.stdout),
    stderr: new TextDecoder().decode(out.stderr),
  };
}

async function must(cmd: string, args: string[], cwd: string) {
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
    "-c", "user.email=w2@snapshot", "-c", "user.name=W2 snapshot",
    "commit", "-qm", "W2 isolated snapshot",
  ], target);
  const rev = await must("git", ["rev-parse", "HEAD"], target);
  return rev.stdout.trim();
}

// 1. Build the generator and materialize the generated artifacts.
await must("dune", ["build", "test/contract_build/gen.exe"], repoRoot);
await must("rm", ["-rf", consumer], repoRoot);
await must("mkdir", ["-p", `${consumer}/app`, `${consumer}/generated/ocaml`,
  `${consumer}/generated/adapters`], repoRoot);
await must(`${repoRoot}/_build/default/test/contract_build/gen.exe`,
  [`${repoRoot}/test/contract_build/fixtures/native`, `${consumer}/stage`], repoRoot);
for (const [from, to] of [["stage/ocaml", "generated/ocaml"],
  ["stage/adapters", "generated/adapters"]]) {
  await must("cp", ["-r", `${consumer}/${from}`, `${consumer}/${to}`], repoRoot);
}
await must("rm", ["-rf", `${consumer}/stage`], repoRoot);

// 2. Materialize the consumer project files.
const duneProject = await Deno.readTextFile(`${here}/dune-project.template`);
const wellRev = await snapshot(
  repoRoot, wellSnapshot, "well",
  [
    'opam-version: "2.0"',
    'synopsis: "Well W2 snapshot"',
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
const cyrografRev = await (async () => {
  // Reuse the snapshot pinned by the Well dune-project when present so Well's
  // own lock stays valid; create it only when missing.
  try {
    const r = await run("git", ["rev-parse", "HEAD"], cyrografSnapshot);
    if (r.code === 0) return r.stdout.trim();
  } catch (_) { /* fall through */ }
  return await snapshot(
    cyrografSource, cyrografSnapshot, "cyrograf",
    'opam-version: "2.0"\nsynopsis: "Cyrograf W2 snapshot"\ndepends: [ "ocaml" "dune" "yojson" "otoml" ]\nbuild: [ ["dune" "build" "-p" name "-j" jobs] ]\n');
})();
await Deno.writeTextFile(`${consumer}/dune-project`,
  duneProject.replace("@WELL_SNAPSHOT@", wellSnapshot)
    .replace("@CYROGRAF_SNAPSHOT@", cyrografSnapshot));
await Deno.copyFile(`${here}/app_dune`, `${consumer}/app/dune`);
await Deno.copyFile(`${here}/main.ml`, `${consumer}/app/main.ml`);
console.error(`well snapshot ${wellRev}, cyrograf snapshot ${cyrografRev}`);

// 3. Lock, build and run the isolated consumer.
await must("dune", ["pkg", "lock"], consumer);
await must("dune", ["build", "app/main.exe"], consumer);
const result = await must("dune", ["exec", "app/main.exe"], consumer);
console.log(result.stdout);
console.error(result.stderr);
Deno.exit(result.code);