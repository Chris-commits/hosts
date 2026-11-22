# hosts — build, test and install.
#
#   make test        run the test suite (never touches /etc/hosts)
#   make install     test, then install the committed version to $(PREFIX)/bin
#   make status      show installed version vs. this checkout
#   make uninstall   remove the installed command
#   make hooks       opt in: auto-install after commits/pulls on main
#
# `make install` refuses to run with uncommitted changes, so what's installed
# always matches a commit. Override with: make install ALLOW_DIRTY=1

PREFIX  ?= /usr/local
BINDIR  := $(PREFIX)/bin
TARGET  := $(BINDIR)/hosts
BUILD   := .build/hosts
SUDO    := $(shell [ -w "$(BINDIR)" ] || echo sudo)

.PHONY: test install status uninstall hooks clean check-clean

test:
	@tests/run.sh

check-clean:
	@if [ -z "$(ALLOW_DIRTY)" ] && [ -n "$$(git status --porcelain)" ]; then \
	  echo "Uncommitted changes — commit first (or: make install ALLOW_DIRTY=1)."; \
	  git status --short; exit 1; \
	fi

$(BUILD): hosts
	@mkdir -p .build
	@version="$$(git describe --always --dirty --abbrev=7) ($$(git log -1 --format=%cs))"; \
	  sed "s|^VERSION=\"dev\".*|VERSION=\"$$version\"|" hosts > $@; \
	  grep -q "^VERSION=\"$$version\"" $@ || { echo "failed to stamp version"; exit 1; }
	@chmod 755 $@

install: check-clean test
	@rm -f $(BUILD); $(MAKE) --no-print-directory $(BUILD)
	@echo "Installing to $(TARGET)$(if $(SUDO), (needs your password))"
	@$(SUDO) mkdir -p "$(BINDIR)"
	@$(SUDO) install -m 755 $(BUILD) "$(TARGET)"
	@"$(TARGET)" version

status:
	@printf 'checkout:  %s\n' "$$(git describe --always --dirty --abbrev=7)"
	@if [ -x "$(TARGET)" ]; then printf 'installed: %s\n' "$$("$(TARGET)" version)"; \
	  else echo "installed: (not installed)"; fi

uninstall:
	@$(SUDO) rm -f "$(TARGET)" && echo "Removed $(TARGET). Your sets in ~/.hosts-sets are untouched."

hooks:
	@git config core.hooksPath .githooks && echo "Auto-install on main enabled (undo: git config --unset core.hooksPath)"

clean:
	@rm -rf .build
