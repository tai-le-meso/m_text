APP      := m_text
BUILDDIR := build
BUNDLE   := $(BUILDDIR)/$(APP).app

.PHONY: all release bundle icon dmg run debug test test-release screenshots clean

all: bundle

release:
	swift build -c release

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

icon: $(ICNS)

$(ICNS): $(wildcard $(ICONSET)/*.png)
	@mkdir -p $(BUILDDIR)
	iconutil -c icns $(ICONSET) -o $(ICNS)
	@echo "Built $(ICNS) from $(ICONSET)"

bundle: release $(ICNS)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp .build/release/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(ICNS) $(BUNDLE)/Contents/Resources/$(APP).icns
	codesign --force --sign - $(BUNDLE)
	@echo "Built $(BUNDLE)"

# Distributable disk image. `hdiutil` is part of macOS, so this needs nothing installed.
# The staging folder gets an /Applications symlink so the DMG opens with the familiar
# drag-to-install layout.
#
# The result is ad-hoc signed only — fine for your own machine, but macOS Gatekeeper will
# refuse it on someone else's until it is signed with a Developer ID and notarised. See
# DISTRIBUTION.md; both steps need an Apple Developer account and network access, so
# neither is run here.
DMG    := $(BUILDDIR)/$(APP).dmg
STAGE  := $(BUILDDIR)/dmg

dmg: bundle
	rm -rf $(STAGE) $(DMG)
	mkdir -p $(STAGE)
	cp -R $(BUNDLE) $(STAGE)/
	ln -s /Applications $(STAGE)/Applications
	hdiutil create -volname "$(APP)" -srcfolder $(STAGE) -ov -format UDZO $(DMG)
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
