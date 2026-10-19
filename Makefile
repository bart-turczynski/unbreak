.DEFAULT_GOAL := build
.PHONY: build release test fmt fmt-check lint clean run

# swift-testing ships as a framework. Full Xcode wires it up automatically, but
# the standalone Command Line Tools do not pass its search/runtime paths, so we
# add them here. Derived from the active developer dir, so no hardcoded path;
# harmless when full Xcode is selected.
# Swift 6.4 builds with the Swift Build engine by default, which on the
# standalone Command Line Tools also misses the TestingMacros compiler plugin
# (`@Test`/`@Suite` fail with "plugin for module 'TestingMacros' not found"),
# so its plugin directory is passed too.
DEVDIR := $(shell xcode-select -p)
FWK := $(DEVDIR)/Library/Developer/Frameworks
LIBT := $(DEVDIR)/Library/Developer/usr/lib
TPLUG := $(DEVDIR)/usr/lib/swift/host/plugins/testing
TEST_FLAGS := -Xswiftc -F -Xswiftc $(FWK) \
	-Xswiftc -plugin-path -Xswiftc $(TPLUG) \
	-Xlinker -F -Xlinker $(FWK) \
	-Xlinker -rpath -Xlinker $(FWK) \
	-Xlinker -rpath -Xlinker $(LIBT)

build:
	swift build

release:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

# Format in place (requires swift-format: `brew install swift-format`).
fmt:
	swift-format format --in-place --recursive Sources Tests Package.swift

# CI-friendly: fail if anything is unformatted.
fmt-check:
	swift-format lint --recursive --strict Sources Tests Package.swift

# Optional static analysis (requires swiftlint: `brew install swiftlint`).
lint:
	swiftlint lint --quiet

clean:
	swift package clean
	rm -rf .build

# Run the CLI against stdin, e.g.: pbpaste | make run
run:
	swift run unbreak -
