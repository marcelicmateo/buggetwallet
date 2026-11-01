// Package steps is the container side of wallet-build: the steps tools/build.sh runs inside the image (or natively in CI).
package steps

import (
	"bufio"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"wallet-build/internal/image"
	"wallet-build/internal/report"
	"wallet-build/internal/run"
)

// PubDirs are the packages `pub get` resolves, in order (they share the pub cache, so sequentially).
var PubDirs = []string{"packages/wallet_importer", "packages/wallet_core", "packages/sync", "relay", "app"}

var rootURI = regexp.MustCompile(`"rootUri": "file://([^"]+)"`)

func newer(a, b string) bool {
	sa, err := os.Stat(a)
	if err != nil {
		return false
	}
	sb, err := os.Stat(b)
	if err != nil {
		return false
	}
	return sa.ModTime().After(sb.ModTime())
}

// PubStale: no package_config, or older than a pubspec/lockfile it depends on (path dependencies included), or resolved
// against a pub cache that isn't here (a deleted volume, a host SDK).
func PubStale(root, d string) bool {
	cfg := filepath.Join(root, d, ".dart_tool", "package_config.json")
	if _, err := os.Stat(cfg); err != nil {
		return true
	}
	files := []string{filepath.Join(root, d, "pubspec.yaml"), filepath.Join(root, d, "pubspec.lock")}
	more, _ := filepath.Glob(filepath.Join(root, "packages", "*", "pubspec.yaml"))
	for _, f := range append(files, more...) {
		if newer(f, cfg) {
			return true
		}
	}
	if f, err := os.Open(cfg); err == nil {
		defer f.Close()
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1<<20), 1<<24)
		for sc.Scan() {
			if m := rootURI.FindStringSubmatch(sc.Text()); m != nil {
				st, err := os.Stat(m[1])
				return err != nil || !st.IsDir()
			}
		}
	}
	return false
}

// PubReady runs `pub get` only where the resolution is out of date, so a warm run skips it (CI always starts clean).
// Also needed by `dart format`, which reads page_width through the analysis_options.yaml includes.
func PubReady(sc *run.StepCtx) int {
	root := sc.C.Root
	for _, d := range PubDirs {
		if !PubStale(root, d) {
			continue
		}
		sc.Printf("--- pub get: %s\n", d)
		// app and relay have a tracked pubspec.lock: --enforce-lockfile fails instead of silently moving versions (to change a
		// dependency run `pub get` without it in a shell, then commit the lock). The packages' locks are git-ignored.
		var argv []string
		switch d {
		case "app":
			argv = []string{"flutter", "pub", "get", "--enforce-lockfile"}
		case "relay":
			argv = []string{"dart", "pub", "get", "--enforce-lockfile"}
		default:
			argv = []string{"dart", "pub", "get"}
		}
		if rc := sc.Cmd(d, argv...); rc != 0 {
			return 1
		}
		cfg := filepath.Join(root, d, ".dart_tool", "package_config.json")
		now := time.Now()
		if err := os.Chtimes(cfg, now, now); err != nil { // pub leaves it alone when nothing changed
			_ = os.MkdirAll(filepath.Dir(cfg), 0o755)
			if f, err := os.OpenFile(cfg, os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
				f.Close()
			}
		}
	}
	return 0
}

// RunPub is the `pub` step: shown (and recorded) only when something had to be resolved.
func RunPub(s *run.Session) {
	c := s.C
	cold := false
	for _, d := range PubDirs {
		if _, err := os.Stat(filepath.Join(c.Root, d, ".dart_tool", "package_config.json")); err != nil {
			cold = true
		}
	}
	rc := s.RunStep("pub", PubReady, false)
	b, _ := os.ReadFile(filepath.Join(s.Logs, "pub.log"))
	if strings.Count(string(b), "\n") > 2 || rc != 0 {
		c.Printf("=== pub ===\n%s", s.LogBody("pub"))
		s.Record("pub", cold)
	}
}

// DartFiles are the Dart sources, skipping generated and build folders.
func DartFiles(root string) []string {
	var out []string
	for _, top := range []string{"app", "packages", "relay"} {
		_ = filepath.WalkDir(filepath.Join(root, top), func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if d.IsDir() {
				switch d.Name() {
				case ".dart_tool", "build", "ephemeral", ".symlinks":
					return filepath.SkipDir
				}
				return nil
			}
			if strings.HasSuffix(p, ".dart") {
				rel, _ := filepath.Rel(root, p)
				out = append(out, rel)
			}
			return nil
		})
	}
	sort.Strings(out)
	return out
}

