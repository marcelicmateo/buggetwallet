# Budget Wallet build entry point. Every target builds tools/wallet-build (Go, no cgo) and calls it; the targets are the
# commands of wallet-build (tools/wallet-build/internal/cli/usage.txt).
#
#   make test | lint | format | analyze P="core app" | outdated | stage
#   make importer|core|sync|relay|app [T="test/x_test.dart …"]    one package, or only those tests
#   make apk | linux | web | all | perf | desktop-smoke | relay-bin [ARCH=x64] | relay-native-test [ARGS=debian]
#   make web-test [T="test/web/x_test.dart"]    make desktop-test [N="a b"]    make mutate ARGS="core lib/x.dart --max 5"
#   make shell [C='command']    make image | image-name | lsp | mcp | version
#   make times [ARGS="-n 5 --ci"] | trend | ci-status [ARGS="--wait <sha>"] | ci-log [ARGS=<name>]
#   make go-test    unit tests of the tool;   make bin    just build dist/bin/wallet-build
#   make emulator-screens | emulator-test [N="flows plan"] | emulator-start|install|shot|adb|stop|reset [ARGS=…]
#   make live-start [ARGS="--demo --headless"] | live-reload|restart|shot|status|stop|mcp [ARGS=…] | live-trace ARGS="start|stop [name]"
# Values are pasted into the shell line: C may hold ' (escaped for you) but a literal $ must be written $$ (make eats one); paths in
# O, P and DIR are double-quoted; T, N, P (analyze) and ARGS are word lists on purpose.
# Q=1 passes -q to the tool (nothing from the tool, not even the compiler log of a failed build), but make itself still prints
# "make: *** ... Error N" for a failed recipe and exits 2 whatever the tool returned. For the real exit codes (0 ok, 1 a step
# failed, 2 usage, 3 the tool did not build) call  dist/bin/wallet-build -q <command>  after `make bin`.
# A failed build of the tool writes the compiler output to dist/wallet-build-build.log.

BIN := dist/bin/wallet-build
Q_FLAG := $(if $(filter 1,$(Q)),-q,)
WB = @$(BIN) $(Q_FLAG)

.PHONY: all bin FORCE go-test version test lint format analyze outdated stage importer core sync relay app apk linux web web-test \
        desktop-test desktop-smoke perf relay-bin relay-native-test mutate shell image image-name lsp mcp times trend ci-status ci-log

.DEFAULT_GOAL := test

# Always runs `go build`: a no-op when nothing changed (~0.2 s), so the binary is never stale.
$(BIN): FORCE
	@mkdir -p dist/bin
	@cd tools/wallet-build && GOTOOLCHAIN=local CGO_ENABLED=0 go build -trimpath -o ../../$(BIN) . > ../../dist/wallet-build-build.log 2>&1 \
	  || { if [ "$(Q)" = 1 ]; then mkdir -p ../../dist/logs; echo "wallet-build $(CURDIR)/dist/wallet-build-build.log" > ../../dist/logs/last-failed.txt; \
	       else cat ../../dist/wallet-build-build.log >&2; echo "wallet-build did not build (see dist/wallet-build-build.log)" >&2; fi; exit 3; }
FORCE:

bin: $(BIN)
version: $(BIN)
	$(WB) version
go-test:
	cd tools/wallet-build && GOTOOLCHAIN=local go test ./...

test lint format outdated stage all apk linux web perf desktop-smoke image image-name lsp mcp: $(BIN)
	$(WB) $@
analyze: $(BIN)
	$(WB) analyze $(P)
importer core sync relay app: $(BIN)
	$(WB) $@ $(T)
web-test: $(BIN)
	$(WB) web-test $(T)
desktop-test: $(BIN)
	$(WB) desktop-test $(N)
relay-bin: $(BIN)
	$(WB) relay-bin $(ARCH)
relay-native-test: $(BIN)
	$(WB) relay-native-test $(ARGS)
mutate: $(BIN)
	$(WB) mutate $(ARGS)
shell: $(BIN)
	$(WB) shell $(if $(C),-c '$(subst ','\'',$(C))',)
times trend: $(BIN)
	$(WB) $@ $(ARGS)
ci-status: $(BIN)
	$(WB) ci status $(ARGS)
ci-log: $(BIN)
	$(WB) ci log $(ARGS)

# Emulator and live mode: make emulator-<command> / make live-<command>, the rest of the command line in N (test names) or ARGS.
.PHONY: emulator-screens emulator-test emulator-start emulator-install emulator-shot emulator-adb emulator-stop emulator-reset \
        live-start live-reload live-restart live-shot live-trace live-status live-stop live-mcp
emulator-screens emulator-test emulator-start emulator-install emulator-shot emulator-adb emulator-stop emulator-reset: $(BIN)
	$(WB) emulator $(patsubst emulator-%,%,$@) $(N) $(ARGS)
live-start live-reload live-restart live-shot live-trace live-status live-stop live-mcp: $(BIN)
	$(WB) live $(patsubst live-%,%,$@) $(ARGS)

# ---- GO4-A helpers (ported Python tools; GO4-B adds its own block below, so the two never touch the same lines) ----
#   make fixtures [DIR=packages/wallet_importer/test/fixtures] [SET=all|banks|bills|generic]   synthetic importer fixtures
#   make fixtures-embed                 app/integration_test/support/fixtures.dart from the committed bank files
#   make token-usage [ARGS="--since 2026-10-20 --json out.json"]
#   make log-summary ARGS="app.log …"
#   make lsp-query ARGS="refs path:line:col …"   (starts the language server in the container)
# (mutate is above: make mutate ARGS="core lib/x.dart --max 5")
.PHONY: fixtures fixtures-embed token-usage log-summary lsp-query
fixtures: $(BIN)
	$(WB) fixtures "$(or $(DIR),packages/wallet_importer/test/fixtures)" $(SET)
fixtures-embed: $(BIN)
	$(WB) fixtures embed
token-usage log-summary lsp-query: $(BIN)
	$(WB) $@ $(ARGS)

# ---- GO4-B helpers (relay, web, signing key, hook)
#   make relay-start|relay-stop|relay-status|relay-reset|relay-image    make relay-logs [ARGS=-f]      (BW_RELAY_PORT, BW_RELAY_ORIGINS, BW_YES)
#   make web-serve [PORT=8080]    make web-stop    make web-status    make web-shot P=/ O=dist/shot.png [S=412x915]
#   make relay-native-check       make signing-key [ARGS=--upload]    make hook-no-poll [ARGS=--self-test]   (reads the hook JSON on stdin)
# The container side `wallet-build web-shot <url> <out.png> <W>x<H> [wait]` is called by `web shot`; relay-native-test, times, trend, ci-status and ci-log are above.
.PHONY: relay-start relay-stop relay-status relay-reset relay-image relay-logs web-serve web-stop web-status web-shot relay-native-check signing-key hook-no-poll

relay-start relay-stop relay-status relay-reset relay-image: $(BIN)
	$(WB) relay $(patsubst relay-%,%,$@)
relay-logs: $(BIN)
	$(WB) relay logs $(ARGS)
web-serve: $(BIN)
	$(WB) web serve $(PORT)
web-stop web-status: $(BIN)
	$(WB) web $(patsubst web-%,%,$@)
web-shot: $(BIN)
	$(WB) web shot "$(P)" "$(O)" $(S)
relay-native-check signing-key: $(BIN)
	$(WB) $@ $(ARGS)
hook-no-poll: $(BIN)
	$(WB) hook no-poll $(ARGS)
