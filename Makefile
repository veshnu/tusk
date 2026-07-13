# Tusk — build & install the GUI app and the `tusk` CLI.
#
#   make            build everything and assemble dist/Tusk.app + dist/tusk
#   make install    install Tusk.app to /Applications and `tusk` onto PATH
#   make uninstall  remove both
#   make dist       zip a release artifact (dist/Tusk-<version>.zip)
#   make clean      remove build + dist output

APP_NAME  := Tusk
VERSION   := 0.1.0
CONFIG    := release

BUILD_DIR := .build/$(CONFIG)
DIST_DIR  := dist
APP       := $(DIST_DIR)/$(APP_NAME).app

# Install locations. Prefer the Homebrew bin dir if present so `tusk` lands on PATH.
BREW_PREFIX := $(shell brew --prefix 2>/dev/null)
BINDIR    ?= $(if $(BREW_PREFIX),$(BREW_PREFIX)/bin,/usr/local/bin)
APPDIR    ?= /Applications

.PHONY: all build bundle install uninstall register-mcp unregister-mcp dist icon clean

all: bundle

build:
	swift build -c $(CONFIG)

# Regenerate packaging/AppIcon.icns from the CoreGraphics renderer.
icon:
	@rm -rf "$(DIST_DIR)/AppIcon.iconset" && mkdir -p "$(DIST_DIR)/AppIcon.iconset"
	@swiftc -O packaging/makeicon.swift -o "$(DIST_DIR)/makeicon"
	@"$(DIST_DIR)/makeicon" "$(DIST_DIR)/AppIcon.iconset"
	@iconutil -c icns "$(DIST_DIR)/AppIcon.iconset" -o packaging/AppIcon.icns
	@echo "Regenerated packaging/AppIcon.icns"

# Assemble Tusk.app around the built GUI binary, and stage the CLI as `tusk`.
bundle: build
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	@sed 's/__VERSION__/$(VERSION)/g' packaging/Info.plist.in > "$(APP)/Contents/Info.plist"
	@cp packaging/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	@cp "$(BUILD_DIR)/tuskcli" "$(DIST_DIR)/tusk"
	@chmod +x "$(DIST_DIR)/tusk"
	@echo "Built $(APP) and $(DIST_DIR)/tusk"

install: bundle
	@rm -rf "$(APPDIR)/$(APP_NAME).app"
	cp -R "$(APP)" "$(APPDIR)/"
	@mkdir -p "$(BINDIR)"
	install -m 0755 "$(DIST_DIR)/tusk" "$(BINDIR)/tusk"
	@mkdir -p "$(HOME)/TuskProjects"
	@echo "Installed $(APPDIR)/$(APP_NAME).app and $(BINDIR)/tusk"
	@echo "Workspace folder ready at $(HOME)/TuskProjects"
	@$(MAKE) --no-print-directory register-mcp

# Register the MCP server with Claude Code at user scope (available in all
# projects). Best-effort: skips gracefully if the `claude` CLI isn't installed.
register-mcp:
	@if command -v claude >/dev/null 2>&1; then \
		claude mcp remove tusk -s user >/dev/null 2>&1 || true; \
		claude mcp add tusk -s user -- "$(BINDIR)/tusk" mcp >/dev/null && \
		echo "Registered MCP server 'tusk' with Claude Code (user scope)."; \
	else \
		echo "Note: 'claude' CLI not found — skipped MCP registration."; \
		echo "      To add it later:  claude mcp add tusk -s user -- $(BINDIR)/tusk mcp"; \
	fi

unregister-mcp:
	@command -v claude >/dev/null 2>&1 && claude mcp remove tusk -s user >/dev/null 2>&1 || true

uninstall: unregister-mcp
	rm -rf "$(APPDIR)/$(APP_NAME).app"
	rm -f "$(BINDIR)/tusk"
	@echo "Removed $(APPDIR)/$(APP_NAME).app, $(BINDIR)/tusk, and the Claude MCP entry"

# Release artifact: a zip containing both Tusk.app and the tusk binary, for the cask.
dist: bundle
	cd "$(DIST_DIR)" && ditto -c -k --sequesterRsrc --keepParent . "$(APP_NAME)-$(VERSION).zip"
	@echo "Wrote $(DIST_DIR)/$(APP_NAME)-$(VERSION).zip"

clean:
	rm -rf "$(DIST_DIR)"
	swift package clean
