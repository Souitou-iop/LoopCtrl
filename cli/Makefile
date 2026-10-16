# Static aarch64 musl binary for the Minis sandbox (Alpine 3.21 arm64), plus a
# native macOS build with nearby discovery.
#
# `build` uses Docker when it's installed: built and tested inside the same
# container image the target runs, so "it compiles" and "it runs there" are the
# same check. Without Docker it falls back to `zig cc`, which cross-compiles the
# same static musl binary but can't run it here — `make test` then runs the
# self-test natively instead (the crypto is portable C).

IMAGE   := loopctrl-cli-build
SRC     := main.c sha256.c x25519.c util.c
CFLAGS  := -O2 -std=c11 -Wall -Wextra -static -fno-strict-aliasing
OUT     := loopctrl
MAC_OUT := loopctrl-macos
HAVE_DOCKER := $(shell command -v docker >/dev/null 2>&1 && echo yes)

.PHONY: all build docker zig macos test clean shell

all: build

## The bundled Linux client: Docker when present, otherwise zig.
ifeq ($(HAVE_DOCKER),yes)
build: docker
else
build: zig
endif

## Cross-compile in Alpine arm64, emitting ./loopctrl on the host.
docker:
	docker build --platform linux/arm64 -t $(IMAGE) .
	docker run --rm --platform linux/arm64 -v "$(PWD):/out" $(IMAGE) \
		sh -c 'cp /build/$(OUT) /out/$(OUT)'
	@file $(OUT) 2>/dev/null || true
	@ls -lh $(OUT)

## Cross-compile with zig (brew install zig): same target, no container.
zig:
	@command -v zig >/dev/null || { echo "❌ zig not found — brew install zig (or install Docker)"; exit 1; }
	zig cc -target aarch64-linux-musl $(CFLAGS) -s -o $(OUT) $(SRC)
	@file $(OUT) 2>/dev/null || true
	@ls -lh $(OUT)

## Native macOS client (arm64 + x86_64) with `scan` / `--nearby`.
macos:
	cc -O2 -std=c11 -Wall -Wextra -fno-strict-aliasing -arch arm64 -arch x86_64 \
		-o $(MAC_OUT) $(SRC) nearby.c
	@ls -lh $(MAC_OUT)

## Run the self-test: in the target environment with Docker, natively without.
ifeq ($(HAVE_DOCKER),yes)
test: build
	docker run --rm --platform linux/arm64 -v "$(PWD):/w" -w /w $(IMAGE) \
		sh -c './loopctrl 2>&1 | head -3; echo "--- selftest ---"; ./selftest'
else
test: build
	cc -O2 -std=c11 -Wall -Wextra -fno-strict-aliasing -o selftest selftest.c sha256.c x25519.c util.c
	./selftest
endif

## Interactive shell in the build image, for poking at things.
shell:
	docker run --rm -it --platform linux/arm64 -v "$(PWD):/w" -w /w $(IMAGE) sh

clean:
	rm -f $(OUT) $(MAC_OUT) selftest
	docker rmi $(IMAGE) 2>/dev/null || true
