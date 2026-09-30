---
name: well-axe
description: Spec-first development for WELL applications using contract-first parallel service implementation in one checkout and coordinated builds. Use for specification edits and well-axe sync in projects selecting this workflow; replaces legacy axe only in those projects.
---

# WELL Axiomatic Engineering

Use this workflow only when the application's AGENTS.md selects `well-axe`.
It is independent of legacy `axe`; do not load that skill or read `axe.toml`.
Read project instructions, `docs/main.md` (map and labels), and the affected
specifications. Use the project's WELL backend/frontend skills for implementation.
Do not change the framework, deploy, or open a PR merely because sync was requested.

## Specification editing

On a request to change specifications, write the requested `docs/` changes directly
for review in Git/T3. Mockup edits are reviewed in the browser; provide the preview
URL and check the affected screen. Stop after the specification changes. Saving,
committing or approving docs does not authorize code. Start implementation only
on `well-axe sync`, `axe sync`, or an explicit request to synchronize.

Docs describe the intended present state, not implementation history. Behavior,
assumptions and acceptance criteria belong in specs; chat context may explain them
but cannot add hidden requirements during sync. Report missing decisions instead
of inventing policy. Preserve IDesign boundaries and the project's label rules.
Tests are authored only from STP or explicit `[test]` scope. Appearance comes from
the mockup and DESIGN.md; frontend component contracts describe attrs/emits/use cases.

## Sync: plan before workers

The root agent owns planning, generated contracts, shared files, builds,
integration, verification, freeze and project-required commits. Service workers
own disjoint implementation files in the SAME checkout. No worktrees or per-worker
build directories. This skill explicitly authorizes bounded parallel subagents.
Use the session's native subagents with inherited model settings, unless the user
explicitly chooses otherwise. If unavailable, report the limitation and execute
locally; do not silently start an external provider. One small task may run locally.

### 1. Snapshot and establish scope

Record UTC start time and the initial Git state, including existing dirty files.
Use a unique `.axe/runs/<run-id>/` for scratch reports, packets and evidence; keep
runtime output out of commits. Do not reset, stage or overwrite unrelated changes.

Snapshot docs into that run's `current/`, retaining relative paths: copy `.md`,
`.toml`, `.html`, `.css`, `.js`, `.json`; record other assets as sorted SHA-256/path
entries in `ASSETS`. Parse JSON. Compare to `.axe/freeze/`, retaining legacy
snapshot compatibility: changes in snapshot format alone are not product work;
verify unchanged source against Git history before classifying such differences.
Do not silently omit changed JavaScript previously represented by an asset hash.

Freeze is the last implemented AND verified specification, not simply the last
edited docs. Missing freeze is a blocker to automatic whole-system implementation:
report it and establish an explicitly agreed baseline or approved bounded delta.
Never treat copying current docs as proof of implementation.

List all added/modified/deleted artifacts and affected labels. Empty delta: stop.
Inherited pending changes remain visible; do not silently narrow sync to the chat.
If the user requests a subset, record it and leave unverified freeze entries intact.

### 2. Consistency and execution plan

Read changed specifications and relevant dependency contracts, not every service's
implementation. Validate links, labels, signatures, shared types, assumptions,
STP coverage, architecture edges and affected mockup ownership. Parse linked
OpenAPI JSON and check agreement with the affected contract where applicable.
Unresolved contradictions block dependent tasks; report exact missing decisions.

Write `plan.md` in the run directory with:
- Approved delta and observable acceptance criteria anchored to spec paths.
- Dependency graph, parallel batches and prerequisite results.
- One owner per editable path; shared generated files, registration, build config,
  common helpers and test registration remain root-owned unless explicitly assigned.
- Required formatting, build/test/browser checks and their owners.
- Temporary stubs, if unavoidable, with exact locations and replacement owners.
- Stage timings and task states: pending/running/ready/verified/blocked.

Choose task boundaries by service ownership and actual dependencies. A single
service may be one task; do not split merely to occupy slots. Freeze shared
interfaces before launching dependent workers. Plan an early compilation checkpoint
for a large batch, not just a final build after all implementation is done.

### 3. Contracts first

