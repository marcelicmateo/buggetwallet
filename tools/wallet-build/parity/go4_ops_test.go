//go:build parity

package parity

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image/png"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// ---------------- relay (tools/relay.sh) ----------------

func TestGO4Relay(t *testing.T) {
	mk := func(name string, args ...string) g4 {
		c := g4mk(name, append([]string{"tools/relay.sh"}, args...), append([]string{"relay"}, args...))
		c.fakes = []string{"podman"}
		return c
	}
	status := mk("relay_status_nothing_running", "status")
	status.want = 0
	status.check = func(t *testing.T, sb *sandbox, r *g4res) {
		if !strings.Contains(r.out, "not running") {
			t.Errorf("%s: status with nothing running must say 'not running':\n%s", sb.impl, r.out)
		}
	}
	stop := mk("relay_stop_nothing_running", "stop")
	stop.want = 0
	logs := mk("relay_logs_nothing_running", "logs")
	logs.exitOnly = true // podman's own error text differs by who calls it; exit code must agree
	badPort := mk("relay_bad_port", "status")
	badPort.env = []string{"BW_RELAY_PORT=abc"}
	badPort.want = 2
	resetNo := mk("relay_reset_declined", "reset")
	resetNo.stdin = "n\n"
	resetNo.prep = func(t *testing.T, sb *sandbox) { sb.write(filepath.Join(sb.data, "relay", "keep.txt"), "x") }
	resetNo.files = []string{"data/relay/keep.txt"}
	resetNo.want = 1
	resetYes := mk("relay_reset_confirmed_by_env", "reset")
	resetYes.env = []string{"BW_YES=1"}
	resetYes.prep = resetNo.prep
	resetYes.files = []string{"data/relay/*"}
	resetYes.want = 0
	resetYes.check = func(t *testing.T, sb *sandbox, r *g4res) {
		if _, err := os.Stat(filepath.Join(sb.data, "relay")); err == nil {
			t.Errorf("%s: reset must delete the relay data folder inside BW_DATA_DIR", sb.impl)
		}
	}
	for _, c := range []g4{status, stop, logs, badPort, resetNo, resetYes} {
		t.Run(c.name, func(t *testing.T) { runG4(t, c) })
	}
}

// Heavy: a real relay container on a free port with a temp data dir. Never `reset` anything but that temp dir.
func TestGO4RelayLifecycle(t *testing.T) {
	if os.Getenv(heavyEnv) != "1" {
		t.Skipf("heavy case (builds the relay image, starts a container): set %s=1", heavyEnv)
	}
	if _, err := exec.LookPath("podman"); err != nil {
		t.Skip("podman missing")
	}
	repo := repoRoot(t)
	if out, _ := exec.Command("podman", "inspect", "-f", "{{.State.Running}}", "bw-relay").Output(); strings.TrimSpace(string(out)) == "true" {
		t.Skip("a bw-relay container is already running (the owner's relay): not touching it")
	}
	bin := ""
	if goSide() {
		if bin = wbBinary(repo); bin == "" {
			t.Skip("dist/bin/wallet-build not built")
		}
	}
	var outs [2][]string
	for i, impl := range []string{"bash", implName()} {
		data, port := t.TempDir(), freePort(t)
		env := append(sanitizedEnv(), fmt.Sprintf("BW_DATA_DIR=%s", data), fmt.Sprintf("BW_RELAY_PORT=%d", port), "BW_YES=1")
		call := func(args ...string) (string, string, int) {
			if impl == "bash" {
				return runSimple(t, repo, env, filepath.Join(repo, "tools", "relay.sh"), args...)
			}
			return runSimple(t, repo, env, bin, append([]string{"relay"}, args...)...)
		}
		t.Cleanup(func() { runSimple(t, repo, env, filepath.Join(repo, "tools", "relay.sh"), "stop") })
		mask := func(s string) string {
			s = strings.ReplaceAll(s, fmt.Sprint(port), "<PORT>")
			return strings.ReplaceAll(s, data, "<DATA>")
		}
		steps := [][]string{{"start"}, {"status"}, {"start"}, {"logs"}, {"stop"}, {"status"}}
		for _, st := range steps {
			so, se, rc := call(st...)
			line := fmt.Sprintf("%s: exit %d", strings.Join(st, " "), rc)
			if st[0] != "logs" && st[0] != "status" { // log lines and the health answer follow timing
				line += " | " + mask(strings.TrimSpace(so))
			}
			if st[0] == "status" {
				line += " | " + strings.SplitN(mask(strings.TrimSpace(so)), ":", 2)[0]
			}
			if st[0] == "logs" && strings.TrimSpace(so+se) == "" {
				line += " | EMPTY LOG"
			}
			outs[i] = append(outs[i], line)
		}
		if _, err := os.Stat(filepath.Join(data, "relay")); err != nil {
			t.Errorf("%s: start must create <BW_DATA_DIR>/relay", impl)
		}
		if out, _ := exec.Command("podman", "ps", "-a", "--filter", "name=^bw-relay$", "--format", "{{.Names}}").Output(); strings.TrimSpace(string(out)) != "" {
			t.Errorf("%s: the bw-relay container is left after stop", impl)
		}
	}
	diffLines(t, "relay_lifecycle", "steps", outs[0], outs[1])
}

func sanitizedEnv() []string {
	var env []string
	for _, e := range os.Environ() {
		if !strings.HasPrefix(e, "BW_") {
			env = append(env, e)
		}
	}
	return env
}

