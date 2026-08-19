# AGENTS.md

Instrukcje dla agentów AI pracujących w repozytorium `well`. Punkt wejścia:
twarde reguły + wskaźniki do artefaktów, które są źródłem prawdy. Nie duplikuj
ich tutaj — jeśli coś tu brzmi lakonicznie, szczegóły są w linkowanym pliku.

## Czym jest well

Full-stackowy framework webowy w OCaml 5 (EIO, fiber-per-connection). Jeden
binarny plik, brak JavaScriptu dla logiki biznesowej. MLX = JSX dla OCaml.
SQLite (bundled). Kontrakty usług w TOML → codegen (OCaml server, OCaml browser Proxy/jsoo, TS, Go, Dart). Klient przeglądarki: `build/ocaml_browser` `Proxy`, nie ręczny Http pod kontrakt.
Pełna wizja i stan w `ROADMAP.md`.

Dwie warstwy frontendu:

- **Backend (server-side)** — routing, LiveView (string-diff over WS), SQL,
  usługi. Profil: strony renderowane na serwerze. Skill: `/well`.
- **well.web (client-side, TEA)** — Web Components kompilowane do JS przez
  js_of_ocaml, The Elm Architecture (init/update/view), stan na kliencie.
  Docelowo zastępuje LiveView dla interaktywnego UI. Statyczna architektura w
  `lib/well_web/ARCH.md`, decyzje API w `DESIGN-COMPONENT.md`. Skill: `/well-front`.

## Build

```bash
make build   # dune build (vendor/dune)
make check   # dune build @check — type-check only, najszybsze
make test    # dune test
make dev     # bin/main.exe
```

Znany, niezależny failure runtime: `oauth_provider_test` — ignorować.

## Język

- **Kod** (identyfikatory, funkcje, messages commitów): angielski.
- **Dokumentacja i komentarze**: angielski w kodzie, **polski w artefaktach
  spec** (`ARCH.md`, `SERVICE.md`, `DESIGN-COMPONENT.md`, handoffy, docstringi
  nad `.mli`). Spójne z istniejącą konwencją.
- **UI użytkownika**: polski (dziedzictwo projektu `dg`).

## Źródła prawdy (czytaj w tej kolejności przed zmianą)

1. `lib/well_web/ARCH.md` — statyczna architektura podsystemu well.web (warstwy
   IDesign, komponenty, call-graph, resource map). Poziom podsystemu; well.web
   jest częścią większego `well`, ale tu opisana jest jego wewnętrzna struktura.
2. `lib/<service>/SERVICE.md` — rola, granica abstrakcji, założenia, scenariusze,
   strategia weryfikacji usługi. **Czarnoskrzynkowa** — co usługa oferuje, nie
   jak jest zbudowana w środku.
3. `lib/<service>/<service>.mli` — kontrakt wiążący (compiler egzekwuje w
   compile-time). Well.web nie używa TOML dla codegenu kontraktów — `.mli`
   zastępuje TOML. Diagramy przypadków użycia w doc-comment `(** *)` nad
   publicznym `val`.
4. `DESIGN-COMPONENT.md` — decyzje projektowe API frontendu (`D1`–`D18`).
   Uwaga: `D7`/`D9`/`D10`/`D11`/`D17` są historycznie unieważnione przez `D18`
   + sekcję „FINALNA SYGNATURA" — czytaj te jako aktualne.
5. `ROADMAP.md` — wizja, decyzje, status implementacji (fazy 0–5 done).

Dla usług backendu z kontraktem TOML, trzeci artefakt to `lib/contract/<Service>.toml`
(opis metody w TOML jest wiążący — kod musi go zrealizować dosłownie).

## Twarde reguły

- **Brak komentarzy w kodzie źródłowym.** Kod ma być samowyjaśniający się
  (nazwy, struktura). Cała wiedza domenowa/architektoniczna żyje w `ARCH.md`,
  `SERVICE.md`, kontraktach. To nie jest preferencja stylistyczna — to reguła
  Juvala: komentowanie kodu oznacza, że przegrałeś, a komentarze dryfują od
  kodu i stają się mylące.
- **Workflow `axe` jest obowiązkowy** dla każdej zmiany pod `lib/` lub `test/`,
  nawet drobnej. Pięć faz: Diagnosis → Propose (diff spec) → Completeness →
  Coherence → Implement. Nie pisz kodu, dopóki spec nie jest kompletny,
  spójny i zatwierdzony. Skill: `/axe` (symlink w `.agents/skills/axe`).
