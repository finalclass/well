const root = Deno.cwd();
const encoder = new TextEncoder();
const decoder = new TextDecoder();
let passed = 0;
function check(name: string, condition: boolean) {
  if (!condition) throw new Error(name);
  passed++;
  console.log(`ok ${name}`);
}

class Socket {
  private buffer = new Uint8Array();
  private inbox: Record<string, unknown>[] = [];
  private waiters: ((message: Record<string, unknown>) => void)[] = [];
  private closed = false;
  private constructor(private conn: Deno.TcpConn) {}

  private async bytes(size: number): Promise<Uint8Array> {
    while (this.buffer.length < size) {
      const chunk = new Uint8Array(4096);
      const length = await this.conn.read(chunk);
      if (length === null) throw new Error("WebSocket closed");
      const joined = new Uint8Array(this.buffer.length + length);
      joined.set(this.buffer);
      joined.set(chunk.subarray(0, length), this.buffer.length);
      this.buffer = joined;
    }
    const result = this.buffer.slice(0, size);
    this.buffer = this.buffer.slice(size);
    return result;
  }

  static async open(port: number, cookie = "") {
    const conn = await Deno.connect({ hostname: "127.0.0.1", port });
    const socket = new Socket(conn);
    const key = btoa(
      String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16))),
    );
    await socket.write(encoder.encode(
      `GET /ws HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ${key}\r\n${
        cookie ? `Cookie: ${cookie}\r\n` : ""
      }\r\n`,
    ));
    let headers = "";
    while (!headers.endsWith("\r\n\r\n")) {
      headers += decoder.decode(await socket.bytes(1));
      if (headers.length > 8192) throw new Error("Oversized handshake");
    }
    check(
      "shared WebSocket accepts connection",
      headers.startsWith("HTTP/1.1 101"),
    );
    const digest = new Uint8Array(
      await crypto.subtle.digest(
        "SHA-1",
        encoder.encode(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"),
      ),
    );
    check(
      "valid WebSocket handshake",
      headers.includes(btoa(String.fromCharCode(...digest))),
    );
    void socket.receive();
    return socket;
  }

  private async write(bytes: Uint8Array) {
    let offset = 0;
    while (offset < bytes.length) {
      offset += await this.conn.write(bytes.subarray(offset));
    }
  }

  private async frame(opcode: number, payload: Uint8Array) {
    if (payload.length >= 126) throw new Error("Test frame too large");
    const mask = crypto.getRandomValues(new Uint8Array(4));
    const frame = new Uint8Array(6 + payload.length);
    frame[0] = 0x80 | opcode;
    frame[1] = 0x80 | payload.length;
    frame.set(mask, 2);
    for (let i = 0; i < payload.length; i++) {
      frame[i + 6] = payload[i] ^ mask[i % 4];
    }
    await this.write(frame);
  }

  private async receive() {
    try {
      while (!this.closed) {
        const header = await this.bytes(2);
        const opcode = header[0] & 15;
        let size = header[1] & 127;
        if (size === 126) {
          const length = await this.bytes(2);
          size = (length[0] << 8) | length[1];
        } else if (size === 127) {
          size = Number(
            new DataView((await this.bytes(8)).buffer).getBigUint64(0),
          );
        }
        if (size > 65536 || header[1] & 128) {
          throw new Error("Invalid server frame");
        }
        const payload = await this.bytes(size);
        if (opcode === 8) break;
        if (opcode === 9) await this.frame(10, payload);
        if (opcode === 1) {
          const message = JSON.parse(decoder.decode(payload));
          const waiter = this.waiters.shift();
          if (waiter) waiter(message);
          else this.inbox.push(message);
        }
      }
    } catch (error) {
      if (!this.closed) console.error(error);
    }
  }

  send(type: string, channel: string, event = "echo") {
    return this.frame(
      1,
      encoder.encode(JSON.stringify({ type, channel, event })),
    );
  }

  next(): Promise<Record<string, unknown>> {
    const ready = this.inbox.shift();
    if (ready) return Promise.resolve(ready);
    return new Promise((resolve, reject) => {
      const waiter = (message: Record<string, unknown>) => {
        clearTimeout(timeout);
        resolve(message);
      };
      const timeout = setTimeout(() => {
        this.waiters = this.waiters.filter((item) => item !== waiter);
        reject(new Error("Timed out waiting for WebSocket message"));
      }, 3000);
      this.waiters.push(waiter);
    });
  }

  close() {
    this.closed = true;
    this.conn.close();
  }
}

