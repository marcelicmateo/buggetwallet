package signing

import (
	"bytes"
	crand "crypto/rand"
	"encoding/base64"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

// Everything here happens in a temp BW_SIGNING_DIR: never the real ~/.config/budget-wallet, never gh.

type fixture struct {
	m    *Maker
	fake *sys.Fake
	out  *bytes.Buffer
	err  *bytes.Buffer
	dir  string
}

func newFixture(t *testing.T, r sys.Runner) *fixture {
	t.Helper()
	f := &fixture{out: &bytes.Buffer{}, err: &bytes.Buffer{}, dir: filepath.Join(t.TempDir(), "keys")}
	c := run.New(t.TempDir(), sys.Env{"BW_SIGNING_DIR=" + f.dir, "HOME=" + t.TempDir()}, f.out, f.err, r)
	f.m = &Maker{C: c, Rand: bytes.NewReader(bytes.Repeat([]byte{0xfb, 0xff, 0x3e}, 8))} // base64 "+/8+" repeated: all characters that are removed
	return f
}

func TestPassword(t *testing.T) {
	// 24 bytes of 0xfb 0xff 0x3e encode to "+/8+" x 8: the three characters that tr removes go, "8" stays
	p, err := Password(bytes.NewReader(bytes.Repeat([]byte{0xfb, 0xff, 0x3e}, 8)))
	if err != nil || p != strings.Repeat("8", 8) {
		t.Errorf("got %q, %v", p, err)
	}
	// with real randomness: only [A-Za-z0-9], at most 32 characters, different every time, and enough of them
	seen := map[string]bool{}
	for i := 0; i < 20; i++ {
		p, err := Password(nil2())
		if err != nil || !regexp.MustCompile(`^[A-Za-z0-9]{20,32}$`).MatchString(p) {
			t.Fatalf("password %q, %v", p, err)
		}
		seen[p] = true
	}
	if len(seen) != 20 {
		t.Error("passwords repeat")
	}
	if _, err := Password(strings.NewReader("short")); err == nil {
		t.Error("short random input accepted")
	}
}

func nil2() io.Reader { return crand.Reader }

func TestEnvFileAndParsing(t *testing.T) {
	txt := EnvFileText("budget-wallet", "pw123")
	if txt != "BW_KEY_ALIAS=budget-wallet\nBW_KEYSTORE_PASSWORD=pw123\nBW_KEY_PASSWORD=pw123\n" {
		t.Errorf("env file %q", txt)
	}
	if v, ok := EnvValue(txt, "BW_KEYSTORE_PASSWORD"); !ok || v != "pw123" {
		t.Errorf("EnvValue %q %v", v, ok)
	}
	if _, ok := EnvValue(txt, "NOPE"); ok {
		t.Error("missing key found")
	}
	if v, _ := EnvValue("X_BW_KEY_ALIAS=a\nBW_KEY_ALIAS=b\n", "BW_KEY_ALIAS"); v != "b" {
		t.Errorf("prefix match: %q", v)
	}
}

func TestCertLine(t *testing.T) {
	out := "Keystore type: PKCS12\nCertificate fingerprints:\n\t SHA1: AA:BB\n\t SHA256: 12:34:56\nSignature algorithm name: SHA256withRSA\n"
	if got, ok := CertLine(out); !ok || got != "Certificate SHA256: 12:34:56" {
		t.Errorf("got %q %v", got, ok)
	}
	if _, ok := CertLine("nothing here\n"); ok {
		t.Error("found a fingerprint in nothing")
	}
	if got, _ := CertLine("SHA256: x\nSHA256: y\n"); got != "Certificate SHA256: x" {
		t.Errorf("first only: %q", got)
	}
}

func TestDir(t *testing.T) {
	if got := Dir(sys.Env{"BW_SIGNING_DIR=/k", "HOME=/h"}); got != "/k" {
		t.Errorf("got %q", got)
	}
	if got := Dir(sys.Env{"HOME=/h"}); got != "/h/.config/budget-wallet" {
		t.Errorf("got %q", got)
	}
}

// keytoolFake answers genkeypair by writing a keystore file and list by printing a fingerprint.
func keytoolFake() func(c sys.Cmd) int {
	return func(c sys.Cmd) int {
		switch {
		case c.Argv[0] == "keytool" && c.Argv[1] == "-genkeypair":
			for i, a := range c.Argv {
				if a == "-keystore" {
					os.WriteFile(c.Argv[i+1], []byte("keystore bytes"), 0o644)
				}
			}
		case c.Argv[0] == "keytool" && c.Argv[1] == "-list":
			io.WriteString(c.Stdout, "Certificate fingerprints:\n\t SHA256: DE:AD:BE:EF\n")
		}
		return 0
	}
}

func TestCreateCallsKeytoolAndWritesPrivateFiles(t *testing.T) {
	fake := &sys.Fake{}
	fake.Handle = keytoolFake()
	f := newFixture(t, fake)
	if rc := f.m.Main(nil); rc != 0 {
		t.Fatalf("rc %d err %q", rc, f.err.String())
	}
	ks := filepath.Join(f.dir, "android-release.jks")
	if len(fake.Calls) != 2 {
		t.Fatalf("calls %v", fake.Argvs())
	}
	gen := fake.Calls[0].Argv
	pass := fake.Calls[0].Env.Get(PassEnv) // the password reaches keytool through its environment
	wantGen := []string{"keytool", "-genkeypair", "-keystore", ks, "-storetype", "PKCS12", "-alias", "budget-wallet", "-keyalg", "RSA", "-keysize", "4096",
		"-validity", "20000", "-dname", "CN=Budget Wallet", "-storepass:env", PassEnv, "-keypass:env", PassEnv}
	if strings.Join(gen, "\x00") != strings.Join(wantGen, "\x00") || pass == "" {
		t.Errorf("genkeypair argv %q", gen)
	}
	if list := strings.Join(fake.Calls[1].Argv, " "); list != "keytool -list -keystore "+ks+" -storepass:env "+PassEnv+" -v" || fake.Calls[1].Env.Get(PassEnv) != pass {
		t.Errorf("list argv %q", list)
	}
	// the password is on no command line (it would show in /proc/<pid>/cmdline)
	for _, c := range fake.Calls {
		for _, a := range c.Argv {
			if strings.Contains(a, pass) {
				t.Errorf("the password is in argv: %q", c.Argv)
			}
		}
	}
	env, err := os.ReadFile(filepath.Join(f.dir, "signing.env"))
	if err != nil || string(env) != EnvFileText("budget-wallet", pass) {
		t.Errorf("signing.env %q, %v", env, err)
	}
	for p, mode := range map[string]os.FileMode{f.dir: 0o700, ks: 0o600, filepath.Join(f.dir, "signing.env"): 0o600} {
		if st, err := os.Stat(p); err != nil || st.Mode().Perm() != mode {
			t.Errorf("%s: mode %v, %v (want %v)", p, st.Mode().Perm(), err, mode)
		}
	}
	if got := f.out.String(); got != "Created "+ks+"\nCertificate SHA256: DE:AD:BE:EF\n" {
		t.Errorf("out %q", got)
	}
	// no password in anything we print
	if strings.Contains(f.out.String()+f.err.String(), pass) {
		t.Error("the password was printed")
	}
}

func TestExistingKeyIsNeverOverwritten(t *testing.T) {
	for _, existing := range []string{"android-release.jks", "signing.env"} {
		fake := &sys.Fake{}
		f := newFixture(t, fake)
		os.MkdirAll(f.dir, 0o700)
		os.WriteFile(filepath.Join(f.dir, existing), []byte("BW_KEYSTORE_PASSWORD=old\n"), 0o600)
		fake.Handle = func(c sys.Cmd) int {
			if c.Argv[1] == "-genkeypair" {
				t.Error("keytool -genkeypair ran with a key present")
			}
			io.WriteString(c.Stdout, "\t SHA256: 11:22\n")
			return 0
		}
		rc := f.m.Main(nil)
		b, _ := os.ReadFile(filepath.Join(f.dir, existing))
		if string(b) != "BW_KEYSTORE_PASSWORD=old\n" {
			t.Errorf("%s was changed: %q", existing, b)
		}
		if want := "Signing key already exists in " + f.dir + " \u2014 not overwriting it.\n"; !strings.HasPrefix(f.out.String(), want) {
			t.Errorf("out %q", f.out.String())
		}
		if existing == "android-release.jks" { // a keystore without its signing.env: the password is unknown, nothing is created
			if rc != 1 || len(fake.Calls) != 0 {
				t.Errorf("jks only: rc %d calls %v", rc, fake.Argvs())
			}
			if _, err := os.Stat(filepath.Join(f.dir, "signing.env")); err == nil {
				t.Error("signing.env created next to an existing keystore")
			}
			continue
		}
		if rc != 0 || !strings.HasSuffix(f.out.String(), "Certificate SHA256: 11:22\n") {
			t.Errorf("%s: rc %d err %q out %q", existing, rc, f.err.String(), f.out.String())
		}
		if len(fake.Calls) != 1 || fake.Calls[0].Env.Get(PassEnv) != "old" || strings.Contains(strings.Join(fake.Calls[0].Argv, " "), "old") {
			t.Errorf("calls %v", fake.Argvs())
		}
	}
}

func TestKeytoolFailures(t *testing.T) {
	// genkeypair fails: no env file is written
	fake := &sys.Fake{Handle: func(c sys.Cmd) int { return 1 }}
	f := newFixture(t, fake)
	if rc := f.m.Main(nil); rc != 1 {
		t.Errorf("rc %d", rc)
	}
	if _, err := os.Stat(filepath.Join(f.dir, "signing.env")); err == nil {
		t.Error("signing.env written although keytool failed")
	}
	// list fails (wrong password): the script ends with that status; no fingerprint printed
	fake = &sys.Fake{Handle: func(c sys.Cmd) int {
		if c.Argv[1] == "-list" {
			return 2
		}
		os.WriteFile(c.Argv[3], []byte("k"), 0o600)
		return 0
	}}
	f = newFixture(t, fake)
	if rc := f.m.Main(nil); rc != 2 || strings.Contains(f.out.String(), "SHA256") {
		t.Errorf("rc %d out %q", rc, f.out.String())
	}
	// list prints no fingerprint
	fake = &sys.Fake{Handle: func(c sys.Cmd) int {
		if c.Argv[1] == "-genkeypair" {
			os.WriteFile(c.Argv[3], []byte("k"), 0o600)
		}
		return 0
	}}
	f = newFixture(t, fake)
	if rc := f.m.Main(nil); rc != 1 {
		t.Errorf("no fingerprint: rc %d", rc)
	}
}

func TestPasswordsAreRedactedFromKeytoolOutput(t *testing.T) {
	fake := &sys.Fake{}
	fake.Handle = func(c sys.Cmd) int {
		if c.Argv[1] == "-genkeypair" {
			os.WriteFile(c.Argv[3], []byte("k"), 0o600)
			io.WriteString(c.Stderr, "keytool says storepass "+c.Env.Get(PassEnv)+"\n")
			return 0
		}
		io.WriteString(c.Stdout, "\t SHA256: AA\n")
		return 0
	}
	f := newFixture(t, fake)
	if rc := f.m.Main(nil); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if strings.Contains(f.err.String(), fake.Calls[0].Env.Get(PassEnv)) || !strings.Contains(f.err.String(), "keytool says storepass") {
		t.Errorf("stderr %q", f.err.String())
	}
}

// Upload is tested with a fake gh only: the secrets go through stdin, never through a command line, and nothing real is written.
func TestUploadSendsSecretsOnStdin(t *testing.T) {
	var stdin = map[string]string{}
	fake := &sys.Fake{}
	fake.Handle = func(c sys.Cmd) int {
		switch c.Argv[0] {
		case "keytool":
			if c.Argv[1] == "-genkeypair" {
				os.WriteFile(c.Argv[3], []byte("keystore bytes"), 0o600)
			} else {
				io.WriteString(c.Stdout, "\t SHA256: AA\n")
			}
		case "gh":
			b, _ := io.ReadAll(c.Stdin)
			stdin[c.Argv[3]] = string(b)
		}
		return 0
	}
	f := newFixture(t, fake)
	if rc := f.m.Main([]string{"--upload"}); rc != 0 {
		t.Fatalf("rc %d err %q", rc, f.err.String())
	}
	env, _ := os.ReadFile(filepath.Join(f.dir, "signing.env"))
	pass, _ := EnvValue(string(env), "BW_KEYSTORE_PASSWORD")
	want := map[string]string{
		"ANDROID_KEYSTORE_BASE64":   base64.StdEncoding.EncodeToString([]byte("keystore bytes")),
		"ANDROID_KEYSTORE_PASSWORD": pass,
		"ANDROID_KEY_ALIAS":         "budget-wallet",
	}
	for k, v := range want {
		if stdin[k] != v {
			t.Errorf("%s: stdin %q, want %q", k, stdin[k], v)
		}
	}
	for _, c := range fake.Calls {
		if c.Argv[0] == "gh" {
			if strings.Join(c.Argv[:3], " ") != "gh secret set" || len(c.Argv) != 4 {
				t.Errorf("gh argv %v", c.Argv)
			}
			for _, a := range c.Argv {
				if a == pass || a == want["ANDROID_KEYSTORE_BASE64"] {
					t.Error("a secret is on a command line")
				}
			}
		}
	}
	if !strings.HasSuffix(f.out.String(), "Uploaded to GitHub Actions secrets: ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS\n") {
		t.Errorf("out %q", f.out.String())
	}
	// a failing gh stops the upload with its status
	fake2 := &sys.Fake{Handle: func(c sys.Cmd) int {
		if c.Argv[0] == "gh" {
			return 4
		}
		return fake.Handle(c)
	}}
	f = newFixture(t, fake2)
	if rc := f.m.Main([]string{"--upload"}); rc != 4 || strings.Contains(f.out.String(), "Uploaded") {
		t.Errorf("rc %d out %q", rc, f.out.String())
	}
}

func TestNoUploadWithoutTheFlag(t *testing.T) {
	fake := &sys.Fake{Handle: func(c sys.Cmd) int {
		if c.Argv[1] == "-genkeypair" {
			os.WriteFile(c.Argv[3], []byte("k"), 0o600)
		} else {
			io.WriteString(c.Stdout, "\t SHA256: AA\n")
		}
		return 0
	}}
	f := newFixture(t, fake)
	f.m.Main([]string{"something-else"})
	for _, c := range fake.Calls {
		if c.Argv[0] == "gh" {
			t.Error("gh was called without --upload")
		}
	}
}

// With the real keytool of the host (skipped without one): a key is created in a temp folder, the fingerprint printed, a
// second run refuses to overwrite it, and the keystore opens with the password of signing.env.
func TestRealKeytool(t *testing.T) {
	if testing.Short() {
		t.Skip("short")
	}
	if _, err := exec.LookPath("keytool"); err != nil {
		t.Skip("no keytool on the host")
	}
	f := newFixture(t, sys.Real{})
	f.m.Rand = New(f.m.C).Rand
	if rc := f.m.Main(nil); rc != 0 {
		t.Fatalf("rc %d err %q", rc, f.err.String())
	}
	if !regexp.MustCompile(`(?m)^Certificate SHA256: ([0-9A-F]{2}:){31}[0-9A-F]{2}$`).MatchString(f.out.String()) {
		t.Errorf("out %q", f.out.String())
	}
	ks := filepath.Join(f.dir, "android-release.jks")
	env, _ := os.ReadFile(filepath.Join(f.dir, "signing.env"))
	pass, _ := EnvValue(string(env), "BW_KEYSTORE_PASSWORD")
	if st, _ := os.Stat(ks); st.Mode().Perm() != 0o600 {
		t.Errorf("keystore mode %v", st.Mode().Perm())
	}
	if strings.Contains(f.out.String()+f.err.String(), pass) {
		t.Error("the password was printed")
	}
	before, _ := os.ReadFile(ks)
	f2 := &fixture{out: &bytes.Buffer{}, err: &bytes.Buffer{}, dir: f.dir}
	f2.m = &Maker{C: run.New(t.TempDir(), sys.Env{"BW_SIGNING_DIR=" + f.dir}, f2.out, f2.err, sys.Real{}), Rand: f.m.Rand}
	if rc := f2.m.Main(nil); rc != 0 || !strings.Contains(f2.out.String(), "not overwriting it") {
		t.Errorf("second run: rc %d out %q", rc, f2.out.String())
	}
	if after, _ := os.ReadFile(ks); !bytes.Equal(before, after) {
		t.Error("the keystore changed")
	}
	out, err := exec.Command("keytool", "-list", "-keystore", ks, "-storepass", pass).CombinedOutput()
	if err != nil || !strings.Contains(string(out), "budget-wallet") {
		t.Errorf("keytool -list: %v %s", err, out)
	}
}