- **Gdy kod i spec się rozchodzą:** (1) zgłoś rozbieżność, (2) domyślny fix to
  doprowadzić kod do zgodności ze specem, (3) **nigdy nie zmieniaj specu sam** —
  wymaga wyraźnej zgody architekta.
- **Brak auto-branchowania.** Commit na `master` tylko gdy wyraźnie
  poproszony. Nie twórz gałęzi własną inicjatywą.
- **SQLite:** handle `Sqlite3.db` NIE jest thread-safe. Każdy aktor otwiera
  własne połączenie w `init` z `PRAGMA journal_mode=WAL` i `busy_timeout=5000`.
  Nigdy nie współdziel handle między aktorami/domainami. Brak connection poolu.
- **Bez `Co-Authored-By` w commitach.**

## Konwencje frontendu well.web

- **Jeden plik `.mlx` = jeden komponent = jeden moduł OCaml.** Bez wrapper
  `module Foo = struct ... end` — plik JEST modułem. Samo-odniesienie na końcu:
  `component ~module_:(module Counter) ~tag_name:"well-counter" () ;;`
- `module_` z podkreślnikiem (D4, non-negotiable — `module` jest słowem
  kluczowym).
- **Trzy typy abstrakcyjne per komponent:** `state`, `msg`, `emits`. `props :
  msg Props.t` zastępuje stare `attribute_change`. `Cmd.t` jest dwuparametrowy
  `('msg, 'emits)`.
- **Toolchain (D15):** js_of_ocaml (NIE Melange — psuje dialekt MLX).
  `(preprocess (pps js_of_ocaml-ppx))` musi być w **executable** stanza (nie
  dziedziczy z library). Każdy executable komponentu musi to mieć.
- **MLX attribute values:** full OCaml `expr` inside parentheses works, including
  inline `fun`: `on_change=(fun v -> Set_name v)`. Bare `on_change=fun …`
  still fails (needs parens). Named handlers remain fine: `on_change=handle_change`.
- `{x}` w MLX to **wyrażenie rekordowe**, NIE interpolacja. `<span>{n}</span>`
  to błąd; użyj `<span>(txt (string_of_int n))</span>`.
- **Vdom jest zunifikowany** (`Html.node` == `Vdom.t`, generyczny nad `'msg`).
  Frontend: `msg vdom`. Backend: `unit vdom`. Definicja w `lib/well_html/html.ml`.
- **Handlery zdarzeń są typowane** (wariant `Msg` | `On_key` | `On_value` |
  `On_form` | `On_event` | `Ignore`). `on_submit` → `On_form` (`form_data ->
  msg`, FormData + preventDefault). Zob. `DESIGN-COMPONENT.md` /
  `skills/well-front/SKILL.md`.
- **Parent → child:** `Html.element ~addr` (MLX `addr=`) nazywa pętlę dziecka;
  `Cmd.send ~addr child_msg` kładzie `msg` na jej `dispatch`. To nie jest
  `key`, `ref`, `querySelector` ani bus. Child → parent zostaje `Cmd.emit`.
  Brak `addr` = no-op. Skill: `/well-front`.

## Testowanie zmian w samym frameworku

`well init` scaffolduje projekt pinujący `well` z GitHub. Aby przetestować
lokalne zmiany frameworka na scaffoldzie:

1. W scaffoldzie zmień pin w `dune-project` na `file:///home/sel/well`.
2. Przed `dune pkg lock` tymczasowo przenieś `.agents` (skrypt `dune pkg scan`
   crashuje na katalogu-źródle `.agents/skills/axe`). Przywróć po lock.
3. `rm -rf dune.lock _build && dune pkg lock && dune build`.
4. Po zmianie `lib/well_cli/template.ml` przebuduj `./vendor/dune build
   bin/main.exe` w frameworku zanim scaffoldujesz.

## Skills dostępne w sesji

- `/axe` — spec-anchored development workflow (obowiązkowy dla zmian w
  `lib/`/`test/`). `.agents/skills/axe` (symlink).
- `/well` — referencja backendu frameworka (routing, LiveView, SQL, kontrakty).
  `skills/well/SKILL.md`.
- `/well-front` — well.web / TEA / Web Components (interaktywny UI klienta).
  `skills/well-front/SKILL.md`.