// ---------------- web (tools/web.sh) ----------------

func TestGO4Web(t *testing.T) {
	mk := func(name string, args ...string) g4 {
		c := g4mk(name, append([]string{"tools/web.sh"}, args...), append([]string{"web"}, args...))
		c.sbRepo, c.tools, c.fakes = true, []string{"web.sh", "timing.sh"}, []string{"podman"}
		return c
	}
	withBuild := func(c g4) g4 {
		c.prep = func(t *testing.T, sb *sandbox) {
			sb.write(filepath.Join(sb.repo, "dist", "web", "index.html"), "<!doctype html><title>synthetic</title>\n")
		}
		return c
	}
	status := mk("web_status_nothing_running", "status")
	status.want = 0
	status.check = func(t *testing.T, sb *sandbox, r *g4res) {
		if !strings.Contains(r.out, "not running") {
			t.Errorf("%s: want 'not running':\n%s", sb.impl, r.out)
		}
	}
	stop := mk("web_stop_nothing_running", "stop")
	stop.want = 0
	stopStale := mk("web_stop_removes_stale_pidfile", "stop")
	stopStale.prep = func(t *testing.T, sb *sandbox) {
		sb.write(filepath.Join(sb.repo, "dist", "web-serve.pid"), "999999 http://127.0.0.1:1/ (log x)\n")
	}
	stopStale.check = func(t *testing.T, sb *sandbox, r *g4res) {
		if _, err := os.Stat(filepath.Join(sb.repo, "dist", "web-serve.pid")); err == nil {
			t.Errorf("%s: stop must remove the pid file", sb.impl)
		}
	}
	statusStale := mk("web_status_stale_pidfile_is_not_running", "status")
	statusStale.prep = stopStale.prep
	statusStale.want = 0
	badPort := mk("web_serve_bad_port", "serve", "abc")
	badPort.want, badPort.exitOnly = 2, true
	noBuild := mk("web_serve_without_build", "serve", "18999")
	noBuild.want = 1
	shotNoBuild := mk("web_shot_without_build", "shot", "/", "{WORK}/o.png")
	shotNoBuild.want = 1
	shotArgs := withBuild(mk("web_shot_missing_args", "shot", "/"))
	shotArgs.want, shotArgs.exitOnly = 2, true
	shotSize := withBuild(mk("web_shot_bad_size", "shot", "/", "{WORK}/o.png", "12x"))
	shotSize.want, shotSize.exitOnly = 2, true
	for _, c := range []g4{status, stop, stopStale, statusStale, badPort, noBuild, shotNoBuild, shotArgs, shotSize} {
		t.Run(c.name, func(t *testing.T) { runG4(t, c) })
	}
}

// Heavy: the loopback file server (index.html and a .wasm file: same bytes, same media type), then stop; and a screenshot.
func TestGO4WebServe(t *testing.T) {
	if os.Getenv(heavyEnv) != "1" {
		t.Skipf("heavy case: set %s=1", heavyEnv)
	}
	repo := repoRoot(t)
	bin := ""
	if goSide() {
		if bin = wbBinary(repo); bin == "" {
			t.Skip("dist/bin/wallet-build not built")
		}
	}
	wasm := []byte("\x00asm\x01\x00\x00\x00synthetic")
	type got struct {
		code            int
		mediaType, body string
	}
	var res [2]map[string]got
	for i, impl := range []string{"bash", implName()} {
		c := g4mk("web_serve", []string{"tools/web.sh"}, []string{"web"})
		c.sbRepo, c.tools = true, []string{"web.sh", "timing.sh"}
		c.prep = func(t *testing.T, sb *sandbox) {
			sb.write(filepath.Join(sb.repo, "dist", "web", "index.html"), "<!doctype html><title>synthetic</title>\n")
			sb.write(filepath.Join(sb.repo, "dist", "web", "app.wasm"), string(wasm))
		}
		sb := c.setup(t, impl, repo, bin)
		port := freePort(t)
		call := func(args ...string) (string, string, int) {
			var argv []string
			if impl == "bash" {
				argv = append([]string{filepath.Join(sb.repo, "tools", "web.sh")}, args...)
			} else {
				argv = append([]string{sb.bin, "web"}, args...)
			}
			return runSimple(t, sb.repo, sb.env(c), argv[0], argv[1:]...)
		}
		t.Cleanup(func() { call("stop") })
		so, se, rc := call("serve", fmt.Sprint(port))
		if rc != 0 {
			t.Fatalf("%s: serve: exit %d\n%s\n%s", impl, rc, so, se)
		}
		res[i] = map[string]got{}
		for _, p := range []string{"/", "/index.html", "/app.wasm", "/missing.txt"} {
			resp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d%s", port, p))
			if err != nil {
				t.Fatalf("%s GET %s: %v", impl, p, err)
			}
			b, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			mt := strings.TrimSpace(strings.SplitN(resp.Header.Get("Content-Type"), ";", 2)[0])
			res[i][p] = got{resp.StatusCode, mt, string(b)}
			t.Logf("%s GET %s -> %d %q", impl, p, resp.StatusCode, resp.Header.Get("Content-Type"))
		}
		if g := res[i]["/app.wasm"]; g.body != string(wasm) || g.mediaType != "application/wasm" {
			t.Errorf("%s: /app.wasm served as %q with %d bytes", impl, g.mediaType, len(g.body))
		}
		st, _, _ := call("status")
		if !strings.Contains(st, "running") || strings.Contains(st, "not running") {
			t.Errorf("%s: status after serve: %q", impl, st)
		}
		if so2, _, rc2 := call("serve", fmt.Sprint(port)); rc2 != 0 || !strings.Contains(so2, "already running") {
			t.Errorf("%s: serve twice: exit %d, stdout %q (want 0 and 'already running')", impl, rc2, so2)
		}
		if so3, _, rc3 := call("stop"); rc3 != 0 || strings.TrimSpace(so3) != "stopped" {
			t.Errorf("%s: stop: exit %d, stdout %q", impl, rc3, so3)
		}
		if _, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/", port)); err == nil {
			t.Errorf("%s: still answering after stop", impl)
		}
	}
	for p, a := range res[0] {
		b := res[1][p]
		if a.code != b.code || a.mediaType != b.mediaType || a.body != b.body {
			t.Errorf("GET %s: bash {%d %s %d bytes} vs %s {%d %s %d bytes}", p, a.code, a.mediaType, len(a.body), implName(), b.code, b.mediaType, len(b.body))
		}
	}
}

