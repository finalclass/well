const root = Deno.cwd();
const chrome = Deno.env.get("CHROME_BIN");
if (!chrome) throw new Error("Set CHROME_BIN to a Chrome/Chromium executable");
const runtime = await Deno.makeTempDir({ prefix: "well-cap-browser-" });
const profile = await Deno.makeTempDir({ prefix: "well-cap-chrome-" });
const output = Deno.env.get("CAP_EVIDENCE") ??
  `${root}/.local/liveview-migration/browser`;
await Deno.mkdir(output, { recursive: true });
const server = new Deno.Command(
  `${root}/_build/default/test/cap_mpa/server.exe`,
  { cwd: runtime, env: { CAP_PORT: "8495" }, stdout: "null", stderr: "null" },
).spawn();
const browser = new Deno.Command(chrome, {
  args: [
    "--headless=new",
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--disable-extensions",
    "--disable-features=PasswordLeakDetection,PasswordManagerOnboarding",
    "--no-default-browser-check",
    "--window-size=1440,900",
  ],
  stdout: "null",
  stderr: "null",
}).spawn();
let ws: WebSocket | undefined;
let scaffoldServer: Deno.ChildProcess | undefined;
const results: string[] = [];
const exceptions: unknown[] = [];
const requests: Array<{ url: string; type: string }> = [];
const sockets: string[] = [];
const origin = "http://127.0.0.1:8495";
let send: (method: string, params?: unknown) => Promise<any>;
async function wait(fn: () => Promise<boolean>, name: string, timeout = 8000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {
      if (await fn()) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`Timeout: ${name}`);
}
async function evaluate(expression: string): Promise<any> {
  const response = await send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (response.exceptionDetails) {
    throw new Error(JSON.stringify(response.exceptionDetails));
  }
  return response.result.value;
}
async function check(name: string, condition: () => Promise<boolean>) {
  await wait(condition, name);
  results.push(name);
  console.log(`ok browser ${name}`);
}
async function fill(selector: string, text: string) {
  await wait(
    () =>
      evaluate(
        `document.readyState==="complete"&&document.querySelector(${
          JSON.stringify(selector)
        })!==null`,
      ),
    `input ${selector}`,
  );
  await evaluate(
    `(()=>{const e=document.querySelector(${
      JSON.stringify(selector)
    });if(!e)throw new Error('Missing input');e.focus();e.select();})()`,
  );
  await send("Input.insertText", { text });
  await wait(
    () =>
      evaluate(
        `document.querySelector(${JSON.stringify(selector)})?.value===${
          JSON.stringify(text)
        }`,
      ),
    `fill ${selector}`,
  );
}
async function click(selector: string) {
  await wait(() => evaluate('document.readyState==="complete"'), "page ready");
  const navigation = await evaluate(
    `(()=>{const e=document.querySelector(${
      JSON.stringify(selector)
    });if(!e)throw new Error("Missing element");const a=e.closest("a[href]");const f=e.form;const navigation=!!a||!!(f&&e.type==="submit"&&!e.closest("cap-repl"));window.__acceptanceDocument=crypto.randomUUID();const id=window.__acceptanceDocument;e.scrollIntoView({block:"center"});e.click();return {navigation,id}})()`,
  );
  if (navigation.navigation) {
    await wait(() =>
      evaluate(
        `window.__acceptanceDocument!==${
          JSON.stringify(navigation.id)
        }&&document.readyState==="complete"`,
      ), "document navigation");
  }
}
async function key(key: string, _number: number) {
  await evaluate(
    `(()=>{const e=document.activeElement;const event=new KeyboardEvent("keydown",{key:${
      JSON.stringify(key)
    },code:${
      JSON.stringify(key)
    },bubbles:true,cancelable:true});const proceed=e.dispatchEvent(event);if(${
      JSON.stringify(key)
    }==="Enter"&&proceed&&e.form)e.form.requestSubmit();e.dispatchEvent(new KeyboardEvent("keyup",{key:${
      JSON.stringify(key)
    },bubbles:true}));})()`,
  );
}
async function path(path: string) {
  await wait(
    () =>
      evaluate(`location.pathname+location.search===${JSON.stringify(path)}`),
    `URL ${path}`,
  );
  await wait(() => evaluate('document.readyState==="complete"'), "page ready");
}
async function text(selector: string, value: string) {
  await wait(
    () =>
      evaluate(
        `document.querySelector(${
          JSON.stringify(selector)
        })?.textContent.includes(${JSON.stringify(value)})===true`,
      ),
    `text ${value}`,
  );
}
async function navigate(path_: string, expected = path_) {
  await send("Page.navigate", { url: origin + path_ });
  await path(expected);
  await wait(() => evaluate('document.readyState==="complete"'), "page ready");
}
async function screenshot(name: string) {
  const shot = await send("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: false,
  });
  await Deno.writeFile(
    `${output}/${name}.png`,
    Uint8Array.from(atob(shot.data), (c) => c.charCodeAt(0)),
  );
}
try {
  await wait(
    async () => {
      try {
        const r = await fetch(origin + "/_cap/login");
        await r.arrayBuffer();
        return r.ok;
      } catch {
        return false;
      }
    },
    "server",
    15000,
  );
  let port = "";
  await wait(
    async () => {
      try {
        port = (await Deno.readTextFile(profile + "/DevToolsActivePort")).split(
          "\n",
        )[0];
        return !!port;
      } catch {
        return false;
      }
    },
    "Chrome",
    15000,
  );
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`))
    .json();
  const target = targets.find((t: { type: string }) => t.type === "page");
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise<void>((resolve, reject) => {
    ws!.onopen = () => resolve();
    ws!.onerror = () => reject(new Error("CDP failed"));
  });
  let next = 0;
  const pending = new Map<
    number,
    { resolve: (value: any) => void; reject: (error: Error) => void }
  >();
  ws.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id) {
      const handler = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) {
        handler?.reject(new Error(JSON.stringify(message.error)));
      } else handler?.resolve(message.result);
    }
    if (message.method === "Runtime.exceptionThrown") {
      exceptions.push(message.params.exceptionDetails);
    }
    if (message.method === "Network.requestWillBeSent") {
      requests.push({
        url: message.params.request.url,
        type: message.params.type,
      });
    }
    if (message.method === "Network.webSocketCreated") {
      sockets.push(message.params.url);
    }
  };
  send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = ++next;
      pending.set(id, { resolve, reject });
      ws!.send(JSON.stringify({ id, method, params }));
    });
  await send("Page.enable");
  await send("Runtime.enable");
  await send("Network.enable");
  await send("Emulation.setDeviceMetricsOverride", {
    width: 1440,
    height: 900,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await navigate("/_cap/login");
  await fill("#email", "cap");
  await fill("#password", "bad");
  await click("button[type=submit]");
  await text(".login-error", "Nieprawidłowy");
  await fill("#email", "cap");
  await fill("#password", "admin");
  await click("button[type=submit]");
  await path("/_cap/");
  await check(
    "login and full SSR overview",
    () => evaluate('document.querySelectorAll(".stat-card").length>0'),
  );
  await screenshot("overview");
  await send("Page.bringToFront");
  for (const section of ["routes", "connections", "users"]) {
    await click(`a[href="/_cap/${section}"]`);
    await path("/_cap/" + section);
    await check(
      `MPA sidebar ${section}`,
      () => evaluate('document.querySelector(".page-header h2")!==null'),
    );
  }
  await screenshot("users");
  await click('a[href="/_cap/users/new"]');
  await path("/_cap/users/new");
  await fill("#email", "ui@example.com");
  await fill("#password", "BrowserPassword1");
  await click("button.btn-accent[type=submit]");
  await path("/_cap/users");
  await text(".data-table", "ui@example.com");
  const user = await evaluate(
    'Array.from(document.querySelectorAll("td a")).find(e=>e.textContent==="ui@example.com").getAttribute("href")',
  );
  await click(`a[href="${user}"]`);
  await path(user);
  await check(
    "user card distinct address",
    () =>
      evaluate(
        'document.querySelector(".card-title").textContent.includes("Użytkownik #")',
      ),
  );
  await fill("#email", "ui-renamed@example.com");
  await click('form[action$="/email"] button');
  await path(user);
  await check(
    "email saved",
    () =>
      evaluate(
        'document.querySelector("#email").value==="ui-renamed@example.com"',
      ),
  );
  await fill("input[name=password]", "ChangedPassword1");
  await click('form[action$="/password"] button');
  await text(".console-content", "Password updated");
  await check(
    "password cleared",
    () => evaluate('document.querySelector("input[name=password]").value===""'),
  );
  await fill("input[name=grant_name]", "reviewer");
  await click('form[action$="/grant"] button');
  await text(".console-content", "reviewer");
  await click('form[action$="/revoke"] button');
  await check(
    "grant revoked",
    () => evaluate(`document.querySelector('form[action$="/revoke"]')===null`),
  );
  await navigate("/_cap/users");
  await fill("input[name=q]", "ui-renamed");
  await click("button[type=submit].btn-sm:not(.sidebar-footer button)");
  await path("/_cap/users?q=ui-renamed");
  await check(
    "search GET URL",
    () => evaluate('document.querySelectorAll("tbody tr").length===1'),
  );
  await send("Page.reload");
  await text("tbody", "ui-renamed@example.com");
  await check(
    "reload retains filter",
    () =>
      evaluate('document.querySelector("input[name=q]").value==="ui-renamed"'),
  );
  await navigate(user);
  await navigate("/_cap/users");
  await evaluate("history.back()");
  await path(user);
  await evaluate("history.forward()");
  await path("/_cap/users");
  await check(
    "history restores user/list pages",
    () => evaluate('document.querySelector("input[name=q]")!==null'),
  );
  await click(`form[action="${user}/delete"] button`);
  await path("/_cap/users");
  await check(
    "delete saved",
    () =>
      evaluate(
        '!document.querySelector("tbody").innerText.includes("ui-renamed")',
      ),
  );
  await click('form[action="/_cap/users/1/delete"] button');
  await text(".login-error", "Cannot delete");
  results.push("last administrator protection");
  await click('a[href="/_cap/db"]');
  await path("/_cap/db");
  await screenshot("database");
  await click('.tab-bar a[href*="source=well"]');
  await text(".console-content", "_well_users");
  await click('.tab-bar a[href*="source=app"]');
  await text(".data-table", "Pozycja 1");
  await click('a[href*="page=1"]');
  await text(".data-table", "Pozycja 25");
  await check(
    "DB MPA pagination",
    () => evaluate('location.search.includes("page=1")'),
  );
  await navigate("/_cap/db?source=app&table=cap_items&page=0");
  await click('td a[href*="row=1&column=name"]');
  await fill("input[name=value]", "Edycja z przeglądarki");
  await click("td form button[type=submit]");
  await text("tbody", "Edycja z przeglądarki");
  results.push("cell edit");
  await fill("textarea[name=sql]", "SELECT name FROM cap_items WHERE id=1");
  await click("form:has(textarea[name=sql]) button");
  await text("tbody", "Edycja z przeglądarki");
  results.push("SQL execute");
  await fill("textarea[name=sql]", "INVALID SQL");
  await click("form:has(textarea[name=sql]) button");
  await text(".login-error", "syntax");
  results.push("SQL validation");
  await click('a[href="/_cap/services"]');
  await path("/_cap/services");
  await click(".svc-nav-link");
  await click(".svc-dropdown-item");
  await check(
    "service/method address",
    () =>
      evaluate(
        'location.search.includes("service=CapDemo")&&location.search.includes("rpc=echoInt")',
      ),
  );
  await fill("textarea[name=payload]", '{"value":12}');
  await click("form:has(textarea[name=payload]) button");
  await text(".code-block", "12");
  results.push("RPC execute");
  await fill("textarea[name=payload]", "bad JSON");
  await click("form:has(textarea[name=payload]) button");
  await text(".code-block", "Error:");
  results.push("RPC validation");
  await click('a[href="/_cap/repl"]');
  await path("/_cap/repl");
  await wait(
    () => evaluate('document.querySelector(".repl-input-field")!==null'),
    "TEA REPL",
  );
  await fill(".repl-input-field", "2 + 3");
  await key("Enter", 13);
  await text(".repl-output-area", "5");
  await check(
    "REPL input reset",
    () => evaluate('document.querySelector(".repl-input-field").value===""'),
  );
  await key("ArrowUp", 38);
  await check(
    "REPL history up key",
    () =>
      evaluate('document.querySelector(".repl-input-field").value==="2 + 3"'),
  );
  await key("ArrowDown", 40);
  await check(
    "REPL next history key",
    () => evaluate('document.querySelector(".repl-input-field").value===""'),
  );
  await fill(".repl-input-field", "CapDemo.");
  await wait(
    () =>
      evaluate(
        'document.querySelector(".repl-completions").textContent.includes("echoInt")',
      ),
    "completion",
  );
  await key("Tab", 9);
  await check(
    "REPL autocomplete key",
    () =>
      evaluate(
        'document.querySelector(".repl-input-field").value==="CapDemo.echoInt "',
      ),
  );
  await fill(".repl-input-field", "let x = CapDemo.echoInt value:19");
  await key("Enter", 13);
  await text(".repl-output-area", "19");
  await fill(".repl-input-field", "x.value");
  await key("Enter", 13);
  await check(
    "REPL RPC and variables",
    () => evaluate('document.querySelectorAll(".repl-entry").length===3'),
  );
  await fill(".repl-input-field", "missingVariable");
  await key("Enter", 13);
  await text(".repl-error", "undefined");
  await check(
    "REPL error remains plain text",
    () =>
      evaluate(
        '!document.querySelector(".repl-error").textContent.includes("&quot;")',
      ),
  );
  results.push("REPL error");
  await click(".repl-toolbar button:first-child");
  await check(
    "REPL help",
    () => evaluate('document.querySelector(".repl-help")!==null'),
  );
  await screenshot("repl");
  await click(".repl-toolbar button:nth-child(2)");
  await check(
    "REPL clear",
    () => evaluate('document.querySelectorAll(".repl-entry").length===0'),
  );
  await click('a[href="/_cap/logs"]');
  await path("/_cap/logs");
  await wait(
    () => evaluate('document.querySelector("cap-stream button")!==null'),
    "TEA logs",
  );
  await fetch(origin + "/acceptance-event");
  await text("cap-stream", "Log testowy CAP");
  results.push("logs update");
  await fill("input[name=q]", "Log testowy");
  await click(".log-filters button");
  await check(
    "log filter URL",
    () =>
      evaluate('new URL(location.href).searchParams.get("q")==="Log testowy"'),
  );
  await text("cap-stream", "Log testowy CAP");
  await screenshot("logs");
  await click("cap-stream button:nth-child(2)");
  await text("cap-stream", "Widok wyczyszczony");
  await click("cap-stream button:first-child");
  await text("cap-stream", "Log testowy CAP");
  results.push("logs clear/resume");
  await evaluate('document.querySelector("select[name=level]").value="error"');
  await click(".log-filters button");
  await text("cap-stream", "Brak wpisów");
  await check(
    "log level URL and empty result",
    () =>
      evaluate('new URL(location.href).searchParams.get("level")==="error"'),
  );
  await click('.log-filters a[href="/_cap/logs"]');
  await path("/_cap/logs");
  await text("cap-stream", "Log testowy CAP");
  await click('a[href="/_cap/messages"]');
  await path("/_cap/messages");
  await wait(
    () => evaluate('document.querySelector("cap-stream button")!==null'),
    "TEA messages",
  );
  await fetch(origin + "/acceptance-event");
  await text("cap-stream", "Wiadomość testowa");
  results.push("messages update");
  await click("cap-stream button:nth-child(2)");
  await text("cap-stream", "Widok wyczyszczony");
  results.push("messages clear");
  await click('a[href="/_cap/telemetry"]');
  await path("/_cap/telemetry");
  await text("cap-stream", "Total requests");
  const firstCount = await evaluate(
    'Array.from(document.querySelectorAll(".stat-card")).find(e=>e.textContent.includes("Total requests")).querySelector(".stat-value").textContent',
  );
  await fetch(origin + "/acceptance-event");
  await check(
    "telemetry updates",
    () =>
      evaluate(
        `Array.from(document.querySelectorAll(".stat-card")).find(e=>e.textContent.includes("Total requests")).querySelector(".stat-value").textContent!==${
          JSON.stringify(firstCount)
        }`,
      ),
  );
  const before = requests.filter((r) =>
    r.url.includes("/_cap/api/telemetry")
  ).length;
  await evaluate('document.querySelector("cap-stream").remove()');
  await new Promise((r) => setTimeout(r, 4500));
  const after = requests.filter((r) =>
    r.url.includes("/_cap/api/telemetry")
  ).length;
  if (after > before + 1) throw new Error("Unmount continues polling");
  results.push("TEA unmount stops polling");
  await navigate("/_cap/users");
  await send("Emulation.setDeviceMetricsOverride", {
    width: 390,
    height: 844,
    deviceScaleFactor: 1,
    mobile: true,
  });
  await click(".menu-toggle");
  await check(
    "mobile MPA menu",
    () => evaluate('document.querySelector("#cap-menu").checked===true'),
  );
  await screenshot("mobile-users");
  await send("Emulation.setDeviceMetricsOverride", {
    width: 1440,
    height: 900,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await navigate("/_cap/users");
  await click(".sidebar-footer button");
  await path("/_cap/login");
  results.push("POST logout");
  await navigate("/_cap/users", "/_cap/login");
  await path("/_cap/login");
  results.push("logout blocks protected pages");
  if (
    sockets.length ||
    requests.some((r) => /\/live(?:\/|\?|$)|\/well\.js/.test(r.url))
  ) throw new Error("Legacy UI transport requested");
  results.push("no legacy transport");
  const scaffold = Deno.env.get("CAP_SCAFFOLD");
  if (scaffold) {
    scaffoldServer = new Deno.Command(
      `${scaffold}/_build/default/bin/main.exe`,
      {
        cwd: scaffold,
        stdout: "null",
        stderr: "null",
      },
    ).spawn();
    const scaffoldOrigin = "http://127.0.0.1:8612";
    await wait(
      async () => {
        try {
          const response = await fetch(scaffoldOrigin);
          const html = await response.text();
          return response.ok && html.includes('href="/counter"');
        } catch {
          return false;
        }
      },
      "scaffold SSR",
      15000,
    );
    await send("Page.navigate", { url: scaffoldOrigin });
    await path("/");
    await check(
      "scaffold SSR home",
      () => evaluate('document.querySelector("h1")!==null'),
    );
    await click('a[href="/counter"]');
    await path("/counter");
    await text("well-counter .count", "0");
    await click("well-counter button:nth-of-type(2)");
    await text("well-counter .count", "1");
    await click("well-counter button:first-of-type");
    await text("well-counter .count", "0");
    await click("well-counter button:nth-of-type(2)");
    await click("well-counter button:last-of-type");
    await text("well-counter .count", "0");
    results.push("scaffold TEA counter increment/decrement/reset");
    await screenshot("scaffold-counter");
  }
  if (exceptions.length) throw new Error(JSON.stringify(exceptions));
  results.push("no browser exceptions");
  await Deno.writeTextFile(
    `${output}/report.json`,
    JSON.stringify(
      {
        passed: results.length,
        checks: results,
        requests: requests.map((r) => ({
          url: r.url.replace(origin, ""),
          type: r.type,
        })),
        sockets,
        exceptions,
      },
      null,
      2,
    ),
  );
  console.log(`CAP browser: ${results.length} passed`);
} catch (error) {
  await screenshot("failure");
  console.log("failure url", await evaluate("location.href"));
  throw error;
} finally {
  ws?.close();
  for (
    const child of [
      browser,
      server,
      ...(scaffoldServer ? [scaffoldServer] : []),
    ]
  ) {
    try {
      child.kill("SIGTERM");
    } catch {}
    await child.status;
  }
  await Deno.remove(profile, { recursive: true });
  await Deno.remove(runtime, { recursive: true });
}
