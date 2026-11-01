package run

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// KeepRuns is how many finished run directories prune keeps.
const KeepRuns = 30

// Dir is the run a host command writes into (nil for nested calls that join the outer run).
type Dir struct {
	Path string
	ID   string
	c    *Ctx
}

// Begin starts a run: dir under runs/ (unique even when worktrees start at the same second), .running marker, prune,
// dist/logs link. A nested call (BW_RUN_DIR already set) keeps the outer run and returns nil.
func (c *Ctx) Begin(cmd string) (*Dir, error) {
	if c.Env.Get("BW_RUN_DIR") != "" {
		return nil, nil
	}
	c.TimingInit(cmd)
	if err := os.MkdirAll(filepath.Join(c.Data, "runs"), 0o755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(c.Data, "history"), 0o755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(c.Root, "dist"), 0o755); err != nil {
		return nil, err
	}
	base := filepath.Join(c.Data, "runs", c.Clock().Format("20060102-150405")+"-"+cmd+"-"+c.Env.Get("BW_COMMIT"))
	dir := base
	for n := 2; ; n++ {
		err := os.Mkdir(dir, 0o755)
		if err == nil {
			break
		}
		if !os.IsExist(err) {
			return nil, err
		}
		dir = fmt.Sprintf("%s-%d", base, n)
	}
	d := &Dir{Path: dir, ID: filepath.Base(dir), c: c}
	if err := os.WriteFile(filepath.Join(dir, ".running"), nil, 0o644); err != nil {
		return nil, err
	}
	c.PruneRuns()
	c.Setenv("BW_RUN_DIR", dir, "BW_RUN_ID", d.ID)
	logs := filepath.Join(c.Root, "dist", "logs")
	if st, err := os.Lstat(logs); err == nil && st.Mode()&os.ModeSymlink == 0 && st.IsDir() {
		_ = os.RemoveAll(logs) // pre-symlink layout
	}
	c.Link(dir)
	return d, nil
}

// Link points dist/logs at dir (ln -sfn).
func (c *Ctx) Link(dir string) {
	logs := filepath.Join(c.Root, "dist", "logs")
	tmp := logs + ".new"
	_ = os.Remove(tmp)
	if err := os.Symlink(dir, tmp); err == nil {
		if os.Rename(tmp, logs) != nil {
			_ = os.Remove(tmp)
		}
	}
}

// Finish is the EXIT trap of a run: last.status and last-failed.txt, then the .running marker goes.
func (d *Dir) Finish(code int) {
	if d == nil {
		return
	}
	d.c.WriteLast(d.Path, code)
	_ = os.Remove(filepath.Join(d.Path, ".running"))
}

// PruneRuns keeps every run in progress (.running younger than 24 h) and the newest KeepRuns finished ones. Under the same
// flock as tools/timing.sh, so bash and Go runs can mix.
func (c *Ctx) PruneRuns() {
	lock, err := os.OpenFile(filepath.Join(c.Data, ".prune.lock"), os.O_WRONLY|os.O_CREATE, 0o644)
	if err != nil {
		return
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		return
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	ents, err := os.ReadDir(filepath.Join(c.Data, "runs"))
	if err != nil {
		return
	}
	var finished []string
	for _, e := range ents { // ReadDir sorts by name, and names start with the timestamp
		if !e.IsDir() {
			continue
		}
		d := filepath.Join(c.Data, "runs", e.Name())
		if st, err := os.Stat(filepath.Join(d, ".running")); err == nil && c.Clock().Sub(st.ModTime()) <= 1440*time.Minute {
			continue
		}
		finished = append(finished, d)
	}
	if len(finished) > KeepRuns {
		for _, d := range finished[:len(finished)-KeepRuns] {
			_ = os.RemoveAll(d)
		}
	}
}

// WriteLast writes last.status ("<step> ok|failed <seconds>", in start order) and last-failed.txt ("<step> <log path>" per
// failed step, empty when green) from the run's <step>.status files. A non-zero exit without a failed step is listed as "run".
func (c *Ctx) WriteLast(dir string, code int) {
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return
	}
	files, _ := filepath.Glob(filepath.Join(dir, "*.status"))
	type row struct {
		at                int64
		written           int64 // .status mtime (ns): steps run one after the other end, and write it, in start order
		name, state, secs string
	}
	var rows []row
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		fields := strings.Fields(string(b))
		if len(fields) < 3 || !strings.HasSuffix(string(b), "\n") {
			continue
		}
		secs, rc, started := fields[0], fields[1], fields[2]
		n := strings.TrimSuffix(filepath.Base(f), ".status")
		state := "failed"
		if rc == "0" {
			state = "ok"
		}
		var at int64 // host steps are stamped in local time, container steps in UTC: order by the instant
		if t, err := time.Parse(time.RFC3339, started); err == nil {
			at = t.Unix()
		}
		var written int64 // stamps are whole seconds: a tie goes to the .status written first, then the name
		if st, err := os.Stat(f); err == nil {
			written = st.ModTime().UnixNano()
		}
		rows = append(rows, row{at, written, n, state, secs})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].at != rows[j].at {
			return rows[i].at < rows[j].at
		}
		if rows[i].written != rows[j].written {
			return rows[i].written < rows[j].written
		}
		return rows[i].name < rows[j].name
	})
	var last, failed strings.Builder
	anyFailed := false
	for _, r := range rows {
		fmt.Fprintf(&last, "%s %s %s\n", r.name, r.state, r.secs)
		if r.state == "failed" {
			anyFailed = true
			fmt.Fprintf(&failed, "%s %s/dist/logs/%s.log\n", r.name, c.Root, r.name)
		}
	}
	if !anyFailed && code != 0 {
		fmt.Fprintf(&failed, "run %s (exit %d, no failed step recorded)\n", dir, code)
	}
	_ = os.WriteFile(filepath.Join(dir, "last.status"), []byte(last.String()), 0o644)
	_ = os.WriteFile(filepath.Join(dir, "last-failed.txt"), []byte(failed.String()), 0o644)
}
