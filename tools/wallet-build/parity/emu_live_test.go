//go:build parity

package parity

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

// GO2: parity cases for tools/emulator.sh and tools/live.sh (+ live_vm.py), the entry scripts of `wallet-build emulator`
// and `wallet-build live`. Same harness as GO1; the case's Script field names the entry script.

const (
	debugAPK       = "app/build/app/outputs/flutter-apk/app-debug.apk" // left by emulator screens/test; any APK installs
	emulatorScript = "tools/emulator.sh"
	liveScript     = "tools/live.sh"
	emulatorName   = "bw-emulator"
)

var (
	reURI       = regexp.MustCompile(`\b(?:https?|wss?)://\S+`)
	reKB        = regexp.MustCompile(`\b\d+ KB\b`)
	reShotName  = regexp.MustCompile(`shot-\d{6}\.png`)
	reFirstFrm  = regexp.MustCompile(` \(main\(\) to first frame: \d+ ms\)`)
	reLoopback  = regexp.MustCompile(`127\.0\.0\.1:\d+`)
	reTraceLine = regexp.MustCompile(`^(timeline:|\s*(build|raster)\b)`)
	reDigits    = regexp.MustCompile(`\d+(?:\.\d+)?`)
)

// maskNames: file names with the time-stamped screenshot name (shot-HHMMSS.png) replaced.
func maskNames(in []string) []string {
	out := make([]string, len(in))
	for i, n := range in {
		out[i] = reShotName.ReplaceAllString(n, "shot-<HMS>.png")
	}
	return out
}

// maskSeq masks what differs between two correct runs of a live/emulator command: times, the app's URIs (port and
// token change every start), file sizes, the optional "main() to first frame" figure, trace statistics.
func maskSeq(m *masker, s string) []string {
	var out []string
	for _, ln := range m.table(s) {
		if strings.TrimSpace(ln) == "" {
			continue
		}
		ln = reURI.ReplaceAllString(ln, "<URI>")
		ln = reLoopback.ReplaceAllString(ln, "<HOST:PORT>")
		ln = reKB.ReplaceAllString(ln, "<N> KB")
		ln = reShotName.ReplaceAllString(ln, "shot-<HMS>.png")
		ln = reFirstFrm.ReplaceAllString(ln, "")
		if reTraceLine.MatchString(ln) {
			ln = reDigits.ReplaceAllString(ln, "#")
		}
		out = append(out, ln)
	}
	return out
}

// seqLines: the comparable record of a Steps sequence: per step the command, the exit code, stdout and stderr (masked).
func seqLines(s *side) []string {
	var out []string
	for _, st := range s.steps {
		out = append(out, "$ "+strings.Join(st.args, " "), "exit "+strconv.Itoa(st.exit), "--- stdout")
		out = append(out, maskSeq(s.m, st.stdout)...)
		out = append(out, "--- stderr")
		out = append(out, maskSeq(s.m, st.stderr)...)
	}
	return out
}

// traceStructure: the trace summary with every number replaced (the figures follow the machine's load) and whitespace
// runs collapsed: the columns are padded to the number's width, so "p90=  12.3" and "p90=   3.2" are the same shape.
func traceStructure(txt string) []string {
	var out []string
	for _, ln := range lines(txt) {
		out = append(out, strings.Join(strings.Fields(reDigits.ReplaceAllString(ln, "#")), " "))
	}
	return out
}

// ---- preconditions ----

func podmanOK() string {
	if _, err := exec.LookPath("podman"); err != nil {
		return "podman not installed"
	}
	return ""
}

// waitEmulatorIdle: a previous case's `podman run --rm` container (or its emulator) may still hold the AVD lock in the
// writable bw-emulator-avd volume; wait up to 60 s until no container from the emulator image runs.
func waitEmulatorIdle(t testing.TB) {
	t.Helper()
	for i := 0; i < 30; i++ {
		out, err := exec.Command("podman", "ps", "--format", "{{.Image}}").Output()
		if err != nil || !strings.Contains(string(out), "budget-wallet-emu") {
			return
		}
		time.Sleep(2 * time.Second)
	}
	t.Logf("a container from the emulator image still runs after 60 s; the AVD may stay locked")
}

