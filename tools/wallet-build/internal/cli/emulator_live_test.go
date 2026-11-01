package cli

import (
	"strings"
	"testing"

	"wallet-build/internal/sys"
)

func noContainer(c sys.Cmd) int {
	if len(c.Argv) > 2 && c.Argv[0] == "podman" && c.Argv[2] == "exists" && (c.Argv[1] == "container" || c.Argv[1] == "pod") {
		return 1
	}
	return 0
}

func TestEmulatorUsageIsTwoAndQuietIsSilent(t *testing.T) {
	for _, args := range [][]string{{"-q", "emulator", "no-such-command"}, {"emulator", "setup"}, {"emulator", "boot"}, {"emulator", "shot"}} {
		for _, env := range [][]string{nil, {"BW_QUIET=1"}} {
			r := runCLI(t, opts{handle: noContainer, env: env}, args...)
			quiet := args[0] == "-q" || env != nil
			if r.code != 2 && !(args[1] == "shot" && r.code == 1) {
				t.Errorf("%v %v: exit %d", args, env, r.code)
			}
			if quiet && (r.out != "" || r.err != "") {
				t.Errorf("%v %v: quiet leaked %q %q", args, env, r.out, r.err)
			}
			if !quiet && args[1] != "shot" && !strings.HasPrefix(r.out, "Android emulator in a rootless Podman container") {
				t.Errorf("%v: no usage text: %q", args, r.out)
			}
		}
	}
}

func TestEmulatorQuietRunPrintsNothing(t *testing.T) {
	root := mkRepo(t)
	write(t, root+"/dev/Containerfile.emulator", "FROM x\n")
	r := runCLI(t, opts{root: root}, "-q", "emulator", "screens")
	if r.code != 0 || r.out != "" || r.err != "" {
		t.Errorf("exit %d out %q err %q", r.code, r.out, r.err)
	}
	if len(podmanRuns(r)) != 2 {
		t.Errorf("setup and screens containers: %v", podmanRuns(r))
	}
	// the run is closed, the logs written as without -q
	dir := runDirs(t, r)[0]
	if !strings.HasPrefix(file(t, dir+"/last.status"), "emulator-screens ok ") || file(t, dir+"/last-failed.txt") != "" {
		t.Errorf("last.status %q", file(t, dir+"/last.status"))
	}
}

func TestLiveHasNoQuietMode(t *testing.T) {
	// tools/live.sh has no -q and ignores BW_QUIET: so does the port, for now
	r := runCLI(t, opts{handle: noContainer, env: []string{"BW_QUIET=1"}}, "live", "status")
	if r.code != 0 || r.out != "not running\n" {
		t.Errorf("BW_QUIET=1: %d %q", r.code, r.out)
	}
	r = runCLI(t, opts{handle: noContainer}, "live", "-q", "status") // what `tools/live.sh -q status` hands over
	if r.code != 2 || !strings.HasPrefix(r.out, "Live mode: the Linux desktop app") {
		t.Errorf("-q after live: %d %q", r.code, r.out)
	}
	r = runCLI(t, opts{handle: noContainer}, "live", "bogus")
	if r.code != 2 || !strings.HasPrefix(r.out, "Live mode:") {
		t.Errorf("bogus: %d %q", r.code, r.out)
	}
}

func TestLiveAndEmulatorContainerSideDispatch(t *testing.T) {
	for _, cmd := range []string{"emulator", "live"} {
		r := native(t, opts{}, cmd, "bogus")
		if r.code != 2 || r.out == "" {
			t.Errorf("%s: %d %q", cmd, r.code, r.out)
		}
		if len(r.fake.Calls) != 0 {
			t.Errorf("%s: ran %v", cmd, r.calls)
		}
	}
	// the container side of live, helpers only: serve needs its environment
	r := native(t, opts{}, "live", "serve")
	if r.code != 1 || !strings.Contains(r.err, "BW_LIVE_DIR") {
		t.Errorf("serve without environment: %d %q", r.code, r.err)
	}
}
