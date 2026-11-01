package cli

import (
	"path/filepath"
	"strings"
	"testing"

	"wallet-build/internal/sys"
)

// ubuntu-latest's Go (before GO3) is older than go.mod's: skipped like a missing Go, not a failure
func TestGoCheckNativeOldGoIsSkipped(t *testing.T) {
	root := mkRepo(t)
	write(t, filepath.Join(root, "tools/wallet-build/go.mod"), "module wallet-build\n\ngo 1.26.0\n\ntoolchain go1.26.10\n")
	for _, c := range []struct {
		have string
		skip bool
	}{{"go version go1.22.3 linux/amd64", true}, {"go version go1.25.9 linux/amd64", true}, {"go version go1.26.0 linux/amd64", false}, {"go version go1.26.10 linux/amd64", false}} {
		h := func(cmd sys.Cmd) int {
			if len(cmd.Argv) == 2 && cmd.Argv[0] == "go" && cmd.Argv[1] == "version" {
				cmd.Stdout.Write([]byte(c.have + "\n"))
			}
			return goHandle(true)(cmd)
		}
		r := runCLI(t, opts{root: root, env: []string{"BW_NATIVE=1"}, handle: h}, "lint")
		skipped := strings.Contains(r.out, "go not found (CI before GO3), skipped")
		if r.code != 0 || skipped != c.skip {
			t.Errorf("%s: code %d skipped %v\n%s", c.have, r.code, skipped, r.out)
		}
	}
}

// the nested parity module is vetted with its build tag
func TestGoCheckVetsParityModule(t *testing.T) {
	root := mkRepo(t)
	write(t, filepath.Join(root, "tools/wallet-build/parity/go.mod"), "module parity\n")
	r := runCLI(t, opts{root: root, env: []string{"BW_NATIVE=1"}, handle: goHandle(true)}, "lint")
	found := false
	for _, c := range r.calls {
		found = found || c == "tools/wallet-build/parity$ go vet -tags parity ./..."
	}
	if !found || r.code != 0 {
		t.Errorf("code %d calls %v", r.code, r.calls)
	}
}
