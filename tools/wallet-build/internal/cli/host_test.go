package cli

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"wallet-build/internal/host"
	"wallet-build/internal/sys"
)

const imgPrefix = "localhost/budget-wallet-dev:3.47.7-"

func podmanRuns(r result) []string {
	var out []string
	for _, c := range r.fake.Calls {
		if len(c.Argv) > 1 && c.Argv[0] == "podman" && c.Argv[1] == "run" {
			out = append(out, strings.Join(c.Argv, " "))
		}
	}
	return out
}

func runDirs(t *testing.T, r result) []string {
	m, _ := filepath.Glob(filepath.Join(r.data, "runs", "*"))
	return m
}

const runEnvFlags = "-e BW_DATA_DIR -e BW_RUN_DIR -e BW_RUN_ID -e BW_RUN -e BW_COMMIT -e BW_CMD -e BW_IMAGE -e BW_COLD -e BW_SOURCE -e BW_WORKTREE"
const passFlags = "-e BW_NATIVE=1 -e BW_JOBS -e BW_GL_THREADS -e BW_APK_ABIS -e BW_FUZZ_ITERATIONS -e BW_FUZZ_SEED -w /work"

func TestHostPodmanRunArgv(t *testing.T) {
	r := runCLI(t, opts{handle: goHandle(true)}, "core", "test/x_test.dart")
	if r.code != 0 {
		t.Fatalf("code %d %s", r.code, r.err)
	}
	runs := podmanRuns(r)
	if len(runs) != 1 {
		t.Fatalf("podman runs: %v", runs)
	}
	id := filepath.Base(runDirs(t, r)[0])
	if id != "20261101-101328-core-abc1234" && !strings.HasSuffix(id, "-core-abc1234") {
		t.Errorf("run id %s", id)
	}
	img := strings.Fields(runs[0])
	// everything up to the image
	want := "podman run --rm --init --name wallet-build-wt-" + id + " -v " + r.root + ":/work:z -v bw-pub-cache:/cache/pub -v bw-gradle-cache:/cache/gradle " +
		"-v bw-android-user:/cache/android -v " + r.data + ":" + r.data + ":z " + runEnvFlags + " " + passFlags + " "
	if !strings.HasPrefix(runs[0], want) {
		t.Errorf("podman run argv\n got %s\nwant %s...", runs[0], want)
	}
	if !strings.Contains(img[len(img)-4], imgPrefix) || strings.Join(img[len(img)-3:], " ") != "dist/bin/wallet-build core test/x_test.dart" {
		t.Errorf("tail: %v", img[len(img)-4:])
	}
	// no tty: neither -it
	if strings.Contains(runs[0], " -it ") {
		t.Error("no terminal, no -it")
	}
	// the run is closed: last.status, last-failed.txt, .running gone; dist/logs points at it
	dir := runDirs(t, r)[0]
	if _, err := os.Stat(filepath.Join(dir, ".running")); err == nil {
		t.Error(".running left behind")
	}
	if lf := file(t, filepath.Join(dir, "last-failed.txt")); lf != "" {
		t.Errorf("green run, last-failed.txt: %q", lf)
	}
	if link, _ := os.Readlink(r.logs); link != dir {
		t.Errorf("dist/logs -> %s", link)
	}
}

func TestHostLintRunsGoCheckFirst(t *testing.T) {
	for _, cmd := range []string{"lint", "test"} {
		r := runCLI(t, opts{handle: goHandle(true)}, cmd)
		if r.code != 0 {
			t.Fatalf("%s: code %d\n%s%s", cmd, r.code, r.out, r.err)
		}
		var seq []string
		for _, c := range r.calls {
			seq = append(seq, c)
		}
		order := []string{"$ podman image exists", "$ gofmt -l tools/wallet-build", "tools/wallet-build$ go vet ./...", "tools/wallet-build$ go test ./...", "$ go version -m dist/bin/wallet-build", "$ podman run "}
		pos := 0
		for _, c := range seq {
			if pos < len(order) && strings.HasPrefix(c, order[pos]) {
				pos++
			}
		}
		if pos != len(order) {
			t.Errorf("%s: calls out of order: %v", cmd, seq)
		}
		dir := runDirs(t, r)[0]
		if st := file(t, filepath.Join(dir, "go-check.status")); len(strings.Fields(st)) != 3 {
			t.Errorf("go-check.status %q", st)
		}
		if !strings.Contains(file(t, filepath.Join(r.data, "history", "steps.jsonl")), `"step":"go-check"`) {
			t.Errorf("%s: go-check has no history line", cmd)
		}
		if !strings.Contains(file(t, filepath.Join(dir, "last.status")), "go-check ok ") {
			t.Errorf("%s: last.status %q", cmd, file(t, filepath.Join(dir, "last.status")))
		}
	}
	// a failing go-check stops before the container
	r := runCLI(t, opts{handle: goHandle(false)}, "lint")
	if r.code != 1 || len(podmanRuns(r)) != 0 {
		t.Errorf("code %d, podman runs %v", r.code, podmanRuns(r))
	}
	if lf := file(t, filepath.Join(runDirs(t, r)[0], "last-failed.txt")); !strings.HasPrefix(lf, "go-check "+r.root+"/dist/logs/go-check.log") {
		t.Errorf("last-failed.txt %q", lf)
	}
	// other commands have no go-check
	r = runCLI(t, opts{}, "core")
	for _, c := range r.calls {
		if strings.Contains(c, "gofmt") {
			t.Errorf("core ran go-check")
		}
	}
}

