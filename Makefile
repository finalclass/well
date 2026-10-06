DUNE := $(shell if [ -x ./vendor/dune ]; then echo ./vendor/dune; else command -v dune; fi)
PATCHELF := patchelf
RELEASE_DIR := _release

INSTALL_DIR := $(HOME)/.local/bin

.PHONY: build check test clean lock dev release install ocamlformat-mlx \
	contract-check contract-build contract-native contract-publish \
	contract-browser contract-clients contract-socket contract-actor \
	contract-scaffold

.PHONY: api-token-test
api-token-test: build
	$(DUNE) exec test/api_token/api_token_test.exe
	deno run -A test/api_token/run.ts

build:
	$(DUNE) build

check:
	$(DUNE) build @check

test:
	$(DUNE) test

clean:
	$(DUNE) clean

lock:
	$(DUNE) pkg lock

dev:
	$(DUNE) exec bin/main.exe

# Patched formatter for Well MLX (keywords + hyphen attrs in JSX).
ocamlformat-mlx:
	./tools/ocamlformat-mlx/build.sh

# Editor tooling on PATH (default ~/.local/bin).
# Prefer this directory over opam's bin in the editor so ocamllsp finds these.
install: build ocamlformat-mlx
	@mkdir -p $(INSTALL_DIR)
	@rm -f $(INSTALL_DIR)/well $(INSTALL_DIR)/well-mlx-pp \
		$(INSTALL_DIR)/ocamlmerlin-well $(INSTALL_DIR)/ocamlformat-mlx
	@cp -fL _build/install/default/bin/well $(INSTALL_DIR)/well
	@cp -fL _build/install/default/bin/well-mlx-pp $(INSTALL_DIR)/well-mlx-pp
	@cp -fL _build/install/default/bin/ocamlmerlin-well $(INSTALL_DIR)/ocamlmerlin-well
	@cp -fL tools/ocamlformat-mlx/ocamlformat-mlx $(INSTALL_DIR)/ocamlformat-mlx
	@chmod 755 $(INSTALL_DIR)/well $(INSTALL_DIR)/well-mlx-pp \
		$(INSTALL_DIR)/ocamlmerlin-well $(INSTALL_DIR)/ocamlformat-mlx
	@echo "Installed to $(INSTALL_DIR)/:"
	@echo "  well"
	@echo "  well-mlx-pp       (dune dialect + merlin reader backend)"
	@echo "  ocamlmerlin-well  (merlin_reader well -> ocamllsp)"
	@echo "  ocamlformat-mlx   (Well JSX-aware formatter for ocamllsp)"
	@# ocamllsp uses Bin.which on PATH; envrc/opam often wins over ~/.local/bin.
	@# Overwrite switch binary (backup stock once) so format always hits Well.
	@if [ -n "$$OPAM_SWITCH_PREFIX" ] && [ -d "$$OPAM_SWITCH_PREFIX/bin" ]; then \
	  if [ -x "$$OPAM_SWITCH_PREFIX/bin/ocamlformat-mlx" ] \
	     && [ ! -e "$$OPAM_SWITCH_PREFIX/bin/ocamlformat-mlx.stock" ]; then \
	    cp -fL "$$OPAM_SWITCH_PREFIX/bin/ocamlformat-mlx" \
	      "$$OPAM_SWITCH_PREFIX/bin/ocamlformat-mlx.stock"; \
	    echo "  (backed up opam ocamlformat-mlx -> .stock)"; \
	  fi; \
	  cp -fL tools/ocamlformat-mlx/ocamlformat-mlx \
	    "$$OPAM_SWITCH_PREFIX/bin/ocamlformat-mlx"; \
	  chmod 755 "$$OPAM_SWITCH_PREFIX/bin/ocamlformat-mlx"; \
	  echo "  also -> $$OPAM_SWITCH_PREFIX/bin/ocamlformat-mlx"; \
	fi

release: build
	@echo "==> Creating release bundle..."
	@rm -rf $(RELEASE_DIR)
	@mkdir -p $(RELEASE_DIR)/bin/lib
	@# Copy binary
	@cp _build/default/bin/main.exe $(RELEASE_DIR)/bin/well
	@chmod 755 $(RELEASE_DIR)/bin/well
	@# Copy shared libraries from vendor/lib (skip project-specific ones)
	@for lib in ld-linux-x86-64.so.2 libc.so.6 libm.so.6 libgcc_s.so.1 \
	            libgmp.so.10 libsqlite3.so.0 libz.so.1 \
	            libpthread.so.0 librt.so.1; do \
		if [ -f vendor/lib/$$lib ]; then \
			cp vendor/lib/$$lib $(RELEASE_DIR)/bin/lib/; \
		fi; \
	done
	@# Patch binary: interpreter relative to CWD, rpath relative to binary
	$(PATCHELF) \
		--set-interpreter bin/lib/ld-linux-x86-64.so.2 \
		--set-rpath '$$ORIGIN/lib' \
		$(RELEASE_DIR)/bin/well
	@echo "==> Release ready: $(RELEASE_DIR)/"
	@echo "    Run with: cd $(RELEASE_DIR) && ./bin/well"

# ── Contract migration targets (W2) ───────────────────────────────────
# Binding names from lib/well_cli/contract/STP.md. Later stages extend them.

W2_FIXTURES := $(CURDIR)/test/contract_build/fixtures
W2_GEN := _build/default/test/contract_build/gen.exe
W2_TEST := _build/default/test/contract_build/contract_build_test.exe
CONTRACT_WORK := _build/contract-work/w2

contract-check: build
	@mkdir -p $(CONTRACT_WORK)
	rm -rf $(CONTRACT_WORK)/native
	$(W2_GEN) $(W2_FIXTURES)/native $(CONTRACT_WORK)/native
	@test -f $(CONTRACT_WORK)/native/manifest.json

contract-build: contract-check
	@echo "contract-build: isolated layout generated under $(CONTRACT_WORK)/native"

contract-publish: build
	$(W2_TEST) $(CURDIR)/test/contract_build

contract-native: build
	deno run -A test/contract_native/run.ts

contract-browser: build
	deno run -A test/contract_browser/run.ts

contract-clients: build
	deno run -A test/contract_clients/run.ts

contract-socket: build
	$(DUNE) test test/contract_socket
	deno run -A test/contract_socket/run.ts

# W5: Actor descriptors/hashes against the preserved old generator, and the
# durable store resume / Blocked regression in test/actor_test.
contract-actor: build
	$(DUNE) test --force test/contract_actor
	$(DUNE) test --force test/actor_test

# W6: scaffold build with native .cyrograf sources, real RPC + browser Proxy,
# and deterministic regeneration after deleting only the generated results.
contract-scaffold: build
	deno run -A test/contract_scaffold/run.ts

.PHONY: cap-test cap-browser-test
cap-test: build
	deno run -A test/cap_mpa/run.ts

cap-browser-test: build
	deno run -A test/cap_mpa/browser.ts

.PHONY: cap-access-test cap-http-test
cap-access-test:
	$(DUNE) build test/cap_access/server.exe
	deno run -A test/cap_access/run.ts

cap-http-test:
	$(DUNE) test --force test/hardening_test test/production_test test/bus_test

.PHONY: auth-test
auth-test:
	$(DUNE) runtest test/auth_test
