package steps

import (
	"bufio"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"wallet-build/internal/report"
	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

// ShardsOf are the files that run as several units, each a slice of the file's tests (flutter test --total-shards).
var ShardsOf = map[string]int{"layout": 5}

// procDir is /proc and numCPU the core count (variables for the tests).
var (
	procDir = "/proc"
	numCPU  = runtime.NumCPU
)

// Headless runs argv on a virtual X display (Mesa software GL) inside a private D-Bus session, with the app's data
// (XDG_DATA_HOME: wallet, key file, logs), documents and runtime folders inside dir. The display is the first free one, or
// :$BW_XDISPLAY (parallel workers: xvfb-run's search for a free one races when several start at once). The bus has no
// activatable services (tools/dbus-headless.conf), and the whole command is killed after $BW_HEADLESS_TIMEOUT seconds
// (default 20 min) so a hang fails the step instead of blocking.
func Headless(sc *run.StepCtx, dir, workdir string, kv []string, argv ...string) int {
	display := []string{"-a"}
	if d := sc.Env.Get("BW_XDISPLAY"); d != "" {
		display = []string{"-n", d}
	}
	_ = os.MkdirAll(filepath.Join(dir, "data"), 0o755)
	_ = os.MkdirAll(filepath.Join(dir, "docs"), 0o755)
	_ = os.Mkdir(filepath.Join(dir, "run"), 0o700)
	timeout := sc.Env.Get("BW_HEADLESS_TIMEOUT")
	if timeout == "" {
		timeout = "1200"
	}
	chain := []string{"timeout", "-k", "10", timeout, "dbus-run-session", "--config-file=" + filepath.Join(sc.C.Root, "tools", "dbus-headless.conf"), "--",
		"xvfb-run"}
	chain = append(chain, display...)
	chain = append(chain, "-s", "-screen 0 1920x1080x24")
	chain = append(chain, argv...)
	env := append([]string{"XDG_DATA_HOME", filepath.Join(dir, "data"), "XDG_DOCUMENTS_DIR", filepath.Join(dir, "docs"),
		"XDG_RUNTIME_DIR", filepath.Join(dir, "run"), "NO_AT_BRIDGE", "1"}, kv...)
	return sc.CmdEnv(workdir, env, chain...)
}

// AppLogs are the app's log files (path_provider: $XDG_DATA_HOME/<application id>/logs/), oldest first.
func AppLogs(dir string) []byte {
	var files []string
	_ = filepath.WalkDir(filepath.Join(dir, "data"), func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && filepath.Base(filepath.Dir(p)) == "logs" && strings.HasPrefix(d.Name(), "bw-") && strings.HasSuffix(d.Name(), ".log") {
			files = append(files, p)
		}
		return nil
	})
	sort.Strings(files)
	var out []byte
	for _, f := range files {
		b, _ := os.ReadFile(f)
		out = append(out, b...)
	}
	return out
}

func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		t := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(t, 0o755)
		}
		return copyFile(p, t)
	})
}

