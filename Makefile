DUNE := ./vendor/dune
PATCHELF := patchelf
RELEASE_DIR := _release

.PHONY: build check test clean lock dev release

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
