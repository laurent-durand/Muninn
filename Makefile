# Muninn — polyglot TUI system monitor
# SPDX-License-Identifier: GPL-3.0-or-later

SHELL  := bash
.PHONY: all build clean run proto fmt lint help \
        core net api config rules stats logs syscall \
        tui fanout watchdog plugins dsl embed wasm \
        julia parallel

# ─── Directories ──────────────────────────────────────────────────────────────

SRC   := src
PROTO := proto
OUT   := out

$(OUT):
	mkdir -p $(OUT)

# ─── Proto codegen ────────────────────────────────────────────────────────────

proto:
	protoc --go_out=$(SRC)/api     --go_opt=paths=source_relative \
	       --go-grpc_out=$(SRC)/api --go-grpc_opt=paths=source_relative \
	       $(PROTO)/muninn.proto
	@echo "proto: generated Go bindings"

# ─── Per-language build targets ───────────────────────────────────────────────

core:
	@echo "[zig] building muninn-core..."
	cd $(SRC)/core && zig build -Doptimize=ReleaseFast
	cp $(SRC)/core/zig-out/bin/muninn-core $(OUT)/

net:
	@echo "[rust] building muninn-net..."
	cd $(SRC)/net && cargo build --release
	cp $(SRC)/net/target/release/muninn-net $(OUT)/

api:
	@echo "[go] building muninn-api..."
	cd $(SRC)/api && go build -ldflags="-s -w" -o ../../$(OUT)/muninn-api .

config:
	@echo "[nim] building muninn-config..."
	cd $(SRC)/config && nim compile -d:release -o:../../$(OUT)/muninn-config config.nim

rules:
	@echo "[ocaml] building muninn-rules..."
	cd $(SRC)/rules && opam exec -- dune build && cp _build/default/rule_engine.exe ../../$(OUT)/muninn-rules

stats:
	@echo "[d] building muninn-stats..."
	cd $(SRC)/stats && dub build --build=release && cp bin/muninn-stats ../../$(OUT)/

logs:
	@echo "[crystal] building muninn-logs..."
	cd $(SRC)/logs && crystal build --release aggregator.cr -o ../../$(OUT)/muninn-logs

syscall:
	@echo "[hare] building muninn-syscall..."
	cd $(SRC)/syscall && hare build -o ../../$(OUT)/muninn-syscall .

tui:
	@echo "[odin] building muninn-tui..."
	cd $(SRC)/tui && odin build . -out:../../$(OUT)/muninn-tui -opt:3

fanout:
	@echo "[gleam] building muninn-fanout..."
	cd $(SRC)/fanout && gleam build && cp priv/muninn_fanout ../../$(OUT)/muninn-fanout

watchdog:
	@echo "[ada] building muninn-watchdog..."
	cd $(SRC)/watchdog && gnatmake watchdog.adb -o ../../$(OUT)/muninn-watchdog

plugins:
	@echo "[lua] no build needed — scripts loaded at runtime"

proctree:
	@echo "[v] building muninn-proctree..."
	cd $(SRC)/proctree && v -prod -o ../../$(OUT)/muninn-proctree .

julia:
	@echo "[julia] precompiling muninn-analysis..."
	julia --project=$(SRC)/julia_layer -e 'using Pkg; Pkg.precompile()'

parallel:
	@echo "[chapel] building muninn-parallel..."
	cd $(SRC)/parallel && chpl aggregator.chpl -o ../../$(OUT)/muninn-parallel

wasm:
	@echo "[moonbit] building WASM plugin..."
	cd $(SRC)/wasm && moon build --target wasm
	@echo "[grain] building WASM plugin..."
	cd $(SRC)/grain_wasm && grain compile plugin.gr -o ../../$(OUT)/plugin_grain.wasm

# ─── Top-level build ──────────────────────────────────────────────────────────

build: $(OUT) core net api config rules stats logs syscall tui fanout watchdog proctree
	@echo "✓ muninn built — binaries in $(OUT)/"

all: proto build

# ─── Run (dev) ────────────────────────────────────────────────────────────────

run:
	docker compose up --build

run-dev:
	$(OUT)/muninn-core | tee >($(OUT)/muninn-api) >($(OUT)/muninn-rules) \
	    >($(OUT)/muninn-stats) | $(OUT)/muninn-tui

# ─── Formatting ───────────────────────────────────────────────────────────────

fmt:
	cd $(SRC)/net    && cargo fmt
	cd $(SRC)/api    && gofmt -w .
	cd $(SRC)/config && nimpretty config.nim

# ─── Linting ──────────────────────────────────────────────────────────────────

lint:
	cd $(SRC)/net  && cargo clippy -- -D warnings
	cd $(SRC)/api  && go vet ./...

# ─── Clean ────────────────────────────────────────────────────────────────────

clean:
	rm -rf $(OUT)
	cd $(SRC)/core   && zig build clean 2>/dev/null || true
	cd $(SRC)/net    && cargo clean
	cd $(SRC)/api    && go clean
	cd $(SRC)/rules  && opam exec -- dune clean 2>/dev/null || true
	cd $(SRC)/stats  && dub clean 2>/dev/null || true
	cd $(SRC)/fanout && gleam clean 2>/dev/null || true

# ─── Help ─────────────────────────────────────────────────────────────────────

help:
	@echo "Muninn build targets:"
	@echo "  make all       — codegen + build all components"
	@echo "  make build     — build all compiled components"
	@echo "  make run       — run via docker compose"
	@echo "  make run-dev   — run binaries directly (no Docker)"
	@echo "  make proto     — regenerate protobuf bindings"
	@echo "  make fmt       — format source code"
	@echo "  make lint      — run linters"
	@echo "  make clean     — remove build artefacts"
	@echo ""
	@echo "Per-component: make core | net | api | config | rules |"
	@echo "               stats | logs | syscall | tui | fanout |"
	@echo "               watchdog | proctree | parallel | wasm | julia"
