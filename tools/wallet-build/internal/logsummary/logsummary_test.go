package logsummary

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The goldens are what the real tools/log-summary.py printed for the same synthetic logs (testdata/gen_golden.py).
func TestMatchesPython(t *testing.T) {
	raw, err := os.ReadFile("testdata/cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var g struct {
		Cases []struct {
			Name   string
			Files  []string
			Exit   int
			Stdout string
		}
	}
	if err := json.Unmarshal(raw, &g); err != nil {
		t.Fatal(err)
	}
	if len(g.Cases) < 8 {
		t.Fatalf("%d cases", len(g.Cases))
	}
	logs, _ := filepath.Abs("testdata/logs")
	for _, c := range g.Cases {
		t.Run(c.Name, func(t *testing.T) {
			var args []string
			for _, f := range c.Files {
				args = append(args, filepath.Join(logs, f))
			}
			var out, errb bytes.Buffer
			rc := Run(args, &out, &errb)
			want := strings.ReplaceAll(c.Stdout, "{LOGS}", logs)
			if rc != c.Exit || out.String() != want || errb.Len() != 0 {
				t.Errorf("exit %d (want %d), stderr %q\n--- got\n%s\n--- want\n%s", rc, c.Exit, errb.String(), out.String(), want)
			}
		})
	}
}

func TestUsage(t *testing.T) {
	for _, args := range [][]string{nil, {"-h"}, {"--help"}} {
		var out bytes.Buffer
		if rc := Run(args, &out, &bytes.Buffer{}); rc != 2 || !strings.Contains(out.String(), "log-summary <logfile>") {
			t.Errorf("%v: rc %d out %q", args, rc, out.String())
		}
	}
}

func TestMissingFile(t *testing.T) {
	var out, errb bytes.Buffer
	if rc := Run([]string{filepath.Join(t.TempDir(), "nope.log")}, &out, &errb); rc != 1 || out.Len() != 0 || errb.Len() == 0 {
		t.Errorf("rc %d out %q err %q", rc, out.String(), errb.String())
	}
}

func TestNumberFormats(t *testing.T) {
	for _, c := range []struct {
		f    float64
		want string
	}{{12, "12"}, {2.25, "2.2"}, {2.35, "2.4"}, {100.75, "100.8"}, {0.04, "0.0"}, {1e15, "1000000000000000"}} {
		if got := fmtFloat(c.f); got != c.want {
			t.Errorf("fmtFloat(%v) = %q, want %q", c.f, got, c.want)
		}
	}
}
