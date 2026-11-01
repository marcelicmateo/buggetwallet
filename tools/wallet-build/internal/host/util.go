package host

import (
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/term"

	"wallet-build/internal/report"
	"wallet-build/internal/run"
)

func realTTY() bool {
	return term.IsTerminal(int(os.Stdin.Fd())) && term.IsTerminal(int(os.Stdout.Fd()))
}

func httpDownload(url, dest string) error {
	client := &http.Client{Timeout: 10 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func stageSummary(dirs []string) string { return report.StageSummary(dirs) }

func trendText(c *run.Ctx) string {
	var sb strings.Builder
	cfg := report.FromCtx(c, "")
	cfg.Out = &sb
	cfg.Trend(report.TrendOpts{N: 10, Top: 10})
	return sb.String()
}

var errWasm = fmt.Errorf("sqlite3mc.wasm unavailable")

// fetchSQLiteWasm provides sqlite3mc.wasm (SQLite3 Multiple Ciphers: the web build's SQLite, encryption capable) for the
// sqlite3 version in app/pubspec.lock: a release asset of the sqlite3.dart project, pinned by dev/sqlite3-wasm.sha256
// ("<sha256>  sqlite3mc-<version>"), cached outside the repo, copied to the git-ignored app/web/sqlite3.wasm (same URL the
// app loads). A new version is pinned by hand after checking its hash against the release page (no trust on first use).
// Messages go to stderr; the error only says that it failed.
func (h *Host) fetchSQLiteWasm() error {
	c := h.C
	lock, _ := os.ReadFile(filepath.Join(c.Root, "app", "pubspec.lock"))
	ver, in := "", false
	for _, line := range strings.Split(string(lock), "\n") {
		if line == "  sqlite3:" {
			in = true
		}
		if in && strings.Contains(line, "version:") {
			f := strings.Fields(line)
			if len(f) >= 2 {
				ver = strings.Trim(f[1], `"`)
			}
			break
		}
	}
	if ver == "" {
		c.Eprintf("no sqlite3 version in app/pubspec.lock\n")
		return errWasm
	}
	cache := filepath.Join(c.Data, "cache", "sqlite3mc-"+ver+".wasm")
	_ = os.MkdirAll(filepath.Dir(cache), 0o755)
	if _, err := os.Stat(cache); err != nil {
		c.Eprintf("fetching sqlite3mc.wasm %s\n", ver)
		url := "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-" + ver + "/sqlite3mc.wasm"
		if err := h.Download(url, cache+".part"); err != nil {
			_ = os.Remove(cache + ".part")
			c.Eprintf("download of sqlite3mc.wasm %s failed\n", ver)
			return errWasm
		}
		_ = os.Rename(cache+".part", cache)
	}
	b, err := os.ReadFile(cache)
	if err != nil {
		return errWasm
	}
	got := fmt.Sprintf("%x", sha256.Sum256(b))
	want := ""
	pinned, _ := os.ReadFile(filepath.Join(c.Root, "dev", "sqlite3-wasm.sha256"))
	for _, line := range strings.Split(string(pinned), "\n") {
		f := strings.Fields(line)
		if len(f) >= 2 && f[1] == "sqlite3mc-"+ver {
			want = f[0]
		}
	}
	switch {
	case want == "":
		c.Eprintf("sqlite3mc.wasm %s is not pinned. Check its sha256 on the sqlite3.dart release page, then add this line\n", ver)
		c.Eprintf("to dev/sqlite3-wasm.sha256 and commit it:  %s  sqlite3mc-%s\n", got, ver)
		return errWasm
	case want != got:
		_ = os.Remove(cache)
		c.Eprintf("sqlite3mc.wasm %s sha256 mismatch: pinned %s, got %s (cache deleted)\n", ver, want, got)
		return errWasm
	}
	for _, dst := range []string{"app/web/sqlite3.wasm", "app/test/sqlite3.wasm"} { // flutter test --platform chrome serves app/test/ at the root
		if err := os.WriteFile(filepath.Join(c.Root, dst), b, 0o644); err != nil {
			c.Eprintf("%v\n", err)
			return errWasm
		}
	}
	return nil
}