func TestHostShellDashC(t *testing.T) {
	h := func(c sys.Cmd) int {
		if c.Argv[0] == "podman" && len(c.Argv) > 1 && c.Argv[1] == "run" {
			c.Stdout.Write([]byte("out line\n"))
			c.Stderr.Write([]byte("err line\n"))
			return 3
		}
		return 0
	}
	r := runCLI(t, opts{handle: h, setup: func(hh *host.Host) { hh.IsTTY = func() bool { return true } }}, "shell", "-c", "exit 3")
	if r.code != 3 {
		t.Fatalf("shell -c returns the command's code: %d", r.code)
	}
	runs := podmanRuns(r)
	if len(runs) != 1 || strings.Contains(runs[0], "-it") || !strings.HasSuffix(runs[0], " bash -c exit 3") {
		t.Errorf("argv %v", runs)
	}
	dir := runDirs(t, r)[0]
	log := file(t, filepath.Join(dir, "shell.log"))
	if !strings.HasPrefix(log, "# shell: started ") || !strings.Contains(log, "out line\n") || !strings.Contains(log, "err line\n") || !strings.HasSuffix(log, ", exit 3\n") {
		t.Errorf("shell.log %q", log)
	}
	if r.out != "out line\n" || r.err != "err line\n" {
		t.Errorf("split mode keeps stdout on stdout and stderr on stderr: %q %q", r.out, r.err)
	}
	if st := strings.Fields(file(t, filepath.Join(dir, "shell.status"))); len(st) != 3 || st[1] != "3" {
		t.Errorf("status %v", st)
	}
	if got := file(t, filepath.Join(dir, "last.status")); !strings.HasPrefix(got, "shell failed ") {
		t.Errorf("last.status %q", got)
	}
	hist := file(t, filepath.Join(r.data, "history", "steps.jsonl"))
	if !strings.Contains(hist, `"cmd":"shell","step":"shell","seconds":`) || !strings.Contains(hist, `"result":"FAILED"`) || !strings.HasSuffix(hist, `"cold":false}`+"\n") {
		t.Errorf("history %s", hist)
	}
}

func TestHostInteractiveShellHasNoRunAndAllocatesTTY(t *testing.T) {
	r := runCLI(t, opts{setup: func(hh *host.Host) { hh.IsTTY = func() bool { return true } }}, "shell")
	runs := podmanRuns(r)
	if len(runs) != 1 || !strings.Contains(runs[0], " --init --name wallet-build-wt-shell-") || !strings.Contains(runs[0], " -it ") || !strings.HasSuffix(runs[0], " bash") {
		t.Errorf("argv %v", runs)
	}
	if strings.Contains(runs[0], "-e BW_RUN_DIR") {
		t.Error("no run, no run variables")
	}
	if len(runDirs(t, r)) != 0 {
		t.Error("an interactive shell has no run dir")
	}
	if !r.fake.Calls[len(r.fake.Calls)-1].Foreground || r.fake.Calls[len(r.fake.Calls)-1].Stdin == nil {
		t.Error("the terminal must be handed to podman")
	}
}