The authored contract is the project's native source: a `.cyrograf` file per
module under `lib/contract/` (Markdown may embed the same contract in
```cyrograf``` fences, which project deterministically to `.cyrograf`). Plain
TOML remains a Cyrograf compatibility input, so legacy authored TOML keeps an
explicit project convention; do not migrate its format incidentally and never
keep two definitions of the same module. The generated `lib/contract_generated`
tree is a projection, never an alternative source.

For each affected service, collect the linked contract blocks (`.cyrograf` or
legacy TOML) and merge semantically with the language owner's compiler. Reject
conflicting keys, duplicate type definitions, multiple RPC owners, unlinked
contract-bearing files and unresolved references. Repeated tables may contribute
disjoint or identical method keys. Validate qualified references against
dependency type catalogs. Then run the project contract-generation command
(typically `well contract build`, which `dune build` also drives). Only root
writes generated files. Generation success is not evidence that the full
application compiles.

Prefer generated types and Proxy to temporary implementations. If compilation
requires a stub, use an explicit unimplemented failure, never a fake success or
plausible domain value. Track every stub in the plan; none may remain at completion.
This workflow permits tracked temporary stubs only during sync, not standalone
TODO comments or incomplete final implementation.

### 4. Parallel implementation and build barriers

Give each worker a self-contained packet: WORKER role, exact accepted spec delta,
relevant dependency interfaces, acceptance criteria, read-only dependencies,
editable allowlist, project/framework instructions and output location.
Workers may inspect code and edit only assigned paths. They do not change docs,
contracts, freeze, Git state, configuration or shared files; do not delegate,
build, run tests, generate assets, deploy or commit. Local source review and
formatting of owned files are allowed. Report a required shared edit to root.

Workers return READY/BLOCKED/FAILED, changed paths, criteria addressed, local
review/formatting evidence and unresolved issues. READY is not VERIFIED.
Before a build, every active worker must explicitly acknowledge a pause with no
pending writes, or finish its task. A sent pause message is not acknowledgement.
Include root edits and any background generators in this barrier. Record the
source fingerprint being checked; run only one build/test/generation process at
a time against the shared `_build`. Never launch competing builds or clear caches.

Root checks allowlists and runs project lifecycle commands through `make` (WELL
application build: `make build`). Use project formatting rules. Distribute compiler
errors to their owners, reopen writes for the correction batch, then repeat the
barrier. Stop/reconfigure only processes owned by this run; do not kill unrelated
builds or user watches. Report an external writer/build that prevents a stable check.
Bound waits so progress and blockers can be communicated regularly.

If an interface proves insufficient, stop affected workers and report the spec
gap. Do not invent a contract during implementation. Two correction rounds per
unchanged task are the default limit: on repeated failure root diagnoses the cause
and either performs a bounded spec-backed fix or reports the blocker. Do not retry
an unchanged failing setup. Root can fix integration issues but cannot broaden scope.

### 5. Verify and finish

After integration, run required existing checks and STP-derived tests through the
project's make targets. Add tests only where the approved STP/[test] requires them.
For `[look]`, compare mockup and running UI at the same project-specified viewports
(default 1440x900), including affected states. Workers' source review does not
replace compiled/tested/browser evidence. Failures are corrected within the delta;
record unrelated defects separately unless they block acceptance.

Verify all stub locations are implemented, write ownership was respected and docs
still match the input snapshot (except explicitly derived token regeneration,
which must be checked against DESIGN.md and included in the final snapshot).
Changed input invalidates dependent evidence: recompute scope before finishing.
After all selected work passes, update only verified freeze entries (including
asset hashes and deletions); a full sync may replace the full freeze. Do not advance
freeze on a failed sync or certify pending work through a partial snapshot copy.
Preserve `.axe/freeze` tracking as configured by the project.

Write `.axe/last-sync.md` with the selected delta, task outcomes, checks/exit codes,
blockers, evidence paths and measured elapsed times for planning, contracts,
implementation batches, build/test, browser checks, correction rounds and total.
Record overlapping worker durations separately; their sum is not wall-clock time.
Report actual model usage/cost only if exposed. Keep successful timing summaries
in Git so the pilot can be compared with subsequent runs. Commit only owned files
as project instructions require; include issue ids from the selected scope without
automatic issue-closing keywords. Do not claim speedup without comparable measurements.
