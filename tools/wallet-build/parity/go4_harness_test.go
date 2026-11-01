//go:build parity

package parity

// GO4 harness: old helper script vs `dist/bin/wallet-build <cmd>` on the same synthetic input.
//
// A g4 case names the old command (a script under tools/, argv relative to the repo) and the new one (wallet-build
// arguments). Each side gets its own sandbox (HOME, BW_DATA_DIR, work dir, optionally a copy of the repo layout), so
// nothing of the owner's (transcripts, logs, relay data, keys, wallet) is ever read. Exit code, stdout, stderr and the
// named files are compared after masking the sandbox paths. BW_PARITY_IMPL=bash runs the old command on both sides
// (harness proof). Never given: --upload (signing-key), anything that resets real data.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"
)

type sandbox struct {
	t                                  *testing.T
	impl                               string
	root, home, data, work, repo, fake string
	real                               string
	bin                                string // wallet-build to run (real repo's, or the copy in the sandbox repo)
	stdinText                          string
	extraMasks                         []func(string) string
	envExtra                           []string
	fakeData                           string
	realHome                           bool
	cwd                                string
}

type g4 struct {
	name string
	// heavy: needs podman/Chrome/network or minutes of CPU: skipped unless BW_PARITY_HEAVY=1.
	heavy bool
	// newContainer: the new side may start the build container (the old one runs on the host): skipped for the Go
	// side unless BW_PARITY_HEAVY=1; with BW_PARITY_IMPL=bash it runs (old vs old).
	newContainer bool
	// old is the script (repo-relative) plus arguments; new is the wallet-build argument list. Placeholders in
	// arguments and env: {SB} {HOME} {DATA} {WORK} {REPO} (sandbox repo) {REAL} (the real repo) {FAKE}.
	old, new []string
	stdin    string
	env      []string
	// inRepo: run in the real repo (cwd, tool paths) instead of the sandbox work dir.
	inRepo bool
	// sbRepo: run in a sandbox copy of the repo layout: tools listed in tools/, trees in trees/, and the wallet-build
	// binary at <sandbox repo>/dist/bin (the binary finds its root from there). git: also `git init` with one commit.
	sbRepo bool
	tools  []string
	trees  []string
	git    bool
	fakes  []string // "podman", "gh"
	prep   func(t *testing.T, sb *sandbox)
	// compare
	exitOnly bool     // only the exit codes (usage texts differ between a script and the Go tool)
	files    []string // globs relative to the sandbox root: masked contents compared
	dirs     []string // directories relative to the sandbox root: file names and permission bits compared
	mask     func(string) string
	want     int // asserted exit for both sides when >= 0
	check    func(t *testing.T, sb *sandbox, r *g4res)
	skip     func(t *testing.T) string
	realHome bool
	timeout  time.Duration
}

type g4res struct {
	exit        int
	out, errOut string
	files       map[string]string
	dirs        map[string]string
}

func g4mk(name string, old, newArgs []string) g4 {
	return g4{name: name, old: old, new: newArgs, want: -1}
}

func newSandbox(t *testing.T, impl, real string) *sandbox {
	t.Helper()
	root := evalLinks(t.TempDir())
	sb := &sandbox{t: t, impl: impl, root: root, real: real}
	sb.home, sb.data, sb.work, sb.repo, sb.fake = filepath.Join(root, "home"), filepath.Join(root, "data"), filepath.Join(root, "work"),
		filepath.Join(root, "repo"), filepath.Join(root, "fakebin")
	sb.fakeData = filepath.Join(root, "fakedata")
	for _, d := range []string{sb.home, sb.data, sb.work, sb.repo, sb.fake, sb.fakeData} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return sb
}

func (sb *sandbox) write(rel, content string) string {
	sb.t.Helper()
	p := rel
	if !filepath.IsAbs(rel) {
		p = filepath.Join(sb.root, rel)
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		sb.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		sb.t.Fatal(err)
	}
	return p
}

func (sb *sandbox) subst(s string) string {
	r := strings.NewReplacer("{SB}", sb.root, "{HOME}", sb.home, "{DATA}", sb.data, "{WORK}", sb.work, "{REPO}", sb.repo,
		"{REAL}", sb.real, "{FAKE}", sb.fakeData)
	return r.Replace(s)
}

func (sb *sandbox) maskText(s string) string {
	dash := func(p string) string { return strings.NewReplacer("/", "-", ".", "-").Replace(p) }
	s = strings.ReplaceAll(s, dash(sb.repo), "<DASHREPO>")
	s = strings.ReplaceAll(s, sb.root, "<SB>")
	s = strings.ReplaceAll(s, sb.real, "<REAL>")
	s = reMktemp.ReplaceAllString(s, "<TMP>")
	for _, m := range sb.extraMasks {
		s = m(s)
	}
	return s
}