// chunks splits file names the way xargs does, so no command line gets too long.
func chunks(files []string) [][]string {
	var out [][]string
	var cur []string
	size := 0
	for _, f := range files {
		if size+len(f)+1 > 100000 && len(cur) > 0 {
			out = append(out, cur)
			cur, size = nil, 0
		}
		cur = append(cur, f)
		size += len(f) + 1
	}
	if len(cur) > 0 {
		out = append(out, cur)
	}
	return out
}

func dartFormat(sc *run.StepCtx, args ...string) int {
	rc := 0
	for _, ch := range chunks(DartFiles(sc.C.Root)) {
		argv := append(append([]string{"dart", "format"}, args...), ch...)
		if sc.Cmd("", argv...) != 0 {
			rc = 123 // xargs: a command exited 1-125
		}
	}
	return rc
}

// FormatCheck fails when a Dart file is not formatted.
func FormatCheck(sc *run.StepCtx) int {
	if dartFormat(sc, "-o", "none", "--set-exit-if-changed") != 0 {
		sc.Printf("format check failed: run tools/build.sh format\n")
		return 1
	}
	return 0
}

// Format rewrites the Dart files.
func Format(sc *run.StepCtx) int { return dartFormat(sc) }

func expand(root string, patterns ...string) []string {
	var out []string
	for _, p := range patterns {
		m, _ := filepath.Glob(filepath.Join(root, p))
		sort.Strings(m)
		for _, f := range m {
			rel, _ := filepath.Rel(root, f)
			out = append(out, rel)
		}
	}
	return out
}

var envRead = regexp.MustCompile(`Platform\.environment\[['"](BW_[A-Z_]+)`)

// EnvSelftest: every BW_* variable a test reads through Platform.environment must be passed into the container.
func EnvSelftest(sc *run.StepCtx) int {
	root := sc.C.Root
	found := map[string]bool{}
	var dirs []string
	pk, _ := filepath.Glob(filepath.Join(root, "packages", "*", "test"))
	dirs = append(dirs, pk...)
	dirs = append(dirs, filepath.Join(root, "relay", "test"), filepath.Join(root, "app", "test"))
	for _, d := range dirs {
		_ = filepath.WalkDir(d, func(p string, e fs.DirEntry, err error) error {
			if err != nil || e.IsDir() {
				return nil
			}
			if b, err := os.ReadFile(p); err == nil {
				for _, m := range envRead.FindAllStringSubmatch(string(b), -1) {
					found[m[1]] = true
				}
			}
			return nil
		})
	}
	delete(found, "BW_ANDROID_ROOT")
	passed := map[string]bool{"BW_NATIVE": true}
	for _, v := range image.PassEnv {
		passed[v] = true
	}
	var names []string
	for v := range found {
		names = append(names, v)
	}
	sort.Strings(names)
	rc := 0
	for _, v := range names {
		if !passed[v] && !strings.HasPrefix(v, "BW_TIMEOUT_") {
			sc.Printf("env-selftest: %s is read by a test but not passed by wallet-build (internal/image PassEnv)\n", v)
			rc = 1
		}
	}
	return rc
}

func lintSpecs(c *run.Ctx) []run.Spec {
	root := c.Root
	cmd := func(argv ...string) func(*run.StepCtx) int {
		return func(sc *run.StepCtx) int { return sc.Cmd("", argv...) }
	}
	return []run.Spec{
		{Name: "format", Fn: FormatCheck},
		{Name: "shellcheck", Fn: func(sc *run.StepCtx) int {
			files := expand(root, "tools/*.sh", "dev/*.sh", ".github/scripts/*.sh")
			if len(files) == 0 {
				return 0
			}
			return sc.Cmd("", append([]string{"shellcheck"}, files...)...)
		}},
		{Name: "actionlint", Fn: cmd("actionlint")},
		// the bash hook and its Go port (wallet-build hook no-poll) both have to pass until the hook is switched (GO4-B)
		{Name: "hook-selftest", Fn: func(sc *run.StepCtx) int {
			rc := sc.Cmd("", "tools/no-poll-hook.sh", "--self-test")
			if sc.Cmd("", "dist/bin/wallet-build", "hook", "no-poll", "--self-test") != 0 {
				rc = 1
			}
			return rc
		}},
		{Name: "env-selftest", Fn: EnvSelftest},
		{Name: "deploy-selftest", Fn: cmd("tools/relay-deploy.sh", "--self-test")},
		{Name: "native-units", Fn: cmd("dist/bin/wallet-build", "relay-native-check")},
	}
}

// LintNames are the steps of lint, in order.
func LintNames(c *run.Ctx) []string {
	var n []string
	for _, s := range lintSpecs(c) {
		n = append(n, s.Name)
	}
	return n
}

