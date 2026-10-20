const executable =
  `${Deno.cwd()}/_build/default/test/cap_log_retention/retention.exe`;
for (
  const mode of ["functional", "raw", "small", "large", "context", "import"]
) {
  const runtime = await Deno.makeTempDir({ prefix: "well-cap-retention-" });
  try {
    const child = new Deno.Command(executable, {
      args: [mode],
      cwd: runtime,
      env: { TZ: "Europe/Warsaw" },
      stdout: "inherit",
      stderr: "inherit",
    }).spawn();
    const timeout = setTimeout(() => child.kill("SIGKILL"), 180000);
    const result = await child.status;
    clearTimeout(timeout);
    if (!result.success) throw new Error(`${mode} failed: ${result.code}`);
  } finally {
    await Deno.remove(runtime, { recursive: true });
  }
}