// logcat and flutter progress lines whose count and content follow timing.
var emuNoise = regexp.MustCompile(`^[VDIWEF]/\S.*\(\s*\d+\):|^\d\d:\d\d \+\d+|^flutter: |^VMServiceFlutterDriver: `)

func podmanHas(args ...string) bool {
	return exec.Command("podman", args...).Run() == nil
}

func liveName(repo string) string { return "bw-live-" + checkoutSlug(repo) }
func livePod(repo string) string  { return "bw-" + checkoutSlug(repo) }

// checkoutSlug is live.sh's `basename "$ROOT" | tr -c 'a-zA-Z0-9_.\n-' '-'`.
func checkoutSlug(repo string) string {
	var sb strings.Builder
	for _, r := range filepath.Base(repo) {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_', r == '.', r == '-', r == '\n':
			sb.WriteRune(r)
		default:
			sb.WriteRune('-')
		}
	}
	return sb.String()
}

// nothingRunning: the "not running" cases are only valid when no emulator and no live container of this checkout exist
// (the owner may be using them); they skip instead of touching them.
func nothingRunning(t *testing.T, repo string) string {
	if why := podmanOK(); why != "" {
		return why
	}
	if podmanHas("container", "exists", emulatorName) {
		return "container " + emulatorName + " exists (an emulator is running): the not-running cases would observe it"
	}
	if podmanHas("container", "exists", liveName(repo)) {
		return "container " + liveName(repo) + " exists (live mode is running): the not-running cases would observe it"
	}
	return ""
}

func emulatorVolumes(t *testing.T, repo string) string {
	if why := nothingRunning(t, repo); why != "" {
		return why
	}
	for _, v := range []string{"bw-emulator", "bw-emulator-image"} {
		if !podmanHas("volume", "exists", v) {
			return "podman volume " + v + " missing: the emulator is not set up on this machine (tools/emulator.sh screens sets it up, ~2 GB)"
		}
	}
	return ""
}

// ---- case builders ----

func mkS(script, name string, want int, args ...string) Case {
	c := mk(name, want, args...)
	c.Script = script
	return c
}

func notRunning(script, name string, want int, args ...string) Case {
	c := mkS(script, name, want, args...)
	c.CmpStderr = true
	c.SkipIf = nothingRunning
	c.Check = checkNoRunDir
	return c
}

func usageS(script, name string, args ...string) Case {
	c := mkS(script, name, 2, args...)
	c.CmpStderr = true
	c.SkipIf = nothingRunning // a usage error never reaches podman, but the pre-check keeps every GO2 case honest
	c.Check = checkNoRunDir
	return c
}

func quietS(script, name string, want int, env string, args ...string) Case {
	c := mkS(script, name, want, args...)
	c.Quiet = true
	c.SkipIf = nothingRunning
	if env != "" {
		c.Env = []string{env}
	}
	return c
}

// checkStepsInHistory: the history lines carry these steps in this order (as a subsequence), none FAILED.
func checkStepsInHistory(want ...string) func(t *testing.T, s *side) {
	return func(t *testing.T, s *side) {
		t.Helper()
		var got []string
		for _, j := range historyLines(s, "steps.jsonl") {
			// bash's log_history lines for the emulator's own steps (screens, <name>) carry no result; the field is
			// compared between the sides by the history diff. Only an explicit failure is an error here.
			if r := j.vals["result"]; r == `"FAILED"` {
				t.Errorf("%s steps.jsonl: step %s has result FAILED", s.impl, j.vals["step"])
			}
			got = append(got, strings.Trim(j.vals["step"], `"`))
		}
		i := 0
		for _, g := range got {
			if i < len(want) && g == want[i] {
				i++
			}
		}
		if i < len(want) {
			t.Errorf("%s steps.jsonl steps %v: missing %v (wanted this subsequence: %v)", s.impl, got, want[i:], want)
		}
	}
}

