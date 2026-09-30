# Domknięcie publikacji Well → Cyrograf — 2026-09-30

Cyrograf: opublikowana rewizja 0b886ea9e5965448e6c5d1855713220835b573a8.
Pin frameworka, lock i scaffold wskazują tę samą osiągalną rewizję GitHub.
Ponowny odbiór: make lock, make check, make build i make contract-scaffold
(exit 0; scaffold 10/10, realny browser Proxy i deterministyczne odtworzenie).
Logi: .local/closeout/{lock,published-pin-check,published-pin-build,scaffold}.log.
Zakres W0–W7 zachowany; bazowe ograniczenia make test opisano poniżej.
Nie zmieniano checkoutów ani wdrożeń innych aplikacji zależnych.

# axe sync — Well → Cyrograf (W7)

Data: 2026-09-29
Baza: 5c573753367f10d7226f5eaedf1adbeacab2c09d (working tree z deltą W0–W7)

## Zakres

Migracja Well na Cyrograf (W0–W7): usunięcie własnego parsera/modelu/generatorów
danych RPC (`Contract_parser`, `Contract_types`, `Contract_codegen`) i starego
testu codegenu; pozostają adaptery integracji (`Contract_build`,
`Contract_adapters`, `Well.Actor.Contract`). Cyrograf jest jedynym właścicielem
języka, typów i kodeków; Well komponuje je z adapterami.

## Weryfikacja

- `make check` exit 0; `make build` exit 0.
- `make test`: znane błędy bazowe `oauth_provider_test` (Not_found),
  `cmd_effects_test` i `props_parse_test` (caml_pure_js_expr) — potwierdzone
  identycznie na czystym drzewie 5c573753; bez nowych porażek.
- Cele `contract-*`: check, build, publish (9/9), native (11/11),
  browser (14/14, prawdziwa przeglądarka), clients (TS/Go/Dart 7/7),
  socket (13/13), actor (2/2 + 110/110, deskryptor i JCS/SHA-256 identyczne),
  scaffold (10/10), actor_contract_test (17/17) — wszystkie exit 0.
- Dowody: `/home/sel/.local/share/operators/task-packets/well/cyrograf-migration-20260929/progress/W7*.log`, `W7.json`.

## Freeze

Freeze przesunięty wyłącznie dla zweryfikowanego zakresu migracji:
`lib/well_cli/contract/{SERVICE.md,STP.md}`, `README.md` oraz zmodyfikowane
`lib/well/actor/{CONTRACT,API,ARCH,STP}.md` i `lib/well/actor/examples/`
(`Reports.cyrograf`, `*.actor.toml`). Cudze, nieśledzone wpisy freeze
(`AGENTS.md`, `ROADMAP.md`, `DESIGN-COMPONENT.md`, `skills/`, `lib/well_web/`,
`lib/well_cap/`) pozostawiono bez zmian.

---

# axe sync — Well.Actor

Data: 2026-09-17
Baza: 9d345d78f78857df41969f2689ee57d73740a6ce

## Zakres

Implementacja zatwierdzonej specyfikacji lib/well/actor/: trwałe instancje, obiegi, routing, agregacja, retry i odzyskiwanie. Pozostałe API frameworka bez zmian. Freeze uzupełniony wyłącznie o specyfikację Actor.

## Weryfikacja

- dune build @all @check: sukces.
- Actor: 110 testów; kontrakty Actor: 15 testów — sukces.
- Pełna regresja: znane błędy bazowe oauth_provider_test (Not_found), cmd_effects_test i props_parse_test (caml_pure_js_expr). Bez nowych porażek.
- Atomowe retire_activation i trwały licznik aktywacji; testy przeplotów dwóch domen oraz odzyskania po błędzie DELETE.
- Użytkownik zaakceptował zamknięcie historycznego SEGV i zlecił wdrożenie. Przyczyna historycznej awarii nie została niezależnie ustalona.

Dowody lokalne: /home/sel/.local/share/well-deployments/2026-09-17-actor/ oraz /home/sel/.local/share/well-reviews/aktorm-2026-09-16/.
