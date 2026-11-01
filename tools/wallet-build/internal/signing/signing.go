// Package signing ports tools/make-signing-key.sh: it creates the one Android signing key every release build uses (local and
// CI), so updates install over the existing app instead of needing an uninstall that wipes the wallet.
//
// The key never goes into git and never into a log: the passwords are registered with the run's redactor, and nothing here
// prints them. Back up the whole signing folder (~/.config/budget-wallet/): if the key is lost, the next APK can't update the
// installed app.
package signing

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

// Usage is what `signing-key` prints for a wrong command line.
const Usage = `Creates the one Android signing key every release build uses (local and CI), so updates install
over the existing app instead of needing an uninstall that wipes the wallet.

  wallet-build signing-key            create the key in ~/.config/budget-wallet/ (refuses to overwrite)
  wallet-build signing-key --upload   also store it as GitHub Actions secrets for CI

The key never goes into git. Back up the whole ~/.config/budget-wallet/ folder (e.g. in a password
manager): if the key is lost, the next APK can't update the installed app.
`

// Alias is the key alias in the keystore and in signing.env.
const Alias = "budget-wallet"

// Maker is one invocation of `signing-key`.
type Maker struct {
	C *run.Ctx
	// Rand supplies the password bytes; crypto/rand unless a test replaces it.
	Rand io.Reader
}

// New returns a Maker with crypto/rand.
func New(c *run.Ctx) *Maker { return &Maker{C: c, Rand: rand.Reader} }

// Dir is the signing folder: $BW_SIGNING_DIR or ~/.config/budget-wallet.
func Dir(env sys.Env) string {
	if d := env.Get("BW_SIGNING_DIR"); d != "" {
		return d
	}
	return filepath.Join(env.Get("HOME"), ".config", "budget-wallet")
}

// Password is 24 random bytes in base64 without '/', '+' and '=' (head -c 24 /dev/urandom | base64 | tr -d '/+=').
func Password(r io.Reader) (string, error) {
	b := make([]byte, 24)
	if _, err := io.ReadFull(r, b); err != nil {
		return "", err
	}
	return strings.NewReplacer("/", "", "+", "", "=", "").Replace(base64.StdEncoding.EncodeToString(b)), nil
}

// EnvFileText is the content of signing.env.
func EnvFileText(alias, pass string) string {
	return fmt.Sprintf("BW_KEY_ALIAS=%s\nBW_KEYSTORE_PASSWORD=%s\nBW_KEY_PASSWORD=%s\n", alias, pass, pass)
}

// EnvValue reads KEY=value from signing.env text (grep -oP '^KEY=\K.*').
func EnvValue(text, key string) (string, bool) {
	for _, l := range strings.Split(text, "\n") {
		if v, ok := strings.CutPrefix(l, key+"="); ok {
			return v, true
		}
	}
	return "", false
}

// CertLine turns the output of `keytool -list -v` into the one line the script prints: its first line with "SHA256:", the
// leading blanks replaced by "Certificate " (grep -m1 'SHA256:' | sed 's/^\s*/Certificate /').
func CertLine(keytoolOut string) (string, bool) {
	for _, l := range strings.Split(keytoolOut, "\n") {
		if strings.Contains(l, "SHA256:") {
			return "Certificate " + strings.TrimLeft(l, " \t\r\f\v"), true
		}
	}
	return "", false
}

// Main is `signing-key [--upload]`: 0 ok, 1 a tool failed.
func (m *Maker) Main(args []string) int {
	c := m.C
	dir := Dir(c.Env)
	keystore := filepath.Join(dir, "android-release.jks")
	envFile := filepath.Join(dir, "signing.env")
	if exists(keystore) || exists(envFile) {
		c.Printf("Signing key already exists in %s — not overwriting it.\n", dir)
	} else if rc := m.create(dir, keystore, envFile); rc != 0 {
		return rc
	}
	text, err := os.ReadFile(envFile)
	if err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	pass, _ := EnvValue(string(text), "BW_KEYSTORE_PASSWORD")
	c.Red = sys.NewRedactor(c.Env, sys.ReadSecretsFile(envFile)...)
	var list strings.Builder
	ew := c.Red.Writer(c.Err)
	rc := c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"keytool", "-list", "-keystore", keystore, "-storepass", pass, "-v"}, Env: c.Env, Stdout: &list, Stderr: ew})
	_ = ew.Close()
	if rc != 0 {
		return rc
	}
	line, ok := CertLine(list.String())
	if !ok {
		return 1 // grep found no fingerprint: the script ends silently with status 1
	}
	c.Printf("%s\n", line)

	if len(args) > 0 && args[0] == "--upload" {
		return m.upload(keystore, string(text))
	}
	return 0
}

func exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

func (m *Maker) create(dir, keystore, envFile string) int {
	c := m.C
	if err := os.MkdirAll(dir, 0o755); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	pass, err := Password(m.Rand)
	if err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	c.Red = sys.NewRedactor(c.Env, pass)
	old := syscall.Umask(0o077) // the keystore is private from the first byte (the script chmod'ed it afterwards)
	defer syscall.Umask(old)
	ew := c.Red.Writer(c.Err)
	defer ew.Close()
	if rc := c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"keytool", "-genkeypair", "-keystore", keystore, "-storetype", "PKCS12", "-alias", Alias,
		"-keyalg", "RSA", "-keysize", "4096", "-validity", "20000", "-dname", "CN=Budget Wallet", "-storepass", pass, "-keypass", pass},
		Env: c.Env, Stderr: ew}); rc != 0 {
		return rc
	}
	if err := os.WriteFile(envFile, []byte(EnvFileText(Alias, pass)), 0o600); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	_ = os.Chmod(keystore, 0o600)
	_ = os.Chmod(envFile, 0o600)
	c.Printf("Created %s\n", keystore)
	return 0
}

// upload stores the key as GitHub Actions secrets; every value goes to gh on stdin, none on a command line.
func (m *Maker) upload(keystore, envText string) int {
	c := m.C
	ks, err := os.ReadFile(keystore)
	if err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	pass, _ := EnvValue(envText, "BW_KEYSTORE_PASSWORD")
	alias, _ := EnvValue(envText, "BW_KEY_ALIAS")
	ew := c.Red.Writer(c.Err)
	defer ew.Close()
	for _, s := range []struct{ name, value string }{
		{"ANDROID_KEYSTORE_BASE64", base64.StdEncoding.EncodeToString(ks)},
		{"ANDROID_KEYSTORE_PASSWORD", pass},
		{"ANDROID_KEY_ALIAS", alias},
	} {
		if rc := c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"gh", "secret", "set", s.name}, Env: c.Env, Stdin: strings.NewReader(s.value), Stderr: ew}); rc != 0 {
			return rc
		}
	}
	c.Printf("Uploaded to GitHub Actions secrets: ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS\n")
	return 0
}
