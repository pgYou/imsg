SHELL := /bin/bash

.PHONY: help format lint test build imsg clean

help:
	@printf "%s\n" \
		"make format  - swift format in-place" \
		"make lint    - swift format lint + swiftlint" \
		"make test    - sync version, patch deps, run swift test" \
		"make build   - universal release build into bin/" \
		"make imsg    - clean rebuild + run debug binary (ARGS=...)" \
		"make clean   - swift package clean"

format:
	swift format --in-place --recursive Sources Tests

lint:
	swift format lint --recursive Sources Tests
	swiftlint

test:
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	swift test

build:
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	scripts/build-universal.sh

imsg:
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	swift package clean
	swift build -c debug --product imsg \
		-Xswiftc -target -Xswiftc x86_64-apple-macos12.0
	./.build/debug/imsg $(ARGS)

clean:
	swift package clean
