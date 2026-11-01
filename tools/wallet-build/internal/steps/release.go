package steps

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// BuildAPK builds the release APK and checks its signature against the release key.
func BuildAPK(s *run.Session) {
	c := s.C
	if st, err := os.Stat(c.Getenv("BW_KEYSTORE")); c.Getenv("BW_KEYSTORE") == "" || err != nil || !st.Mode().IsRegular() {
		s.FailStep("apk", "BW_KEYSTORE is not set to the release key; refusing to build an APK that can't update the app.")
		return
	}
	_, err := os.Stat(filepath.Join(c.Root, "app", "build", "app"))
	cold := err != nil
	// BW_APK_ABIS=arm64: phone-only APK (what CI publishes); default also has x86_64 for tools/emulator.sh install
	abis := "android-arm64,android-x64"
	if c.Getenv("BW_APK_ABIS") == "arm64" {
		abis = "android-arm64"
	}
	s.Step(run.Spec{Name: "apk", Cold: cold, Fn: func(sc *run.StepCtx) int {
		if rc := sc.Cmd("app", "flutter", "build", "apk", "--release", "--target-platform", abis); rc != 0 {
			return rc
		}
		_ = os.MkdirAll(filepath.Join(sc.C.Root, "dist"), 0o755)
		if err := copyFile(filepath.Join(sc.C.Root, "app/build/app/outputs/flutter-apk/app-release.apk"), filepath.Join(sc.C.Root, "dist/BudgetWallet-android.apk")); err != nil {
			sc.Printf("cp: %v\n", err)
			return 1
		}
		return 0
	}})
	if !s.Failed {
		s.Step(run.Spec{Name: "apk-signature", Fn: CheckSignature})
	}
}

var (
	reKeytool  = regexp.MustCompile(`SHA256:\s*([0-9A-F:]+)`)
	reApksign  = regexp.MustCompile(`SHA-256 digest: ([0-9a-f]+)`)
	reVersions = regexp.MustCompile(`\d+`)
)

func versionLess(a, b string) bool {
	x, y := reVersions.FindAllString(a, -1), reVersions.FindAllString(b, -1)
	for i := 0; i < len(x) && i < len(y); i++ {
		if x[i] != y[i] {
			if len(x[i]) != len(y[i]) {
				return len(x[i]) < len(y[i])
			}
			return x[i] < y[i]
		}
	}
	return len(x) < len(y)
}

// CheckSignature: the APK must carry the release key's certificate, or Android refuses it as an update. The password goes
// to keytool through the environment, not the command line.
func CheckSignature(sc *run.StepCtx) int {
	var kt bytes.Buffer
	rc := sc.Do(sys.Cmd{Argv: []string{"keytool", "-list", "-v", "-keystore", sc.Env.Get("BW_KEYSTORE"), "-storepass:env", "BW_KEYSTORE_PASSWORD",
		"-alias", sc.Env.Get("BW_KEY_ALIAS")}, Stdout: &kt, Stderr: sc.Out})
	want := ""
	if m := reKeytool.FindStringSubmatch(kt.String()); rc == 0 && m != nil {
		want = strings.ToLower(strings.ReplaceAll(m[1], ":", ""))
	}
	tools, _ := filepath.Glob(filepath.Join(sc.Env.Get("ANDROID_HOME"), "build-tools", "*", "apksigner"))
	sort.Slice(tools, func(i, j int) bool { return versionLess(tools[i], tools[j]) })
	got := ""
	if len(tools) > 0 {
		var out bytes.Buffer
		sc.Do(sys.Cmd{Argv: []string{tools[len(tools)-1], "verify", "--print-certs", "dist/BudgetWallet-android.apk"}, Stdout: &out, Stderr: sc.Out})
		if m := reApksign.FindStringSubmatch(out.String()); m != nil {
			got = m[1]
		}
	}
	sc.Printf("release key: %s\napk signer:  %s\n", want, got)
	if want != "" && want == got {
		return 0
	}
	return 1
}