// checkRunFiles: each glob (relative to a run dir) matches in some run dir.
func checkRunFiles(want ...string) func(t *testing.T, s *side) {
	return func(t *testing.T, s *side) {
		t.Helper()
		if len(s.runs) == 0 {
			t.Errorf("%s: no run dir", s.impl)
			return
		}
		for _, w := range want {
			found := false
			for _, r := range s.runs {
				if m, _ := filepath.Glob(filepath.Join(r, w)); len(m) > 0 {
					found = true
				}
			}
			if !found {
				t.Errorf("%s: no run dir contains %s", s.impl, w)
			}
		}
	}
}

func chain(fs ...func(t *testing.T, s *side)) func(t *testing.T, s *side) {
	return func(t *testing.T, s *side) {
		for _, f := range fs {
			f(t, s)
		}
	}
}

// checkAllSteps: every invocation of a Steps case (or the single one) exited with want.
func checkAllSteps(want int) func(t *testing.T, s *side) {
	return func(t *testing.T, s *side) {
		t.Helper()
		for _, st := range s.steps {
			if st.exit != want {
				t.Errorf("%s: `%s` exit %d, want %d\nstderr: %s", s.impl, strings.Join(st.args, " "), st.exit, want, tail(st.stderr))
			}
		}
	}
}

// ---- cheap cases ----

func go2Cheap(t *testing.T, repo string) []Case {
	E, L := emulatorScript, liveScript
	out := []Case{
		// usage errors: exit 2, stdout and stderr compared, no run dir
		usageS(E, "emulator_usage_unknown_command", "no-such-command"),
		usageS(L, "live_usage_unknown_command", "no-such-command"),
		usageS(L, "live_usage_start_bad_flag", "start", "--no-such-flag"),
		usageS(L, "live_usage_start_headless_bad_flag", "start", "--headless", "--no-such-flag"),
		// -q and BW_QUIET=1: emulator.sh prints nothing at all
		quietS(E, "emulator_quiet_flag_unknown_command", 2, "", "-q", "no-such-command"),
		quietS(E, "emulator_quiet_long_flag_unknown_command", 2, "", "--quiet", "no-such-command"),
		quietS(E, "emulator_quiet_env_unknown_command", 2, "BW_QUIET=1", "no-such-command"),
		quietS(E, "emulator_quiet_flag_stop", 0, "", "-q", "stop"),
		quietS(E, "emulator_quiet_env_stop", 0, "BW_QUIET=1", "stop"),
		quietS(E, "emulator_quiet_flag_adb_not_running", 1, "", "-q", "adb", "devices"),
		// emulator.sh with nothing running (reset is deliberately absent: with nothing running it would delete the real
		// bw-emulator* volumes; "refused while running" needs a running emulator)
		notRunning(E, "emulator_stop_not_running", 0, "stop"),
		notRunning(E, "emulator_adb_not_running", 1, "adb", "devices"),
		notRunning(E, "emulator_shot_not_running", 1, "shot", "x"),
		notRunning(E, "emulator_shot_no_name_not_running", 1, "shot"),
		notRunning(E, "emulator_install_not_running", 1, "install"),
		// live.sh with nothing running
		notRunning(L, "live_status_not_running", 0, "status"),
		notRunning(L, "live_no_args_is_status", 0),
		notRunning(L, "live_stop_not_running", 0, "stop"),
		notRunning(L, "live_reload_not_running", 1, "reload"),
		notRunning(L, "live_restart_not_running", 1, "restart"),
		notRunning(L, "live_shot_not_running", 1, "shot"),
		notRunning(L, "live_shot_file_not_running", 1, "shot", "dist/screens/parity-live-none.png"),
		notRunning(L, "live_trace_start_not_running", 1, "trace", "start"),
		notRunning(L, "live_trace_stop_not_running", 1, "trace", "stop", "t"),
		{Name: "live_pod", WantExit: -1, Custom: livePodCase, SkipIf: podSkip},
	}
	// live.sh has no -q in bash (its header lists none): `-q` is an unknown command there (usage, exit 2) and BW_QUIET=1
	// is ignored. These two cases compare whatever bash does with the Go port; they do not assert zero bytes.
	qf := mkS(L, "live_quiet_flag_status_parity", -1, "-q", "status")
	qf.CmpStderr, qf.SkipIf = true, nothingRunning
	qe := mkS(L, "live_quiet_env_status_parity", -1, "status")
	qe.Env, qe.CmpStderr, qe.SkipIf = []string{"BW_QUIET=1"}, true, nothingRunning
	return append(out, qf, qe)
}

