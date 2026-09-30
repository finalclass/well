// W3 TypeScript client against the W3 Well server through the generated Proxy.
// Runs under Deno; the generated proxy uses only the public toDrut/fromDrut.

import * as Common from "./common.ts";
import * as Orders from "./orders.ts";
import { type ProxyResult, Proxy } from "./proxy_orders.ts";

const base = Deno.args[0] ?? "http://127.0.0.1:8478";
const token = Deno.args[1] ?? "";
(globalThis as Record<string, unknown>).__WELL_BASE = base;
(globalThis as Record<string, unknown>).__WELL_CSRF = token;

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

const call = <R>(f: (cb: (r: ProxyResult<R>) => void) => void) =>
  new Promise<ProxyResult<R>>((resolve) => f(resolve));

const reservation = await call<Orders.ReserveResponse>((cb) =>
  Proxy.reserve({
    ownerId: "owner-1",
    quantity: 9007199254740991,
    thing: { id: "t-1" },
    tags: ["a", "b"],
  }, cb)
);
if (reservation.ok && reservation.value.tag === "Reserved") {
  check("wide reserve",
    reservation.value.value.count === 9007199254740991 &&
      reservation.value.value.id === "owner-1");
} else check("wide reserve", false);

const echo = await call<Common.Thing>((cb) =>
  Proxy.echo({ id: "cross-module" }, cb)
);
check("cross-module echo", echo.ok && echo.value.id === "cross-module");

const numbers = await call<Common.Numbers>((cb) =>
  Proxy.numbers({
    small: 7,
    big: 9007199254740991,
    negative: -9007199254740991,
    ratio: 1.5,
    unicode: "Zażółć gęślą jaźń",
  }, cb)
);
check("wide numbers and unicode",
  numbers.ok && numbers.value.big === 9007199254740991 &&
    numbers.value.negative === -9007199254740991 &&
    numbers.value.unicode === "Zażółć gęślą jaźń");

const legacy = await call<Common.Thing>((cb) =>
  Proxy.echo({ id: "legacy-error" }, cb)
);
check("2xx with error body",
  !legacy.ok && legacy.error.includes("legacy failure"));

const bad = await call<Common.Thing>((cb) => Proxy.echo({ id: "bad-response" }, cb));
check("invalid response", !bad.ok && bad.error.length > 0);

const raw404 = await fetch(`${base}/rpc/Orders/unknown_xyz`, {
  method: "POST",
  headers: { "Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest" },
  body: "null",
});
check("http status 404", raw404.status === 404);

(globalThis as Record<string, unknown>).__WELL_BASE = "http://127.0.0.1:9";
const offline = await call<Common.Thing>((cb) => Proxy.echo({ id: "t" }, cb));
check("network error", !offline.ok && /network/i.test(offline.error));
(globalThis as Record<string, unknown>).__WELL_BASE = base;

console.log(`\nW3 ts client: ${pass} passed, ${fail} failed`);
if (fail > 0) Deno.exit(1);