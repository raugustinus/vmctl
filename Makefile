# Release build and ad-hoc signing of vmctl and vmctld. No Homebrew, Go, Node,
# Python, or package downloads. Override SIGN_IDENTITY for a Developer ID build.
SHELL := /bin/sh
.SHELLFLAGS := -euc
SIGN_IDENTITY ?= -
BUILD_SYSTEM ?= native
BUILD := .build
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
SWIFTFLAGS := --build-system $(BUILD_SYSTEM) --disable-sandbox -debug-info-format none
export CLANG_MODULE_CACHE_PATH := $(CURDIR)/$(BUILD)/clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE := $(CURDIR)/$(BUILD)/module-cache

.PHONY: all build install uninstall test clean check-arch

all: build

check-arch:
	@[ "$$(uname -m)" = arm64 ] || { echo 'Apple Silicon is required.' >&2; exit 1; }

# Binaries are staged, signed, then moved into place atomically, so a running
# daemon keeps its original executable inode.
build: check-arch
	swift build -c release $(SWIFTFLAGS)
	mkdir -p bin
	staging=$$(mktemp -d "$(CURDIR)/bin/.staging.XXXXXX"); \
	trap 'rm -rf "$$staging"' EXIT HUP INT TERM; \
	cp $(BUILD)/release/vmctl $(BUILD)/release/vmctld "$$staging/"; \
	codesign --force --sign "$(SIGN_IDENTITY)" --entitlements vmctld.entitlements "$$staging/vmctld"; \
	codesign --force --sign "$(SIGN_IDENTITY)" "$$staging/vmctl"; \
	mv -f "$$staging/vmctld" bin/vmctld; \
	mv -f "$$staging/vmctl" bin/vmctl

# Copies the already-signed binaries, so `make && sudo make install` never builds
# as root. Both land in one directory: vmctl finds vmctld beside its own resolved
# path, so a symlink to BINDIR/vmctl elsewhere (as Homebrew makes) still works.
# install(1) copies the embedded code signature unchanged.
install:
	@[ -x bin/vmctl ] && [ -x bin/vmctld ] || { echo 'Run make first.' >&2; exit 1; }
	mkdir -p "$(DESTDIR)$(BINDIR)"
	install -m 755 bin/vmctld "$(DESTDIR)$(BINDIR)/vmctld"
	install -m 755 bin/vmctl "$(DESTDIR)$(BINDIR)/vmctl"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/vmctl" "$(DESTDIR)$(BINDIR)/vmctld"

# Unit tests plus the daemon integration tests against the signed binaries.
test: build
	VMCTL_TEST_BIN="$(CURDIR)/bin" swift test $(SWIFTFLAGS)

clean:
	rm -rf $(BUILD) bin