// DesktopTest runs app/integration_test/<name>_test.dart on the Linux desktop (in $BW_APP_DIR, a copy of app/ when workers
// run in parallel), with a JSON report and per-test timings. Screenshots come from integration_test/flutter_test_config.dart
// (BW_SCREENS_DIR). With a shard (0-based, parallel runs only) it runs that slice of the file's tests; the caller cleans
// the screenshot folder first and merges the reports (desktopMerge).
func DesktopTest(sc *run.StepCtx, name string, shard, shards int) int {
	logs := sc.S.Logs
	sfx := ""
	if shard >= 0 {
		sfx = ".s" + strconv.Itoa(shard)
	}
	shots := filepath.Join(sc.C.Root, "dist", "screens", "linux", name)
	jsonPath := filepath.Join(logs, "tests-desktop-"+name+sfx+".json")
	var opts []string
	if shards > 1 {
		opts = []string{"--total-shards", strconv.Itoa(shards), "--shard-index", strconv.Itoa(shard)}
	}
	dir, err := os.MkdirTemp("", "tmp.")
	if err != nil {
		sc.Printf("mktemp: %v\n", err)
		return 1
	}
	defer os.RemoveAll(dir)
	if shard < 0 {
		_ = os.RemoveAll(shots)
		_ = os.RemoveAll(filepath.Join(logs, "screens-linux-"+name))
		_ = os.Remove(filepath.Join(logs, "tests-desktop-"+name+"-summary.txt"))
	}
	_ = os.Remove(jsonPath)
	appDir := sc.Env.Get("BW_APP_DIR")
	if appDir == "" {
		appDir = "app"
	}
	target := "integration_test/" + name + "_test.dart"
	if name == combinedName {
		target = "integration_test/" + combinedName + ".dart"
	}
	argv := append([]string{"flutter", "test", target, "-d", "linux", "--no-pub", "-r", "expanded",
		"--file-reporter", "json:" + jsonPath}, opts...)
	rc := Headless(sc, dir, appDir, []string{"BW_SCREENS_DIR", shots}, argv...)
	_ = os.WriteFile(filepath.Join(logs, "app-linux-"+name+sfx+".log"), AppLogs(dir), 0o644)
	if shard < 0 {
		if st, err := os.Stat(shots); err == nil && st.IsDir() {
			_ = copyTree(shots, filepath.Join(logs, "screens-linux-"+name))
		}
		if _, err := os.Stat(jsonPath); err == nil {
			rcfg := report.FromCtx(sc.C, logs)
			rcfg.Env, rcfg.Out = sc.Env, sc.Out
			rcfg.Tests("tests", "desktop-"+name, []string{jsonPath})
		}
	}
	return rc
}

// PerfRun runs app/integration_test/perf_test.dart in profile mode (`flutter drive`, the host side is
// app/test_driver/perf_driver.dart), then the numbers into perf-summary.txt and history/perf.jsonl. The driver exits
// non-zero on a budget overrun.
func PerfRun(sc *run.StepCtx) int {
	logs := sc.S.Logs
	dir, err := os.MkdirTemp("", "tmp.")
	if err != nil {
		return 1
	}
	defer os.RemoveAll(dir)
	for _, pat := range []string{"perf-records.jsonl", "perf-summary.txt", "*.timeline.json", "*.timeline_summary.json"} {
		m, _ := filepath.Glob(filepath.Join(logs, pat))
		for _, f := range m {
			_ = os.Remove(f)
		}
	}
	// A killed run (SIGKILL of the container) leaves build state that makes the next `flutter drive` stall after
	// "Built ..." without ever launching the app (seen 2026-10-20, three times). Start from a clean profile build:
	// it costs ~1 min of rebuild on a step that is not in `test`/CI.
	root := sc.C.Root
	_ = os.RemoveAll(filepath.Join(root, "app/build/linux/x64/profile"))
	_ = os.RemoveAll(filepath.Join(root, "app/.dart_tool/flutter_build"))
	old, _ := filepath.Glob(filepath.Join(root, "app/build/flutter_driver_commands_*.log"))
	for _, f := range old {
		_ = os.Remove(f)
	}
	rc := Headless(sc, dir, "app", []string{"BW_PERF_OUT", logs}, "flutter", "drive", "--profile", "-d", "linux", "--no-pub",
		"--driver=test_driver/perf_driver.dart", "--target=integration_test/perf_test.dart")
	_ = os.WriteFile(filepath.Join(logs, "app-linux-perf.log"), AppLogs(dir), 0o644)
	rcfg := report.FromCtx(sc.C, logs)
	rcfg.Env, rcfg.Out = sc.Env, io.Discard // the table is perf-summary.txt, shown by the summary
	rcfg.Perf(filepath.Join(logs, "perf-records.jsonl"))
	return rc
}

