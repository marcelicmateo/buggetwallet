package cli

import (
	"path/filepath"
	"strings"
	"testing"
)

// Every mistake in the arguments of `mutate` is reported on the host, before the image, a run or any podman call: with no
// image yet (a fresh worktree) the old behaviour was a 15-minute `podman build` before the usage message.
func TestMutateUsageErrorsNeverTouchPodman(t *testing.T) {
	root := mkRepo(t)
	write(t, filepath.Join(root, "packages/wallet_core/lib/ok.dart"), "int f() => 1;\n")
	cases := []struct {
		name string
		args []string
		code int
		err  string
	}{
		{"no arguments", []string{"mutate"}, 2, ""},
		{"package only", []string{"mutate", "core"}, 2, ""},
		{"unknown package", []string{"mutate", "bogus", "lib/ok.dart"}, 2, "invalid choice: 'bogus'"},
		{"bad int", []string{"mutate", "core", "lib/ok.dart", "--max", "x"}, 2, "invalid int value: 'x'"},
		{"bad seed", []string{"mutate", "core", "lib/ok.dart", "--seed", "1.5"}, 2, "invalid int value"},
		{"bad float", []string{"mutate", "core", "lib/ok.dart", "--timeout", "soon"}, 2, "invalid float value"},
		{"unknown flag", []string{"mutate", "core", "lib/ok.dart", "--frobnicate"}, 2, "unrecognized arguments"},
		{"missing value", []string{"mutate", "core", "lib/ok.dart", "--seed"}, 2, "expected one argument"},
		{"missing lib file", []string{"mutate", "core", "lib/nope.dart"}, 1, "not a .dart file under packages/wallet_core/lib: lib/nope.dart"},
		{"outside lib", []string{"mutate", "core", "pubspec.yaml"}, 1, "not a .dart file"},
		{"other package's file", []string{"mutate", "core", "packages/wallet_importer/lib/x.dart"}, 1, "not a .dart file"},
	}
	for _, c := range cases {
		for _, q := range []bool{false, true} {
			args := c.args
			if q {
				args = append([]string{"-q"}, args...)
			}
			r := runCLI(t, opts{root: root}, args...)
			if r.code != c.code {
				t.Errorf("%s %v: exit %d, want %d", c.name, args, r.code, c.code)
			}
			for _, call := range r.calls {
				if strings.Contains(call, "podman") || strings.Contains(call, "git ") {
					t.Errorf("%s %v: ran %q before reporting the mistake", c.name, args, call)
				}
			}
			if len(r.fake.Execs) != 0 {
				t.Errorf("%s: exec %v", c.name, r.execs)
			}
			if m, _ := filepath.Glob(filepath.Join(r.data, "runs", "*")); len(m) != 0 {
				t.Errorf("%s: a run dir was created: %v", c.name, m)
			}
			if q && (r.out != "" || r.err != "") {
				t.Errorf("%s: quiet printed %q %q", c.name, r.out, r.err)
			}
			if !q && c.err != "" && !strings.Contains(r.err, c.err) {
				t.Errorf("%s: stderr %q lacks %q", c.name, r.err, c.err)
			}
		}
	}
	// a good call still goes on to the container
	r := runCLI(t, opts{root: root}, "mutate", "core", "lib/ok.dart", "--list")
	ran := false
	for _, call := range r.calls {
		ran = ran || strings.Contains(call, "podman")
	}
	if !ran {
		t.Errorf("a valid call must reach podman: %v", r.calls)
	}
	// -h is help on the host too
	if r := runCLI(t, opts{root: root}, "mutate", "core", "x", "-h"); r.code != 0 || !strings.Contains(r.out, "usage: mutate") || len(r.calls) != 0 {
		t.Errorf("-h: %d %q %v", r.code, r.out, r.calls)
	}
}
