DUNE := ./vendor/dune
PATCHELF := patchelf
RELEASE_DIR := _release

INSTALL_DIR := $(HOME)/.local/bin

.PHONY: build check test clean lock dev release install

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

# Editor tooling (ocamllsp/Merlin) needs well-mlx-pp + ocamlmerlin-well on PATH.
# Same destination as CLI: $(INSTALL_DIR) (default ~/.local/bin).
install: build
	@mkdir -p $(INSTALL_DIR)
	@rm -f $(INSTALL_DIR)/well $(INSTALL_DIR)/well-mlx-pp $(INSTALL_DIR)/ocamlmerlin-well
	@cp -fL _build/install/default/bin/well $(INSTALL_DIR)/well
	@cp -fL _build/install/default/bin/well-mlx-pp $(INSTALL_DIR)/well-mlx-pp
	@cp -fL _build/install/default/bin/ocamlmerlin-well $(INSTALL_DIR)/ocamlmerlin-well
	@chmod 755 $(INSTALL_DIR)/well $(INSTALL_DIR)/well-mlx-pp $(INSTALL_DIR)/ocamlmerlin-well
	@echo "Installed to $(INSTALL_DIR)/:"
	@echo "  well"
	@echo "  well-mlx-pp      (dune dialect + merlin reader backend)"
	@echo "  ocamlmerlin-well (merlin_reader well -> ocamllsp)"

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

