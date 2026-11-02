package vmservice

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
)

// TraceEvent is the part of a Chrome trace event the summary reads.
type TraceEvent struct {
	Name string   `json:"name"`
	Ph   string   `json:"ph"`
	TS   *float64 `json:"ts"`
	Dur  *float64 `json:"dur"`
	TID  any      `json:"tid"`
}

// ParseTrace decodes raw trace events; unreadable events become empty ones (they match nothing).
func ParseTrace(raw []json.RawMessage) []TraceEvent {
	out := make([]TraceEvent, len(raw))
	for i, r := range raw {
		_ = json.Unmarshal(r, &out[i])
	}
	return out
}

// Pct is live_vm.py pct: the value at round-half-even(p/100*(n-1)) of the sorted values.
func Pct(values []float64, p float64) float64 {
	if len(values) == 0 {
		return 0
	}
	s := append([]float64(nil), values...)
	sort.Float64s(s)
	i := int(math.RoundToEven(p / 100 * float64(len(s)-1)))
	if i > len(s)-1 {
		i = len(s) - 1
	}
	return s[i]
}

// spans are the durations (ms) of the named events: complete events (ph X) and begin/end pairs per thread, in start order.
func spans(trace []TraceEvent, names map[string]bool) []float64 {
	type span struct{ ts, dur float64 }
	var out []span
	open := map[string][]float64{}
	for _, e := range trace {
		if !names[e.Name] {
			continue
		}
		key := fmt.Sprintf("%v\x00%s", e.TID, e.Name)
		switch e.Ph {
		case "X":
			if e.Dur != nil && e.TS != nil {
				out = append(out, span{*e.TS, *e.Dur / 1000})
			}
		case "B":
			if e.TS != nil {
				open[key] = append(open[key], *e.TS)
			}
		case "E":
			if st := open[key]; len(st) > 0 && e.TS != nil {
				start := st[len(st)-1]
				open[key] = st[:len(st)-1]
				out = append(out, span{start, (*e.TS - start) / 1000})
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].ts != out[j].ts {
			return out[i].ts < out[j].ts
		}
		return out[i].dur < out[j].dur
	})
	d := make([]float64, len(out))
	for i, s := range out {
		d[i] = s.dur
	}
	return d
}

var (
	buildEvents  = map[string]bool{"Animator::BeginFrame": true}
	rasterEvents = map[string]bool{"GPURasterizer::Draw": true} // Rasterizer::DoDraw is nested inside it
)

// Summary is the text of live_vm.py summary(): frames, build/raster p50/p90/max, frames over the 16 ms budget. A non-profile mode
// adds the "not representative" warning.
func Summary(trace []TraceEvent, mode string) string {
	const budget = 16.0
	build := spans(trace, buildEvents)
	raster := spans(trace, rasterEvents)
	frames := max(len(build), len(raster))
	lo, hi, any := 0.0, 0.0, false
	for _, e := range trace {
		if e.TS == nil || e.Ph == "M" {
			continue
		}
		if !any || *e.TS < lo {
			lo = *e.TS
		}
		if !any || *e.TS > hi {
			hi = *e.TS
		}
		any = true
	}
	secs := 0.0
	if any {
		secs = (hi - lo) / 1e6
	}
	// a frame is janky when its build or its raster time is over budget; pair them by order
	janky := 0
	for i := 0; i < frames; i++ {
		if (i < len(build) && build[i] > budget) || (i < len(raster) && raster[i] > budget) {
			janky++
		}
	}
	lines := []string{fmt.Sprintf("timeline: %.1f s, %d events, %d frames, %d over %.0f ms (build or raster)", secs, len(trace), frames, janky, budget)}
	for _, l := range []struct {
		label  string
		values []float64
	}{{"build", build}, {"raster", raster}} {
		mx := 0.0
		for i, v := range l.values {
			if i == 0 || v > mx {
				mx = v
			}
		}
		lines = append(lines, fmt.Sprintf("%-7s n=%-5d p50=%6.1f ms  p90=%6.1f ms  max=%6.1f ms", l.label, len(l.values), Pct(l.values, 50), Pct(l.values, 90), mx))
	}
	if mode != "" && mode != "profile" {
		lines = append(lines, fmt.Sprintf("(%s build: timings are not representative; make live-start ARGS=--profile for real numbers)", mode))
	}
	return strings.Join(lines, "\n") + "\n"
}
