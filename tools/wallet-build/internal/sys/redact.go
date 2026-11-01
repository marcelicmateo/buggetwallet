package sys

import (
	"bytes"
	"io"
	"os"
	"strings"
	"sync"
)

// SecretVars are the environment variables whose values never reach a log, status file, history line or stdout.
var SecretVars = []string{"BW_KEYSTORE_PASSWORD", "BW_KEY_PASSWORD", "GH_TOKEN"}

const redacted = "***"

// Redactor replaces secret values with *** in everything written through it.
type Redactor struct {
	secrets []string
	maxLen  int
}

// NewRedactor collects the secret values from env and from extra (e.g. the lines of signing.env). Values shorter than
// 4 bytes are ignored: they would blank out ordinary text.
func NewRedactor(env Env, extra ...string) *Redactor {
	r := &Redactor{}
	for _, k := range SecretVars {
		r.add(env.Get(k))
	}
	for _, v := range extra {
		r.add(v)
	}
	return r
}

func (r *Redactor) add(v string) {
	if len(v) < 4 {
		return
	}
	for _, s := range r.secrets {
		if s == v {
			return
		}
	}
	r.secrets = append(r.secrets, v)
	if len(v) > r.maxLen {
		r.maxLen = len(v)
	}
}

// ReadSecretsFile returns the values of the secret variables in a KEY=VALUE env file (podman --env-file format).
func ReadSecretsFile(path string) []string {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var out []string
	for _, line := range strings.Split(string(b), "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		for _, s := range SecretVars {
			if k == s {
				out = append(out, strings.Trim(v, `"'`))
			}
		}
	}
	return out
}

// Active reports whether there is anything to redact.
func (r *Redactor) Active() bool { return r != nil && len(r.secrets) > 0 }

// Clean returns s with every secret replaced.
func (r *Redactor) Clean(s string) string {
	if !r.Active() {
		return s
	}
	for _, sec := range r.secrets {
		s = strings.ReplaceAll(s, sec, redacted)
	}
	return s
}

// Writer wraps w. Output is held back to the end of a line (newline or carriage return), so a secret split over two
// writes is still caught. With nothing to redact it returns w unchanged. Close flushes the rest.
func (r *Redactor) Writer(w io.Writer) io.WriteCloser {
	if w == nil {
		w = io.Discard
	}
	if !r.Active() {
		return nopCloser{w}
	}
	return &redactWriter{r: r, w: w}
}

type nopCloser struct{ io.Writer }

func (nopCloser) Close() error { return nil }

type redactWriter struct {
	mu  sync.Mutex
	r   *Redactor
	w   io.Writer
	buf []byte
}

func (rw *redactWriter) Write(p []byte) (int, error) {
	rw.mu.Lock()
	defer rw.mu.Unlock()
	rw.buf = append(rw.buf, p...)
	var out string
	if cut := bytes.LastIndexAny(rw.buf, "\r\n"); cut >= 0 {
		out = rw.r.Clean(string(rw.buf[:cut+1]))
		rw.buf = append([]byte(nil), rw.buf[cut+1:]...)
	} else if len(rw.buf) > 8192 {
		// a very long line: release all but the tail that could still be the start of a secret
		clean := rw.r.Clean(string(rw.buf))
		keep := rw.r.maxLen - 1
		out = clean[:len(clean)-keep]
		rw.buf = []byte(clean[len(clean)-keep:])
	} else {
		return len(p), nil
	}
	if _, err := io.WriteString(rw.w, out); err != nil {
		return len(p), err
	}
	return len(p), nil
}

func (rw *redactWriter) Close() error {
	rw.mu.Lock()
	defer rw.mu.Unlock()
	if len(rw.buf) == 0 {
		return nil
	}
	out := rw.r.Clean(string(rw.buf))
	rw.buf = nil
	_, err := io.WriteString(rw.w, out)
	return err
}
