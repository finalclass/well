# Handoff: nowy frontend well (TEA w OCaml → Web Components)

> Ten plik jest instrukcją startową dla nowej sesji kodującej w tym repozytorium (`well`).
> Czytaj uważnie, potem omów otwarte problemy z użytkownikiem ZANIM napiszesz kod.

Jesteś agentem kodującym. Pracujesz w repozytorium `well` — frameworku webowym w OCamlu
(serwer: własny HTTP na EIO + router, kontrakty TOML → codegen 4 języków, HTML przez
moduł `Html` + dialekt MLX). Instrukcje frameworka czytaj w `CLAUDE.md` (NIE AGENTS.md).

## CO BUDUJEMY I DLACZEGO

Budujemy nowy podsystem frontendowy well: implementację The Elm Architecture (TEA) w OCaml,
która produkuje Web Components (custom elements, domyślnie BEZ shadow DOM, atrybuty-w /
eventy-w-górę). To ma **ZASTĄPIĆ** istniejący LiveView (klient-server string-diff over
WebSocket), który uważamy za porażkę. To jest „holy grail dla AI": frontend z tego samego
materiału (OCaml) co backend, tak aby język wymuszał dobre wzorce, które AI-junior może
utrzymać.

Teza nadrzędna (Juval Lowy / IDesign): AI radzi sobie do progu złożoności, powyżej wymięka.
Więc architektura musi dzielić system na małe, proste, samowystarczalne klocki. Frontend
dotąd był traktowany jako „za prosty by go dzielić" — to już nieprawda. TEA + web components
to sposób, by wymusić jednokierunkowy przepływ stanu (czytelny dla AI) i kompozycję przez
wolatylności (dekompozycja IDesign).

## PRZECZYTAJ NAJPIERW (w tej kolejności)

1. `~/Documents/well/ROADMAP.md` — design doc po polsku. Szczególnie §4 „Braki w LiveView".
   Tu jest intencja i historia decyzji.
2. `~/Documents/well/CLAUDE.md` — konwencje frameworka (~17KB).
3. `~/Documents/sw-lib/src/state-mgr/state-mgr.ts` (414 linii) — **REFERENCJA API do portu.**
   To jest istniejący, działający `stm` w TypeScriptie (Preact-based). Sprawdził się z juniorami.
4. `~/Documents/sw-lib/README.md` — tutorial `stm`. **Najlepsze źródło prawdy** o API i data flow.
5. `~/Documents/well/lib/well/liveview.ml` (812 linii) — rzecz, którą zastępujemy. Zrozum
   DLACZEGO zawiodła: patcher (`compute_patches`) liczy tylko `dynamic`+`each`; zmiany
   strukturalne DOM z `if/else` w view „cicho się nie udają". Nowy system ma **OWN the DOM
   client-side**, nie round-tripować patchy stringów przez WebSocket.
6. `~/Documents/well/lib/well_html/html.ml` (266 linii) — rendering HTML do reużycia.
7. `~/Documents/well/lib/well_cli/contract_codegen.ml` (1590 linii) — codegen kontraktów.
   Emituje już TS browser-facing Proxy (`generate_ts_proxy`) oraz OCaml/jsoo browser Proxy (`generate_ocaml_browser_*` → `build/ocaml_browser/`).
8. Skill `/well` — obecny guidance frontendowy. Uczy LiveView. Będzie wymagał sekcji
   równoległej o nowym systemie.
9. Skill `/axe` — spec-anchored workflow. **UŻYJ GO** dla fazy projektowej tego frameworka.
10. Skill `/idesign-architecture` — volatility-based decomposition. Frontend też podlega VBD.

## DECYZJE JUŻ PODJĘTE (nie relitiguj — to kosztowało godzinę dyskusji)

1. **Architektura: TEA** (Model-View-Update). Stan niezmienny, jeden punkt zmiany `update`,
   view czystą funkcją. Powód: jednokierunkowy przepływ jest czytelny dla AI-juniora.
