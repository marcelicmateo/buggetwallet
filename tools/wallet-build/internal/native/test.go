package native

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"wallet-build/internal/sys"
)

// Pinned base images (bump by hand). Caddy is the distro package of each image (as on a Pi), so its version follows the image.
const (
	fedoraImage = "registry.fedoraproject.org/fedora:43"
	debianImage = "docker.io/library/debian:trixie-20261005"
)

// insideScript is run inside the container (bash -s). It prints "ok: ..." lines, "FAIL: ..." for problems and notes as
// "info: ...". Everything runs as root inside the container: the sudo and firewall branches of the install script are NOT
// exercised here.
//
//go:embed inside.sh.txt
var insideScript string

// Containerfile is the image of one distro: systemd as PID 1, the distro's Caddy, curl and friends.
func Containerfile(osName string) (string, bool) {
	switch osName {
	case "fedora":
		return "FROM " + fedoraImage + "\n" +
			"RUN dnf -y install systemd caddy curl rsync iproute procps-ng && dnf clean all\n" +
			"STOPSIGNAL SIGRTMIN+3\n" +
			"CMD [\"/sbin/init\"]\n", true
	case "debian":
		return "FROM " + debianImage + "\n" +
			"RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends systemd systemd-sysv dbus caddy curl rsync iproute2 procps ca-certificates && rm -rf /var/lib/apt/lists/*\n" +
			"STOPSIGNAL SIGRTMIN+3\n" +
			"CMD [\"/sbin/init\"]\n", true
	}
	return "", false
}

// Tester runs `relay-native-test`: relay/deploy/native/ and the x64 relay binary on real systemd in rootless Podman containers
// (Fedora and Debian). Checks: bw-relay.service active, health answer, listening on 127.0.0.1 only, syscall filter silent in
// the journal, systemd-analyze security score, Caddy: validate + adapt + drop-in. Needs network (image pulls, distro
// packages), so it is NOT part of lint. Containers and images are removed at the end (BW_KEEP=1 keeps them). Everything is
// local; nothing connects to another machine. The domain and token used are test values.
type Tester struct {
	R    sys.Runner
	Root string
	Env  sys.Env
	Out  io.Writer // stdout of the script
	Err  io.Writer // stderr of the script
	// TmpDir is ${TMPDIR:-/tmp} (build logs and the two scripts).
	TmpDir string
}

func (t *Tester) podman(ctx context.Context, stdout, stderr io.Writer, stdin io.Reader, args ...string) int {
	return t.R.Run(ctx, sys.Cmd{Argv: append([]string{"podman"}, args...), Env: t.Env, Stdin: stdin, Stdout: stdout, Stderr: stderr})
}

// Test returns the script's exit code: 0 all ok, 1 a check failed, 2 usage or a missing/damaged binary.
func (t *Tester) Test(ctx context.Context, args []string) int {
	oses := args
	if len(oses) == 0 {
		oses = []string{"fedora", "debian"}
	}
	bin := filepath.Join(t.Root, "dist", "relay", "relay-linux-x64")
	if st, err := os.Stat(bin); err != nil || st.IsDir() || st.Mode()&0o111 == 0 {
		fmt.Fprintln(t.Err, "relay-native-test: build the binary first: make relay-bin ARCH=x64")
		return 2
	}
	if !shaOK(bin) {
		fmt.Fprintln(t.Err, "relay-native-test: sha256 mismatch")
		return 2
	}
	fail := 0
	for _, osName := range oses {
		if _, ok := Containerfile(osName); !ok {
			fmt.Fprintln(t.Err, "usage: relay-native-test [fedora|debian]...")
			return 2
		}
		rc, bad := t.one(ctx, bin, osName)
		if rc != 0 { // a command failed under set -e: the script stops with its status
			return rc
		}
		if bad {
			fail = 1
		}
	}
	if fail == 0 {
		fmt.Fprintln(t.Out, "relay-native-test: all ok")
	} else {
		fmt.Fprintln(t.Err, "relay-native-test: FAILED")
	}
	return fail
}

// shaOK is `cd dist/relay && sha256sum -c relay-linux-x64.sha256`.
func shaOK(bin string) bool {
	want, err := os.ReadFile(bin + ".sha256")
	if err != nil {
		return false
	}
	f := strings.Fields(string(want))
	if len(f) < 2 || filepath.Base(strings.TrimPrefix(f[1], "*")) != filepath.Base(bin) {
		return false
	}
	b, err := os.ReadFile(bin)
	if err != nil {
		return false
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]) == strings.ToLower(f[0])
}