func TestGO4WebShot(t *testing.T) {
	if os.Getenv(heavyEnv) != "1" {
		t.Skipf("heavy case (Chrome in the build container): set %s=1", heavyEnv)
	}
	repo := repoRoot(t)
	if _, err := os.Stat(filepath.Join(repo, "dist", "web", "index.html")); err != nil {
		t.Skip("no dist/web (tools/build.sh web)")
	}
	bin := ""
	if goSide() {
		if bin = wbBinary(repo); bin == "" {
			t.Skip("dist/bin/wallet-build not built")
		}
	}
	for _, impl := range []string{"bash", implName()} {
		out := filepath.Join(t.TempDir(), "shot.png")
		var argv []string
		if impl == "bash" {
			argv = []string{filepath.Join(repo, "tools", "web.sh"), "shot", "/", out, "360x640"}
		} else {
			argv = []string{bin, "web", "shot", "/", out, "360x640"}
		}
		so, se, rc := runSimple(t, repo, sanitizedEnv(), argv[0], argv[1:]...)
		if rc != 0 {
			t.Fatalf("%s: shot exit %d\n%s\n%s", impl, rc, tail(so), tail(se))
		}
		b, err := os.ReadFile(out)
		if err != nil {
			t.Fatalf("%s: no screenshot: %v", impl, err)
		}
		cfg, err := png.DecodeConfig(bytes.NewReader(b))
		if err != nil {
			t.Fatalf("%s: not a PNG: %v", impl, err)
		}
		if cfg.Width != 360 || cfg.Height != 640 {
			t.Errorf("%s: screenshot is %dx%d, want 360x640", impl, cfg.Width, cfg.Height)
		}
		if !strings.Contains(so, "screenshot: "+out) {
			t.Errorf("%s: stdout lacks 'screenshot: <path>': %q", impl, so)
		}
	}
}

// ---------------- relay-native-check ----------------