// SmokeRun starts the binary, it must still run after secs seconds, then SIGTERM must end it within 10 s (exit 0 or 143 =
// terminated; a crash shows as 134 abort, 139 segfault, ...). Output goes to out; the app's console to console.
func SmokeRun(out io.Writer, binary string, secs int, console string, env sys.Env) int {
	f, err := os.Create(console)
	if err != nil {
		fmt.Fprintf(out, "FAIL: %v\n", err)
		return 1
	}
	defer f.Close()
	c := newCmd(binary, f, env)
	if err := c.Start(); err != nil {
		fmt.Fprintf(out, "FAIL: %v\n", err)
		return 1
	}
	exited := make(chan error, 1)
	go func() { exited <- c.Wait() }()
	code := func(error) int {
		if c.ProcessState == nil {
			return 1
		}
		if ws, ok := c.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal())
		}
		return c.ProcessState.ExitCode()
	}
	for i := 0; i < secs; i++ {
		select {
		case err := <-exited:
			fmt.Fprintf(out, "FAIL: the app exited after %ds with code %d\n", i, code(err))
			return 1
		case <-time.After(time.Second):
		}
	}
	fmt.Fprintf(out, "app still running after %d s; sending SIGTERM\n", secs)
	_ = c.Process.Signal(syscall.SIGTERM)
	var rc int
	select {
	case err := <-exited:
		rc = code(err)
	case <-time.After(10 * time.Second):
		_ = c.Process.Kill()
		fmt.Fprintf(out, "FAIL: the app ignored SIGTERM for 10 s\n")
		return 1
	}
	fmt.Fprintf(out, "app exited with code %d\n", rc)
	if rc != 0 && rc != 143 {
		fmt.Fprintf(out, "FAIL: unexpected exit code\n")
		return 1
	}
	return 0
}

// DesktopSmoke unpacks the release bundle from dist/BudgetWallet-linux-x64.tar.gz into a temp folder and runs it with an
// empty HOME, like a first start on the owner's computer.
func DesktopSmoke(sc *run.StepCtx, self string) int {
	logPath := filepath.Join(sc.S.Logs, "app-linux-smoke.log")
	dir, err := os.MkdirTemp("", "tmp.")
	if err != nil {
		return 1
	}
	defer os.RemoveAll(dir)
	rc := 0
	if sc.Cmd("", "tar", "-xzf", "dist/BudgetWallet-linux-x64.tar.gz", "-C", dir) != 0 {
		return 1
	}
	_ = os.MkdirAll(filepath.Join(dir, "home"), 0o755)
	secs := sc.Env.Get("BW_SMOKE_SECONDS")
	if secs == "" {
		secs = "10"
	}
	home := filepath.Join(dir, "home")
	kv := []string{"HOME", home, "XDG_CONFIG_HOME", filepath.Join(home, ".config"), "XDG_CACHE_HOME", filepath.Join(home, ".cache"),
		"SMOKE_OUT", filepath.Join(sc.S.Logs, "app-linux-smoke-console.log")}
	if Headless(sc, dir, "", kv, self, "smoke-run", filepath.Join(dir, "bundle", "budget_wallet"), secs) != 0 {
		rc = 1
	}
	logBytes := AppLogs(dir)
	_ = os.WriteFile(logPath, logBytes, 0o644)
	text := string(logBytes)
	lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	if text == "" {
		lines = nil
	}
	sc.Printf("app log: %d lines (dist/logs/app-linux-smoke.log)\n", len(lines))
	if !strings.Contains(text, `app.start {"phase":"ready"`) {
		sc.Printf("FAIL: no app.start ready line in the app log\n")
		rc = 1
	}
	severe := regexp.MustCompile(`^[^ ]* SEVERE `)
	warn := regexp.MustCompile(`^[^ ]* WARNING `)
	var sev []int
	warnings := 0
	for i, l := range lines {
		if severe.MatchString(l) {
			sev = append(sev, i)
		}
		if warn.MatchString(l) {
			warnings++
		}
	}
	if len(sev) > 0 {
		sc.Printf("FAIL: %d SEVERE lines:\n", len(sev))
		var outl []string
		printed := -1
		for _, i := range sev {
			end := min(i+3, len(lines)-1)
			if printed >= 0 && i > printed+1 {
				outl = append(outl, "--")
			}
			for j := max(i, printed+1); j <= end; j++ {
				outl = append(outl, lines[j])
			}
			printed = max(printed, end)
		}
		if len(outl) > 40 {
			outl = outl[:40]
		}
		for _, l := range outl {
			sc.Printf("%s\n", l)
		}
		rc = 1
	}
	sc.Printf("WARNING lines: %d\n", warnings)
	return rc
}

