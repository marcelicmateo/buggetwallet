// Package native ports tools/relay-native-check.sh (offline checks of relay/deploy/native/, a lint step) and
// tools/relay-native-test.sh (the same files on real systemd in Podman containers, host only, needs network).
package native

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"wallet-build/internal/sys"
)

// unitDir is where the deployment files live, relative to the repository.
const unitDir = "relay/deploy/native"

var (
	// systemd-analyze lines that are not errors for verify: the real binary and the service user only exist on the Pi.
	reVerifyIgnore = []*regexp.Regexp{regexp.MustCompile(`bw-relay.*not found`), regexp.MustCompile(`Failed to create bw-relay`), regexp.MustCompile(`Unit .*not found`)}
	reVerifyKeep   = regexp.MustCompile(`(?i)unknown|invalid|failed|error|bad`)
	reUnitLine     = regexp.MustCompile(`^\s*(#.*)?$|^\[[A-Za-z]+\]$|^[A-Za-z]+=`)
	reSecretWord   = regexp.MustCompile(`(?i)TOKEN|SECRET|PASSWORD`)
	reCredential   = regexp.MustCompile(`(?m)^LoadCredential=create-token:`)
)

// Check is `relay-native-check`: systemd-analyze verify on the relay service (against a stand-in binary, since the real one only
// exists on the Pi), the Caddy drop-in as plain unit syntax, and a few invariants: the relay stays on 127.0.0.1, uses
// --trust-proxy, takes its token from a credential, no secret in the env template. It returns 0, 1 (a check failed) or 2 (a
// file could not be read). Messages go to errw like the script's.
func Check(ctx context.Context, r sys.Runner, root string, env sys.Env, out, errw io.Writer) int {
	d := filepath.Join(root, unitDir)
	fail := 0
	bad := func(format string, a ...any) {
		fmt.Fprintf(errw, "relay-native-check: "+format+"\n", a...)
		fail = 1
	}
	service, err := os.ReadFile(filepath.Join(d, "bw-relay.service"))
	if err != nil {
		fmt.Fprintf(errw, "relay-native-check: %v\n", err)
		return 2
	}
	tmp, err := os.MkdirTemp("", "relay-native-check")
	if err != nil {
		fmt.Fprintf(errw, "relay-native-check: %v\n", err)
		return 2
	}
	defer os.RemoveAll(tmp)
	// Stand-in for /usr/local/bin/bw-relay: verify wants the executable to exist, so the unit is verified with ExecStart
	// pointing at /bin/true.
	standIn := regexp.MustCompile(`(?m)^ExecStart=/usr/local/bin/bw-relay`).ReplaceAll(service, []byte("ExecStart=/bin/true"))
	unit := filepath.Join(tmp, "bw-relay.service")
	if err := os.WriteFile(unit, standIn, 0o644); err != nil {
		fmt.Fprintf(errw, "relay-native-check: %v\n", err)
		return 2
	}
	if _, err := r.LookPath("systemd-analyze"); err == nil {
		// Missing user/credential files are not errors for verify; anything else (unknown key, bad value) is.
		var buf bytes.Buffer
		r.Run(ctx, sys.Cmd{Argv: []string{"systemd-analyze", "verify", "--man=no", unit}, Env: env, Stdout: &buf, Stderr: &buf})
		var kept []string
	lines:
		for _, l := range strings.Split(buf.String(), "\n") {
			for _, re := range reVerifyIgnore {
				if re.MatchString(l) {
					continue lines
				}
			}
			if reVerifyKeep.MatchString(l) {
				kept = append(kept, l)
			}
		}
		if res := strings.TrimRight(strings.Join(kept, "\n"), "\n"); res != "" {
			bad("systemd-analyze verify: %s", res)
		}
	} else {
		fmt.Fprintln(errw, "relay-native-check: systemd-analyze missing, syntax-only check")
	}

	for _, f := range []string{"bw-relay.service", "caddy.service.d/bw-relay.conf", "bw-relay.sysusers"} {
		if st, err := os.Stat(filepath.Join(d, f)); err != nil || st.Size() == 0 {
			bad("%s missing", filepath.Join(unitDir, f))
		}
	}
	// every non-comment line of a unit is a section header or Key=Value
	for _, f := range []string{"bw-relay.service", "caddy.service.d/bw-relay.conf"} {
		b, err := os.ReadFile(filepath.Join(d, f))
		if err != nil {
			continue
		}
		offending := false
		for _, l := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
			if !reUnitLine.MatchString(l) {
				fmt.Fprintln(out, l) // grep -v prints the lines it found
				offending = true
			}
		}
		if offending {
			bad("%s: line that is not Key=Value", filepath.Join(unitDir, f))
		}
	}
	text := string(service)
	if !regexp.MustCompile(`--host 127.0.0.1`).MatchString(text) {
		bad("relay must be bound to 127.0.0.1")
	}
	if !strings.Contains(text, "--trust-proxy") {
		bad("relay needs --trust-proxy behind Caddy")
	}
	if !reCredential.MatchString(text) {
		bad("creation token must come from LoadCredential=")
	}
	if b, err := os.ReadFile(filepath.Join(d, "Caddyfile")); err != nil || !regexp.MustCompile(`reverse_proxy 127.0.0.1:8787`).Match(b) {
		bad("Caddyfile must proxy to 127.0.0.1:8787")
	}
	if b, err := os.ReadFile(filepath.Join(d, "bw-relay.env.example")); err == nil {
		var code []string
		for _, l := range strings.Split(string(b), "\n") {
			if !strings.HasPrefix(l, "#") {
				code = append(code, l)
			}
		}
		if reSecretWord.MatchString(strings.Join(code, "\n")) {
			bad("env template must not hold secrets")
		}
	}
	return fail
}