func TestHostSecretsNeverLogged(t *testing.T) {
	root := mkRepo(t)
	home := t.TempDir()
	signing := filepath.Join(home, ".config", "budget-wallet")
	write(t, filepath.Join(signing, "signing.env"), "BW_KEY_ALIAS=al\nBW_KEYSTORE_PASSWORD=Sup3rSecretPass\nBW_KEY_PASSWORD=Sup3rSecretPass\n")
	h := func(c sys.Cmd) int {
		if c.Argv[0] == "podman" && len(c.Argv) > 1 && c.Argv[1] == "run" {
			c.Stdout.Write([]byte("password is Sup3rSecretPass\n"))
		}
		return 0
	}
	r := runCLI(t, opts{root: root, handle: h, env: []string{"HOME=" + home}}, "shell", "-c", "echo hi")
	runs := podmanRuns(r)
	want := "-v " + signing + ":/signing:ro,z --env-file " + signing + "/signing.env -e BW_KEYSTORE=/signing/android-release.jks"
	if len(runs) != 1 || !strings.Contains(runs[0], want) {
		t.Errorf("signing mounts missing: %v", runs)
	}
	if strings.Contains(r.out+r.err, "Sup3rSecretPass") {
		t.Errorf("secret on stdout/stderr: %q %q", r.out, r.err)
	}
	filepath.Walk(r.data, func(p string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() && strings.Contains(file(t, p), "Sup3rSecretPass") {
			t.Errorf("secret in %s", p)
		}
		return nil
	})
	if !strings.Contains(file(t, filepath.Join(runDirs(t, r)[0], "shell.log")), "password is ***") {
		t.Error("redaction marker missing")
	}
}

func TestHostApkWithoutSigningKey(t *testing.T) {
	for _, cmd := range []string{"apk", "all"} {
		r := runCLI(t, opts{}, cmd)
		if r.code != 1 || !strings.Contains(r.err, "No Android signing key in ") || !strings.Contains(r.err, "tools/make-signing-key.sh") || len(podmanRuns(r)) != 0 {
			t.Errorf("%s: code %d err %q runs %v", cmd, r.code, r.err, podmanRuns(r))
		}
		dir := runDirs(t, r)[0]
		if !strings.Contains(file(t, filepath.Join(dir, "last-failed.txt")), cmd+" ") {
			t.Errorf("last-failed.txt %q", file(t, filepath.Join(dir, "last-failed.txt")))
		}
	}
}

func TestHostBuildsMissingImage(t *testing.T) {
	h := func(c sys.Cmd) int {
		if strings.Join(c.Argv[:min(3, len(c.Argv))], " ") == "podman image exists" {
			return 1
		}
		if len(c.Argv) > 1 && c.Argv[1] == "build" {
			c.Stdout.Write([]byte("STEP 1/9\n"))
		}
		return 0
	}
	r := runCLI(t, opts{handle: h}, "core")
	var build string
	for _, c := range r.fake.Calls {
		if len(c.Argv) > 1 && c.Argv[1] == "build" {
			build = strings.Join(c.Argv, " ")
		}
	}
	if !strings.HasPrefix(build, "podman build --build-arg FLUTTER_VERSION=3.47.7 -t "+imgPrefix) || !strings.HasSuffix(build, " "+r.root+"/dev") {
		t.Errorf("build: %s", build)
	}
	dir := runDirs(t, r)[0]
	if log := file(t, filepath.Join(dir, "image-dev.log")); !strings.Contains(log, "STEP 1/9\n") || !strings.HasPrefix(log, "# image: started ") {
		t.Errorf("image-dev.log %q", log)
	}
	if !strings.Contains(file(t, filepath.Join(dir, "last.status")), "image-dev ok ") {
		t.Errorf("last.status %q", file(t, filepath.Join(dir, "last.status")))
	}
	hist := file(t, filepath.Join(r.data, "history", "steps.jsonl"))
	if !strings.Contains(hist, `"step":"image"`) || !strings.Contains(hist, `"cold":true`) {
		t.Errorf("history %s", hist)
	}
	// the container run after a build is marked cold
	for _, c := range r.fake.Calls {
		if len(c.Argv) > 1 && c.Argv[1] == "run" && c.Env.Get("BW_COLD") != "1" {
			t.Errorf("BW_COLD=%q", c.Env.Get("BW_COLD"))
		}
	}
	// a failing build stops everything and returns podman's code
	r = runCLI(t, opts{handle: func(c sys.Cmd) int {
		if len(c.Argv) > 1 && c.Argv[1] == "build" {
			return 125
		}
		return h(c)
	}}, "image")
	if r.code != 125 || len(podmanRuns(r)) != 0 {
		t.Errorf("code %d", r.code)
	}
}