// ---- parallel desktop tests ----

// DesktopJobs is the number of workers: BW_JOBS, else a quarter of the idle cores and one per 3 GB of free RAM, at most 6,
// at least 1.
func DesktopJobs(env sys.Env) (int, error) {
	if v := env.Get("BW_JOBS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || strings.HasPrefix(v, "0") || strings.HasPrefix(v, "+") {
			return 0, fmt.Errorf("BW_JOBS must be a positive number, not '%s'", v)
		}
		return n, nil
	}
	load := 0
	if b, err := os.ReadFile(filepath.Join(procDir, "loadavg")); err == nil {
		f := strings.Fields(string(b))
		if len(f) > 0 {
			l, _, _ := strings.Cut(strings.ReplaceAll(f[0], ",", "."), ".")
			load, _ = strconv.Atoi(l)
		}
	}
	mem := 1 << 30
	if f, err := os.Open(filepath.Join(procDir, "meminfo")); err == nil {
		defer f.Close()
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			if strings.HasPrefix(sc.Text(), "MemAvailable:") {
				fs := strings.Fields(sc.Text())
				if len(fs) > 1 {
					kb, _ := strconv.Atoi(fs[1])
					mem = kb / 3145728 // kB per 3 GB
				}
			}
		}
	}
	jobs := (numCPU() - load) / 4
	if jobs > mem {
		jobs = mem
	}
	if jobs > 6 {
		jobs = 6
	}
	if jobs < 1 {
		jobs = 1
	}
	return jobs, nil
}

// workerApp refreshes worker w's copy of app/ in dist/desktop-test/w<w>/app (build/ and .dart_tool/flutter_build stay there
// between runs, so only changed files rebuild). packages/ is a symlink next to it for the path dependencies.
func workerApp(sc *run.Ctx, w int) error {
	base := filepath.Join(sc.Root, "dist", "desktop-test", "w"+strconv.Itoa(w))
	if err := os.MkdirAll(filepath.Join(base, "app", ".dart_tool"), 0o755); err != nil {
		return err
	}
	for _, l := range []string{"packages", "relay"} {
		_ = os.Remove(filepath.Join(base, l))
		if err := os.Symlink("../../../"+l, filepath.Join(base, l)); err != nil {
			return err
		}
	}
	for _, d := range []string{"lib", "test", "integration_test", "test_driver", "tool"} {
		_ = os.RemoveAll(filepath.Join(base, "app", d))
	}
	pr, pw := io.Pipe()
	done := make(chan int, 1)
	go func() {
		rc := sc.R.Run(sc.Ctx, sys.Cmd{Argv: []string{"tar", "-C", "app", "--exclude=./build", "--exclude=./.dart_tool", "--exclude=./linux/flutter/ephemeral", "-cf", "-", "."},
			Dir: sc.Root, Env: sc.Env, Stdout: pw})
		pw.Close()
		done <- rc
	}()
	rc2 := sc.R.Run(sc.Ctx, sys.Cmd{Argv: []string{"tar", "-C", filepath.Join(base, "app"), "-xf", "-"}, Dir: sc.Root, Env: sc.Env, Stdin: pr})
	pr.Close()
	if rc1 := <-done; rc1 != 0 || rc2 != 0 {
		return fmt.Errorf("tar failed")
	}
	for _, f := range []string{"package_config.json", "package_graph.json", "version"} {
		src := filepath.Join(sc.Root, "app", ".dart_tool", f)
		if st, err := os.Stat(src); err == nil {
			dst := filepath.Join(base, "app", ".dart_tool", f)
			if copyFile(src, dst) == nil {
				_ = os.Chmod(dst, st.Mode())
				_ = os.Chtimes(dst, st.ModTime(), st.ModTime())
			}
		}
	}
	return nil
}

