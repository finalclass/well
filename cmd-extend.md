# Agent brief: Well.Web — real `Cmd` effects (`perform` + EffectsManager)

## Goal

Make Well.Web TEA **commands actually run**, so application components can keep
`update` pure and put side effects (HTTP/XHR, timers, arbitrary async work) in
`Cmd` — not inline in `update`.

Primary consumer (out of scope for this repo change, but the acceptance driver):
**DigitAllFlow LoginClient** (`~/Documents/dg/web/dg_login_*.mlx`) currently calls
`Http.post` and mutates the DOM from `update`. After this work, that pattern must
be expressible as:

```ocaml
| Submit ->
    ({ state with loading = true; error = "" },
     Well_web.Cmd.perform (fun ~dispatch ->
       Http.post ~url ~fields ~on_done:(fun r -> dispatch (Got_result r))))

| Got_result r ->
    (* pure: map result → state / Cmd.emit / Cmd.msg *)
```

Do **not** change DG in this task unless needed for a Well-internal e2e test.
Ship the framework capability; DG migrates separately.

---

## Repo / conventions

- Root: `~/Documents/well`
- Read first: `AGENTS.md`, then:
  - `lib/well_web/ARCH.md`
  - `lib/well_web/SERVICE.md`
  - `lib/well_web/effects_manager/SERVICE.md`
  - `lib/well_web/component_access/component_access.mli`
  - `lib/well_web/effects_manager/effects_manager.mli`
  - `DESIGN-COMPONENT.md` (D8 history + D18 final `Cmd` shape)
  - `skills/well-front/SKILL.md` (public API docs — update when done)
- Spec language: Polish in `SERVICE.md` / design docs; English in code identifiers
  and commit messages.
- Build: `make check`, `make build`, `make test` (ignore known `oauth_provider_test`).
- Stay on `main`. No new branches. Commit when the change is coherent.
- Do not invent a second effects system outside `Cmd` + EffectsManager + MessageBus.

---

## Current state (facts — verify, then fix)

| Piece | Path | Reality today |
|-------|------|----------------|
| `Cmd` ADT | `component_access.ml` | `None \| Msg \| Emit \| Focus` only |
| `Cmd` public API | `component_access.mli` / `Well_web.Cmd` | `none`, `msg`, `emit`, `focus`, `is_none` |
| EffectsManager | `effects_manager.ml` | **stub**: `let handle_cmd ~instance_id envelope = ()` |
| LoopManager | `loop_manager.ml` | publishes non-none cmd on MessageBus topic `"cmd"` |
| Wiring | `well_web.ml` | subscribes `"msg"` → LoopManager; **no** subscribe on `"cmd"` → EffectsManager |
| `init` dispatch | `component_access.ml` `init_state` | `~dispatch:(fun _ -> ())` — **no-op** |
| `view` dispatch (update path) | `component_access.ml` `render_view` | also no-op; real dispatch lives in `rendering.ml` via bus |
| Design debt | `DESIGN-COMPONENT.md` D8 | historically promised `batch` + `then_`; D18 public sketch has `batch` + `focus` but **no** general perform; runtime never implemented runners |

Design docs already describe EffectsManager as the interpreter of Cmd
(emit / Promise / focus / DOM-ops) and mention `Cmd.then_`. Implement the
minimal complete loop, not a paper redesign of the whole architecture.

---

## Target design

### 1. Extend `Cmd.t`

In `Component_access.Cmd` (implementation + `.mli`, re-exported as `Well_web.Cmd`):

```ocaml
module Cmd : sig
  type ('msg, 'emits) t

  val none    : ('msg, 'emits) t
  val msg     : 'msg -> ('msg, 'emits) t
  val emit    : 'emits -> ('msg, 'emits) t
  val focus   : string -> ('msg, 'emits) t
  val batch   : ('msg, 'emits) t list -> ('msg, 'emits) t
  (** General effect: runtime calls [run] with a live [dispatch] that
      publishes msgs for this instance. [run] must not block the TEA loop
      for long work — schedule async (XHR, Promise, rAF, setTimeout) and
      call [dispatch] from callbacks. *)
  val perform : (dispatch:('msg -> unit) -> unit) -> ('msg, 'emits) t

  val is_none : ('msg, 'emits) t -> bool
end
```

Implementation sketch (private ADT):

```ocaml
type ('msg, 'emits) t =
  | None
  | Msg of 'msg
  | Emit of 'emits
  | Focus of string
  | Batch of ('msg, 'emits) t list
  | Perform of (dispatch:('msg -> unit) -> unit)
```

**Rules:**

- `update` / `init` stay pure: they only *construct* `Perform` closures; they must
  not run network or DOM mutation before returning.
- Closures may capture values from the message (url, fields, tokens). Prefer
  capturing data, not mutable component state refs.
- `batch` flattens / runs sequentially in EffectsManager (order preserved).
  Nested `batch` is OK.
- `is_none`: true only for `None` and empty/`batch` of only nones (optional
  optimization; at least treat `None` as none).

