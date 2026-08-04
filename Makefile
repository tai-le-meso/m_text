APP      := m_text
BUILDDIR := build
BUNDLE   := $(BUILDDIR)/$(APP).app

.PHONY: all release bundle icon dmg run debug test test-release clean

all: bundle

release:
	swift build -c release

# The icon is drawn in code (Tools/make-icon.swift) rather than checked in as a binary
# blob nobody can diff, and regenerated with `iconutil`, which ships with the Command Line
# Tools. Offline, like everything else here.
ICNS := $(BUILDDIR)/$(APP).icns

icon: $(ICNS)

$(ICNS): Tools/make-icon.swift
	@mkdir -p $(BUILDDIR)
	swift Tools/make-icon.swift $(BUILDDIR)/$(APP).iconset
	iconutil -c icns $(BUILDDIR)/$(APP).iconset -o $(ICNS)
	@echo "Built $(ICNS)"

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
