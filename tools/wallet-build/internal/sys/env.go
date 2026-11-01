// Package sys holds the process-level plumbing: environment, running commands (real and fake), secret redaction.
package sys

import (
	"strings"
)

// Env is a process environment as KEY=VALUE strings. Methods return copies.
type Env []string

// Lookup returns the value of k and whether it is set.
func (e Env) Lookup(k string) (string, bool) {
	for i := len(e) - 1; i >= 0; i-- {
		if strings.HasPrefix(e[i], k+"=") {
			return e[i][len(k)+1:], true
		}
	}
	return "", false
}

// Get returns the value of k, or "" when unset.
func (e Env) Get(k string) string {
	v, _ := e.Lookup(k)
	return v
}

// With returns a copy with the given KEY, VALUE pairs set (replacing earlier values).
func (e Env) With(kv ...string) Env {
	keys := map[string]bool{}
	for i := 0; i+1 < len(kv); i += 2 {
		keys[kv[i]] = true
	}
	out := make(Env, 0, len(e)+len(kv)/2)
	for _, s := range e {
		k, _, _ := strings.Cut(s, "=")
		if !keys[k] {
			out = append(out, s)
		}
	}
	for i := 0; i+1 < len(kv); i += 2 {
		out = append(out, kv[i]+"="+kv[i+1])
	}
	return out
}

// Without returns a copy with the given keys removed.
func (e Env) Without(keys ...string) Env {
	drop := map[string]bool{}
	for _, k := range keys {
		drop[k] = true
	}
	out := make(Env, 0, len(e))
	for _, s := range e {
		k, _, _ := strings.Cut(s, "=")
		if !drop[k] {
			out = append(out, s)
		}
	}
	return out
}

// Environ returns the plain slice, for exec.Cmd.Env.
func (e Env) Environ() []string { return []string(e) }