**Optional later (not required this PR):** `then_ : 'a Js.promise -> ('a -> 'msg) -> …`
can be sugar over `perform`. Do not block on it if `perform` is enough.

### 2. Wire EffectsManager into the bus

In `well_web.ml` (or the registration/init path that already subscribes `"msg"`):

1. On first `component` / runtime init, also:
   ```ocaml
   Message_bus.subscribe ~topic:"cmd" (fun env ->
     Effects_manager.handle_cmd
       ~instance_id:(Message_bus.instance_id env)
       (Obj.magic env))
   ```
2. Keep a single subscription (same pattern as Rendering.init guard), not one
   per component type.

### 3. Implement `Effects_manager.handle_cmd`

Interpret the cmd payload for `instance_id`:

| Cmd | Action |
|-----|--------|
| `None` | no-op |
| `Msg m` | publish `m` on topic `"msg"` for this `instance_id` (same envelope shape LoopManager expects) — async/microtask preferred so update stack unwinds |
| `Emit e` | resolve host DOM via `Component_access.dom_element`; dispatch a bubbling/composed `CustomEvent`. Event **name** and **detail** must be defined once and documented. Prefer a stable convention used by parent listeners (see Emit section below). |
| `Focus sel` | `requestAnimationFrame` → `querySelector` on host (or document) → `.focus()`; missing node = no-op |
| `Batch cs` | run each child in order |
| `Perform f` | build `dispatch` that publishes `'msg` on `"msg"` for this instance; call `f ~dispatch`. Catch exceptions from `f` setup so one bad perform does not kill the bus (log / ignore). Callbacks inside `f` are app responsibility. |

**Dispatch helper** (same idea as `rendering.ml`):

```ocaml
let dispatch_msg ~instance_id (msg : 'msg) =
  Message_bus.publish ~topic:"msg"
    (Message_bus.create ~instance_id (Obj.obj (Obj.repr msg)))
```

Use `Bridge` for DOM/rAF where possible; avoid scattering raw jsoo outside Bridge
unless Bridge already lacks a primitive (then add a thin Bridge verb).

### 4. Emit convention (type-safe emits → DOM)

Today `Cmd.emit` exists in the ADT but nothing runs it. Parents in DG listen with
string CustomEvents (`want-remind`, `want-password`) via manual DOM listeners.

Choose **one** approach and document it in `effects_manager/SERVICE.md` + skill:

**Recommended (minimal, works with current DG panel):**

- Runtime converts `emits` to a CustomEvent using a **registered encoder** per
  component type, **or**
- Simpler v1: document that apps that need DOM events should use
  `Cmd.perform` to `Bridge.dispatch_event`, and implement **typed** `Cmd.emit`
  only if you can map `emits` → `(name, detail)` without breaking encapsulation.

**Preferred clean design (implement if low cost):**

- Extend registration or COMPONENT with optional:
  ```ocaml
  val emit_to_dom : emits -> string * Bridge.value option
  ```
  or a Well helper:
  ```ocaml
  val Cmd.emit_dom : name:string -> ?detail:Bridge.value -> unit -> …
  ```
  Separate from typed `Cmd.emit` if typed parent wiring is not ready.

Do **not** leave `Cmd.emit` as a silent no-op after this task. Either implement
DOM dispatch with a clear name mapping, or remove/hide it until parent wiring
exists — silent drop is a bug.

If full typed emit→DOM is too large, minimum bar:

1. `perform` works end-to-end.
2. `msg`, `focus`, `batch` work.
3. `emit` either works with a documented naming scheme or fails loudly in debug.

### 5. Fix no-op `init` dispatch (required companion)

`Component_access.init_state` currently:

```ocaml
let (st, _cmd) = M.init ~dispatch:(fun (_ : M.msg) -> ()) in
```

Problems:

1. `init`'s returned **cmd is discarded** (`_cmd`).
2. `dispatch` passed into `init` is a no-op — any async started from `init` via
   that dispatch never updates state (this is exactly the LoginClient footgun).

**Required behavior:**

1. Run `init`, get `(state, cmd)`.
2. Persist state (already done in `well_web.ml`).
3. If cmd is not none, publish it on `"cmd"` for the new `instance_id` (same as
   LoopManager after update) **after** the instance is fully registered and
   msg subscription exists — order matters.
4. The `~dispatch` argument to `init` must be a **real** dispatch (publish on
   `"msg"`), not `fun _ -> ()`.

Also fix `render_view`'s dummy dispatch if view is ever supposed to call it;
handlers should go through Rendering's blit dispatch (already OK for DOM
events). Do not make `view` the place for effects.

### 6. LoopManager

Keep publishing `"cmd"` when cmd is not none. Optionally:

- Inline-run `Msg` without bus hop (micro-optimization) — not required.
- Ensure `instance_id` on cmd envelopes matches msg envelopes
  (`Message_bus.create` / existing envelope type).

Verify `is_cmd_none` still works after ADT extension (`Obj.magic` path).