type suiteDef struct {
	name, dir string
	analyze   []string
	test      []string
}

var suiteDefs = []suiteDef{
	{"importer", "packages/wallet_importer", dartAnalyze, dartTest},
	{"core", "packages/wallet_core", dartAnalyze, dartTest},
	{"sync", "packages/sync", dartAnalyze, dartTest},
	{"relay", "relay", dartAnalyze, dartTest},
	{"app", "app", []string{"flutter", "analyze", "--fatal-infos", "--no-pub"}, []string{"flutter", "test", "--no-pub", "--timeout", "60s"}},
}

var (
	dartAnalyze = []string{"dart", "analyze", "--fatal-infos"}
	dartTest    = []string{"dart", "test", "--timeout", "60s"}
)

func findSuite(pkg string) (suiteDef, bool) {
	for _, d := range suiteDefs {
		if d.name == pkg {
			return d, true
		}
	}
	return suiteDef{}, false
}

// suiteFn is suite(): analyze, test with a JSON report next to the logs, then per-test timings (histogram, slowest tests,
// history lines) even when tests failed.
func suiteFn(name, dir string, analyze, test []string) func(*run.StepCtx) int {
	return func(sc *run.StepCtx) int {
		logs := sc.S.Logs
		jsonPath := filepath.Join(logs, "tests-"+name+".json")
		_ = os.Remove(jsonPath)
		_ = os.Remove(filepath.Join(logs, "tests-"+name+"-summary.txt"))
		rc := 0
		if analyze != nil {
			rc = sc.Cmd(dir, analyze...)
		}
		if rc == 0 {
			rc = sc.Cmd(dir, append(append([]string{}, test...), "--file-reporter", "json:"+jsonPath)...)
		}
		if _, err := os.Stat(jsonPath); err == nil {
			rcfg := report.FromCtx(sc.C, logs)
			rcfg.Env, rcfg.Out = sc.Env, sc.Out
			rcfg.Tests("tests", name, []string{jsonPath})
		}
		return rc
	}
}

// SuiteSpecs are the five packages, analyze + tests, one step each.
func SuiteSpecs() []run.Spec {
	var out []run.Spec
	for _, d := range suiteDefs {
		out = append(out, run.Spec{Name: d.name, Fn: suiteFn(d.name, d.dir, d.analyze, d.test)})
	}
	return out
}

// OneSuite runs only the given test paths of a package (no analyze) as step "<pkg>:one".
func OneSuite(s *run.Session, pkg string, paths []string) {
	c := s.C
	d, _ := findSuite(pkg)
	var files []string
	for _, f := range paths {
		f = strings.TrimPrefix(f, c.Root+"/")
		f = strings.TrimPrefix(f, d.dir+"/")
		if _, err := os.Stat(filepath.Join(c.Root, d.dir, f)); err != nil {
			s.FailStep(pkg+":one", fmt.Sprintf("no such test file or dir in %s: %s", d.dir, f))
			return
		}
		files = append(files, f)
	}
	c.Printf("(%s: %d path(s), no analyze)\n", pkg, len(files))
	test := []string{"dart", "test", "--timeout", "60s"} // per-test cap: a hung test fails in 1 min, not 10
	if pkg == "app" {
		test = []string{"flutter", "test", "--timeout", "60s", "--no-pub"}
	}
	s.Steps(run.Spec{Name: pkg + ":one", Fn: suiteFn(pkg+":one", d.dir, nil, append(test, files...))})
}

// AnalyzePkgs runs analysis only (fatal infos), in parallel, as steps "analyze-<pkg>".
func AnalyzePkgs(s *run.Session, pkgs []string) {
	if len(pkgs) == 0 {
		for _, d := range suiteDefs {
			pkgs = append(pkgs, d.name)
		}
	}
	var specs []run.Spec
	for _, p := range pkgs {
		d, ok := findSuite(p)
		if !ok {
			s.FailStep("analyze", fmt.Sprintf("analyze: unknown package %s (importer core sync relay app)", p))
			return
		}
		dir, an := d.dir, d.analyze
		specs = append(specs, run.Spec{Name: "analyze-" + p, Fn: func(sc *run.StepCtx) int { return sc.Cmd(dir, an...) }})
	}
	s.Steps(specs...)
}

// Outdated is `dart pub outdated` per package (network). The SDK has no advisory check, so this is the table only.
func Outdated(sc *run.StepCtx) int {
	for _, d := range PubDirs {
		sc.Printf("=== %s\n", d)
		if d == "app" {
			sc.Cmd(d, "flutter", "pub", "outdated")
		} else {
			sc.Cmd(d, "dart", "pub", "outdated")
		}
	}
	return 0
}
