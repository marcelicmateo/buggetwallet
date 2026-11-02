// Package shellhelpers is the command table of the GO4-B helpers: the ports of tools/relay.sh, wallet-build web, tools/web_shot.py,
// tools/relay-native-check.sh, tools/make-signing-key.sh and tools/no-poll-hook.sh. relay-native-test lives in the host side
// of the tool (it is a logged step); times, trend and ci are in the cli package.
package shellhelpers

import (
	"fmt"
	"io"
	"os"
	"strings"

	"wallet-build/internal/hook"
	"wallet-build/internal/host"
	"wallet-build/internal/native"
	"wallet-build/internal/relaydev"
	"wallet-build/internal/run"
	"wallet-build/internal/signing"
	"wallet-build/internal/webdev"
)

// Deps are what the tests replace.
type Deps struct {
	// HostSetup adjusts the Host that provides the dev image name (`web shot`).
	HostSetup func(h *host.Host)
	// Stdin is the hook's input and reset's answer; os.Stdin unless a test replaces it.
	Stdin io.Reader
}

// Handles reports whether cmd with these arguments is one of the helpers (the plain build steps `relay` and `web` are not).
func Handles(cmd string, rest []string) bool {
	switch cmd {
	case "relay":
		return len(rest) > 0 && relaydev.IsCommand(rest[0])
	case "web":
		return len(rest) > 0 && (webdev.IsCommand(rest[0]) || rest[0] == "_serve")
	case "web-shot", "relay-native-check", "signing-key", "hook":
		return true
	}
	return false
}

// Dispatch runs the helper for cmd and returns its exit code; ok is false when cmd is not a helper.
func Dispatch(c *run.Ctx, cmd string, rest []string, self string, usage func() int, d Deps) (rc int, ok bool) {
	if !Handles(cmd, rest) {
		return 0, false
	}
	in := d.Stdin
	if in == nil {
		in = os.Stdin
	}
	switch cmd {
	case "relay":
		r := relaydev.New(c)
		r.In = in
		return r.Main(rest), true
	case "web":
		if rest[0] == "_serve" { // the detached server of `web serve`
			if len(rest) != 3 {
				return usage(), true
			}
			if err := webdev.ServeDir(c.Ctx, rest[1], rest[2], os.Stderr); err != nil {
				fmt.Fprintf(os.Stderr, "web server: %v\n", err)
				return 1, true
			}
			return 0, true
		}
		w := webdev.New(c, self)
		w.ImageName = func() (string, int) { return imageName(c, self, usage, d) }
		return w.Main(rest), true
	case "web-shot":
		return webdev.NewShot(c).Main(rest), true
	case "relay-native-check":
		return native.Check(c.Ctx, c.R, c.Root, c.Env, c.Out, c.Err), true
	case "signing-key":
		if len(rest) > 1 || (len(rest) == 1 && rest[0] != "--upload") {
			fmt.Fprint(c.Out, signing.Usage)
			return 2, true
		}
		return signing.New(c).Main(rest), true
	case "hook":
		rc, good := hook.Main(rest, in, c.Out, c.Err)
		if !good {
			return usage(), true
		}
		return rc, true
	}
	return 0, false
}

// imageName is wallet-build image-name: the dev image tag, built first when it is missing.
func imageName(c *run.Ctx, self string, usage func() int, d Deps) (string, int) {
	h := host.New(c, self, usage)
	if d.HostSetup != nil {
		d.HostSetup(h)
	}
	var sb strings.Builder
	saved := c.Out
	c.Out = &sb
	rc := h.Main("image-name", nil)
	c.Out = saved
	return strings.TrimSpace(sb.String()), rc
}