---

## Emit / perform interaction with parents

For LoginClient-style child→panel navigation, after this lands DG should do:

```ocaml
| Click_remind -> (state, Well_web.Cmd.emit Want_remind)
(* or perform + CustomEvent if emit-DOM mapping is the v1 path *)
```

Panel keeps listening and switches child without `location.href` full reload.

Framework task ends when the **mechanism** exists; DG migration is a follow-up.

---

## Tests / verification

Add or extend tests under `lib/well_web/` (prefer existing e2e style in
`test_e2e_counter/`):

1. **`Cmd.msg`**: update returns `Cmd.msg Next` → second update runs, state reflects both.
2. **`Cmd.perform`**: update returns `perform` that `dispatch`es `Done` asynchronously
   (e.g. `Js_of_ocaml.Dom_html.window##setTimeout` or resolved Promise) → final
   state updated; **no** network required.
3. **`Cmd.batch`**: `[msg A; msg B]` or `[perform …; msg …]` ordered.
4. **`Cmd.focus`**: if hard in headless, unit-test that EffectsManager calls Bridge
   (or skip with documented manual check).
5. **`init` cmd**: component `init` returns `Cmd.msg Boot` or `perform` → runs after mount.
6. **Regression**: existing counter e2e still passes (`Cmd.emit` path if implemented).

Commands:

```bash
make check
make test
# if there is a well_web-specific alias, run it; otherwise full test suite
```

Manual smoke (optional): tiny component in well's own demo that `perform`s a
timeout and shows a flag in the view.

---

## Docs to update (same PR)

1. `lib/well_web/component_access/component_access.mli` — Cmd constructors + semantics.
2. `lib/well_web/effects_manager/SERVICE.md` — no longer stub; list supported Cmds.
3. `lib/well_web/SERVICE.md` — note cmd bus subscription + init cmd flush.
4. `DESIGN-COMPONENT.md` — short addendum: `Cmd.perform` is the supported general
   effect; reconcile D8 `then_` as optional sugar; mark EffectsManager implemented.
5. `skills/well-front/SKILL.md` — document `perform` / `batch` with a login-shaped example.
6. `ROADMAP.md` — one line if it tracks well.web effects status.

---

## Out of scope

- Migrating DigitAllFlow login components (separate DG task).
- HTTP helper inside Well (apps keep their own `Http.post`; they only need
  `Cmd.perform` + real `dispatch`).
- Shadow DOM changes, vdom diff rewrites, LiveView.
- Full Elm-style `Cmd.map` / task packages — not required.

---

## Implementation order (suggested)

1. Extend `Cmd` ADT + mli (`perform`, `batch`); keep backward compatible constructors.
2. Implement `Effects_manager.handle_cmd` for `Msg` / `Focus` / `Batch` / `Perform`.
3. Subscribe `"cmd"` in runtime init (`well_web.ml`).
4. Flush `init` cmd + real `init` dispatch.
5. Decide and implement `Emit` (or explicit non-support with assert/log).
6. Tests.
7. Docs + skill.
8. `make check && make test`, commit on `main`.

---

## Acceptance criteria

- [ ] `Well_web.Cmd.perform` exists and is publicly usable from app `web/*.mlx`.
- [ ] `update` can return only a perform closure; XHR-style work runs after update;
      completion `dispatch`s a msg that goes through LoopManager → state → view.
- [ ] `Cmd.msg`, `Cmd.batch`, `Cmd.focus` executed by EffectsManager (not stubs).
- [ ] `init`'s cmd is not dropped; `init ~dispatch` is live.
- [ ] Topic `"cmd"` has a subscriber; LoopManager publish is not a dead end.
- [ ] `Cmd.emit` is not a silent no-op (implemented or explicitly deferred with
      compile-time/doc clarity — prefer implemented).
- [ ] Tests cover perform + msg + init cmd.
- [ ] Docs/skill updated.
- [ ] `make check` clean for touched code; relevant tests green.

---

## Non-goals / anti-patterns to reject in review

- Putting `XmlHttpRequest` back into `update` “just this once”.
- Storing `dispatch` in a global `ref` inside app components as the primary
  async pattern (the LoginClient `dispatch_ref` hack) — framework must make
  that unnecessary for cmd-driven work.
- EffectsManager that only handles `Focus` and ignores `Perform`.
- Breaking the COMPONENT module type for all existing components without a
  default (new Cmd constructors are additive; existing counters must still compile).

---

## Context snippet for the agent (copy-paste start)

```text
Implement real Well.Web command execution per ~/Documents/well/cmd-extend.md.

Problem: Cmd is published on MessageBus topic "cmd" but EffectsManager.handle_cmd
is a no-op and nothing subscribes. init discards cmd and passes a no-op dispatch.
Apps (e.g. DG login) therefore run HTTP inside update.

Deliver: Cmd.perform + Cmd.batch, working EffectsManager, bus subscription,
init cmd flush + live init dispatch, tests, docs. Stay on main, commit when done.
```
