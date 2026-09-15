# Przykłady kontraktowe

Każdy JSON jest pełną definicją obiegu formatu 1. Pliki TOML stanowią jeden
katalog wejściowy generatora Actor, nie rozszerzenie kontraktów RPC.

| Obieg | Wejście pozycjonalne | Oczekiwany przebieg |
|---|---|---|
| [choice.json](choice.json) | `["finance","Q3"]` | decyzja emituje Accepted i uruchamia Reporter albo Rejected i kończy wynikiem Summary; nigdy obie ścieżki przy one |
| [three-reports.json](three-reports.json) | `["unused","Q3"]` | fork tworzy finance/sales/stock; trzy wyniki są agregowane przed SummaryBuilder |
| [nested-reports.json](nested-reports.json) | `["unused","Q3"]` | finance/sales łączą się w ReportCombiner; jego Report wraz ze stock daje zewnętrzny batch |
| [dynamic-reports.json](dynamic-reports.json) | `[[["finance","Q3"],["sales","Q3"]]]` | ReportSpawner emituje Request dla każdego elementu; liczba gałęzi wynika z emisji |

Puste wejście dynamiczne `[[]]` daje jeden pusty ReportBatch, po którym
SummaryBuilder emituje podsumowanie pustej listy. Pozycja reporter_id jest
pierwszym polem Request; input_path czyta ją przez deskryptor, nie przez
nazwę klucza w payloadzie. Przykłady używają timeout wykonania 60000 ms.

## Kontrakty

[Reports.toml](Reports.toml) definiuje wspólne wiadomości.
[Reporter.toml](Reporter.toml), [ReportSpawner.toml](ReportSpawner.toml),
[ReportDecision.toml](ReportDecision.toml), [ReportCombiner.toml](ReportCombiner.toml)
i [SummaryBuilder.toml](SummaryBuilder.toml) określają niezależne typy aktorów.

## Przykładowa implementacja jednego typu

To przykład do skompilowania podczas weryfikacji implementacji, nie kod
produktu zapisywany przez propozycję specyfikacji. Zależność Reporter jest
wyłącznie od kontraktu Reporter i Reports oraz Well.Actor.

```ocaml
module Impl : Reporter.IMPL = struct
  type state = int
  let state_version = 1
  let init _ = 0
  let state_to_wire n = `Int n
  let state_of_wire = function
    | `Int n when n >= 0 -> Ok n
    | _ -> Error "invalid reporter state"
  let handle ctx state = function
    | Reporter.Inbound.Generate request ->
      let report = Reports.Report.make
        ~source:ctx.self.id ~text:request.subject () in
      Ok (state + 1, [Reporter.Outbound.Produced report])
end

let definition = Reporter.make (module Impl)
```

ReportSpawner mapuje RequestList.requests na listę Outbound.Requested
w kolejności wejścia. ReportCombiner łączy teksty z ReportBatch.items
w Report o source równym własnemu ID. SummaryBuilder łączy teksty w Summary;
join listy jest deterministyczny, a pusty batch daje pusty tekst.
ReportDecision przy subject="reject" emituje Rejected ze Summary,
a w pozostałych przypadkach Accepted z oryginalnym Request.
Te reguły dotyczą fixtures, nie wbudowanych reguł biznesowych runtime'u.

## Kompozycja

Aplikacja najpierw generuje kontrakty przez Well.Actor.Contract.build,
a następnie buduje biblioteki zachowań. Kod startowy konfiguruje Actor,
rejestruje definicje przez register_type, waliduje JSON i wywołuje istniejące
Well.run. Pierwsze send następuje z callbacka działającej aplikacji.
Nie wywołuje się send przed startem schedulera.

```ocaml
let send_report workflow request =
  Well.Actor.send
    ~request_id:"report-q3-001"
    ~timeout_ms:60000
    workflow
    (Well.Actor.Message (Reports.Request.message_type, request))
```

request_id należy do konkretnej operacji aplikacji; stała powyżej jest
wyłącznie przykładem. W produkcji nowa operacja otrzymuje nowy klucz,
a ponowienie tej samej zachowuje poprzedni.
