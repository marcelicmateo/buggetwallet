//go:build parity

package parity

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

var reLastFailedFormat = regexp.MustCompile(`^format \S+/dist/logs/format\.log$`)

// TestGO4QuietDefaultPath is tools/test_quiet.sh as a Go test, run on the default path of the entry scripts (BW_IMPL unset,
// which is the Go tool now): the same three groups -- a silent lint on a clean tree, a silent failing lint with one
// unformatted Dart file, silent usage errors of build.sh and emulator.sh -- with every assertion the shell test made.
// (The bash-vs-Go side by side of the same cases is quiet_* / emulator_quiet_* in cases_test.go and emu_live_test.go.)
func TestGO4QuietDefaultPath(t *testing.T) {
	if _, err := exec.LookPath("podman"); err != nil {
		t.Skip("podman missing")
	}
	repo := repoRoot(t)
	run := func(data string, extra []string, script string, args ...string) (string, int) {
		cmd := exec.Command(filepath.Join(repo, "tools", script), args...)
		cmd.Dir = repo
		env := sanitizedEnv()
		env = append(env, "BW_DATA_DIR="+data)
		cmd.Env = append(env, extra...) // no BW_IMPL: the default path
		out, err := cmd.CombinedOutput()
		return string(out), exitCode(t, err)
	}
	newestRun := func(data string) string {
		runs := listRuns(data)
		if len(runs) == 0 {
			t.Fatalf("no run dir under %s/runs", data)
		}
		return runs[len(runs)-1]
	}
	read := func(p string) string { b, _ := os.ReadFile(p); return string(b) }

	t.Run("clean_tree_lint_is_silent", func(t *testing.T) {
		data := t.TempDir()
		out, rc := run(data, nil, "build.sh", "-q", "lint")
		if out != "" {
			t.Errorf("no output expected, got %d bytes: %q", len(out), tail(out))
		}
		if rc != 0 {
			t.Errorf("exit %d, want 0", rc)
		}
		d := newestRun(data)
		ls := read(filepath.Join(d, "last.status"))
		if !strings.Contains("\n"+ls, "\nformat ok ") || strings.Contains(ls, " failed ") {
			t.Errorf("last.status must have the format step ok and none failed:\n%s", ls)
		}
		if strings.TrimSpace(read(filepath.Join(d, "last-failed.txt"))) != "" {
			t.Errorf("last-failed.txt must be empty:\n%s", read(filepath.Join(d, "last-failed.txt")))
		}
		if strings.TrimSpace(read(filepath.Join(d, "format.log"))) == "" {
			t.Error("the format step log must be written, even in quiet mode")
		}
	})

	t.Run("unformatted_file_lint_is_silent_and_fails", func(t *testing.T) {
		data := t.TempDir()
		bad := filepath.Join(repo, "app", "lib", "zz_parity_quiet_unformatted.dart")
		if err := os.WriteFile(bad, []byte("void   main( ) {  }\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Remove(bad) })
		out, rc := run(data, nil, "build.sh", "-q", "lint")
		_ = os.Remove(bad)
		if out != "" {
			t.Errorf("no output expected, got %d bytes: %q", len(out), tail(out))
		}
		if rc != 1 {
			t.Errorf("exit %d, want 1", rc)
		}
		d := newestRun(data)
		lf := strings.TrimSpace(read(filepath.Join(d, "last-failed.txt")))
		if !reLastFailedFormat.MatchString(lf) {
			t.Errorf("last-failed.txt must name the format step and its log (format <repo>/dist/logs/format.log), got %q", lf)
		}
		if !strings.Contains(read(filepath.Join(d, "last.status")), "format failed") {
			t.Errorf("last.status must mark format failed:\n%s", read(filepath.Join(d, "last.status")))
		}
		if !strings.Contains(read(filepath.Join(d, "format.log")), "zz_parity_quiet_unformatted") {
			t.Error("the format log must say which file is unformatted")
		}
	})

	t.Run("usage_errors_are_silent_exit_2", func(t *testing.T) {
		for _, c := range []struct {
			name, script string
			env          []string
			args         []string
		}{
			{"build.sh --quiet", "build.sh", nil, []string{"--quiet", "no-such-command"}},
			{"build.sh -q", "build.sh", nil, []string{"-q", "no-such-command"}},
			{"BW_QUIET=1 build.sh", "build.sh", []string{"BW_QUIET=1"}, []string{"no-such-command"}},
			{"BW_QUIET=1 emulator.sh", "emulator.sh", []string{"BW_QUIET=1"}, []string{"no-such-command"}},
			{"emulator.sh -q", "emulator.sh", nil, []string{"-q", "no-such-command"}},
		} {
			out, rc := run(t.TempDir(), c.env, c.script, c.args...)
			if out != "" || rc != 2 {
				t.Errorf("%s: exit %d with %d bytes of output (want 2 and none): %q", c.name, rc, len(out), tail(out))
			}
		}
		// the check can fail: without -q the same call prints a usage text
		if out, rc := run(t.TempDir(), nil, "build.sh", "no-such-command"); out == "" || rc != 2 {
			t.Errorf("control: build.sh no-such-command must print usage and exit 2, got exit %d, %d bytes", rc, len(out))
		}
	})
}