func TestHostMutateRefusesLeftoverMutant(t *testing.T) {
	h := func(c sys.Cmd) int {
		if c.Argv[0] == "git" {
			return 1
		}
		return 0
	}
	r := runCLI(t, opts{handle: h}, "mutate", "core", "lib/x.dart")
	if r.code != 1 || !strings.Contains(r.err, "mutate: lib files differ from HEAD") || len(podmanRuns(r)) != 0 {
		t.Errorf("code %d err %q", r.code, r.err)
	}
	joined := strings.Join(r.calls, "\n")
	if !strings.Contains(joined, "git -C "+r.root+" diff --quiet HEAD -- packages/wallet_core/lib packages/sync/lib packages/wallet_importer/lib") {
		t.Errorf("calls:\n%s", joined)
	}
}

func TestHostWebFetchesPinnedWasm(t *testing.T) {
	root := mkRepo(t)
	write(t, filepath.Join(root, "app/pubspec.lock"), "packages:\n  other:\n    version: \"1.0.0\"\n  sqlite3:\n    dependency: transitive\n    version: \"3.8.0\"\n")
	body := "wasm bytes"
	sum := fmt.Sprintf("%x", sha256.Sum256([]byte(body)))
	var urls []string
	setup := func(hh *host.Host) {
		hh.Download = func(url, dest string) error { urls = append(urls, url); return os.WriteFile(dest, []byte(body), 0o644) }
	}
	// not pinned: refuse, say how to pin it
	r := runCLI(t, opts{root: root, setup: setup}, "web")
	if r.code != 1 || !strings.Contains(r.err, "sqlite3mc.wasm 3.8.0 is not pinned") || !strings.Contains(r.err, sum+"  sqlite3mc-3.8.0") || len(podmanRuns(r)) != 0 {
		t.Errorf("unpinned: code %d err %q", r.code, r.err)
	}
	if want := "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.8.0/sqlite3mc.wasm"; len(urls) != 1 || urls[0] != want {
		t.Errorf("urls %v", urls)
	}
	// wrong pin: cache deleted
	write(t, filepath.Join(root, "dev/sqlite3-wasm.sha256"), strings.Repeat("0", 64)+"  sqlite3mc-3.8.0\n")
	r = runCLI(t, opts{root: root, setup: setup}, "web-test")
	if r.code != 1 || !strings.Contains(r.err, "sha256 mismatch") {
		t.Errorf("mismatch: code %d err %q", r.code, r.err)
	}
	// right pin
	write(t, filepath.Join(root, "dev/sqlite3-wasm.sha256"), sum+"  sqlite3mc-3.8.0\n")
	os.Remove(filepath.Join(root, "app/web/sqlite3.wasm"))
	r = runCLI(t, opts{root: root, setup: setup}, "web")
	if r.code != 0 || len(podmanRuns(r)) != 1 {
		t.Errorf("pinned: code %d err %q", r.code, r.err)
	}
	if file(t, filepath.Join(root, "app/web/sqlite3.wasm")) != body || file(t, filepath.Join(root, "app/test/sqlite3.wasm")) != body {
		t.Error("wasm not copied to app/web and app/test")
	}
}

