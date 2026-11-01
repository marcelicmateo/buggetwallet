package report

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"
)

// StageSummary is tools/stage_summary.py: the failing tests and the BUG: skips of the sub-runs' tests-*.json reports.
func StageSummary(dirs []string) string {
	var failed, bug []string
	for _, d := range dirs {
		d = strings.TrimSpace(d)
		if d == "" {
			continue
		}
		files, _ := filepath.Glob(filepath.Join(d, "tests-*.json"))
		sort.Strings(files)
		for _, p := range files {
			suite := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(p), "tests-"), ".json")
			f, b := scanStage(p)
			for _, n := range f {
				failed = append(failed, suite+": "+n)
			}
			for _, n := range b {
				bug = append(bug, suite+": "+n)
			}
		}
	}
	var sb strings.Builder
	section := func(title string, items []string) {
		if len(items) == 0 {
			fmt.Fprintf(&sb, "--- %s: none\n", title)
			return
		}
		fmt.Fprintf(&sb, "--- %s\n", title)
		set := map[string]bool{}
		var uniq []string
		for _, n := range items {
			if !set[n] {
				set[n] = true
				uniq = append(uniq, n)
			}
		}
		sort.Strings(uniq)
		for _, n := range uniq {
			fmt.Fprintf(&sb, "  %s\n", n)
		}
	}
	section("failing tests", failed)
	section("BUG: skips", bug)
	return sb.String()
}

func scanStage(path string) (failed, bug []string) {
	names := map[int]string{}
	skips := map[int]string{}
	skipped := map[int]bool{}
	var order []int
	_ = scanEvents(path, func(e *event) {
		switch e.Type {
		case "testStart":
			if e.Test != nil {
				names[e.Test.ID] = e.Test.Name
			}
		case "print":
			if e.MessageType == "skip" && e.TestID != nil {
				skips[*e.TestID] = e.Message
			}
		case "testDone":
			if e.Hidden || e.TestID == nil {
				return
			}
			id := *e.TestID
			if e.Skipped {
				if !skipped[id] {
					order = append(order, id)
				}
				skipped[id] = true
			} else if e.Result == nil || *e.Result != "success" {
				n, ok := names[id]
				if !ok {
					n = "?"
				}
				failed = append(failed, n)
			}
		}
	})
	for _, id := range order {
		n, ok := names[id]
		if !ok {
			n = "?"
		}
		if strings.Contains(skips[id], "BUG:") || strings.Contains(n, "BUG:") {
			bug = append(bug, n)
		}
	}
	return
}
