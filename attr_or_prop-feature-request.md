# Feature request: polymorphic attr-or-prop Props (Well.Web)

## Goal

Add first-class support in Well.Web for a **polymorphic component prop** that can be supplied either as:

1. an **HTML attribute string** (parsed), or
2. a **JS property value** (used as-is, no string round-trip).

Primary consumer pattern (DigitAllFlow `dg-table` and similar TEA CEs):

- Server-rendered HTML embeds:

  ```html
  <my-el payload='{"columns":[...],"data":[...]}'></my-el>
  ```

- A future JS parent may set:

  ```js
  el.payload = { columns: [...], data: [...] }  // object, not JSON string
  ```

Today we only have:

- `Props.string` → works for attributes; JS property is coerced with `Js.to_string` (objects become `"[object Object]"`).
- `Props` list / `of_eq` (complex) → property path only; `parse_string = None`, not in `observedAttributes`.

There is **no** single prop kind that means: “if attribute string → parse; if property non-string → use as-is”.

## Desired API (proposal — refine if a cleaner name fits the codebase)

Add something like:

```ocaml
Props.json "payload"
  ~decode:(string -> 'a option)   (* attribute / string property *)
  ~encode:('a -> string) option   (* optional, for symmetry / tests *)
  ~on:('a -> 'msg)
  ?default
  ()
```

Or a more general union:

```ocaml
Props.attr_or_prop "payload"
  ~of_string:(string -> 'a option)
  ~of_js:(Bridge.value -> 'a option)  (* or Js.Unsafe.any *)
  ~equal:('a -> 'a -> bool)
  ~on:('a -> 'msg)
  ()
```

`json` can be a thin wrapper around `attr_or_prop` with Yojson/JSON parse helpers if Yojson is acceptable in well.web; otherwise keep parse/decode in the app and only ship `attr_or_prop` in the framework.

## Required behavior

On **hydrate** (connect) and on later **attributeChanged** / **property set**:

1. If a **JS own property** is set and `of_js` / non-string succeeds → use that value (prefer property over attribute when both exist — same rule as current Inputs hydrate).
2. Else if **attribute** (or string property) is present → `of_string` / JSON parse → use result.
3. Empty string / missing → default (or skip msg), **must not throw** in `connectedCallback`.
4. Parse failure → treat as default / no-op (document choice); never abort paint of the whole component.

`observedAttributes` **must include** the prop name so server HTML attributes still drive the CE.

`Object.defineProperty` on the prototype **must still** fire for JS assignments of objects (current property_names path).

## Non-goals

- Do not require apps to dual-declare `payload` as both string and complex.
- Do not break existing `Props.string` / bool / int / float / list / of_eq.
- Do not force every app to depend on Yojson if `attr_or_prop` is the primitive.
- No change to server HTML generation in apps in this PR (DG can adopt later).

## Implementation hints (current tree)

- `lib/well_web/component_access` — `Props` kinds, `prop_spec`, `parse_string`, `to_msg`.
- `lib/well_web/inputs.ml` — `hydrate_instance`, `handle_attribute_change`, `handle_property_set`, `coerce_js_scalar`, `observed_attribute_names`, `property_names`.
- `lib/well_web/bridge` — `get_attribute`, `get_js_property`, `take_own_js_property`, CE `observedAttributes` + property install.
- Existing tests: `test_props_wire` (extend or add a sibling test).

Suggested approach:

1. New `Props.kind` variant (e.g. `Attr_or_js`) carrying `of_string` + `of_js` + `equal`.
2. Include name in `observed_attribute_names` (like string).
3. In property path: if value is JS string → `of_string`; else → `of_js` (object/array).
4. In attribute path: always `of_string`.
5. Document in DESIGN-COMPONENT / well_web.mli with a short use-case.

## Acceptance criteria

- [ ] Unit/e2e test: CE with attr `payload='{"x":1}'` hydrates decoded value and view sees it.
- [ ] Unit/e2e test: `el.payload = {x: 1}` (object) hydrates **without** JSON.stringify; view sees same shape.
- [ ] Test: attr set first, then property object overwrites (or documented order).
- [ ] Test: invalid JSON string does not throw; component still mounts.
- [ ] Existing props wire tests still pass.
- [ ] CHANGELOG + short docs note for app authors.

## Motivation (product)

Planner tables (`dg-table`) embed large data via server HTML attributes today (JSON string is correct). We want the same prop to accept in-memory objects when a JS parent appears, without inventing a second API (`columns`/`data` Lit-style) and without apps hand-rolling dual paths outside Props.

## Out of scope for this Well PR

- Changing DigitAllFlow `dg_table.mlx` (follow-up after Well ships).
- Fixing `#frag` / `Html.cat` blit (separate bug).

## Context

- Source: FC sprawa `PDR-pr-dg` (obieg `global/pr`), branch `fc/pr-dg-table-not-rendering`.
- Written: 2026-08-13.