2. **Pakowanie: Web Components** (custom elements). Domyślnie **BEZ** shadow DOM (light DOM,
   globalne style Tailwind/CSS). shadow opcjonalne per-komponent.
3. **Integracja: atrybuty/props w dół, eventy w górę.** Komponent nie mutuje rodzica;
   dispatchuje `CustomEvent`. Rodzic (shell) jest Managerem stanu domeny.
4. **Polityka stanu:** stan domeny (konfiguracja, dane biznesowe) = one-way, własność
   shella/Managera. Stan interakcji (modal open, draft formularza) = lokalny w liściu.
   To rozróżnienie jest zgodne z IDesign Method (ViewModels na kliencie = anti-pattern
   wg alumni; logika domeny zostaje w Managerze).
5. **Message bus** przez `window`/`document` dla sideways communication (odpowiednik
   Pub/Sub z Method) — opcjonalny, rozwiązuje sideways bez łamania closed layers.
6. **Język: OCaml** (wymusza dyscyplinę, którą TS/Lit tylko pozwalają). To jest powód,
   dla którego portujemy `stm` z TS do OCaml, zamiast zostawić w TS.
7. **Zastępuje LiveView** — nie koegzystuje jako równorzędny. Współistnieje podczas
   migracji, ale nowy system NIE ma zależeć od `Liveview.compute_patches` ani `Websocket`.
8. **`stm` (TS) jest REFERENCJĄ API do portu**, nie celem samym w sobie. Semantyka `stm`
   (`init`/`update`/`view`/`Cmd`/`attributeChangeFactory`/`willMount`/`willUnmount`) przenosi się.
9. **Reużyj contract codegen** — dodaj target melange (mirror `generate_ts_module`),
   reużyj tego samego formatu wire (pozycyjne tablice `to_wire`/`of_wire`), który
   `/rpc/<svc>/<rpc>` już serwuje. Frontend woła RPC type-safely.
10. **Reużyj koncepcję `html.ml`** do renderowania (light DOM = HTML stringi są OK), ale
    runtime custom-element ma **NIE** być modelem string-patch-over-WS.

## `stm` API — SZKIC PORTU DO OCAML (do doprecyzowania)

TS (referencja, z `state-mgr.ts`):

```
component({ tagName, init, update, view, attributeChangeFactory, propTypes,
            shadow, passStateByReference, willMount, willUnmount, debug })
Cmd<Msg> = Promise<Msg> | Msg | null | Event | ['Focus',sel] | CombinedCmds<Msg>
```

**Otwarty problem projektowy** (do rozwiązania w sesji): `stm` w TS jest generyczny
`<State,Msg>`. W OCaml masz trzy drogi: (a) first-class module
`(module S with type state = .. type msg = ..)`, (b) functor, (c) typowe-wartości z
egzystencjałami. To decyduje o ergonomii — omów z użytkownikiem **PRZED** implementacją.

Początkowy szkic sygnatury:

```ocaml
module type COMPONENT = sig
  type state
  type msg
  val tag_name : string
  val init : dispatch:(msg -> unit) -> state * msg Cmd.t
  val update : state -> msg -> unit -> state * msg Cmd.t
  val view : state -> msg Vdom.t
  val attribute_change : (string -> string -> msg) option
  val prop_types : (string * prop_type) list
  val shadow : bool
end
val component : (module COMPONENT) -> unit
```

Zastanów się nad renderowaniem: czy `view` produkuje virtual DOM diffowany client-side
(ocaml-vdom `Vdom` lub własny), czy html-stringi. `stm` używa Preact vdom; port OCaml może
użyć ocaml-vdom lub napisać minimalny diff. To też decyzja projektowa.

## REKOMENDOWANA SEKWENCJA (nie implementuj od razu)

