package tokenusage

import (
	"bytes"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type goldenCase struct {
	Name      string
	Args      []string
	JSON      bool
	Exit      int
	Stdout    string
	Stderr    string
	JSONText  string   `json:"json_text"`
	GitArgs   []string `json:"git_args"`
	GitStdout string   `json:"git_stdout"`
}

// copyHome copies testdata/home (synthetic transcripts, project dir "PROJECT") to a temp HOME under the name the repo maps to.
func copyHome(t *testing.T, repo string) string {
	t.Helper()
	home := t.TempDir()
	dst := filepath.Join(home, ".claude", "projects", strings.NewReplacer("/", "-", ".", "-").Replace(repo))
	src := filepath.Join("testdata", "home", ".claude", "projects", "PROJECT")
	err := filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		if d.IsDir() {
			return os.MkdirAll(filepath.Join(dst, rel), 0o755)
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(dst, rel), b, 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
	return home
}

// The goldens are what the real tools/token-usage.py printed for the same synthetic transcripts (testdata/gen_golden.py).
func TestMatchesPython(t *testing.T) {
	raw, err := os.ReadFile("testdata/cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var g struct{ Cases []goldenCase }
	if err := json.Unmarshal(raw, &g); err != nil {
		t.Fatal(err)
	}
	if len(g.Cases) < 6 {
		t.Fatalf("%d cases", len(g.Cases))
	}
	repo := "/x/repo.d"
	for _, c := range g.Cases {
		t.Run(c.Name, func(t *testing.T) {
			home := copyHome(t, repo)
			if c.Name == "no-transcripts" {
				home = t.TempDir()
			}
			o := Opts{Home: home}
			for i := 0; i < len(c.Args); i += 2 {
				switch c.Args[i] {
				case "--since":
					o.Since = c.Args[i+1]
				case "--until":
					o.Until = c.Args[i+1]
				}
			}
			jsonPath := filepath.Join(t.TempDir(), "out.json")
			if c.JSON {
				o.JSON = jsonPath
			}
			git := func(dir string, args ...string) (string, int) {
				if dir != repo {
					t.Errorf("git runs in %q, want the repo", dir)
				}
				if !reflect.DeepEqual(args, c.GitArgs) {
					t.Errorf("git args %q, want %q", args, c.GitArgs)
				}
				return c.GitStdout, 0
			}
			var out, errb bytes.Buffer
			rc := Run(o, repo, git, &out, &errb)
			pdir := ProjectDir(home, repo)
			want := strings.NewReplacer("{JSON}", jsonPath, "{PDIR}", pdir).Replace(c.Stdout)
			if rc != c.Exit || out.String() != want {
				t.Errorf("exit %d (want %d)\n--- got\n%s\n--- want\n%s", rc, c.Exit, out.String(), want)
			}
			if wantErr := strings.NewReplacer("{HOME}", home, "{MANGLED}", strings.NewReplacer("/", "-", ".", "-").Replace(repo)).Replace(c.Stderr); errb.String() != wantErr {
				t.Errorf("stderr %q, want %q", errb.String(), wantErr)
			}
			if c.JSON {
				if b, err := os.ReadFile(jsonPath); err != nil || string(b) != c.JSONText {
					t.Errorf("json file differs (err %v):\n%s\nwant\n%s", err, b, c.JSONText)
				}
			}
		})
	}
}

func TestPercentileOfRequestsKeepsMostOutputPerID(t *testing.T) {
	// one request logged as three lines: the line with the most output tokens counts once
	dir := t.TempDir()
	p := filepath.Join(dir, "s.jsonl")
	lines := `{"type":"assistant","requestId":"a","timestamp":"2026-01-01T00:00:00Z","message":{"model":"m","usage":{"output_tokens":3}}}
{"type":"assistant","requestId":"a","timestamp":"2026-01-01T00:00:01Z","message":{"model":"m","usage":{"output_tokens":9}}}
{"type":"assistant","requestId":"a","timestamp":"2026-01-01T00:00:02Z","message":{"model":"m","usage":{"output_tokens":5}}}`
	if err := os.WriteFile(p, []byte(lines), 0o644); err != nil { // no final newline
		t.Fatal(err)
	}
	reqs, err := requests(p)
	if err != nil || len(reqs) != 1 || reqs[0].output != 9 || reqs[0].day != "2026-01-01" {
		t.Errorf("%+v %v", reqs, err)
	}
}

func TestProjectDirMapsSlashAndDot(t *testing.T) {
	if got := ProjectDir("/h", "/home/u/proj.x/.claude/w"); got != "/h/.claude/projects/-home-u-proj-x--claude-w" {
		t.Error(got)
	}
}

func TestJSONWriteFailure(t *testing.T) {
	home := copyHome(t, "/x/repo.d")
	var out, errb bytes.Buffer
	rc := Run(Opts{Home: home, JSON: filepath.Join(t.TempDir(), "no", "such", "dir.json")}, "/x/repo.d", func(string, ...string) (string, int) { return "", 0 }, &out, &errb)
	if rc != 1 || errb.Len() == 0 {
		t.Errorf("rc %d err %q", rc, errb.String())
	}
}
