import * as Orders from "./orders.ts";
import { createClient, RpcError } from "./well_transport.ts";
const base = Deno.args[0];
const token = Deno.args[1];
(globalThis as Record<string, unknown>).__WELL_CSRF = token;
const browser = createClient({ baseUrl: base });
function check(name: string, valid: boolean) {
  if (!valid) throw new Error(name);
  console.log("ok " + name);
}
const reservation = await Orders.reserve(browser, {
  owner_id: "owner-1", quantity: 9007199254740991, thing: { id: "t-1" }, tags: ["a", "b"],
});
check("wide reserve", reservation.tag === "Reserved" && reservation.value.count === 9007199254740991 && reservation.value.id === "owner-1");
const echo = await Orders.echo(browser, { id: "cross-module" });
check("cross-module echo", echo.id === "cross-module");
const numbers = await Orders.numbers(browser, { small: 7, big: 9007199254740991, negative: -9007199254740991, ratio: 1.5, unicode: "Zażółć gęślą jaźń" });
check("wide numbers and unicode", numbers.big === 9007199254740991 && numbers.negative === -9007199254740991 && numbers.unicode === "Zażółć gęślą jaźń");
for (const id of ["legacy-error", "bad-response"]) {
  let failed = false;
  try { await Orders.echo(browser, { id }); } catch { failed = true; }
  check(id + " rejects Promise", failed);
}
let failed = false;
try { await Orders.echo(createClient({ baseUrl: "http://127.0.0.1:9" }), { id: "t" }); }
catch (error) { failed = error instanceof RpcError && error.kind === "transport"; }
check("network failure classified", failed);
