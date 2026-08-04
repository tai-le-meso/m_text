APP      := m_text
BUILDDIR := build
BUNDLE   := $(BUILDDIR)/$(APP).app

.PHONY: all release bundle run debug test test-release clean

all: bundle

release:
	swift build -c release

bundle: release
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp .build/release/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)
	@echo "Built $(BUNDLE)"

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