// podSkip: live.sh pod creates the checkout's pod, which the dart MCP server may be using: only run when it is absent.
func podSkip(t *testing.T, repo string) string {
	if why := podmanOK(); why != "" {
		return why
	}
	if podmanHas("pod", "exists", livePod(repo)) {
		return "pod " + livePod(repo) + " exists (the MCP server may be using it): not touched"
	}
	return ""
}

// livePodCase: `live.sh pod` prints the pod name and leaves the pod behind. The pod this case created is removed after
// each side (podSkip ensured it did not exist before, and the name is this checkout's own).
func livePodCase(t *testing.T, repo, impl string) []string {
	t.Helper()
	pod := livePod(repo)
	rm := func() { _ = exec.Command("podman", "pod", "rm", "-f", pod).Run() }
	t.Cleanup(rm)
	data := t.TempDir()
	cmd := exec.Command(filepath.Join(repo, liveScript), "pod")
	cmd.Dir = repo
	cmd.Env = buildEnv(data, impl, nil)
	out, err := cmd.Output()
	res := []string{"exit " + strconv.Itoa(exitCode(t, err))}
	for _, ln := range lines(string(out)) {
		res = append(res, "stdout: "+ln)
	}
	if got := strings.TrimSpace(string(out)); got != pod {
		t.Errorf("%s: live.sh pod printed %q, want the pod name %q", impl, got, pod)
	}
	if podmanHas("pod", "exists", pod) {
		res = append(res, "pod exists afterwards")
	} else {
		res = append(res, "no pod afterwards")
	}
	if entries, _ := os.ReadDir(filepath.Join(data, "runs")); len(entries) != 0 {
		res = append(res, "created a run dir")
	}
	rm()
	return res
}

// ---- heavy cases ----

