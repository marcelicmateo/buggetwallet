package image

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const repoRoot = "../../../.."

// The tag must be exactly what wallet-build computes (the same image serves both implementations).
func TestTagEqualsBash(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}
	root, _ := filepath.Abs(repoRoot)
	script := `cd "` + root + `"
FLUTTER_VERSION=$(grep -oP '^\s+flutter:\s*"?\K[0-9]+\.[0-9]+\.[0-9]+' app/pubspec.yaml)
echo "localhost/budget-wallet-dev:$FLUTTER_VERSION-$(cat dev/Containerfile dev/install-lint-tools.sh dev/linux-packages.txt | sha256sum | cut -c1-8)"`
	want, err := exec.Command("bash", "-c", script).Output()
	if err != nil {
		t.Fatal(err)
	}
	got, err := Tag(root)
	if err != nil {
		t.Fatal(err)
	}
	if got != strings.TrimSpace(string(want)) {
		t.Errorf("got %s want %s", got, want)
	}
	if v, _ := FlutterVersion(root); FlutterOf(got) != v {
		t.Errorf("FlutterOf %s vs %s", FlutterOf(got), v)
	}
}

func TestTagChangesWithInputs(t *testing.T) {
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, "app"), 0o755)
	os.MkdirAll(filepath.Join(root, "dev"), 0o755)
	os.WriteFile(filepath.Join(root, "app/pubspec.yaml"), []byte("environment:\n  sdk: ^3.0.0\n  flutter: \"3.47.7\"\n"), 0o644)
	for _, f := range []string{"Containerfile", "install-lint-tools.sh", "linux-packages.txt"} {
		os.WriteFile(filepath.Join(root, "dev", f), []byte(f), 0o644)
	}
	a, err := Tag(root)
	if err != nil || !strings.HasPrefix(a, "localhost/budget-wallet-dev:3.47.7-") {
		t.Fatalf("%s %v", a, err)
	}
	os.WriteFile(filepath.Join(root, "dev/linux-packages.txt"), []byte("changed"), 0o644)
	if b, _ := Tag(root); a == b {
		t.Error("editing an image input must change the tag")
	}
}

func TestContainerName(t *testing.T) {
	if got := ContainerName("agent-a1b2", "20261101-111328-app-9098d74-dirty"); got != "wallet-build-agent-a1b2-20261101-111328-app-9098d74-dirty" {
		t.Error(got)
	}
	if got := ContainerName("my tree/x", "a:b"); got != "wallet-build-my_tree_x-a_b" {
		t.Error(got)
	}
}
