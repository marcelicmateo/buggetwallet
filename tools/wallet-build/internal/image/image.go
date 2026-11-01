// Package image computes the dev image tag and the podman arguments of a host run.
package image

import (
	"bufio"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var flutterLine = regexp.MustCompile(`^\s+flutter:\s*"?([0-9]+\.[0-9]+\.[0-9]+)`)

// FlutterVersion is `environment: flutter:` of app/pubspec.yaml.
func FlutterVersion(root string) (string, error) {
	f, err := os.Open(filepath.Join(root, "app", "pubspec.yaml"))
	if err != nil {
		return "", err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if m := flutterLine.FindStringSubmatch(sc.Text()); m != nil {
			return m[1], nil
		}
	}
	return "", fmt.Errorf("no flutter version in app/pubspec.yaml")
}

// Tag is localhost/budget-wallet-dev:<flutter version>-<8 hex of sha256 over the image inputs>, so editing any input
// rebuilds the image on the next run.
func Tag(root string) (string, error) {
	v, err := FlutterVersion(root)
	if err != nil {
		return "", err
	}
	h := sha256.New()
	for _, f := range []string{"dev/Containerfile", "dev/install-lint-tools.sh", "dev/linux-packages.txt"} {
		b, err := os.ReadFile(filepath.Join(root, f))
		if err != nil {
			return "", err
		}
		h.Write(b)
	}
	return fmt.Sprintf("localhost/budget-wallet-dev:%s-%s", v, fmt.Sprintf("%x", h.Sum(nil))[:8]), nil
}

// FlutterOf extracts the Flutter version from a tag.
func FlutterOf(tag string) string {
	_, v, _ := strings.Cut(tag, ":")
	v, _, _ = strings.Cut(v, "-")
	return v
}

// PassEnv are the variables handed to the container by name (-e NAME): the host's value, when set. BW_NATIVE=1 is fixed.
// A test that reads BW_* through Platform.environment must be listed here (the env-selftest lint step).
var PassEnv = []string{"BW_JOBS", "BW_GL_THREADS", "BW_APK_ABIS", "BW_FUZZ_ITERATIONS", "BW_FUZZ_SEED",
	"BW_STEP_TIMEOUT", "BW_HEADLESS_TIMEOUT", "BW_SMOKE_SECONDS"}

// ForwardEnv are the BW_TIMEOUT_<STEP> variables set on the host (sorted): the step time limits apply inside the container.
func ForwardEnv(env []string) []string {
	var out []string
	for _, kv := range env {
		if k, _, ok := strings.Cut(kv, "="); ok && strings.HasPrefix(k, "BW_TIMEOUT_") {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// RunEnv are the run variables that make the container write into the host's run (tools/timing.sh run_env).
var RunEnv = []string{"BW_DATA_DIR", "BW_RUN_DIR", "BW_RUN_ID", "BW_RUN", "BW_COMMIT", "BW_CMD", "BW_IMAGE", "BW_COLD", "BW_SOURCE", "BW_WORKTREE"}

// ContainerName is wallet-build-<worktree>-<runid>, with characters podman rejects replaced.
func ContainerName(worktree, id string) string {
	clean := func(s string) string {
		return strings.Map(func(r rune) rune {
			switch {
			case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_', r == '.', r == '-':
				return r
			}
			return '_'
		}, s)
	}
	return "wallet-build-" + clean(worktree) + "-" + clean(id)
}