func go2Heavy(t *testing.T, repo string) []Case {
	h := func(c Case) Case { c.Heavy = true; return c }
	E, L := emulatorScript, liveScript
	var out []Case

	screens := mkS(E, "emulator_screens", 0, "screens")
	screens.Artifacts = []string{"dist/screens"}
	screens.SkipIf = emulatorVolumes
	screens.StdoutDrop = emuNoise
	screens.Check = chain(checkAllSteps(0), checkRunFiles("emulator-screens.log", "emulator.log", "*.png"), // screens copies dist/screens/*.png to the run dir root
		checkStepsInHistory("prepare", "boot", "build", "total"))
	out = append(out, h(screens))

	// A file that runs on Android: the smallest one by size can be desktop-only (chart_dpr skips every test there, and
	// flutter drive then waits for the driver extension without end). onboarding runs on both, ~60 s on the emulator.
	if small := []string{"onboarding"}; fileExists(filepath.Join(repo, "app/integration_test/onboarding_test.dart")) {
		et := mkS(E, "emulator_test_one_small_file", 0, "test", small[0])
		et.Artifacts = []string{"dist/screens/" + small[0]}
		et.SkipIf = emulatorVolumes
		et.StdoutDrop = emuNoise
		et.Check = chain(checkAllSteps(0), checkRunFiles("emulator-test.log", "drive-"+small[0]+".log", "tests-"+small[0]+"-summary.txt", "screens/*"),
			checkStepsInHistory("prepare", "boot", "build", "install", "test-"+small[0], small[0], "total"))
		out = append(out, h(et))
	}

	// start -> install -> shot -> adb -> stop, one container at a time; needs the APK from `tools/build.sh apk`.
	sis := mkS(E, "emulator_start_install_shot_stop", 0)
	sis.Steps = [][]string{{"start"}, {"install", debugAPK}, {"shot", "parity_x"}, {"adb", "shell", "echo", "parity"}, {"stop"}}
	sis.Cleanup = [][]string{{"stop"}}
	sis.Artifacts = []string{"dist/screens/parity_x.png"}
	sis.SkipIf = func(t *testing.T, repo string) string {
		if why := emulatorVolumes(t, repo); why != "" {
			return why
		}
		if _, err := os.Stat(filepath.Join(repo, "app", "build", "app", "outputs", "flutter-apk", "app-debug.apk")); err != nil {
			return "no app/build/app/outputs/flutter-apk/app-debug.apk (emulator_screens or a debug build makes it)"
		}
		return ""
	}
	sis.Check = chain(checkAllSteps(0), checkStepsInHistory("prepare", "emulator-install"), func(t *testing.T, s *side) {
		for _, st := range s.steps {
			if len(st.args) > 0 && st.args[0] == "stop" && strings.TrimSpace(st.stdout) != "stopped" {
				t.Errorf("%s: stop printed %q, want \"stopped\"", s.impl, st.stdout)
			}
		}
		if png, err := os.ReadFile(filepath.Join(s.repo, "dist", "screens", "parity_x.png")); err != nil || !strings.HasPrefix(string(png), "\x89PNG") {
			t.Errorf("%s: dist/screens/parity_x.png is missing or not a PNG", s.impl)
		}
	})
	out = append(out, h(sis))

	// Headless only: never a window on the owner's desktop (and so never the Wayland socket or X11 of the host).
	live := mkS(L, "live_headless_demo_session", 0)
	live.Steps = [][]string{
		{"start", "--headless", "--demo", "--fresh"}, {"reload"}, {"restart"}, {"shot"},
		{"trace", "start"}, {"trace", "stop", "t"}, {"status"}, {"stop"},
	}
	live.Cleanup = [][]string{{"stop"}}
	live.Artifacts = []string{"dist/screens/live.png"}
	live.SkipIf = nothingRunning
	live.Check = chain(checkAllSteps(0), checkStepsInHistory("live-start", "live-reload", "live-restart"),
		checkRunFiles("flutter-run.jsonl", "app-live.log", "shot-*.png", "trace-t.json", "trace-t-summary.txt"), checkLiveFiles)
	out = append(out, h(live))
	return out
}

func checkLiveFiles(t *testing.T, s *side) {
	t.Helper()
	for _, r := range s.runs {
		if b, err := os.ReadFile(filepath.Join(r, "trace-t.json")); err == nil {
			var v struct {
				TraceEvents []json.RawMessage `json:"traceEvents"`
				Unit        string            `json:"displayTimeUnit"`
			}
			if err := json.Unmarshal(b, &v); err != nil || v.Unit != "ms" || v.TraceEvents == nil {
				t.Errorf("%s: trace-t.json is not {traceEvents, displayTimeUnit:\"ms\"}: %v", s.impl, err)
			}
		}
		if m, _ := filepath.Glob(filepath.Join(r, "shot-*.png")); len(m) > 0 {
			if b, _ := os.ReadFile(m[0]); !strings.HasPrefix(string(b), "\x89PNG") {
				t.Errorf("%s: %s is not a PNG", s.impl, filepath.Base(m[0]))
			}
		}
		if b, err := os.ReadFile(filepath.Join(r, "flutter-run.jsonl")); err == nil && len(b) == 0 {
			t.Errorf("%s: flutter-run.jsonl is empty", s.impl)
		}
	}
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}