**Faza 0 — SPIKE TOOLCHAINU** (priorytet, mały):
Udowodnij, że Melange kompiluje OCaml → JS w build graph well. Najmniejszy możliwy
przykład: jeden moduł `Hello.ml` → `hello.js`, wstawiony w dune `(melange.emit ...)`.
Jeśli Melange się nie łączy czysto, rozważ js_of_ocaml. **BEZ TEGO cała reszta jest
przedwczesna** — ograniczenia interopu kształtują design.
→ Dostarcz: działający build, jeden element `<hello-world>` renderujący tekst z OCaml.

**Faza 1 — SPEC (axe):**
Napisz spec dla TEA runtime: msg/state/cmd model, lifecycle (init/update/view),
attribute→msg, willMount/willUnmount, Cmd semantics, custom element registration,
reużycie contract codegen (target melange). Omów otwarte problemy z użytkownikiem.
→ Dostarcz: spec + diagramy (skill `/diagrams`: static architecture runtime'u TEA,
call chain init/update/render, sekwencja atrybut→msg→update→view).

**Faza 2 — IMPLEMENTACJA MINIMALNA:**
Portuj rdzeń `stm`: `init`/`update`/`view`/`dispatch`/`Cmd`/`attributeChangeFactory`.
Jeden realny komponent testowy (np. counter z atrybutem, albo edytor listy).
→ Dostarcz: działający komponent z atrybutami w dół i eventami w górę.

**Faza 3 — CONTRACT CODEGEN TARGET:** ✅ (jsoo browser Proxy)
OCaml browser Proxy = mirror TS Proxy (`generate_ocaml_browser_*` w
`contract_codegen.ml`). Output: `lib/contract/build/ocaml_browser/` (+ `rpc.ml`).
Wire bez zmian: `Msg.to_wire`/`of_wire`, `POST /rpc/<Service>/<method>`.
**Używaj `Service.Proxy.*`, nie hand-rolled `Http.*` pod kontrakt.** Runtime: jsoo
(nie Melange). In-process OCaml (`build/ocaml/`) bez zmian.

**Faza 4 (PÓŹNIEJ, nie teraz) — OPIS FRONTU DLA AI:**
Użytkownik chce wymyślić sposób deklaratywnego opisu komponentów, tak aby AI pisało
je z łatwością. To jest meta-poziom, **ZOSTAW na później**.

## ZACZNIJ OD

Nie pisz kodu. Najpierw:

1. Przeczytaj pozycje 1–7 z listy powyżej.
2. Sprawdź obecną konfigurację builda (`dune-project`, `dune.lock/`) — potwierdź brak
   ścieżki OCaml→JS (brak melange/js_of_ocaml/bucklescript/rescript).
3. Omów ze mną:
   - (a) **Melange vs js_of_ocaml** — pierwszy preferowany, ale jeśli build się nie łączy.
   - (b) **First-class module vs functor** dla generyczności `COMPONENT`.
   - (c) **vdom vs html-string** dla `view`.
   - (d) **SSR/hydratacja a MPA well** — czy TEA komponent SSR-swoje initial HTML przez `Html`,
     potem hydrate, czy client-only.
4. Zaproponuj plan fazy 0 (spike) i czekaj na zgodę.

## UWAGI O STYLE I INTEGRACJI

- Trzymaj się house style'u: snake_case pliki, CamelCase moduły, ASCII separatory
  `(* ── Sekcja ── *)`, komentarze doc po angielsku, `@@deriving yojson` gdzie pasuje.
- Nowy podsystem ląduje jako sibling `lib/well/` — prawdopodobnie `lib/well_web/`
  (mirroring public-name pattern `well.core`/`well.html`/`well.cli`).
- Dwa realne ryzyka do mieć na uwadze od pierwszego dnia:
  1. **Melange to nowa zależność**, której well nie ma. Spike fazy 0 jest pierwszym
     krokiem dlatego — ograniczenia interopu kształtują cały design.
  2. **Skill `/well` uczy LiveView.** Jeśli go nie zaktualizujesz, kolejne sesje będą
     generować stary kod LiveView obok nowego. Sekcja równoległa o nowym systemie
     powinna wylądować w skillu wraz z fazą 1.
