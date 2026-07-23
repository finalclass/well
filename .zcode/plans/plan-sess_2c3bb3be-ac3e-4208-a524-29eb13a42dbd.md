## Cel
Stworzyć skill `well-front` (dokumentujący nowy system well.web: TEA → Web Components przez js_of_ocaml), instalowany razem ze skillem `well` w nowych projektach (przez `well init`).

## Zakres (potwierdzony przez użytkownika)
TYLKO well.web (TEA). LiveView pozostaje w skillu `well` — `well-front` wskazuje na `well` dla LiveView, bez duplikacji.

## Pojedyncza zmiana: `lib/well_cli/template.ml`

### A. Dodać zmienną `well_front_skill` (przed linią 6243, przed `frontend_design_skill`)
Wzór: quoted string `{well_front|...|well_front}`, identyczny styl jak `well_skill` (linia 3145) i `frontend_design_skill` (linia 6243).

**Zawartość SKILL.md (cel < 500 linii):**

Frontmatter:
```
---
name: well-front
description: Build client-side interactive UI with well.web — The Elm Architecture (TEA) in OCaml compiled to Web Components via js_of_ocaml. Use whenever adding interactive client components, custom elements (<well-*>), or anything requiring state/updates on the client (buttons that count, forms that react, search, live filters). NOT for server-side LiveView (that's the `well` skill).
user-invocable: true
allowed-tools: Read, Edit, Write, Bash, Glob, Grep
---
```

Sekcje (uziemione w `DESIGN-COMPONENT.md`, `lib/well_web/*.mli`, `lib/well_html/html.ml`, istniejącym `web/counter.mlx`):
1. Czym jest well.web (TEA → Web Components, light DOM domyślnie, jeden bundle `/static/app.js`, zastępuje LiveView długoterminowo).
2. Relacja do skilla `well` (LiveView = stary system, tu nie).
3. Układ plików + build graph (`web/<name>.mlx`, `web/register.ml` entry `(modes js)`, `web/dune`, `static/dune` kopia → `app.js`). Kroki dodania komponentu.
4. Kontrakt `COMPONENT` (dokładna sygnatura: `state`/`msg`/`emits` + `props` + `init`/`update`/`view`; 3. arg `view` = projected children; plik = moduł, rejestracja = top-level `let ()`).
5. Typowane handlery (wariant `Msg|On_key|On_value|On_event` z `html.ml`); tabela MLX desugaringu (`on_click=Msg`, `on_keydown`/`on_input`=nazwana funkcja, reszta → `On_event`); KRYTYCZNE: brak inline `fun` w wartości atrybutu MLX.
6. `Props.t` (`int`/`float`/`bool`/`string`/`list`/`of_eq`, `~default`, `~on`).
7. `Cmd.t` + `emits` (event-w-górę, rodzic = Manager stanu).
8. Rejestracja (`Well_web.component ~module_:(module X) ~tag_name:"well-x" ()`) + użycie na stronie (`<well-x></well-x>` + `<script src="/static/app.js">`).
9. Referencyjny przykład: dystylowany `counter.mlx` (props `Set_step`, emits `CountChanged`, handlery `on_click=Increment`).
10. Pitfalls MLX (`class'`/`style'`, bare-string children, `(txt "")`).

### B. Zarejestrować w `project_files` (po linii 6399)
```ocaml
{ path = ".agents/skills/well-front/SKILL.md"; content = well_front_skill };
```

## Weryfikacja
1. `./vendor/dune build bin/main.exe` — framework kompiluje się po zmianie `template.ml`.
2. `cd /tmp && rm -rf tt && ./_build/default/bin/main.exe init tt` — sprawdzić, że `/tmp/tt/.agents/skills/well-front/SKILL.md` istnieje obok `well/SKILL.md`.
3. Szybka inspekcja: plik ma poprawny frontmatter i zawiera kontrakt COMPONENT + przykład counter.
4. `rm -rf /tmp/tt`.

## Poza zakresem
- Modyfikacja istniejącego `well_skill` (LiveView zostaje).
- Zmiany w samym runtime well.web lub scaffoldzie.
- Aktualizacja AGENTS.md (to osobna decyzja — tam są instrukcje MLX/HTML; well-front je reużywa).