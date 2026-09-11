## Change list (implementation)

### lib/well/SERVICE.md
- [x] `Well.cors`: required non-empty `origins`; no default `*`; never `Allow-Credentials`; `Vary: Origin` when echoing a specific origin
- [x] `Well.csrf`: reject `Sec-Fetch-Site` cross-site/same-site and mismatched/`null` Origin before XHR/token
- [x] Scaffold unchanged: `Well.csrf` on, `Well.cors` off
- [x] Derived signatures: `well.ml`, `skills/well/SKILL.md`, `template.ml`

## Verification
- [x] tests from SERVICE.md Verification strategy
  - hardening_test: 101 passed, 0 failed
  - production_test: 160 passed, 0 failed
  - contract_codegen_test: 56 passed, 0 failed