func copyFile(t testing.TB, src, dst string, mode os.FileMode) {
	t.Helper()
	b, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, b, mode); err != nil {
		t.Fatal(err)
	}
}

func copyTree(t testing.TB, src, dst string) {
	t.Helper()
	err := filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		if info.IsDir() {
			return os.MkdirAll(filepath.Join(dst, rel), 0o755)
		}
		copyFile(t, p, filepath.Join(dst, rel), info.Mode().Perm())
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

// wbBinary is the real repo's binary (built by tools/build.sh's Go path or `make bin`), or "".
func wbBinary(real string) string {
	if v := os.Getenv("BW_PARITY_BIN"); v != "" {
		return v
	}
	p := filepath.Join(real, "dist", "bin", "wallet-build")
	if _, err := os.Stat(p); err == nil {
		return p
	}
	return ""
}

var fakeScripts = map[string]string{
	// No container tool runs in cheap cases: a podman that knows nothing (no container, no image).
	"podman": "#!/bin/bash\ncase \"$1\" in\n  inspect|logs|container|stop|kill) echo 'Error: no such container' >&2; exit 125 ;;\n" +
		"  rm) echo 'Error: no container' >&2; exit 1 ;;\n  image) exit 1 ;;\n  ps) exit 0 ;;\n  *) echo \"fake podman: unsupported: $*\" >&2; exit 125 ;;\nesac\n",
	// gh answers from files in $FAKE_GH_DIR, filtered through the real jq like `gh --jq` does.
	"gh": "#!/bin/bash\nd=$FAKE_GH_DIR\nf=\njq=\nprev=\nfor a in \"$@\"; do [ \"$prev\" = --jq ] && jq=$a; prev=$a; done\n" +
		"case \"$1 $2\" in\n  api\\ repos/*check-runs) f=$d/checkruns.json ;;\n  run\\ list) f=$d/runs.json ;;\n" +
		"  *) echo \"fake gh: unsupported: $*\" >&2; exit 1 ;;\nesac\n[ -f \"$f\" ] || { echo 'fake gh: no data' >&2; exit 1; }\n" +
		"if [ -n \"$jq\" ]; then jq -r \"$jq\" \"$f\"; else cat \"$f\"; fi\n",
}

func (sb *sandbox) env(c g4) []string {
	var env []string
	for _, e := range os.Environ() {
		if strings.HasPrefix(e, "BW_") || strings.HasPrefix(e, "XDG_") || strings.HasPrefix(e, "GH_") || strings.HasPrefix(e, "GIT_") ||
			strings.HasPrefix(e, "HOME=") || strings.HasPrefix(e, "TZ=") || strings.HasPrefix(e, "LC_") || strings.HasPrefix(e, "LANG=") {
			continue
		}
		env = append(env, e)
	}
	path := os.Getenv("PATH")
	if len(c.fakes) > 0 {
		path = sb.fake + string(os.PathListSeparator) + path
	}
	home := sb.home
	if c.realHome {
		home = os.Getenv("HOME")
	}
	env = append(env, "PATH="+path, "HOME="+home, "TZ=UTC", "LC_ALL=C.UTF-8", "BW_DATA_DIR="+sb.data, "FAKE_GH_DIR="+sb.fakeData,
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0")
	for _, e := range c.env {
		env = append(env, sb.subst(e))
	}
	return env
}

// gitEnv: deterministic identity and dates, so both sandboxes get the same commit ids.
func (sb *sandbox) gitEnv(date string) []string {
	return append(sb.env(g4{}), "GIT_AUTHOR_NAME=T", "GIT_AUTHOR_EMAIL=t@example.invalid", "GIT_COMMITTER_NAME=T",
		"GIT_COMMITTER_EMAIL=t@example.invalid", "GIT_AUTHOR_DATE="+date, "GIT_COMMITTER_DATE="+date)
}

func (sb *sandbox) git(date string, args ...string) string {
	sb.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = sb.repo
	cmd.Env = sb.gitEnv(date)
	out, err := cmd.CombinedOutput()
	if err != nil {
		sb.t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

const day1 = "2026-03-01T12:00:00+0000"

func (sb *sandbox) initGit() {
	sb.git(day1, "init", "-q", "-b", "master")
	sb.write(filepath.Join(sb.repo, "README"), "synthetic\n")
	sb.git(day1, "add", "README")
	sb.git(day1, "commit", "-q", "-m", "first")
	bare := filepath.Join(sb.root, "origin.git")
	if err := os.MkdirAll(bare, 0o755); err != nil {
		sb.t.Fatal(err)
	}
	cmd := exec.Command("git", "init", "-q", "--bare", bare)
	cmd.Env = sb.gitEnv(day1)
	if out, err := cmd.CombinedOutput(); err != nil {
		sb.t.Fatalf("git init --bare: %v\n%s", err, out)
	}
	sb.git(day1, "remote", "add", "origin", bare)
}

// pushCILogs makes an orphan ci-logs branch holding files, pushes it to origin (and master when asked), and returns to master.
func (sb *sandbox) pushCILogs(files map[string]string, pushMaster bool) {
	sb.git(day1, "checkout", "-q", "--orphan", "ci-logs")
	sb.git(day1, "rm", "-rfq", "--cached", ".")
	names := make([]string, 0, len(files))
	for n := range files {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		sb.write(filepath.Join(sb.repo, n), files[n])
		sb.git(day1, "add", n)
	}
	sb.git(day1, "commit", "-q", "-m", "logs")
	sb.git(day1, "push", "-q", "origin", "ci-logs")
	sb.git(day1, "checkout", "-q", "-f", "master")
	sb.git(day1, "branch", "-q", "-D", "ci-logs")
	for _, n := range names {
		_ = os.Remove(filepath.Join(sb.repo, n))
	}
	if pushMaster {
		sb.git(day1, "push", "-q", "origin", "master")
	}
}

func (sb *sandbox) head() string { return sb.git(day1, "rev-parse", "HEAD") }

// setup builds the sandbox for one side of a case.
func (c g4) setup(t *testing.T, impl, real, bin string) *sandbox {
	sb := newSandbox(t, impl, real)
	sb.bin = bin
	if c.sbRepo {
		for _, tl := range c.tools {
			copyFile(t, filepath.Join(real, "tools", tl), filepath.Join(sb.repo, "tools", tl), 0o755)
		}
		for _, tr := range c.trees {
			fi, err := os.Stat(filepath.Join(real, tr))
			if err != nil {
				t.Fatal(err)
			}
			if fi.IsDir() {
				copyTree(t, filepath.Join(real, tr), filepath.Join(sb.repo, tr))
			} else {
				copyFile(t, filepath.Join(real, tr), filepath.Join(sb.repo, tr), fi.Mode().Perm())
			}
		}
		if c.git {
			sb.initGit()
		}
		if bin != "" {
			sb.bin = filepath.Join(sb.repo, "dist", "bin", "wallet-build")
			copyFile(t, bin, sb.bin, 0o755)
		}
	}
	for _, f := range c.fakes {
		sb.write(filepath.Join(sb.fake, f), fakeScripts[f])
		_ = os.Chmod(filepath.Join(sb.fake, f), 0o755)
	}
	if c.prep != nil {
		c.prep(t, sb)
	}
	return sb
}

func (c g4) argv(sb *sandbox, impl string) []string {
	var out []string
	if impl == "bash" {
		root := sb.real
		if c.sbRepo {
			root = sb.repo
		}
		out = append(out, filepath.Join(root, c.old[0]))
		for _, a := range c.old[1:] {
			out = append(out, sb.subst(a))
		}
	} else {
		out = append(out, sb.bin)
		for _, a := range c.new {
			out = append(out, sb.subst(a))
		}
	}
	for _, a := range out {
		if a == "--upload" { // never: it would write the owner's GitHub secrets
			sb.t.Fatalf("refusing to run %v: --upload is never allowed in tests", out)
		}
	}
	return out
}

func (c g4) run(t *testing.T, impl, real, bin string) (*sandbox, *g4res) {
	t.Helper()
	sb := c.setup(t, impl, real, bin)
	argv := c.argv(sb, impl)
	cwd := sb.work
	switch {
	case c.sbRepo:
		cwd = sb.repo
	case c.inRepo:
		cwd = real
	}
	d := c.timeout
	if d == 0 {
		d = 3 * time.Minute
	}
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = cwd
	cmd.Env = sb.env(c)
	cmd.Stdin = strings.NewReader(sb.subst(c.stdin))
	var so, se bytes.Buffer
	cmd.Stdout, cmd.Stderr = &so, &se
	err := cmd.Run()
	if ctx.Err() != nil {
		t.Fatalf("[%s] %s: timed out after %s\nstdout: %s\nstderr: %s", c.name, impl, d, tail(so.String()), tail(se.String()))
	}
	r := &g4res{exit: exitCode(t, err), out: so.String(), errOut: se.String(), files: map[string]string{}, dirs: map[string]string{}}
	if c.mask != nil {
		sb.extraMasks = append(sb.extraMasks, c.mask)
	}
	for _, g := range c.files {
		ms, _ := filepath.Glob(filepath.Join(sb.root, g))
		sort.Strings(ms)
		if len(ms) == 0 {
			r.files[g] = "<no file>"
		}
		for _, m := range ms {
			b, rerr := os.ReadFile(m)
			rel, _ := filepath.Rel(sb.root, m)
			if rerr != nil {
				r.files[rel] = "<unreadable>"
				continue
			}
			r.files[rel] = sb.maskText(string(b))
		}
	}
	for _, d := range c.dirs {
		var rows []string
		_ = filepath.Walk(filepath.Join(sb.root, d), func(p string, info os.FileInfo, err error) error {
			if err != nil {
				return nil
			}
			rel, _ := filepath.Rel(sb.root, p)
			rows = append(rows, fmt.Sprintf("%s %04o", rel, info.Mode().Perm()))
			return nil
		})
		r.dirs[d] = strings.Join(rows, "\n")
	}
	return sb, r
}

func runG4(t *testing.T, c g4) {
	t.Helper()
	if c.heavy && os.Getenv(heavyEnv) != "1" {
		t.Skipf("heavy case: set %s=1 to run it", heavyEnv)
	}
	if c.newContainer && goSide() && os.Getenv(heavyEnv) != "1" {
		t.Skipf("the new side may start the build container (heavy): set %s=1; BW_PARITY_IMPL=bash runs it old vs old", heavyEnv)
	}
	if c.skip != nil {
		if why := c.skip(t); why != "" {
			t.Skip(why)
		}
	}
	real := repoRoot(t)
	bin := ""
	if goSide() {
		if bin = wbBinary(real); bin == "" {
			t.Skip("dist/bin/wallet-build not built (make bin, or BW_PARITY_BIN)")
		}
	}
	var sbs [2]*sandbox
	var rs [2]*g4res
	for i, impl := range []string{"bash", implName()} {
		sbs[i], rs[i] = c.run(t, impl, real, bin)
		if c.want >= 0 && rs[i].exit != c.want {
			t.Errorf("[%s] %s: exit %d, want %d\nstdout: %s\nstderr: %s", c.name, impl, rs[i].exit, c.want, tail(rs[i].out), tail(rs[i].errOut))
		}
		if c.check != nil {
			c.check(t, sbs[i], rs[i])
		}
	}
	a, b := rs[0], rs[1]
	if a.exit != b.exit {
		t.Errorf("parity[%s]: exit code bash %d, %s %d\nbash stderr: %s\n%s stderr: %s", c.name, a.exit, implName(), b.exit, tail(a.errOut), implName(), tail(b.errOut))
		return
	}
	if c.exitOnly {
		return
	}
	ao, bo := sbs[0].maskText(a.out), sbs[1].maskText(b.out)
	ae, be := sbs[0].maskText(a.errOut), sbs[1].maskText(b.errOut)
	ok := diffLines(t, c.name, "stdout", lines(ao), lines(bo))
	ok = diffLines(t, c.name, "stderr", lines(ae), lines(be)) && ok
	if ok && (ao != bo || ae != be) {
		t.Errorf("parity[%s]: same lines but different blank lines/trailing newline in stdout or stderr", c.name)
	}
	keys := map[string]bool{}
	for k := range a.files {
		keys[k] = true
	}
	for k := range b.files {
		keys[k] = true
	}
	var names []string
	for k := range keys {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, k := range names {
		x, xok := a.files[k]
		y, yok := b.files[k]
		if !xok || !yok {
			t.Errorf("parity[%s]: file %s present only on one side", c.name, k)
			continue
		}
		if x != y {
			diffLines(t, c.name, "file "+k, strings.Split(x, "\n"), strings.Split(y, "\n"))
		}
	}
	for k, x := range a.dirs {
		if y := b.dirs[k]; x != y {
			diffLines(t, c.name, "dir "+k, strings.Split(x, "\n"), strings.Split(y, "\n"))
		}
	}
}

// ---- small helpers shared by the GO4 files ----

func jsonLine(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(b) + "\n"
}

func freePort(t testing.TB) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func runSimple(t testing.TB, dir string, env []string, name string, args ...string) (string, string, int) {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Env = env
	var so, se bytes.Buffer
	cmd.Stdout, cmd.Stderr = &so, &se
	err := cmd.Run()
	return so.String(), se.String(), exitCode(t, err)
}

func readAll(r io.Reader) []byte {
	b, _ := io.ReadAll(r)
	return b
}

var reMktemp = regexp.MustCompile(`/tmp/tmp\.[A-Za-z0-9]+`)

var reFingerprint = regexp.MustCompile(`SHA256: [0-9A-F:]+`)
