package ci

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

// CI builds wallet-build with the toolchain the laptop uses: the setup action's go-version must equal go.mod's toolchain line
// (setup-go@v5's go-version-file would read only the `go` line).
func TestSetupGoVersionIsTheToolchain(t *testing.T) {
	root := filepath.Join("..", "..", "..", "..")
	mod, err := os.ReadFile(filepath.Join(root, "tools", "wallet-build", "go.mod"))
	if err != nil {
		t.Skip("repository layout not found")
	}
	act, err := os.ReadFile(filepath.Join(root, ".github", "actions", "setup", "action.yml"))
	if err != nil {
		t.Fatal(err)
	}
	tc := regexp.MustCompile(`(?m)^toolchain go(\S+)\s*$`).FindSubmatch(mod)
	if tc == nil {
		t.Fatal("go.mod has no toolchain line")
	}
	gv := regexp.MustCompile(`(?m)^\s+go-version: (\S+)\s*$`).FindSubmatch(act)
	if gv == nil {
		t.Fatal("the setup action has no go-version")
	}
	if string(gv[1]) != string(tc[1]) {
		t.Errorf("setup action go-version %s, go.mod toolchain %s", gv[1], tc[1])
	}
}
