# Budget Wallet build entry point. Every target builds tools/wallet-build (Go, no cgo) and calls it; the targets are the
# commands of tools/build.sh (tools/wallet-build/internal/cli/usage.txt).
#
#   make test | lint | format | analyze P="core app" | outdated | stage
#   make importer|core|sync|relay|app [T="test/x_test.dart …"]    one package, or only those tests
#   make apk | linux | web | all | perf | desktop-smoke | relay-bin [ARCH=x64] | relay-native-test [ARGS=debian]
#   make web-test [T="test/web/x_test.dart"]    make desktop-test [N="a b"]    make mutate ARGS="core lib/x.dart --max 5"
#   make shell [C='command']    make image | image-name | lsp | mcp | version
#   make times [ARGS="-n 5 --ci"] | trend | ci-status [ARGS="--wait <sha>"] | ci-log [ARGS=<name>]
#   make go-test    unit tests of the tool;   make bin    just build dist/bin/wallet-build
# Q=1 passes -q to the tool (nothing from the tool, not even the compiler log of a failed build), but make itself still prints
# "make: *** ... Error N" for a failed recipe and exits 2 whatever the tool returned. Before M6 the quiet entry with the real
# exit codes (0 ok, 1 a step failed, 2 usage, 3 the tool did not build) is  BW_IMPL=go tools/build.sh -q <command>  or
# dist/bin/wallet-build -q <command>.
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
	  || { [ "$(Q)" = 1 ] || { cat ../../dist/wallet-build-build.log >&2; echo "wallet-build did not build (see dist/wallet-build-build.log)" >&2; }; exit 3; }
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
	$(WB) shell $(if $(C),-c '$(C)',)
times trend: $(BIN)
	$(WB) $@ $(ARGS)
ci-status: $(BIN)
	$(WB) ci status $(ARGS)
ci-log: $(BIN)
	$(WB) ci log $(ARGS)
