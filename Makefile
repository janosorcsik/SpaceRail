## SpaceRail — window-based virtual workspaces for macOS.
## The Xcode project is generated from project.yml (XcodeGen); never edit the .xcodeproj.

SHELL       := /bin/bash
PROJECT     := SpaceRail
XCODEPROJ   := $(PROJECT).xcodeproj
SCHEME      := $(PROJECT)
BUILD_DIR   := build
BUNDLE_ID   := com.janosorcsik.$(PROJECT)
DEV_APP     := $(BUILD_DIR)/Build/Products/Debug/$(PROJECT) Dev.app
ARCHIVE     := $(BUILD_DIR)/$(PROJECT).xcarchive
APP_IN_ARCH := $(ARCHIVE)/Products/Applications/$(PROJECT).app
INSTALLED   := /Applications/$(PROJECT).app
VERSION     := $(shell awk -F'= *' '/^MARKETING_VERSION/ {print $$2; exit}' Config.xcconfig 2>/dev/null)

## Package.resolved lives inside the generated (gitignored) .xcodeproj, so it is mirrored at the
## repo root: `generate` seeds the project with the committed copy, `build` writes back whatever
## Xcode resolved. Commit the root copy.
RESOLVED_IN_PROJ := $(XCODEPROJ)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

XCODEBUILD := xcodebuild -project "$(XCODEPROJ)" -scheme "$(SCHEME)" -derivedDataPath "$(BUILD_DIR)" -quiet

.DEFAULT_GOAL := help
.PHONY: help generate build test run install uninstall logs reset-permissions clean distclean

help: ## Show this help
	@echo "$(PROJECT) $(VERSION)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

generate: ## Regenerate the Xcode project from project.yml
	@command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
	xcodegen generate --spec project.yml --quiet
	@if [ -f Package.resolved ]; then \
	  mkdir -p "$(dir $(RESOLVED_IN_PROJ))"; cp Package.resolved "$(RESOLVED_IN_PROJ)"; fi

build: generate ## Build the dev app (Debug, "SpaceRail Dev", separate bundle ID)
	$(XCODEBUILD) -configuration Debug -destination 'platform=macOS,arch=arm64' build
	@cp "$(RESOLVED_IN_PROJ)" Package.resolved 2>/dev/null || true
	@echo "==> $(DEV_APP)"

test: generate ## Run the unit tests (model and geometry; never launches the app)
	$(XCODEBUILD) -configuration Debug -destination 'platform=macOS,arch=arm64' test

run: build ## Build and (re)launch the dev app
	@pkill -x "$(PROJECT) Dev" 2>/dev/null || true
	open "$(DEV_APP)"

install: generate ## Archive Release and install to /Applications (replaces the running copy)
	@rm -rf "$(ARCHIVE)"
	$(XCODEBUILD) -configuration Release -destination 'generic/platform=macOS' -archivePath "$(ARCHIVE)" archive
	@pkill -x "$(PROJECT)" 2>/dev/null || true
	@rm -rf "$(INSTALLED)"
	cp -R "$(APP_IN_ARCH)" "$(INSTALLED)"
	@rm -rf "$(ARCHIVE)"
	@echo "==> installed $(INSTALLED) ($(VERSION))"
	@codesign -dv "$(INSTALLED)" 2>&1 | grep -E 'Authority=Apple|Runtime' | head -2
	open "$(INSTALLED)"

uninstall: ## Quit and remove the installed app
	@pkill -x "$(PROJECT)" 2>/dev/null || true
	rm -rf "$(INSTALLED)"

logs: ## Stream the app's logs, dev and installed alike (Ctrl-C to stop)
	/usr/bin/log stream --style compact --level debug \
	  --predicate 'subsystem BEGINSWITH "$(BUNDLE_ID)"'

## TCC ties the Accessibility grant to bundle ID + signature. Reset it to exercise the
## first-launch permission flow again:  make reset-permissions          (installed app)
##                                      make reset-permissions PROFILE=dev  (dev app)
reset-permissions: ## Revoke the Accessibility grant (PROFILE=dev for the dev app)
	tccutil reset Accessibility $(BUNDLE_ID)$(if $(filter dev,$(PROFILE)),.debug,)

clean: ## Remove build products
	rm -rf "$(BUILD_DIR)"

distclean: clean ## Also remove the generated Xcode project
	rm -rf "$(XCODEPROJ)"