// RelayBin compiles the relay server for linux/<arch> (the pinned Dart cross-compiles; needs glibc on the target).
func RelayBin(sc *run.StepCtx, arch string) int {
	root := sc.C.Root
	out := "dist/relay/relay-linux-" + arch
	if err := os.MkdirAll(filepath.Join(root, "dist", "relay"), 0o755); err != nil {
		return 1
	}
	if rc := sc.Cmd("relay", "dart", "compile", "exe", "--target-os", "linux", "--target-arch", arch, "bin/relay.dart", "-o", "../"+out); rc != 0 {
		return 1
	}
	b, err := os.ReadFile(filepath.Join(root, out))
	if err != nil {
		sc.Printf("sha256sum: %v\n", err)
		return 1
	}
	sum := fmt.Sprintf("%x  relay-linux-%s\n", sha256.Sum256(b), arch)
	if err := os.WriteFile(filepath.Join(root, out+".sha256"), []byte(sum), 0o644); err != nil {
		return 1
	}
	sc.Cmd("", "file", out)
	sc.Printf("%s", sum)
	return 0
}

// BuildLinux builds the Linux release bundle and packs it.
func BuildLinux(s *run.Session) {
	_, err := os.Stat(filepath.Join(s.C.Root, "app", "build", "linux"))
	s.Step(run.Spec{Name: "linux", Cold: err != nil, Fn: func(sc *run.StepCtx) int {
		if rc := sc.Cmd("app", "flutter", "build", "linux", "--release"); rc != 0 {
			return rc
		}
		_ = os.MkdirAll(filepath.Join(sc.C.Root, "dist"), 0o755)
		return sc.Cmd("app", "tar", "-C", "build/linux/x64/release", "-czf", "../dist/BudgetWallet-linux-x64.tar.gz", "bundle")
	}})
}

var (
	reBlockPub   = regexp.MustCompile(`^/cache/pub/hosted/[^/]+/([a-z0-9_]+)-[0-9]`)
	reBlockPkg   = regexp.MustCompile(`^\S*packages/([a-z0-9_]+)`)
	reBlockLocal = regexp.MustCompile(`^lib/([a-z]+)`)
)

// WebBlockers lists the packages with compile errors in a wasm build log (pub packages by name, path packages, the app).
func WebBlockers(log string) string {
	set := map[string]bool{}
	for _, line := range strings.Split(log, "\n") {
		if !strings.Contains(line, ": Error: ") {
			continue
		}
		for _, re := range []*regexp.Regexp{reBlockPub, reBlockPkg, reBlockLocal} {
			if m := re.FindStringSubmatch(line); m != nil {
				set[m[1]] = true
				break
			}
		}
	}
	if len(set) == 0 {
		return "unknown, see web-wasm.log"
	}
	var names []string
	for n := range set {
		names = append(names, n)
	}
	sort.Strings(names)
	return strings.Join(names, ",")
}

// BuildWeb: --wasm (WasmGC) first; a dependency that doesn't compile to it falls back to the JS build, with one line saying which.
func BuildWeb(sc *run.StepCtx) int {
	root := sc.C.Root
	mode := "wasm"
	if _, err := os.Stat(filepath.Join(root, "app/web/sqlite3.wasm")); err != nil {
		sc.Printf("app/web/sqlite3.wasm missing (tools/build.sh web fetches it on the host)\n")
		return 1
	}
	logPath := filepath.Join(sc.S.Logs, "web-wasm.log")
	f, err := os.Create(logPath)
	if err != nil {
		return 1
	}
	rc := sc.Do(sys.Cmd{Argv: []string{"flutter", "build", "web", "--wasm", "--release"}, Dir: "app", Stdout: f, Stderr: f})
	f.Close()
	b, _ := os.ReadFile(logPath)
	if rc == 0 {
		sc.Printf("%s", b)
	} else {
		mode = "js"
		sc.Printf("wasm build failed; blocked by: %s\n", WebBlockers(string(b)))
		if sc.Cmd("app", "flutter", "build", "web", "--release") != 0 {
			return 1
		}
	}
	_ = os.RemoveAll(filepath.Join(root, "dist", "web"))
	_ = os.MkdirAll(filepath.Join(root, "dist"), 0o755)
	if sc.Cmd("", "cp", "-r", "app/build/web", "dist/web") != 0 {
		return 1
	}
	sc.Printf("web build mode: %s -> dist/web\n", mode)
	return 0
}

// WebTest is flutter test --platform chrome on app/test/web (or the given files, relative to app/ or the repo root).
func WebTest(sc *run.StepCtx, args []string) int {
	var files []string
	for _, f := range args {
		f = strings.TrimPrefix(f, sc.C.Root+"/")
		files = append(files, strings.TrimPrefix(f, "app/"))
	}
	if len(files) == 0 {
		files = []string{"test/web"}
	}
	return sc.Cmd("app", append([]string{"flutter", "test", "--platform", "chrome", "--no-pub"}, files...)...)
}