func TestGO4RelayNativeCheck(t *testing.T) {
	nat := "relay/deploy/native"
	edit := func(file string, fn func(string) string) func(*testing.T, *sandbox) {
		return func(t *testing.T, sb *sandbox) {
			p := filepath.Join(sb.repo, nat, file)
			b, err := os.ReadFile(p)
			if err != nil {
				t.Fatal(err)
			}
			n := fn(string(b))
			if n == string(b) {
				t.Fatalf("edit of %s changed nothing: the broken-invariant case would prove nothing", file)
			}
			if err := os.WriteFile(p, []byte(n), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	mk := func(name string, want int, prep func(*testing.T, *sandbox)) g4 {
		c := g4mk(name, []string{"tools/relay-native-check.sh"}, []string{"relay-native-check"})
		c.sbRepo, c.tools, c.trees, c.prep, c.want = true, []string{"relay-native-check.sh"}, []string{nat}, prep, want
		return c
	}
	svc := "bw-relay.service"
	cases := []g4{
		mk("native_check_real_files_pass", 0, nil),
		mk("native_check_listen_on_all_interfaces", 1, edit(svc, func(s string) string { return strings.ReplaceAll(s, "--host 127.0.0.1", "--host 0.0.0.0") })),
		mk("native_check_no_trust_proxy", 1, edit(svc, func(s string) string { return strings.ReplaceAll(s, "--trust-proxy", "") })),
		mk("native_check_token_not_from_credential", 1, edit(svc, func(s string) string {
			return strings.ReplaceAll(s, "LoadCredential=create-token:", "Environment=create-token:")
		})),
		mk("native_check_caddy_wrong_upstream", 1, edit("Caddyfile", func(s string) string { return strings.ReplaceAll(s, "127.0.0.1:8787", "127.0.0.1:9999") })),
		mk("native_check_secret_in_env_template", 1, edit("bw-relay.env.example", func(s string) string { return s + "\nBW_CREATE_TOKEN=hunter2\n" })),
		mk("native_check_line_not_key_value", 1, edit(svc, func(s string) string { return s + "\nthis line is not a setting\n" })),
		mk("native_check_missing_sysusers", 1, func(t *testing.T, sb *sandbox) {
			if err := os.Remove(filepath.Join(sb.repo, nat, "bw-relay.sysusers")); err != nil {
				t.Fatal(err)
			}
		}),
		mk("native_check_two_things_broken", 1, func(t *testing.T, sb *sandbox) {
			edit(svc, func(s string) string { return strings.ReplaceAll(s, "--host 127.0.0.1", "--host 0.0.0.0") })(t, sb)
			edit("Caddyfile", func(s string) string { return strings.ReplaceAll(s, "127.0.0.1:8787", "127.0.0.1:9999") })(t, sb)
		}),
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, err := exec.LookPath("systemd-analyze"); err != nil {
				t.Log("systemd-analyze missing: both sides do the syntax-only check")
			}
			runG4(t, c)
		})
	}
}

// ---------------- signing-key (temp BW_SIGNING_DIR only, never --upload) ----------------

var (
	rePassLine = regexp.MustCompile(`(?m)^(BW_(?:KEYSTORE|KEY)_PASSWORD)=.*$`)
)

func TestGO4SigningKey(t *testing.T) {
	skip := func(t *testing.T) string {
		if _, err := exec.LookPath("keytool"); err != nil {
			return "keytool missing on the host (the container is not used here)"
		}
		return ""
	}
	mk := func(name string) g4 {
		c := g4mk(name, []string{"tools/make-signing-key.sh"}, []string{"signing-key"})
		c.env = []string{"BW_SIGNING_DIR={SB}/keys"}
		c.skip = skip
		c.dirs = []string{"keys"}
		c.mask = func(s string) string {
			s = reFingerprint.ReplaceAllString(s, "SHA256: <FP>")
			return rePassLine.ReplaceAllString(s, "$1=<PW>")
		}
		return c
	}
	secretsStayHidden := func(t *testing.T, sb *sandbox, r *g4res) {
		b, err := os.ReadFile(filepath.Join(sb.root, "keys", "signing.env"))
		if err != nil {
			return
		}
		for _, m := range regexp.MustCompile(`(?m)^BW_[A-Z_]*PASSWORD=(.+)$`).FindAllStringSubmatch(string(b), -1) {
			if strings.Contains(r.out, m[1]) || strings.Contains(r.errOut, m[1]) {
				t.Errorf("%s: the password value appears on stdout/stderr", sb.impl)
			}
		}
	}
	fresh := mk("signing_key_fresh")
	fresh.want = 0
	fresh.files = []string{"keys/signing.env"}
	fresh.check = func(t *testing.T, sb *sandbox, r *g4res) {
		secretsStayHidden(t, sb, r)
		env, err := os.ReadFile(filepath.Join(sb.root, "keys", "signing.env"))
		if err != nil {
			t.Fatalf("%s: no env file: %v", sb.impl, err)
		}
		kv := map[string]string{}
		var order []string
		for _, l := range strings.Split(strings.TrimSpace(string(env)), "\n") {
			k, v, _ := strings.Cut(l, "=")
			kv[k] = v
			order = append(order, k)
		}
		if strings.Join(order, ",") != "BW_KEY_ALIAS,BW_KEYSTORE_PASSWORD,BW_KEY_PASSWORD" {
			t.Errorf("%s: env file keys %v", sb.impl, order)
		}
		if kv["BW_KEY_ALIAS"] != "budget-wallet" {
			t.Errorf("%s: alias %q", sb.impl, kv["BW_KEY_ALIAS"])
		}
		if kv["BW_KEYSTORE_PASSWORD"] != kv["BW_KEY_PASSWORD"] || !regexp.MustCompile(`^[A-Za-z0-9]{16,40}$`).MatchString(kv["BW_KEYSTORE_PASSWORD"]) {
			t.Errorf("%s: password must be one alphanumeric value of 16-40 chars (old: 24 random bytes, base64 without / + =)", sb.impl)
		}
		// the keystore opens with it and holds the alias
		out, err := exec.Command("keytool", "-list", "-keystore", filepath.Join(sb.root, "keys", "android-release.jks"),
			"-storepass", kv["BW_KEYSTORE_PASSWORD"]).CombinedOutput()
		if err != nil || !strings.Contains(string(out), "budget-wallet") {
			t.Errorf("%s: keytool -list failed: %v\n%s", sb.impl, err, out)
		}
		if !regexp.MustCompile(`(?m)^Certificate SHA256: [0-9A-F:]+$`).MatchString(r.out) {
			t.Errorf("%s: stdout has no 'Certificate SHA256: …' line:\n%s", sb.impl, r.out)
		}
	}
	// an existing key is never overwritten
	existing := mk("signing_key_refuses_to_overwrite_existing")
	existing.prep = func(t *testing.T, sb *sandbox) {
		sb.write("keys/android-release.jks", "not a keystore\n")
		sb.write("keys/signing.env", "BW_KEY_ALIAS=x\nBW_KEYSTORE_PASSWORD=pw\nBW_KEY_PASSWORD=pw\n")
	}
	existing.files = []string{"keys/*"}
	existing.check = func(t *testing.T, sb *sandbox, r *g4res) {
		secretsStayHidden(t, sb, r)
		if !strings.Contains(r.out, "already exists") {
			t.Errorf("%s: want the 'already exists … not overwriting' message on stdout:\nstdout: %s\nstderr: %s", sb.impl, r.out, r.errOut)
		}
		if b, _ := os.ReadFile(filepath.Join(sb.root, "keys", "android-release.jks")); string(b) != "not a keystore\n" {
			t.Errorf("%s: the existing keystore was overwritten", sb.impl)
		}
		if b, _ := os.ReadFile(filepath.Join(sb.root, "keys", "signing.env")); !strings.Contains(string(b), "BW_KEYSTORE_PASSWORD=pw") {
			t.Errorf("%s: the existing env file was overwritten", sb.impl)
		}
	}
	onlyKeystore := mk("signing_key_refuses_when_only_keystore_exists")
	onlyKeystore.prep = func(t *testing.T, sb *sandbox) { sb.write("keys/android-release.jks", "not a keystore\n") }
	onlyKeystore.exitOnly = true // the message is grep's own error text in bash
	onlyKeystore.check = func(t *testing.T, sb *sandbox, r *g4res) {
		if _, err := os.Stat(filepath.Join(sb.root, "keys", "signing.env")); err == nil {
			t.Errorf("%s: wrote an env file next to an existing keystore", sb.impl)
		}
	}
	// a second run on a real key changes nothing and still prints the certificate
	again := mk("signing_key_second_run_keeps_key")
	again.want = 0
	again.files = []string{"keys/signing.env"}
	again.check = func(t *testing.T, sb *sandbox, r *g4res) {
		secretsStayHidden(t, sb, r)
		argv := again.argv(sb, sb.impl)
		before, _ := os.ReadFile(filepath.Join(sb.root, "keys", "android-release.jks"))
		so, _, rc := runSimple(t, sb.work, sb.env(again), argv[0], argv[1:]...)
		after, _ := os.ReadFile(filepath.Join(sb.root, "keys", "android-release.jks"))
		if rc != 0 || !bytes.Equal(before, after) || !strings.Contains(so, "already exists") || !strings.Contains(so, "Certificate SHA256:") {
			t.Errorf("%s: second run: exit %d, keystore changed=%v, stdout %q", sb.impl, rc, !bytes.Equal(before, after), so)
		}
	}
	for _, c := range []g4{fresh, existing, onlyKeystore, again} {
		t.Run(c.name, func(t *testing.T) { runG4(t, c) })
	}
}

// ---------------- hook no-poll ----------------

func TestGO4HookNoPoll(t *testing.T) {
	hook := func(cmd string) string { return jsonLine(map[string]any{"tool_input": map[string]any{"command": cmd}}) }
	type hc struct{ name, stdin string }
	cases := []hc{
		{"sleep_5_alone", hook("sleep 5")},
		{"until_loop", hook("until grep -q done log; do sleep 5; done")},
		{"until_loop_multiline", hook("until grep -q done log; do\n  sleep 5\ndone")},
		{"while_true_sleep", hook("while true; do sleep 1; done")},
		{"while_not_curl_sleep", hook("while ! curl -s localhost:8787; do sleep 2; done")},
		{"sleep_in_background_command", hook("sleep 30 &")},
		{"sleep_background_with_wait", hook("(sleep 30; echo done) & wait")},
		{"timeout_wrapping_until", hook(`timeout 300 bash -c "until test -f x; do :; done"`)},
		{"timeout_minutes_wrapping_while", hook(`timeout 5m sh -c "while :; do :; done"`)},
		{"timeout_around_build", hook("timeout 120 tools/build.sh test")},
		{"timeout_flag_not_command", hook("tools/build.sh app --timeout 60 until")},
		{"word_before_timeout_is_not_timeout", hook(`mytimeout 5 bash -c "until true; do :; done"`)},
		{"dash_timeout_is_not_timeout", hook(`foo -timeout 5 bash -c "while true; do :; done"`)},
		{"timeout_then_later_loop", hook("timeout 5 x; while true; do :; done")},
		{"word_sleep_in_string", hook(`echo "good sleep tonight"`)},
		{"word_sleep_in_commit_message", hook(`git commit -m "fix: no sleep needed in the test"`)},
		{"until_and_sleep_words_in_string", hook(`echo "wait until you sleep"`)},
		{"while_and_sleep_words_in_string", hook(`echo "while you sleep"`)},
		{"grep_for_until", hook("grep -rn until docs")},
		{"pipe_into_while_read", hook(`tools/build.sh app --timeout 60s | while read -r l; do echo "$l"; done`)},
		{"harmless_ls", hook("ls -la")},
		{"empty_command", hook("")},
		{"no_command_key", jsonLine(map[string]any{"tool_input": map[string]any{}})},
		{"no_tool_input", jsonLine(map[string]any{"other": 1})},
		{"empty_stdin", ""},
		{"not_json", "while true; do sleep 1; done\n"},
		{"json_array", "[1,2,3]\n"},
		{"unicode_command", hook("echo čćžšđ; while true; do sleep 1; done")},
		{"tab_and_newline_separated", hook("until\ttrue;\ndo\nsleep 1\ndone")},
		{"sleep_before_until_still_blocked", hook("sleep 1; until true; do :; done")},
		{"while_uppercase_is_not_while", hook("WHILE true; do SLEEP 1; done")},
		{"sleepy_is_not_sleep", hook("while true; do sleepy 1; done")},
		{"until_as_substring", hook("untilx y; sleep 1")},
	}
	for _, h := range cases {
		c := g4mk("hook_"+h.name, []string{"tools/no-poll-hook.sh"}, []string{"hook", "no-poll"})
		c.stdin = h.stdin
		t.Run(c.name, func(t *testing.T) { runG4(t, c) })
	}
	t.Run("hook_blocks_with_exit_2_and_one_stderr_line", func(t *testing.T) {
		c := g4mk("hook_block_shape", []string{"tools/no-poll-hook.sh"}, []string{"hook", "no-poll"})
		c.stdin = hook("while true; do sleep 1; done")
		c.want = 2
		c.check = func(t *testing.T, sb *sandbox, r *g4res) {
			if n := len(strings.Split(strings.TrimSpace(r.errOut), "\n")); n != 1 || r.out != "" {
				t.Errorf("%s: a block is exit 2 with exactly one stderr line and no stdout; got %d lines, stdout %q", sb.impl, n, r.out)
			}
		}
		runG4(t, c)
	})
	t.Run("hook_allowed_is_silent_exit_0", func(t *testing.T) {
		c := g4mk("hook_allow_shape", []string{"tools/no-poll-hook.sh"}, []string{"hook", "no-poll"})
		c.stdin = hook("sleep 5")
		c.want = 0
		c.check = func(t *testing.T, sb *sandbox, r *g4res) {
			if r.out != "" || r.errOut != "" {
				t.Errorf("%s: an allowed command must be silent; stdout %q stderr %q", sb.impl, r.out, r.errOut)
			}
		}
		runG4(t, c)
	})
	t.Run("hook_self_test_passes", func(t *testing.T) {
		c := g4mk("hook_self_test", []string{"tools/no-poll-hook.sh", "--self-test"}, []string{"hook", "no-poll", "--self-test"})
		c.want, c.exitOnly = 0, true
		c.check = func(t *testing.T, sb *sandbox, r *g4res) {
			if !strings.Contains(r.out+r.errOut, "self-test ok") {
				t.Errorf("%s: self-test output lacks 'self-test ok': %q %q", sb.impl, r.out, r.errOut)
			}
		}
		runG4(t, c)
	})
}

// ---------------- times / trend (tools/build-times.sh) ----------------

type hrec map[string]any

func stepRec(run, ts, cmd, commit, step, result, source string, secs float64, cold bool) hrec {
	return hrec{"ts": ts, "run": run, "source": source, "worktree": "wt", "commit": commit, "cmd": cmd, "image": "img", "cold": cold,
		"step": step, "kind": "step", "seconds": secs, "result": result}
}

func suiteRec(run, ts, cmd, commit, step, source string, count, p50, p90, p99, max int, slow string, slowMs int) hrec {
	return hrec{"ts": ts, "run": run, "source": source, "worktree": "wt", "commit": commit, "cmd": cmd, "image": "img", "cold": false,
		"step": step, "kind": "tests", "count": count, "failed": 0, "total_ms": 12345, "p50": p50, "p90": p90, "p99": p99, "max": max,
		"slowest": slow, "slowest_ms": slowMs}
}

func jsonl(recs ...hrec) string {
	var b strings.Builder
	for _, r := range recs {
		b.WriteString(jsonLine(r))
	}
	return b.String()
}

func timesHistory(t *testing.T, sb *sandbox) {
	steps := jsonl(
		stepRec("r1", "2026-10-30T10:00:00+00:00", "test", "aaa1111", "lint", "ok", "local", 12.04, false),
		stepRec("r1", "2026-10-30T10:00:20+00:00", "test", "aaa1111", "core", "ok", "local", 80.5, true),
		suiteRec("r1", "2026-10-30T10:01:40+00:00", "test", "aaa1111", "core", "local", 900, 3, 20, 400, 5000, "slow test one", 5000),
		stepRec("r2", "2026-10-30T11:00:00+00:00", "test", "bbb2222", "lint", "ok", "local", 10.0, false),
		stepRec("r2", "2026-10-30T11:00:20+00:00", "test", "bbb2222", "core", "failed", "local", 70.25, false),
		stepRec("r3", "2026-10-31T09:30:00+00:00", "apk", "ccc3333", "apk", "ok", "local", 300.0, false),
		stepRec("r4", "2026-10-31T12:00:00+00:00", "test", "ccc3333", "lint", "ok", "local", 11.0, false),
		stepRec("r4", "2026-10-31T12:00:15+00:00", "test", "ccc3333", "core", "ok", "local", 75.0, false),
		suiteRec("r4", "2026-10-31T12:01:30+00:00", "test", "ccc3333", "core", "local", 910, 3, 21, 380, 4900, "slow test one with a very long name that is cut at sixty characters for sure", 4900),
		stepRec("r4", "2026-10-31T12:02:00+00:00", "test", "ccc3333", "app", "ok", "local", 140.7, false),
		stepRec("r5", "2026-11-01T08:00:00+00:00", "test", "ddd4444", "lint", "ok", "local", 13.0, false),
	) + "not json at all\n"
	tests := jsonl(
		hrec{"ts": "2026-10-30T10:01:40+00:00", "run": "r1", "source": "local", "commit": "aaa1111", "suite": "core", "test": "alpha", "ms": 5000, "result": "success"},
		hrec{"ts": "2026-10-30T10:01:40+00:00", "run": "r1", "source": "local", "commit": "aaa1111", "suite": "core", "test": "beta", "ms": 40, "result": "success"},
		hrec{"ts": "2026-10-30T10:01:40+00:00", "run": "r1", "source": "local", "commit": "aaa1111", "suite": "app", "test": "gamma", "ms": 900, "result": "success"},
		hrec{"ts": "2026-10-31T12:01:30+00:00", "run": "r4", "source": "local", "commit": "ccc3333", "suite": "core", "test": "alpha", "ms": 4900, "result": "success"},
		hrec{"ts": "2026-10-31T12:01:30+00:00", "run": "r4", "source": "local", "commit": "ccc3333", "suite": "app", "test": "gamma", "ms": 950, "result": "success"},
		hrec{"ts": "2026-10-31T12:01:30+00:00", "run": "r4", "source": "local", "commit": "ccc3333", "suite": "app", "test": "delta", "ms": 15, "result": "success"},
		hrec{"ts": "2026-11-01T08:01:00+00:00", "run": "r5", "source": "local", "commit": "ddd4444", "suite": "core", "test": "alpha", "ms": 4000, "result": "success"},
	)
	sb.write(filepath.Join(sb.data, "history", "steps.jsonl"), steps)
	sb.write(filepath.Join(sb.data, "history", "tests.jsonl"), tests)
}

func ciHistory() string {
	return jsonl(
		stepRec("c1", "2026-10-31T20:00:00+00:00", "ci", "ccc3333", "lint", "ok", "ci", 20.0, false),
		stepRec("c1", "2026-10-31T20:00:30+00:00", "ci", "ccc3333", "core", "failed", "ci", 200.5, false),
		stepRec("c2", "2026-11-01T07:00:00+00:00", "ci", "ddd4444", "lint", "ok", "ci", 22.0, false),
		stepRec("c2", "2026-11-01T07:00:30+00:00", "ci", "ddd4444", "apk", "ok", "ci", 410.0, false),
	)
}

func TestGO4TimesTrend(t *testing.T) {
	mk := func(name string, trend bool, args ...string) g4 {
		old := []string{"tools/build-times.sh"}
		nw := []string{"times"}
		if trend {
			old, nw = append(old, "trend"), []string{"trend"}
		}
		c := g4mk(name, append(old, args...), append(nw, args...))
		c.sbRepo, c.git, c.tools, c.prep = true, true, []string{"build-times.sh", "build_log.py"}, timesHistory
		c.want = 0
		c.check = func(t *testing.T, sb *sandbox, r *g4res) {
			empty := strings.Contains(r.out, "no matching history") || strings.Contains(r.out, "no history in")
			if want := strings.Contains(name, "none") || strings.Contains(name, "unknown") || strings.Contains(name, "without_ci_data"); empty != want {
				t.Errorf("%s: 'no history' message present=%v, expected %v (the synthetic history must be read):\n%s", sb.impl, empty, want, tail(r.out))
			}
			if strings.HasPrefix(name, "times_ci") && !strings.Contains(name, "without_history") && !strings.Contains(r.out, "ddd4444") {
				t.Errorf("%s: --ci must add the CI history lines (commit ddd4444):\n%s", sb.impl, tail(r.out))
			}
		}
		return c
	}
	ci := func(c g4, pushHistory bool) g4 {
		prev := c.prep
		c.prep = func(t *testing.T, sb *sandbox) {
			prev(t, sb)
			files := map[string]string{"latest.txt": "x\n"}
			if pushHistory {
				files["history.jsonl"] = ciHistory()
			}
			sb.pushCILogs(files, false)
		}
		return c
	}
	times := []g4{
		mk("times_default", false),
		mk("times_n_2", false, "-n", "2"),
		mk("times_n_1", false, "-n", "1"),
		mk("times_n_100", false, "-n", "100"),
		mk("times_cmd_test", false, "--cmd", "test"),
		mk("times_cmd_apk", false, "--cmd", "apk"),
		mk("times_cmd_none_matches", false, "--cmd", "nothing"),
		mk("times_step_core", false, "--step", "core"),
		mk("times_step_lint_n2", false, "--step", "lint", "-n", "2"),
		mk("times_commit_prefix", false, "--commit", "ccc"),
		mk("times_source_local", false, "--source", "local"),
		mk("times_source_ci_without_ci_data", false, "--source", "ci"),
		mk("times_all_flags", false, "-n", "3", "--cmd", "test", "--step", "core", "--commit", "ccc", "--source", "local"),
		ci(mk("times_ci", false, "--ci"), true),
		ci(mk("times_ci_source_ci_only", false, "--ci", "--source", "ci"), true),
		ci(mk("times_ci_with_flags", false, "--ci", "-n", "5", "--step", "lint"), true),
		ci(mk("times_ci_branch_without_history", false, "--ci"), false),
		mk("trend_default", true),
		mk("trend_n_2", true, "-n", "2"),
		mk("trend_top_2", true, "--top", "2"),
		mk("trend_step_app", true, "--step", "app"),
		mk("trend_all_flags", true, "-n", "2", "--top", "3", "--step", "core"),
		mk("trend_step_unknown", true, "--step", "nothing"),
	}
	empty := mk("times_no_history_none", false)
	empty.prep = nil
	emptyTrend := mk("trend_no_history_none", true)
	emptyTrend.prep = nil
	badSource := mk("times_bad_source", false, "--source", "bogus")
	badSource.want, badSource.exitOnly = 2, true
	badN := mk("times_bad_n", false, "-n", "x")
	badN.want, badN.exitOnly = 2, true
	badFlag := mk("times_bad_flag", false, "--frobnicate")
	badFlag.want, badFlag.exitOnly = 2, true
	times = append(times, empty, emptyTrend, badSource, badN, badFlag)
	for _, c := range times {
		t.Run(c.name, func(t *testing.T) { runG4(t, c) })
	}
}

// ---------------- ci status / ci log (tools/ci-status.sh) ----------------

func checkRuns(rows ...[3]string) string {
	rs := []map[string]any{}
	for _, r := range rows {
		m := map[string]any{"name": r[0], "status": r[1], "conclusion": nil}
		if r[2] != "" {
			m["conclusion"] = r[2]
		}
		rs = append(rs, m)
	}
	b, _ := json.Marshal(map[string]any{"check_runs": rs})
	return string(b)
}

func wfRuns(statuses ...string) string {
	rs := []map[string]any{}
	for i, s := range statuses {
		rs = append(rs, map[string]any{"status": s, "databaseId": 100 + i})
	}
	b, _ := json.Marshal(rs)
	return string(b)
}

func ciLatest(sha string, errorLines int) string {
	var b strings.Builder
	fmt.Fprintf(&b, "commit: %s  ref: v2  run: 7\n\nlint=ok:12.0 core=ok:80.5 apk=ok:400.0\njobs lint=success core=success\n", sha)
	b.WriteString("step lint ok\nTest failed: x\ncontinue-on-error: true\n0 errors\nan Exception happened\nSome tests failed.\n[E] boom\n")
	for i := 0; i < errorLines; i++ {
		fmt.Fprintf(&b, "error line %d\n", i)
	}
	return b.String()
}

func TestGO4CIStatus(t *testing.T) {
	greenRows := checkRuns([3]string{"lint", "completed", "success"}, [3]string{"core", "completed", "success"},
		[3]string{"linux", "completed", "skipped"}, [3]string{"log", "completed", "neutral"})
	type opts struct {
		checks, runs string
		logs         func(sha string) map[string]string // nil: no ci-logs branch
		pushMaster   bool
	}
	mk := func(name string, o opts, want int, args ...string) g4 {
		c := g4mk(name, append([]string{"tools/ci-status.sh"}, args...), append([]string{"ci", "status"}, args...))
		c.sbRepo, c.git, c.tools, c.fakes, c.want = true, true, []string{"ci-status.sh"}, []string{"gh"}, want
		c.prep = func(t *testing.T, sb *sandbox) {
			if o.checks != "" {
				sb.write(filepath.Join(sb.fakeData, "checkruns.json"), o.checks)
			}
			sb.write(filepath.Join(sb.fakeData, "runs.json"), o.runs)
			if o.logs != nil {
				sb.pushCILogs(o.logs(sb.head()), o.pushMaster)
			} else if o.pushMaster {
				sb.git(day1, "push", "-q", "origin", "master")
			}
		}
		return c
	}
	latest := func(errs int) func(string) map[string]string {
		return func(sha string) map[string]string { return map[string]string{"latest.txt": ciLatest(sha, errs)} }
	}
	other := func(string) map[string]string {
		return map[string]string{"latest.txt": ciLatest("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", 0)}
	}
	allDone := wfRuns("completed")
	failing := func(c g4) g4 {
		c.check = func(t *testing.T, sb *sandbox, r *g4res) {
			if r.exit == 0 {
				t.Errorf("%s: must not exit 0", sb.impl)
			}
		}
		return c
	}
	cases := []g4{
		mk("ci_status_green_with_step_line", opts{greenRows, allDone, latest(0), true}, 0),
		mk("ci_status_green_log_for_another_commit", opts{greenRows, allDone, other, true}, 0),
		mk("ci_status_green_no_ci_logs_branch", opts{greenRows, allDone, nil, true}, 0),
		mk("ci_status_green_unpushed_commit_note", opts{greenRows, allDone, latest(0), false}, 0),
		mk("ci_status_failed_shows_failing_lines", opts{checkRuns([3]string{"lint", "completed", "success"}, [3]string{"core", "completed", "failure"}), allDone, latest(0), true}, 1),
		mk("ci_status_failed_failing_lines_cut_at_40", opts{checkRuns([3]string{"core", "completed", "failure"}), allDone, latest(60), true}, 1),
		mk("ci_status_failed_log_for_another_commit", opts{checkRuns([3]string{"core", "completed", "cancelled"}), allDone, other, true}, 1),
		mk("ci_status_failed_no_ci_logs_branch", opts{checkRuns([3]string{"core", "completed", "timed_out"}), allDone, nil, true}, 1),
		mk("ci_status_running", opts{checkRuns([3]string{"lint", "completed", "success"}, [3]string{"core", "in_progress", ""}), wfRuns("in_progress"), latest(0), true}, 2),
		mk("ci_status_queued_only", opts{checkRuns([3]string{"core", "queued", ""}), wfRuns("queued"), latest(0), true}, 2),
		mk("ci_status_failed_beats_running", opts{checkRuns([3]string{"lint", "completed", "failure"}, [3]string{"core", "in_progress", ""}), wfRuns("in_progress"), latest(0), true}, 1),
		mk("ci_status_none_yet", opts{checkRuns(), wfRuns(), latest(0), true}, 2),
		mk("ci_status_explicit_head_sha", opts{greenRows, allDone, latest(0), true}, 0, "HEAD"),
		mk("ci_status_wait_green", opts{greenRows, allDone, latest(0), true}, 0, "--wait"),
		mk("ci_status_wait_failed", opts{checkRuns([3]string{"core", "completed", "failure"}), allDone, latest(0), true}, 1, "--wait"),
		mk("ci_log_default_latest", opts{greenRows, allDone, latest(3), true}, 0, "--log"),
		mk("ci_log_named", opts{greenRows, allDone, func(sha string) map[string]string {
			return map[string]string{"latest.txt": "L\n", "run-42.txt": "the named log\nline two\n"}
		}, true}, 0, "--log", "run-42"),
		failing(mk("ci_log_missing_name", opts{greenRows, allDone, latest(0), true}, -1, "--log", "no-such-log")),
		failing(mk("ci_log_no_ci_logs_branch", opts{greenRows, allDone, nil, true}, -1, "--log")),
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { runG4(t, c) })
	}
}