type unit struct {
	name          string
	shard, shards int
}

func parseUnit(s string) unit {
	p := strings.Split(s, ":")
	u := unit{name: p[0], shards: 1}
	if len(p) == 3 {
		u.shard, _ = strconv.Atoi(p[1])
		u.shards, _ = strconv.Atoi(p[2])
	}
	return u
}

func statusOf(path string) (secs string, rc int, started string, ok bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	f := strings.Fields(string(b))
	if len(f) < 3 {
		return
	}
	rc, _ = strconv.Atoi(f[1])
	return f[0], rc, f[2], true
}

// desktopMerge writes the shards' logs, reports and status as one desktop-<name> step (as RunStep writes it).
func desktopMerge(s *run.Session, name string, shards int) {
	c, logs := s.C, s.Logs
	logPath := filepath.Join(logs, "desktop-"+name+".log")
	var body strings.Builder
	tenths, bad, start := 0, 0, ""
	var jsons []string
	for i := 0; i < shards; i++ {
		sn := fmt.Sprintf("desktop-%s.s%d", name, i)
		secs, rc, started, ok := statusOf(filepath.Join(logs, sn+".status"))
		if !ok {
			fmt.Fprintf(&body, "--- shard %d/%d: did not run\n", i+1, shards)
			bad = 1
			continue
		}
		fmt.Fprintf(&body, "--- shard %d/%d: %s s, exit %d\n", i+1, shards, secs, rc)
		body.WriteString(s.LogBody(sn))
		whole, frac, _ := strings.Cut(secs, ".")
		w, _ := strconv.Atoi(whole)
		fr, _ := strconv.Atoi(frac)
		tenths += w*10 + fr
		if rc != 0 {
			bad = 1
		}
		if start == "" || started < start {
			start = started
		}
		j := filepath.Join(logs, fmt.Sprintf("tests-desktop-%s.s%d.json", name, i))
		if _, err := os.Stat(j); err == nil {
			jsons = append(jsons, j)
		}
	}
	rcfg := report.FromCtx(c, logs)
	var rep strings.Builder
	rcfg.Out = &rep
	if len(jsons) == 0 {
		jsons = []string{"/nonexistent"}
	}
	rcfg.Tests("tests", "desktop-"+name, jsons)
	body.WriteString(rep.String())
	if shots := filepath.Join(c.Root, "dist", "screens", "linux", name); dirExists(shots) {
		_ = copyTree(shots, filepath.Join(logs, "screens-linux-"+name))
	}
	var app []byte
	parts, _ := filepath.Glob(filepath.Join(logs, "app-linux-"+name+".s*.log"))
	sort.Strings(parts)
	for _, p := range parts {
		b, _ := os.ReadFile(p)
		app = append(app, b...)
	}
	_ = os.WriteFile(filepath.Join(logs, "app-linux-"+name+".log"), app, 0o644)
	secs := fmt.Sprintf("%d.%d", tenths/10, tenths%10)
	if start == "" {
		start = c.NowISO()
	}
	full := fmt.Sprintf("# desktop-%s: started %s\n%s# desktop-%s: finished %s, %s s, exit %d\n", name, start, body.String(), name, c.NowISO(), secs, bad)
	_ = os.WriteFile(logPath, []byte(full), 0o644)
	_ = os.WriteFile(filepath.Join(logs, "desktop-"+name+".status"), []byte(fmt.Sprintf("%s %d %s\n", secs, bad, start)), 0o644)
	for _, pat := range []string{"desktop-" + name + ".s*.log", "desktop-" + name + ".s*.status", "app-linux-" + name + ".s*.log"} {
		m, _ := filepath.Glob(filepath.Join(logs, pat))
		for _, f := range m {
			_ = os.Remove(f)
		}
	}
}

func dirExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

// desktopParallel runs these files on jobs workers, then records them in the order given. Each worker has its own copy of
// app/ (a shared app/build and .dart_tool can't take two `flutter test` runs), its own Xvfb display and wallet/temp
// folders. Files are units on a shared list, the slowest first (history); files in ShardsOf run as several units and are
// merged back into one log, one history line per file.
func desktopParallel(s *run.Session, jobs int, names []string) {
	c, logs := s.C, s.Logs
	var specs []string
	for _, n := range names {
		if k := ShardsOf[n]; k > 1 {
			specs = append(specs, fmt.Sprintf("%s:%d", n, k))
		} else {
			specs = append(specs, n)
		}
	}
	rcfg := report.FromCtx(c, logs)
	var units []unit
	for _, u := range rcfg.Order(specs) {
		units = append(units, parseUnit(u))
	}
	if jobs > len(units) {
		jobs = len(units)
	}
	c.Printf("=== desktop-test: %d units from %d files on %d workers (BW_JOBS) ===\n", len(units), len(names), jobs)
	for _, n := range names {
		_ = os.RemoveAll(filepath.Join(c.Root, "dist", "screens", "linux", n))
		_ = os.RemoveAll(filepath.Join(logs, "screens-linux-"+n))
		_ = os.Remove(filepath.Join(logs, "tests-desktop-"+n+"-summary.txt"))
	}
	var mu sync.Mutex
	next := 0
	claim := func() (unit, bool) {
		mu.Lock()
		defer mu.Unlock()
		if next >= len(units) {
			return unit{}, false
		}
		next++
		return units[next-1], true
	}
	var wg sync.WaitGroup
	for w := 1; w <= jobs; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := workerApp(c, w); err != nil {
				c.Eprintf("  worker %d: copying app/ failed\n", w)
				return
			}
			kv := []string{"BW_APP_DIR", filepath.Join(c.Root, "dist", "desktop-test", "w"+strconv.Itoa(w), "app"), "BW_XDISPLAY", strconv.Itoa(100 + w)}
			for {
				u, ok := claim()
				if !ok {
					return
				}
				step, label := "desktop-"+u.name, u.name
				shard := -1
				if u.shards > 1 {
					step += fmt.Sprintf(".s%d", u.shard)
					label += fmt.Sprintf(" %d/%d", u.shard+1, u.shards)
					shard = u.shard
				}
				s.RunStepEnv(step, func(sc *run.StepCtx) int { return DesktopTest(sc, u.name, shard, u.shards) }, false, kv)
				secs, rc, _, _ := statusOf(filepath.Join(logs, step+".status"))
				status := "ok"
				if rc != 0 {
					status = "FAILED"
				}
				c.Printf("  desktop-%-14s %-6s %6s s  (worker %d)\n", label, status, secs, w)
			}
		}()
	}
	wg.Wait()
	for _, n := range names {
		if k := ShardsOf[n]; k > 1 {
			desktopMerge(s, n, k)
		} else if _, err := os.Stat(filepath.Join(logs, "desktop-"+n+".status")); err != nil { // never started (every worker failed)
			_ = os.WriteFile(filepath.Join(logs, "desktop-"+n+".log"), []byte(fmt.Sprintf("# desktop-%s: did not run\n", n)), 0o644)
			_ = os.WriteFile(filepath.Join(logs, "desktop-"+n+".status"), []byte("0.0 1 "+c.NowISO()+"\n"), 0o644)
		}
		if _, rc, _, _ := statusOf(filepath.Join(logs, "desktop-"+n+".status")); rc != 0 {
			c.Printf("=== desktop-%s ===\n%s", n, s.LogBody("desktop-"+n))
		}
		s.Record("desktop-"+n, false)
	}
}

