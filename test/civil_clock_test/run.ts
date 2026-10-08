const [consumer, compiler, wellCmi, timedescCmi] = Deno.args;
const base = new URL(`file://${Deno.cwd()}/`);
const decoder = new TextDecoder();

async function run(
  command: string | URL,
  args: string[],
  options: { cwd?: string; env?: Record<string, string> } = {},
) {
  const output = await new Deno.Command(command, {
    args,
    ...options,
    stdout: "piped",
    stderr: "piped",
  }).output();
  return {
    code: output.code,
    stdout: decoder.decode(output.stdout),
    stderr: decoder.decode(output.stderr),
  };
}

for (const timezone of ["UTC", "America/New_York"]) {
  const result = await run(new URL(consumer, base), [], {
    env: { TZ: timezone },
  });
  if (result.code !== 0) {
    throw new Error(`C06 consumer TZ=${timezone}: ${result.stderr}`);
  }
  console.log(`TZ=${timezone}: ${result.stdout.trim()}`);
}

const temporary = await Deno.makeTempDir({ prefix: "well-civil-clock-types-" });
try {
  const includes: string[] = [];
  for (const path of [wellCmi, timedescCmi]) {
    const real = await Deno.realPath(new URL(path, base));
    includes.push("-I", new URL(".", new URL(`file://${real}`)).pathname);
  }
  for (
    const [name, shouldCompile, expectedTypes] of [
      ["valid", true, []],
      ["invalid_zone", false, ["Time_zone.t", "Civil_clock.zone"]],
      ["invalid_date", false, ["Civil_clock.date_time", "Civil_clock.date"]],
    ] as const
  ) {
    const source = new URL(`compile_fail/${name}.ml`, import.meta.url);
    const target = `${temporary}/${name}.ml`;
    await Deno.copyFile(source, target);
    const result = await run(new URL(compiler, base), [
      ...includes,
      "-c",
      target,
    ], { cwd: temporary });
    if ((result.code === 0) !== shouldCompile) {
      throw new Error(
        `C06 ${name}: unexpected compiler result\n${result.stderr}`,
      );
    }
    if (!shouldCompile) {
      if (
        !result.stderr.includes("has type") ||
        !expectedTypes.every((type) => result.stderr.includes(type))
      ) {
        throw new Error(
          `C06 ${name}: unrelated compiler failure\n${result.stderr}`,
        );
      }
    }
    console.log(
      `C06 ${name}: ${shouldCompile ? "compiled" : "type mismatch rejected"}`,
    );
  }
} finally {
  await Deno.remove(temporary, { recursive: true });
}
