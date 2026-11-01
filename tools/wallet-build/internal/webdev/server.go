package webdev

import (
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

func init() {
	// What the Flutter web build needs from a static server: WebAssembly must be application/wasm (streaming compile) and
	// the scripts JavaScript, whatever the host's mime database says.
	for ext, typ := range map[string]string{
		".wasm": "application/wasm", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8",
		".json": "application/json", ".map": "application/json", ".css": "text/css; charset=utf-8",
		".html": "text/html; charset=utf-8", ".png": "image/png", ".ico": "image/x-icon", ".svg": "image/svg+xml",
		".otf": "font/otf", ".ttf": "font/ttf", ".woff2": "font/woff2",
	} {
		_ = mime.AddExtensionType(ext, typ)
	}
}

// Handler serves the files below dir: GET and HEAD only, a directory serves its index.html (or a listing), the way
// `python3 -m http.server` does (no redirect of /index.html). A request log line per request goes to logw.
func Handler(dir string, logw io.Writer) http.Handler {
	fs := http.FileServer(http.Dir(dir))
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "unsupported method", http.StatusNotImplemented)
			return
		}
		clean := path.Clean("/" + r.URL.Path)
		full := filepath.Join(dir, filepath.FromSlash(clean))
		st, err := os.Stat(full)
		switch {
		case err != nil:
			fs.ServeHTTP(w, r) // its 404 / 403
		case st.IsDir():
			if !strings.HasSuffix(r.URL.Path, "/") {
				http.Redirect(w, r, clean+"/", http.StatusMovedPermanently)
				return
			}
			if f, err := os.Open(filepath.Join(full, "index.html")); err == nil {
				defer f.Close()
				if ist, err := f.Stat(); err == nil && !ist.IsDir() {
					http.ServeContent(w, r, "index.html", ist.ModTime(), f)
					return
				}
			}
			fs.ServeHTTP(w, r) // a directory listing
		default:
			f, err := os.Open(full)
			if err != nil {
				fs.ServeHTTP(w, r)
				return
			}
			defer f.Close()
			http.ServeContent(w, r, st.Name(), st.ModTime(), f)
		}
	})
	if logw == nil {
		return h
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		h.ServeHTTP(rec, r)
		fmt.Fprintf(logw, "%s - - [%s] \"%s %s %s\" %d -\n", r.RemoteAddr, time.Now().Format("02/Jan/2006 15:04:05"), r.Method, r.URL.RequestURI(), r.Proto, rec.code)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.code = code
	s.ResponseWriter.WriteHeader(code)
}

// ListenLoopback opens a TCP listener on 127.0.0.1 only; "0" asks for a free port.
func ListenLoopback(port string) (net.Listener, error) {
	return net.Listen("tcp4", net.JoinHostPort("127.0.0.1", port))
}

// ServeDir is `web _serve <dir> <port>`: the detached static file server of `web serve`, in the foreground of its own process.
// It runs until it is killed.
func ServeDir(dir, port string, logw io.Writer) error {
	ln, err := ListenLoopback(port)
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: Handler(dir, logw), ReadHeaderTimeout: 30 * time.Second}
	return srv.Serve(ln)
}
