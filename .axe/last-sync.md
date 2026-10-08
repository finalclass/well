# axe sync — Well.Civil_clock — #3 — 2026-10-08

Zatwierdzona specyfikacja: commit fcd3f44 oraz polecenie użytkownika
„Zatwierdzam. Wykonaj implementację.” Zakres:
lib/well/civil_clock/SERVICE.md i STP.md, implementacja publicznego
Well.Civil_clock oraz integracja zależności i odbioru C01–C06.
Sygnatura civil_clock.mli odpowiada dokładnie blokowi kontraktu w SERVICE.md.

Układ źródeł określa .axe/source-manifest.json. Brak docs/ nie został
potraktowany jako baseline; odbiór dotyczy jawnie zatwierdzonej delty #3.
Specyfikacja zachowała identyczną treść podczas implementacji.

## Odbiór

- make civil-clock-test: exit 0; 62 testy API, w tym 21 przykładów konwersji,
  przeplot dwóch domen, błędne dane i granice reprezentacji.
- C06: osobny konsument well.core bez Well.run/Eio, uruchomiony dla TZ=UTC
  i TZ=America/New_York; oba procesy sprawdziły zegar, aliasy i 21 konwersji.
  Kontrola dodatnia kompiluje się; obie negatywne próby są odrzucane
  z powodu niezgodności typów, nie błędu składni lub brakujących zależności.
- make check: exit 0.
- make build: exit 0.
- dune tools exec ocamlformat -- --check lib/well/civil_clock.ml test/civil_clock_test/cases.ml test/civil_clock_test/civil_clock_test.ml test/civil_clock_test/consumer.ml test/civil_clock_test/compile_fail/valid.ml test/civil_clock_test/compile_fail/invalid_zone.ml test/civil_clock_test/compile_fail/invalid_date.ml: exit 0.
- dune tools exec ocamlformat -- --doc-comments=before --check lib/well/civil_clock.mli: exit 0.
- deno fmt --check test/civil_clock_test/run.ts: exit 0.
- deno check test/civil_clock_test/run.ts: exit 0.
- git diff --check: exit 0.
- Kontrola Deno: sygnatura mli identyczna ze specyfikacją po usunięciu
  docstringów i normalizacji białych znaków; exit 0.

Lock wygenerowano przez make lock z tymczasowym DUNE_WORKSPACE wskazującym
te same trzy rewizje repozytoriów pakietów co bazowy lock. Dodano wyłącznie
nowe zależności; wersje istniejących pakietów i pin Cyrografu zachowane.
Tymczasowy workspace i pliki prób kompilacji zostały usunięte.

Wyniki poleceń są zachowane w wątku T3; skrót odbioru jest publikowany
w PR https://github.com/finalclass/well/pull/5. Nie zapisano lokalnych
plików dowodowych ani surowych logów do repozytorium.

Pomiar od rozpoczęcia implementacji: 2026-10-08T11:18:18.711Z
do 2026-10-08T11:38:30.661Z, 1212 s.

## Freeze

Przesunięto wyłącznie dwa w pełni zweryfikowane dokumenty:
lib/well/civil_clock/SERVICE.md i lib/well/civil_clock/STP.md.
Nie certyfikowano innych zmian frameworka ani migracji DG.

SHA-256 zatwierdzonych źródeł:

- SERVICE.md: 2b9532f9bd0b20f57ebf98e4f52273fda7b584471cf8f2e856cda9b8ff4a1b6d
- STP.md: 3ce6c43dc4b61a76b17c9e46112fdc54544c45882129191101f9b45a89f4ab7e

---

# axe sync — dostęp CAP — 2026-10-04

Zatwierdzona delta tego wątku jest zaimplementowana i zweryfikowana:
AGENTS.md, lib/well/SERVICE.md (Diagnostyka HTTP), lib/well_cap/SERVICE.md
(Wiadomości CAP i dostęp), lib/well_cap/STP.md (dodane scenariusze dostępu).
Rzeczywisty układ źródeł: .axe/source-manifest.json; bez tworzenia docs/.

Diagnostyka HTTP wymaga cap przed middleware aplikacji. Rejestracja tras CAP
wymusza grant z wyjątkiem GET/POST logowania. Wiadomości cap:* są chronione
przy join, push, stanie początkowym, odpowiedziach i dostarczeniu z kolejki;
odebranie grantu nie blokuje kanałów aplikacji. Wildcard nie omija ochrony.

## Odbiór

