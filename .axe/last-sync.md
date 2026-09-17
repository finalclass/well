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