func TestHostStage(t *testing.T) {
	h := func(c sys.Cmd) int {
		if len(c.Argv) > 2 && c.Argv[1] == "volume" {
			return 1
		}
		if c.Argv[0] == "/x/wallet-build" && c.Argv[1] == "perf" {
			return 1
		}
		return 0
	}
	r := runCLI(t, opts{handle: h, env: []string{"BW_RUN_DIR=", "BW_RUN_ID=", "BW_CMD=", "BW_COLD="}}, "stage")
	if r.code != 1 {
		t.Errorf("a failed sub-run fails the stage: %d", r.code)
	}
	var subs []string
	for _, c := range r.fake.Calls {
		if c.Argv[0] == "/x/wallet-build" {
			subs = append(subs, strings.Join(c.Argv[1:], " "))
			if c.Env.Get("BW_RUN_DIR") != "" || c.Env.Get("BW_RUN_ID") != "" || c.Env.Get("BW_CMD") != "" {
				t.Errorf("a sub-run must start its own run: %v", c.Env)
			}
		}
	}
	if strings.Join(subs, ",") != "test,desktop-test,web-test,perf" {
		t.Errorf("sub-runs %v", subs)
	}
	if !strings.Contains(r.out, "stage: emulator volumes missing, skipping emulator-screens") || !strings.Contains(r.out, "=== stage: perf ===") {
		t.Errorf("out:\n%s", r.out)
	}
	dir := runDirs(t, r)[0]
	sum := file(t, filepath.Join(dir, "stage-summary.txt"))
	lines := strings.Split(sum, "\n")
	for i, want := range []string{"test", "desktop-test", "web-test", "perf"} {
		f := strings.Fields(lines[i])
		if f[0] != want || f[2] != "s" {
			t.Errorf("row %d: %q", i, lines[i])
		}
	}
	if !strings.HasSuffix(strings.TrimSpace(lines[3]), "FAILED") || !strings.HasSuffix(strings.TrimSpace(lines[0]), "ok") {
		t.Errorf("rows: %q", lines[:4])
	}
	for _, want := range []string{"--- failing tests: none", "--- BUG: skips: none", "--- slowest 10 tests (tools/build-times.sh trend)"} {
		if !strings.Contains(sum, want) {
			t.Errorf("stage-summary.txt lacks %q:\n%s", want, sum)
		}
	}
	if strings.HasPrefix(r.out, sum[:10]) && !strings.Contains(r.out, sum) {
		t.Error("the summary is printed too")
	}
	if got := file(t, filepath.Join(dir, "perf.log")); !strings.HasPrefix(got, "# perf: sub-run ") || !strings.Contains(got, "failed steps: ") {
		t.Errorf("perf.log %q", got)
	}
	if st := strings.Fields(file(t, filepath.Join(dir, "perf.status"))); len(st) != 3 || st[1] != "1" {
		t.Errorf("perf.status %v", st)
	}
	// with the emulator volumes
	r = runCLI(t, opts{}, "stage")
	var names []string
	for _, c := range r.fake.Calls {
		names = append(names, strings.Join(c.Argv, " "))
	}
	if !strings.Contains(strings.Join(names, "\n"), r.root+"/tools/emulator.sh screens") {
		t.Errorf("emulator.sh screens not run:\n%s", strings.Join(names, "\n"))
	}
}

func TestHostRelayNativeTest(t *testing.T) {
	r := runCLI(t, opts{}, "relay-native-test", "debian")
	var seq []string
	for _, c := range r.fake.Calls {
		if c.Argv[0] == "/x/wallet-build" || strings.HasSuffix(c.Argv[0], "relay-native-test.sh") {
			seq = append(seq, strings.Join(c.Argv, " "))
		}
	}
	if len(seq) != 2 || seq[0] != "/x/wallet-build relay-bin x64" || seq[1] != r.root+"/tools/relay-native-test.sh debian" {
		t.Errorf("sequence %v", seq)
	}
	for _, c := range r.fake.Calls {
		if c.Argv[0] == "/x/wallet-build" && c.Env.Get("BW_RUN_DIR") == "" {
			t.Error("the nested relay-bin must join the run")
		}
	}
	dir := runDirs(t, r)[0]
	if _, err := os.Stat(filepath.Join(dir, "relay-native-test.log")); err != nil {
		t.Error("no relay-native-test.log")
	}
	if r.code != 0 {
		t.Errorf("code %d", r.code)
	}
}

func TestHostLspMcpExec(t *testing.T) {
	r := runCLI(t, opts{}, "lsp")
	if len(r.execs) != 1 {
		t.Fatalf("execs %v (calls %v)", r.execs, r.calls)
	}
	want := "podman run --rm --init --name wallet-build-wt-lsp-"
	if !strings.HasPrefix(r.execs[0], want) || !strings.Contains(r.execs[0], " -i -v "+r.root+":"+r.root+":z -v bw-pub-cache:/cache/pub -v bw-dart-server:/root/.dartServer -e BW_NATIVE=1 -w "+r.root+" "+imgPrefix) ||
		!strings.HasSuffix(r.execs[0], " "+r.root+"/dist/bin/wallet-build lsp") {
		t.Errorf("lsp: %s", r.execs[0])
	}
	if len(runDirs(t, r)) != 0 {
		t.Error("lsp keeps no run")
	}
	h := func(c sys.Cmd) int {
		if strings.HasSuffix(c.Argv[0], "live.sh") {
			c.Stdout.Write([]byte("budget-wallet-live-pod\n"))
		}
		return 0
	}
	r = runCLI(t, opts{handle: h}, "mcp", "--extra")
	if len(r.execs) != 1 || !strings.Contains(r.execs[0], " -i --pod budget-wallet-live-pod -v ") || !strings.Contains(r.execs[0], "-v bw-dart-state:/root/.local/state/Dart") ||
		!strings.HasSuffix(r.execs[0], "wallet-build mcp --extra") {
		t.Errorf("mcp: %v", r.execs)
	}
}

