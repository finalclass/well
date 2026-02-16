DUNE := ./vendor/dune
PATCHELF := patchelf
RELEASE_DIR := _release

INSTALL_DIR := $(HOME)/.local/bin

.PHONY: build check test clean lock dev release install coverage

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

install: build
	@mkdir -p $(INSTALL_DIR)
	@rm -f $(INSTALL_DIR)/well
	@cp _build/default/bin/main.exe $(INSTALL_DIR)/well
	@chmod 755 $(INSTALL_DIR)/well
	@echo "Installed well to $(INSTALL_DIR)/well"

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

coverage:
	$(DUNE) build --instrument-with bisect_ppx
	$(DUNE) exec --instrument-with bisect_ppx test/ppx_test/ppx_test.exe
	$(DUNE) exec -- bisect-ppx-report html -o _coverage/
	$(DUNE) exec -- bisect-ppx-report summary
	@echo "Coverage report: _coverage/index.html"
	@rm -f *.coverage
