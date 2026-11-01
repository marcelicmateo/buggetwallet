package ci

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// Jobs are the jobs of ci.yml whose logs are merged, in the order of the log; PublishJob only shows in the job results line.
var (
	Jobs       = []string{"lint", "importer", "core", "relay", "app", "desktop", "apk", "linux"}
	PublishJob = "publish"
)

func readFile(path string) string {
	b, _ := os.ReadFile(path)
	return string(b)
}

// paste is `paste -sd' '`: the lines of s joined by one space, with a final newline.
func paste(s string) string {
	if s == "" {
		return ""
	}
	return strings.Join(strings.Split(strings.TrimSuffix(s, "\n"), "\n"), " ") + "\n"
}

// MergeLog assembles the text of latest.txt (after the header publish-log adds) from the ci-log-<job> artifact folders in dir
// and the results of the jobs ("success", "skipped", …):
//
//	line 1  per job its outcome.txt, or "<job>=<result>" when the job has none (skipped, or died before its last step)
//	line 2  "job:<job>=<result> " for each job and publish (with the trailing space)
//	blank, "step seconds exit", every job's times.txt, then each job's ci.log after a blank line
//
// and the concatenated history.jsonl files.
func MergeLog(dir string, results map[string]string) (text, history string) {
	var frag, sb, hist strings.Builder
	for _, j := range Jobs {
		d := filepath.Join(dir, "ci-log-"+j)
		if st, err := os.Stat(filepath.Join(d, "outcome.txt")); err == nil && st.Size() > 0 {
			frag.WriteString(readFile(filepath.Join(d, "outcome.txt")))
		} else {
			frag.WriteString(j + "=" + results[j] + "\n")
		}
	}
	sb.WriteString(paste(frag.String()))
	for _, j := range append(append([]string{}, Jobs...), PublishJob) {
		sb.WriteString("job:" + j + "=" + results[j] + " ")
	}
	sb.WriteString("\n\nstep seconds exit\n")
	for _, j := range Jobs {
		sb.WriteString(readFile(filepath.Join(dir, "ci-log-"+j, "times.txt")))
	}
	for _, j := range Jobs {
		sb.WriteString("\n" + readFile(filepath.Join(dir, "ci-log-"+j, "ci.log")))
		hist.WriteString(readFile(filepath.Join(dir, "ci-log-"+j, "history.jsonl")))
	}
	return sb.String(), hist.String()
}

// Merge is `ci merge --artifacts DIR --needs-json JSON --out FILE --history FILE`: JSON is the workflow's toJSON(needs).
func (x *CI) Merge(args []string) int {
	c := x.C
	v, ok := flagValues(args, "--artifacts", "--needs-json", "--out", "--history")
	if !ok || v["--artifacts"] == "" || v["--out"] == "" || v["--history"] == "" {
		return 2
	}
	var needs map[string]struct {
		Result string `json:"result"`
	}
	if j := v["--needs-json"]; j != "" {
		if err := json.Unmarshal([]byte(j), &needs); err != nil {
			c.Eprintf("ci merge: --needs-json: %v\n", err)
			return 2
		}
	}
	results := map[string]string{}
	for j, n := range needs {
		results[j] = n.Result
	}
	text, hist := MergeLog(v["--artifacts"], results)
	for path, body := range map[string]string{v["--out"]: text, v["--history"]: hist} {
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			c.Eprintf("ci merge: %v\n", err)
			return 1
		}
	}
	return 0
}