func TestHostSigintStopsContainer(t *testing.T) {
	sigs := make(chan os.Signal, 1)
	stopped := make(chan struct{})
	h := func(ctx context.Context, c sys.Cmd) int {
		if len(c.Argv) > 1 && c.Argv[0] == "podman" && c.Argv[1] == "run" {
			select {
			case <-stopped:
				return 143 // the container's init forwarded SIGTERM
			case <-ctx.Done():
				return 137
			}
		}
		if len(c.Argv) > 1 && c.Argv[1] == "stop" {
			close(stopped)
		}
		return 0
	}
	root := mkRepo(t)
	fake := &sys.Fake{HandleCtx: h}
	var out, errb strings.Builder
	data := t.TempDir()
	go func() { sigs <- syscall.SIGINT }()
	code := Run([]string{"core"}, []string{"PATH=/usr/bin", "HOME=" + t.TempDir(), "BW_DATA_DIR=" + data, "BW_COMMIT=c", "BW_WORKTREE=wt"}, &out, &errb, Deps{R: fake, Root: root, Self: "/x/wallet-build",
		HostSetup: func(hh *host.Host) { hh.Signals = func() (<-chan os.Signal, func()) { return sigs, func() {} } }})
	if code != 143 && code != 130 {
		t.Errorf("code %d", code)
	}
	var stop string
	var name string
	for _, c := range fake.Calls {
		if len(c.Argv) > 1 && c.Argv[1] == "stop" {
			stop = strings.Join(c.Argv, " ")
		}
		if len(c.Argv) > 1 && c.Argv[1] == "run" {
			for i, a := range c.Argv {
				if a == "--name" {
					name = c.Argv[i+1]
				}
			}
		}
	}
	if stop != "podman stop -t 10 "+name || name == "" {
		t.Errorf("stop %q name %q", stop, name)
	}
	dirs, _ := filepath.Glob(filepath.Join(data, "runs", "*"))
	if len(dirs) != 1 {
		t.Fatal(dirs)
	}
	if _, err := os.Stat(filepath.Join(dirs[0], ".running")); err == nil {
		t.Error(".running left after the interrupt")
	}
	if lf := file(t, filepath.Join(dirs[0], "last-failed.txt")); !strings.Contains(lf, "exit "+fmt.Sprint(code)) {
		t.Errorf("last-failed.txt %q", lf)
	}
}

func TestHostTimedLogTimesOut(t *testing.T) {
	stopped := make(chan struct{})
	h := func(ctx context.Context, c sys.Cmd) int {
		if len(c.Argv) > 1 && c.Argv[0] == "podman" && c.Argv[1] == "run" {
			select {
			case <-stopped:
			case <-ctx.Done():
			}
			return 143
		}
		if len(c.Argv) > 1 && c.Argv[1] == "stop" {
			close(stopped) // podman stop ends the container, and with it `podman run`
		}
		return 0
	}
	root := mkRepo(t)
	fake := &sys.Fake{HandleCtx: h}
	var out, errb strings.Builder
	data := t.TempDir()
	code := Run([]string{"shell", "-c", "sleep 99"}, []string{"PATH=/usr/bin", "HOME=" + t.TempDir(), "BW_DATA_DIR=" + data, "BW_COMMIT=c", "BW_WORKTREE=wt", "BW_TIMEOUT_SHELL=1"},
		&out, &errb, Deps{R: fake, Root: root, Self: "/x/wallet-build"})
	if code != 124 {
		t.Errorf("code %d", code)
	}
	dirs, _ := filepath.Glob(filepath.Join(data, "runs", "*"))
	log := file(t, filepath.Join(dirs[0], "shell.log"))
	if !strings.Contains(log, "# shell: timed out after 1 s\n# shell: finished ") || !strings.HasSuffix(log, "exit 124\n") {
		t.Errorf("log %q", log)
	}
	stops := 0
	for _, c := range fake.Calls {
		if len(c.Argv) > 3 && c.Argv[1] == "stop" && c.Argv[2] == "-t" && c.Argv[3] == "10" {
			stops++
		}
	}
	if stops != 1 {
		t.Errorf("a timed-out container must be stopped with podman stop -t 10: %d", stops)
	}
}