async function run(enabled: boolean) {
  const runtime = await Deno.makeTempDir({ prefix: "well-cap-access-" });
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const port = (listener.addr as Deno.NetAddr).port;
  listener.close();
  const log = await Deno.open(`${runtime}/server.log`, {
    create: true,
    write: true,
  });
  const server = new Deno.Command(
    `${root}/_build/default/test/cap_access/server.exe`,
    {
      cwd: runtime,
      env: {
        CAP_ACCESS_PORT: String(port),
        CAP_ACCESS_ENABLED: String(enabled),
      },
      stdout: "null",
      stderr: "piped",
    },
  ).spawn();
  const logging = server.stderr.pipeTo(log.writable, { preventClose: true });
  const sockets: Socket[] = [];
  const base = `http://127.0.0.1:${port}`;
  async function request(
    path: string,
    cookie = "",
    method = "GET",
    fields?: Record<string, string>,
  ) {
    const response = await fetch(base + path, {
      method,
      redirect: "manual",
      headers: cookie ? { Cookie: cookie } : {},
      body: fields ? new URLSearchParams(fields) : undefined,
      signal: AbortSignal.timeout(5000),
    });
    return {
      status: response.status,
      headers: response.headers,
      text: await response.text(),
    };
  }
  async function login(email: string) {
    const result = await request("/test/login", "", "POST", { email });
    check(`${email} authenticated`, result.status === 200);
    const cookie = result.headers.getSetCookie().find((value) =>
      value.startsWith("well_session=")
    )?.split(";")[0];
    if (!cookie) throw new Error("Missing session cookie");
    return cookie;
  }
  async function connect(cookie = "") {
    const socket = await Socket.open(port, cookie);
    sockets.push(socket);
    return socket;
  }
  async function appBarrier(socket: Socket) {
    await socket.send("push", "app:probe");
    const reply = await socket.next();
    check(
      "application command remains available without CAP data",
      reply.type === "reply" && reply.payload === "application-reply",
    );
  }
  const diagnostics = ["/health", "/ready", "/metrics"];
  const pages = [
    "/",
    "/routes",
    "/connections",
    "/db",
    "/services",
    "/messages",
    "/logs",
    "/telemetry",
    "/metrics",
    "/repl",
    "/users",
    "/users/new",
    "/users/1",
    "/unwrapped",
  ];
  const data = [
    "/api/logs",
    "/api/messages",
    "/api/telemetry",
    "/api/unwrapped",
    "/app.js",
  ];
  try {
    for (let attempt = 0;; attempt++) {
      try {
        await request("/health");
        break;
      } catch (error) {
        if (attempt > 300) throw error;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
    }
    let reader = await login("reader");
    const operator = await login("operator");
    for (const path of diagnostics) {
      for (const method of ["GET", "HEAD"]) {
        for (
          const [cookie, status] of [["", 401], [reader, 403], [
            operator,
            200,
          ]] as const
        ) {
          const result = await request(path, cookie, method);
          check(
            `${enabled ? "CAP on" : "CAP off"} ${method} ${path}: ${status}`,
            result.status === status,
          );
          if (status !== 200 && method === "GET") {
            check(
              "no diagnostic data on denial",
              ["Unauthorized", "Forbidden"].includes(result.text),
            );
          }
        }
      }
    }
    for (const path of diagnostics) {
      for (const alias of [path + "/", path.replace("/", "//")]) {
        check(
          "diagnostic route aliases require CAP",
          (await request(alias)).status === 401,
        );
      }
      for (
        const [cookie, status] of [["", 401], [reader, 403], [
          operator,
          200,
        ]] as const
      ) {
        check(
          "middleware cannot bypass diagnostic access",
          (await request(path + "?shortcut=true", cookie)).status === status,
        );
      }
    }
    const metrics = await request("/metrics", operator);
    check(
      "Prometheus output preserved",
      metrics.text.includes("well_process_rss_bytes") &&
        metrics.headers.get("content-type")?.includes("version=0.0.4") === true,
    );
    if (enabled) {
      for (const cookie of ["", reader]) {
        for (const path of pages) {
          const result = await request("/_cap" + path, cookie);
          check(
            `CAP page rejects missing grant: ${path}`,
            result.status === 302 &&
              result.headers.get("location") === "/_cap/login",
          );
        }
        for (const path of data) {
          check(
            `CAP data rejects missing grant: ${path}`,
            (await request("/_cap" + path, cookie)).status === 401,
          );
        }
        const login = await request("/_cap/login", cookie);
        check("login GET is public", login.status === 200);
        const csrf = login.text.match(/name="_csrf_token" value="([^"]+)"/)
          ?.[1];
        if (!csrf) throw new Error("Missing login CSRF");
        const session = cookie || login.headers.getSetCookie()[0].split(";")[0];
        check(
          "login POST is public with CSRF",
          (await request("/_cap/login", session, "POST", {
            email: "reader",
            password: "test-password",
            _csrf_token: csrf,
          })).status === 200,
        );
        check(
          "unwrapped mutation checks CAP after CSRF",
          (await request("/_cap/api/unwrapped", session, "POST", {
            _csrf_token: csrf,
          })).status === 401,
        );
      }
      check(
        "denied CAP handlers never ran",
        (await request("/test/calls")).text === "0",
      );
      check(
        "unwrapped CAP page authorized",
        (await request("/_cap/unwrapped", operator)).text.includes(
          "protected-page",
        ),
      );
      check(
        "CAP asset authorized",
        (await request("/_cap/app.js", operator)).status === 200,
      );
      const page = await request("/_cap/", operator);
      const csrf = page.text.match(/name="_csrf_token" value="([^"]+)"/)?.[1];
      if (!csrf) throw new Error("Missing CAP CSRF");
      check(
        "unwrapped CAP mutation authorized",
        (await request("/_cap/api/unwrapped", operator, "POST", {
          _csrf_token: csrf,
        })).status === 200,
      );
    }
    reader = await login("reader");
    for (const cookie of ["", reader]) {
      const socket = await connect(cookie);
      const before = (await request("/test/calls")).text;
      await socket.send("join", "cap:probe");
      check("CAP join denied", (await socket.next()).type === "error");
      await socket.send("push", "cap:probe");
      check(
        "CAP push denied without join",
        (await socket.next()).type === "error",
      );
      await socket.send("join", "cap:unknown");
      check(
        "application wildcard cannot expose CAP channel",
        (await socket.next()).type === "error",
      );
      check(
        "denied CAP callbacks never ran",
        (await request("/test/calls")).text === before,
      );
      await socket.send("join", "*");
      check(
        "application wildcard join available",
        (await socket.next()).type === "ok",
      );
      await request("/test/publish", "", "POST");
      const event = await socket.next();
      check(
        "wildcard receives only application event",
        event.channel === "app:probe" && event.payload === "application-event",
      );
      await appBarrier(socket);
      socket.close();
    }
    const socket = await connect(operator);
    await socket.send("join", "cap:unknown");
    check(
      "CAP namespace cannot fall back to application wildcard",
      (await socket.next()).type === "error",
    );
    await socket.send("join", "cap:probe");
    check(
      "CAP initial state authorized",
      (await socket.next()).state === "protected-initial",
    );
    await socket.send("join", "app:probe");
    check(
      "same connection joins application channel",
      (await socket.next()).type === "ok",
    );
    await socket.send("push", "cap:probe");
    check(
      "CAP reply authorized",
      (await socket.next()).payload === "protected-reply",
    );
    await request("/test/publish", "", "POST");
    const events = [await socket.next(), await socket.next()];
    check(
      "authorized CAP event delivered",
      events.some((event) =>
        event.channel === "cap:probe" && event.payload === "protected-event"
      ),
    );
    check(
      "application event delivered on shared connection",
      events.some((event) => event.channel === "app:probe"),
    );
    await socket.send("push", "app:probe", "queue-revoke");
    check(
      "revocation command completed",
      (await socket.next()).payload === "application-reply",
    );
    await appBarrier(socket);
    const before = (await request("/test/calls")).text;
    await socket.send("push", "cap:probe");
    check(
      "CAP command rejected after revocation",
      (await socket.next()).type === "error",
    );
    check(
      "revoked CAP callback never ran",
      (await request("/test/calls")).text === before,
    );
    await request("/test/publish", "", "POST");
    check(
      "CAP delivery stops after revocation",
      (await socket.next()).channel === "app:probe",
    );
    await appBarrier(socket);
    for (const path of diagnostics) {
      check(
        `existing session loses access: ${path}`,
        (await request(path, operator)).status === 403,
      );
    }
    if (enabled) {
      check(
        "CAP page loses access in existing session",
        (await request("/_cap/unwrapped", operator)).status === 302,
      );
      check(
        "CAP resource loses access in existing session",
        (await request("/_cap/app.js", operator)).status === 401,
      );
    }
    await request("/test/grant", "", "POST");
    await socket.send("push", "cap:probe", "revoke");
    check(
      "reply checks grant after callback",
      (await socket.next()).type === "error",
    );
    await appBarrier(socket);
    await request("/test/grant", "", "POST");
    await socket.send("join", "cap:initial-revoke");
    check(
      "initial state checks grant after callback",
      (await socket.next()).type === "error",
    );
    await appBarrier(socket);
    await request("/test/grant", "", "POST");
    await socket.send("join", "cap:error-revoke");
    const joinError = await socket.next();
    check(
      "CAP join error does not disclose data after revocation",
      joinError.type === "error" && joinError.reason === "Unauthorized",
    );
    await appBarrier(socket);
    await request("/test/grant", "", "POST");
    await socket.send("push", "cap:probe", "revoke-error");
    const pushError = await socket.next();
    check(
      "CAP command exception does not disclose data after revocation",
      pushError.type === "error" && pushError.reason === "Unauthorized",
    );
    await appBarrier(socket);
    await request("/test/grant", "", "POST");
    await request("/test/not-ready", "", "POST");
    const notReady = await request("/ready", operator);
    check(
      "authorized readiness failure remains 503",
      notReady.status === 503 &&
        JSON.parse(notReady.text).status === "not_ready",
    );
    check(
      "anonymous readiness failure remains private",
      (await request("/ready")).status === 401,
    );
    console.log(`CAP ${enabled ? "enabled" : "disabled"} acceptance complete`);
  } catch (error) {
    console.error(await Deno.readTextFile(`${runtime}/server.log`));
    throw error;
  } finally {
    for (const socket of sockets) {
      try {
        socket.close();
      } catch {}
    }
    try {
      server.kill("SIGTERM");
    } catch {}
    await server.status;
    await logging;
    log.close();
    await Deno.remove(runtime, { recursive: true });
  }
}
await run(true);
await run(false);
console.log(`PASS ${passed} CAP access assertions`);
