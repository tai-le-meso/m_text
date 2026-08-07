APP      := m_text
BUILDDIR := build
BUNDLE   := $(BUILDDIR)/$(APP).app

# Stamped into the bundle's Info.plist and the DMG filename. CI passes the git tag
# (`make dmg VERSION=1.2.3`); the default is what a local build produces.
VERSION  ?= 1.0.1

# `UNIVERSAL=1` builds an arm64 + x86_64 binary, which is what a release wants — a
# native-only DMG simply will not launch on the other architecture.
#
# Built as two `--triple` builds joined with `lipo`, *not* `swift build --arch a --arch b`:
# that form shells out to xcbuild and therefore needs full Xcode, while this project builds
# with the Command Line Tools alone. Verified: the `--arch` form fails here with
# "xcbuild executable ... does not exist", the `--triple` form succeeds.
UNIVERSAL ?= 0
ifeq ($(UNIVERSAL),1)
  BINARY    := $(BUILDDIR)/$(APP)-universal
  BUILD_DEP := universal
else
  BINARY    := .build/release/$(APP)
  BUILD_DEP := release
endif

.PHONY: all release universal bundle icon dmg run debug test test-release screenshots install-cli uninstall-cli clean

all: bundle

release:
	swift build -c release

universal:
	swift build -c release --triple arm64-apple-macosx13.0
	swift build -c release --triple x86_64-apple-macosx13.0
	@mkdir -p $(BUILDDIR)
	lipo -create -output $(BINARY) \
		.build/arm64-apple-macosx/release/$(APP) \
		.build/x86_64-apple-macosx/release/$(APP)
	@lipo -info $(BINARY)

# The app icon is the brand "Syntax stack" mark (direction 2d): a dark squircle, five
# syntax-coloured token bars and a cyan caret. It ships as PNG pairs in
# Resources/Branding/m_text.iconset, which is the design deliverable — the earlier
# drawn-in-code placeholder (Tools/make-icon.swift) is kept for reference but no longer
# feeds the bundle, because the brand mark is artwork rather than something to re-derive.
#
# `m_text-icon.svg` next to it is the vector source; `m_text-icon-animated.svg` blinks the
# caret and is for in-app/web use only — an app icon cannot animate.
#
# `iconutil` ships with the Command Line Tools. Offline, like everything else here.
ICNS := $(BUILDDIR)/$(APP).icns
ICONSET := Resources/Branding/$(APP).iconset

# Landing-page screenshots, captured from the real app (see docs/README.md).
# Sizes down to 1400px so the page stays light.
screenshots:
	@mkdir -p docs/assets
	MTEXT_CAPTURE=$(BUILDDIR)/shots swift run m_text
	@for f in editor-dark editor-light split-dark; do \
		sips -Z 1400 $(BUILDDIR)/shots/$$f.png --out docs/assets/$$f.png >/dev/null; done
	@sips -Z 1120 $(BUILDDIR)/shots/palette-dark.png --out docs/assets/palette-dark.png >/dev/null
	@echo "Updated docs/assets — check the capture's colour/transparency report above"

# The `mtext` shell command, so `mtext .` opens the current folder like `code .` does.
#
# Installs to ~/.local/bin, not /usr/local/bin: the latter is unwritable on a managed (MDM)
# Mac, where `install` fails with "Permission denied" and there is no sudo to reach for.
# ~/.local/bin needs no privileges. The installer adds it to your shell profile if it is not
# already on PATH; `make install-cli PREFIX=/usr/local` still works if you have the rights.
PREFIX ?= $(HOME)/.local

install-cli:
	@PREFIX=$(PREFIX) Tools/install-cli.sh

uninstall-cli:
	@PREFIX=$(PREFIX) Tools/install-cli.sh --uninstall

icon: $(ICNS)

$(ICNS): $(wildcard $(ICONSET)/*.png)
	@mkdir -p $(BUILDDIR)
	iconutil -c icns $(ICONSET) -o $(ICNS)
	@echo "Built $(ICNS) from $(ICONSET)"

bundle: $(BUILD_DEP) $(ICNS)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(ICNS) $(BUNDLE)/Contents/Resources/$(APP).icns
	# Version lives in one place — $(VERSION) — rather than being edited by hand in the
	# plist for every release and drifting from the tag.
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" $(BUNDLE)/Contents/Info.plist
	# Signing must come last: it seals the bundle, so any edit after this invalidates it.
	codesign --force --sign - $(BUNDLE)
	@echo "Built $(BUNDLE) ($(VERSION))"

# Distributable disk image. `hdiutil` is part of macOS, so this needs nothing installed.
# The staging folder gets an /Applications symlink so the DMG opens with the familiar
# drag-to-install layout.
#
# The result is ad-hoc signed only — fine for your own machine, but macOS Gatekeeper will
# refuse it on someone else's until it is signed with a Developer ID and notarised. See
# DISTRIBUTION.md; both steps need an Apple Developer account and network access, so
# neither is run here.
DMG    := $(BUILDDIR)/$(APP)-$(VERSION).dmg
STAGE  := $(BUILDDIR)/dmg

dmg: bundle
	rm -rf $(STAGE) $(DMG)
	mkdir -p $(STAGE)
	cp -R $(BUNDLE) $(STAGE)/
	ln -s /Applications $(STAGE)/Applications
	hdiutil create -volname "$(APP) $(VERSION)" -srcfolder $(STAGE) -ov -format UDZO $(DMG)
	rm -rf $(STAGE)
	@echo "Built $(DMG)"

run: bundle
	open $(BUNDLE)

# Debug build, runs attached to the terminal (log output visible)
debug:
	swift build
	.build/debug/$(APP)

# Tests do NOT use XCTest (that needs Xcode.app) — they are a plain executable.
# Filter with: make test FILTER=PieceTree
test:
	swift run MTextTests $(FILTER)

# Performance budgets are only meaningful on an optimised build.
test-release:
	swift run -c release MTextTests $(FILTER)

clean:
	rm -rf .build $(BUILDDIR)