- make check: exit 0; .local/cap-access/check.log
- make build: exit 0; .local/cap-access/build.log
- make cap-access-test: exit 0; .local/cap-access/access-test.log
- make cap-test: exit 0; .local/cap-access/cap-test.log
- make cap-http-test: exit 0; .local/cap-access/http-test.log
- git diff --check: exit 0; .local/cap-access/diff-check.log
- cap-access: 226 asercji (panel włączony i wyłączony, HTTP GET/HEAD,
  brak logowania/brak grantu/grant, odebranie grantu, brak wykonania
  handlera, wildcard WS, wspólne połączenie, kolejka oraz błędy po revocation).
- cap-test: 77; hardening: 101; production: 160; MessageBus: 14; brak porażek.
- Formatowanie: ocamlformat (zmienione fragmenty istniejących plików,
  cały channel.ml i nowy server.ml), deno fmt test/cap_access/run.ts: exit 0.

Start: 2026-10-04T14:26:19Z; koniec: 2026-10-04T14:39:55.920Z; czas całkowity: 817 s.
Dowody i SHA-256 specyfikacji: .local/cap-access/acceptance.json.

## Freeze

Freeze bez zmian: CAP nie ma wcześniejszego snapshotu, a Well SERVICE.md
zawiera również inną deltę API-token względem freeze. Odbiór dotyczy wyłącznie
zaakceptowanej ochrony CAP; nie tworzy baseline ani nie certyfikuje cudzej delty.
Nie zmieniano zaakceptowanej specyfikacji podczas implementacji.

---

# Aktualizacja i instalacja skilli Well — 2026-10-04

Na polecenie użytkownika zaktualizowano well i well-front oraz zainstalowano
je w 37 lokalnych projektach; 102 aliasy zweryfikowane.
well init osadza kanoniczne pliki skill przez regułę builda CLI.
Odbiór: make check (0), make build (0), rzeczywiste well init — zgodność
bajtowa obu skilli i brak LiveView (0), make contract-scaffold (0, 10/10),
git diff --check (0). Snapshot testowy pomija lokalny stan .local/.agents.
Raport i kopie: .local/well-skill-rollout/acceptance.md. Freeze bez zmian;
nie certyfikowano pełnej regresji ani cudzej delty.

---

# Weryfikacja zainstalowanego well init — 2026-10-04

Źródłowy template był zgodny z migracją, ale ~/.local/bin/well nadal zawierał stary scaffold. Po make build (exit 0) zainstalowano bieżącą binarkę CLI (install -m 755; exit 0), zachowując kopię wcześniejszej. Rzeczywiste well init z PATH: 61 plików, zero odniesień LiveView; obecne komponent, rejestracja, build js_of_ocaml, strony SSR z Well.Web i skill well-front. Porównanie installed/build oraz git diff --check: exit 0. Dowody: .local/well-init-verification/{before,after}.json i implementation.md. Freeze bez zmian.

---

# Migracja LiveView → MPA + Well.Web — 2026-10-04

Zakres zatwierdzony przez użytkownika: ROADMAP.md, lib/well_cap/SERVICE.md,
lib/well_cap/STP.md. Implementacja wykonana na polecenie „wykonaj tę implementacje”.
Kod i aktywne instrukcje README/AGENTS/skills odzwierciedlają MPA + Well.Web.
Odbiór: make check (0), make build (0), make cap-test (0, 75/75),
make cap-browser-test z CHROME_BIN i CAP_SCAFFOLD (0, 44/44),
make contract-scaffold (0, 10/10), make contract-actor (0, 110/110 + 2/2),
dune test --force test/contract_socket (0, 21/21 + 3/3), git diff --check (0).
make test (2): znane bazowe OAuth i prymitywy JS w cmd_effects/props_parse;
przejściowy timeout Actor D08 w zbiorczym przebiegu rozwiązany ponowieniem Actor.
Formatowanie nowego OCaml: ocamlformat --inplace; TypeScript: deno fmt.
Logi i pełny raport: .local/liveview-migration/acceptance.md.
Czas od rozpoczęcia: 3117 s, koniec 2026-10-04T06:13:54.992Z.

Implementacja i odbiór CAP/scaffoldu są zakończone. Cały sync nie otrzymuje
statusu verified, ponieważ pełna regresja nie przechodzi. Freeze bez zmian;
zachowano wcześniejsze nieśledzone wpisy i nie certyfikowano cudzej delty.

---

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
