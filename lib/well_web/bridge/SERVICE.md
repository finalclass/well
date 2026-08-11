# SERVICE.md — Bridge

## Role

Most między runtime'em OCaml a światem zewnętrznym JS-runtime/DOM. Tłumaczy
żądania runtime (tworzenie elementów DOM, dispatch eventów,
requestAnimationFrame, dostęp do globali) na wywołania JS przez FFI jsoo.

## Abstraction boundary

Enkapsuluje V-bridge — jak reprezentowane są wartości OCaml ↔ JS, jak FFI jest
zrealizowane. Ukrywa przed innymi serwisami: szczegóły jsoo (`Js.Unsafe`,
`##`, `Js.t`), strukturę JS-runtime, konwencje FFI.

Definiuje abstrakcyjne typy reprezentujące byty JS-runtime: `element`, `value`,
`event`, `callback`, `promise`. Inne serwisy operują na tych typach bez
wiedzy o ich wewnętrznej strukturze.

Lista operacji rozrasta się wraz z potrzebami runtime — obecny zestaw to atomic
verbs udowodnione w spajku S7 (`lib/well_web/spike_ffi.ml`).

## Assumptions

- `register_element` jest wołane przed jakimkolwiek elementem tego typu
  pojawi się w DOM (reguła z ComponentAccess). Opcjonalne
  `observed_attributes` / `on_attribute_change` mapują na
  `observedAttributes` + `attributeChangedCallback`; `property_names` /
  `on_property_set` instalują `Object.defineProperty` na prototypie CE
  (get/set + notify).
- `find_element` zwraca `None` jeśli selector nie matchuje (nie rzuca).
- `dispatch_event` tworzy CustomEvent z payloadem jako JS-value (konwersja
  przez FFI; payload musi być konwertowalny).
- `request_animation_frame` callback jest wołany dokładnie raz, z timestampem.
- FFI jsoo jest zawsze dostępne (runtime żyje w przeglądarce, nie w node).
- `insert_before` z `ref_ = None` wstawia dziecko na końcu rodzica (przekazuje
  `null` jako reference node do `insertBefore`).
- `add_event_listener` zwraca funkcję unsub — wołanie jej odpina ten sam
  callback przez `removeEventListener`. Callback jest trzymany w ref, bo
  `removeEventListener` wymaga tej samej referencji funkcji co `addEventListener`.
- `get_parent` zwraca `None` gdy element nie ma rodzica (parentNode === null);
  nie rzuca.
- `get_input_value`/`set_value` operują na właściwości `.value` elementu; dla
  elementów formularza (input/select/textarea) jest to string, dla innych
  elementów zachowanie zależy od JS-runtime.
- Operacje DOM (`create_element`, `child_nodes`, `node_type`, `node_value`,
  `append_child`, `insert_before`,
  `remove_child`, `replace_child`, `set_attribute`, `remove_attribute`,
  `get_attribute`, `set_bool_attribute`, `get_js_property`,
  `set_js_property`) są thin-FFI — nie walidują argumentów, delegują do
  JS-runtime. `set_bool_attribute` ustawia/usuwa atrybut HTML i synchronizuje
  typowe IDL boolean properties po nazwie camelCase (`readOnly`, `isMap`,
  `noValidate`, `formNoValidate`, `allowFullscreen`, …) gdy atrybut jest na
  allowliście. `take_own_js_property` / `set_well_prop_storage` służą Inputs
  do unshadow own data props przy connect. `child_nodes` / `node_type` /
  `node_value` służą ComponentAccess do capture projected light-DOM (bez
  semantyki TEA w Bridge).

## Scenarios

- [RegisterElement](bridge.mli) — zarejestruj custom element w JS.
- [FindElement](bridge.mli) — znajdź element w dokumencie.
- [SetText](bridge.mli) — ustaw textContent elementu.
- [DispatchEvent](bridge.mli) — wyślij CustomEvent z elementu w górę.
- [RequestAnimationFrame](bridge.mli) — zaplanuj callback w następnej klatce.
- [SubscribeChannel](bridge.mli) — zapisz się na wiadomości z kanału WS.
- [PushChannel](bridge.mli) — wyślij wiadomość na kanał WS.
- [UnsubscribeChannel](bridge.mli) — odpisz się z kanału WS.
- [GetNested](bridge.mli) — czytaj zagnieżdżone pole JS-value po ścieżce (get_string/get_int/get_float/get_bool/get_value).
- [CreateElement](bridge.mli) — stwórz element DOM o danym tagu.
- [CreateTextNode](bridge.mli) — stwórz węzeł tekstowy.
- [AppendChild](bridge.mli) — dołącz dziecko do rodzica.
- [InsertBefore](bridge.mli) — wstaw dziecko przed referencyjnym (None = na końcu).
- [RemoveChild](bridge.mli) — usuń dziecko z rodzica.
- [ReplaceChild](bridge.mli) — zastąp stare dziecko nowym.
- [SetAttribute](bridge.mli) — ustaw atrybut HTML na elemencie.
- [RemoveAttribute](bridge.mli) — usuń atrybut HTML z elementu.
- [AddEventListener](bridge.mli) — dodaj listener zdarzenia, zwraca unsub.
- [GetParent](bridge.mli) — zwróć rodzica elementu (None jeśli bez rodzica).
- [GetInputValue](bridge.mli) — czytaj value elementu formularza.
- [SetValue](bridge.mli) — ustaw value elementu formularza.
- [EventPreventDefault](bridge.mli) — `event.preventDefault()`.
- [EventFormData](bridge.mli) — pary `(name, value)` z `FormData(event.target)` (bez File).

## Verification strategy

Utility z FFI — weryfikujemy **w przeglądarce** (jsoo-runtime, nie node).
Spajk S7 (`lib/well_web/spike_ffi.ml`) już udowodnił: register_element,
find_element, set_text (textContent :=), dispatch_event, request_animation_frame.
Krytyczne:

- Czy zarejestrowany custom element wywołuje `on_connect`/`on_disconnect` przy
  wstawieniu/usunięciu z DOM.
- Czy `dispatch_event` faktycznie emituje CustomEvent odbierany przez
  parenta (event-w-górę, D9).
- Czy `request_animation_frame` callback jest wołany z poprawnym timestampem.
- Czy deep-get (`get_string "a.b.c"`) przechodzi zagnieżdżone obiekty i
  zwraca poprawnie typowaną wartość.

Nowe imperatywne operacje DOM (diff/patch vdom Rendering Client) — te nie są
pokryte spajkiem S7, wymagają osobnej weryfikacji w przeglądarce:

- Czy `create_element`/`create_text_node` tworzą poprawne węzły widoczne w DOM.
- Czy `insert_before` z `ref_ = None` faktycznie wstawia na końcu (append
  semantyka), a z `ref_ = Some` przed referencją.
- Czy `replace_child`/`remove_child` mutują rodzica poprawnie (kolejność
  argumentów new_/old zgodna z DOM API).
- Czy `add_event_listener` zwrócony unsub faktycznie odpina callback
  (ponowne wywołanie tego samego eventu nie triggeruje po unsub).
- Czy `get_parent` zwraca `None` dla odłączonego węzła i `Some` dla osadzonego.
- Czy `get_input_value`/`set_value` round-trip na input/select zachowuje value.
