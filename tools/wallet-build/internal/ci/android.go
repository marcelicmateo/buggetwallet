package ci

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// appendFile appends text to the file named by an Actions variable (GITHUB_ENV, GITHUB_OUTPUT); without it the text goes to stdout.
func (x *CI) appendFile(envVar, text string) error {
	p := x.C.Getenv(envVar)
	if p == "" {
		x.C.Printf("%s", text)
		return nil
	}
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(text)
	return err
}

// logError prints a workflow error annotation and adds it to $LOG, like the old `echo ::error:: | tee -a "$LOG"`.
func (x *CI) logError(msg string) {
	line := "::error::" + msg + "\n"
	x.C.Printf("%s", line)
	if p := x.C.Getenv("LOG"); p != "" {
		if f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644); err == nil {
			_, _ = f.WriteString(line)
			f.Close()
		}
	}
}

// Keystore is `ci keystore`: decodes $ANDROID_KEYSTORE_BASE64 to $RUNNER_TEMP/release.jks (mode 0600) and sets BW_KEYSTORE for the
// later steps through $GITHUB_ENV. A missing or unreadable secret is exit 1 with an ::error::; the value is never printed.
func (x *CI) Keystore(args []string) int {
	c := x.C
	if len(args) != 0 {
		return 2
	}
	b64 := strings.Join(strings.Fields(c.Getenv("ANDROID_KEYSTORE_BASE64")), "")
	if b64 == "" {
		x.logError("ANDROID_KEYSTORE_BASE64 secret missing (run tools/make-signing-key.sh --upload)")
		return 1
	}
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(raw) == 0 {
		x.logError("ANDROID_KEYSTORE_BASE64 is not valid base64 (run tools/make-signing-key.sh --upload)")
		return 1
	}
	path := filepath.Join(x.tempDir(), "release.jks")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		x.logError("cannot write the keystore file")
		return 1
	}
	if err := x.appendFile("GITHUB_ENV", "BW_KEYSTORE="+path+"\n"); err != nil {
		x.logError("cannot write GITHUB_ENV")
		return 1
	}
	return 0
}

var reNDK = regexp.MustCompile(`val ndkVersion\s*:\s*String\s*=\s*"([^"]+)"`)

// ndkVersion is the NDK version the installed Flutter SDK builds with (its FlutterExtension.kt).
func (x *CI) ndkVersion() (string, bool) {
	flutter, err := x.C.R.LookPath("flutter")
	if err != nil {
		return "", false
	}
	root := filepath.Dir(filepath.Dir(flutter))
	b, err := os.ReadFile(filepath.Join(root, "packages", "flutter_tools", "gradle", "src", "main", "kotlin", "FlutterExtension.kt"))
	if err != nil {
		return "", false
	}
	m := reNDK.FindSubmatch(b)
	if m == nil {
		return "", false
	}
	return string(m[1]), true
}

// AndroidKey is `ci android-key`: writes ndk, ndk-dir and cmake-dir to $GITHUB_OUTPUT for the Gradle/NDK/CMake cache key.
func (x *CI) AndroidKey(args []string) int {
	c := x.C
	if len(args) != 0 {
		return 2
	}
	ndk, ok := x.ndkVersion()
	if !ok {
		x.logError("cannot read the NDK version from the Flutter SDK (FlutterExtension.kt)")
		return 1
	}
	home := c.Getenv("ANDROID_HOME")
	out := "ndk=" + ndk + "\nndk-dir=" + home + "/ndk/" + ndk + "\ncmake-dir=" + home + "/cmake/3.22.1\n"
	if err := x.appendFile("GITHUB_OUTPUT", out); err != nil {
		c.Eprintf("ci android-key: %v\n", err)
		return 1
	}
	return 0
}