// combinedName is the generated entry that runs every integration file in one app (CI: BW_DESKTOP_COMBINED=1), so the Linux
// app builds and starts once instead of once per file (~29 s each). Each file's main() runs in a group of its own name.
const combinedName = "combined"

func writeCombined(root string, names []string) (string, error) {
	var imp, calls strings.Builder
	imp.WriteString("// Generated by wallet-build desktop-test (BW_DESKTOP_COMBINED=1); git-ignored.\nimport 'flutter_test_config.dart' as cfg;\nimport 'support/harness.dart';\n")
	calls.WriteString("\nvoid main() {\n")
	for _, n := range names {
		fmt.Fprintf(&imp, "import '%s_test.dart' as f_%s;\n", n, n)
		fmt.Fprintf(&calls, "  group('%s', () {\n    Harness.clearRegistered();\n    f_%s.main();\n    final st = Harness.takeRegistered();\n"+
			"    setUpAll(() {\n      cfg.screensSubdir = '%s';\n      Harness.useRegistered(st);\n    });\n  });\n", n, n, n)
	}
	calls.WriteString("}\n")
	imp.WriteString("import 'package:flutter_test/flutter_test.dart';\n")
	p := filepath.Join(root, "app", "integration_test", combinedName+".dart")
	return p, os.WriteFile(p, []byte(imp.String()+calls.String()), 0o644)
}

// DesktopTests runs the integration test files: the names given, or every app/integration_test/*_test.dart. Parallel on
// DesktopJobs workers (a separate copy of app/ each), or one after another in app/ with a single job or a single unit.
func DesktopTests(s *run.Session, args []string) {
	c := s.C
	var names, valid []string
	for _, f := range args {
		f = strings.TrimSuffix(f, ".dart")
		names = append(names, strings.TrimSuffix(f, "_test"))
	}
	if len(names) == 0 {
		m, _ := filepath.Glob(filepath.Join(c.Root, "app", "integration_test", "*_test.dart"))
		sort.Strings(m)
		for _, f := range m {
			names = append(names, strings.TrimSuffix(filepath.Base(f), "_test.dart"))
		}
	}
	units := 0
	for _, f := range names {
		if _, err := os.Stat(filepath.Join(c.Root, "app", "integration_test", f+"_test.dart")); err != nil {
			s.FailStep("desktop-"+f, "no such test: app/integration_test/"+f+"_test.dart")
			continue
		}
		valid = append(valid, f)
		if k := ShardsOf[f]; k > 1 {
			units += k
		} else {
			units++
		}
	}
	if v := c.Getenv("BW_GL_THREADS"); v != "" {
		c.Setenv("LP_NUM_THREADS", v) // llvmpipe rasterizer threads per app
	}
	jobs, err := DesktopJobs(c.Env)
	if err != nil {
		s.FailStep("desktop-test", err.Error())
		return
	}
	if len(args) == 0 && c.Getenv("BW_DESKTOP_COMBINED") == "1" && len(valid) > 0 {
		p, err := writeCombined(c.Root, valid)
		if err != nil {
			s.FailStep("desktop-"+combinedName, err.Error())
			return
		}
		defer os.Remove(p)
		s.Step(run.Spec{Name: "desktop-" + combinedName, Fn: func(sc *run.StepCtx) int { return DesktopTest(sc, combinedName, -1, 1) }})
		return
	}
	if jobs > 1 && units > 1 {
		desktopParallel(s, jobs, valid)
		return
	}
	for _, f := range valid {
		s.Step(run.Spec{Name: "desktop-" + f, Fn: func(sc *run.StepCtx) int { return DesktopTest(sc, f, -1, 1) }})
	}
}

func newCmd(binary string, out io.Writer, env sys.Env) *exec.Cmd {
	c := exec.Command(binary)
	c.Stdout, c.Stderr = out, out
	if env != nil {
		c.Env = env.Environ()
	}
	c.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	return c
}