// one runs one distro. rc != 0 aborts the whole script (a helper script failed); bad marks failed checks.
func (t *Tester) one(ctx context.Context, bin, osName string) (rc int, bad bool) {
	n := filepath.Join(t.Root, unitDir)
	name := "bw-relay-native-test-" + osName // container and image
	keep := t.Env.Get("BW_KEEP") != ""
	var files []string
	defer func() {
		for _, f := range files {
			os.Remove(f)
		}
		if !keep {
			bg := context.Background()
			t.podman(bg, nil, nil, nil, "rm", "-f", "-t", "5", name)
			t.podman(bg, nil, nil, nil, "rmi", "-f", name)
		}
	}()
	fail := func(format string, a ...any) {
		fmt.Fprintf(t.Err, "relay-native-test: FAIL: "+format+"\n", a...)
		bad = true
	}
	tmpFile := func() (string, error) {
		f, err := os.CreateTemp(t.TmpDir, "relay-native-")
		if err != nil {
			return "", err
		}
		f.Close()
		files = append(files, f.Name())
		return f.Name(), nil
	}
	scripts, err := tmpFile()
	if err != nil {
		fmt.Fprintln(t.Err, err)
		return 1, bad
	}
	up := scripts + ".up"
	files = append(files, up)
	deploy := filepath.Join(t.Root, "tools", "relay-deploy.sh")
	for _, p := range [][2]string{{"remote_native_place", scripts}, {"remote_native_upgrade", up}} {
		f, err := os.Create(p[1])
		if err != nil {
			fmt.Fprintln(t.Err, err)
			return 1, bad
		}
		rc := t.R.Run(ctx, sys.Cmd{Argv: []string{deploy, "--print-script", p[0]}, Env: t.Env, Stdout: f, Stderr: t.Err})
		f.Close()
		if rc != 0 {
			return rc, bad
		}
	}
	fmt.Fprintf(t.Out, "== %s ==\n", osName)
	t.podman(ctx, nil, nil, nil, "rm", "-f", name)
	cf, _ := Containerfile(osName)
	buildLog := filepath.Join(t.TmpDir, "bw-relay-native-build-"+osName+".log")
	lf, err := os.Create(buildLog)
	if err != nil {
		fmt.Fprintln(t.Err, err)
		return 1, bad
	}
	brc := t.podman(ctx, lf, lf, strings.NewReader(cf), "build", "-q", "-t", name, "-f", "-", n)
	lf.Close()
	if brc != 0 {
		fail("%s: image build (log %s)", osName, buildLog)
		return 0, bad
	}
	// --systemd=always: systemd as PID 1; rootless Podman delegates the cgroup.
	ro := func(src, dst string) []string { return []string{"-v", src + ":" + dst + ":ro,z"} }
	run := []string{"run", "-d", "--name", name, "--systemd=always"}
	for _, m := range [][2]string{
		{bin, "/t/relay"}, {filepath.Join(n, "bw-relay.service"), "/t/bw-relay.service"}, {filepath.Join(n, "bw-relay.sysusers"), "/t/bw-relay.sysusers"},
		{filepath.Join(n, "caddy.service.d", "bw-relay.conf"), "/t/caddy-dropin.conf"}, {filepath.Join(n, "Caddyfile"), "/t/Caddyfile"},
		{filepath.Join(n, "bw-relay.env.example"), "/t/bw-relay.env.example"}, {scripts, "/t/place.sh"}, {up, "/t/upgrade.sh"},
	} {
		run = append(run, ro(m[0], m[1])...)
	}
	run = append(run, name)
	if t.podman(ctx, nil, t.Err, nil, run...) != 0 {
		fail("%s: run", osName)
		return 0, bad
	}
	// waits (inside systemctl) until boot has finished
	t.podman(ctx, nil, nil, nil, "exec", name, "systemctl", "is-system-running", "--wait")
	var out bytes.Buffer
	t.podman(ctx, &out, &out, strings.NewReader(insideScript), "exec", "-i", name, "bash", "-s")
	text := strings.TrimRight(out.String(), "\n")
	hasFail := false
	for _, line := range strings.Split(text, "\n") {
		fmt.Fprintf(t.Out, "[%s] %s\n", osName, line)
		if strings.HasPrefix(line, "FAIL") {
			hasFail = true
		}
	}
	if hasFail {
		fail("%s: checks failed", osName)
	}
	return 0, bad
}
