package webdev

import (
	"bytes"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func site(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	files := map[string]string{
		"index.html":             "<html>root</html>",
		"main.dart.js":           "console.log(1)",
		"mod.mjs":                "export {}",
		"sqlite3.wasm":           "\x00asm\x01\x00\x00\x00",
		"manifest.json":          "{}",
		"sub/index.html":         "sub index",
		"listing/a.txt":          "a",
		"assets/a b.txt":         "with space",
		"assets/fonts/Icons.otf": "otf",
		"icons/x.png":            "\x89PNG",
	}
	for p, c := range files {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, p)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, p), []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func get(t *testing.T, srv *httptest.Server, method, path string, hdr map[string]string) (*http.Response, string) {
	t.Helper()
	cl := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, err := http.NewRequest(method, srv.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := cl.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, string(b)
}

func TestHandlerServesTheWebBuild(t *testing.T) {
	var logb bytes.Buffer
	srv := httptest.NewServer(Handler(site(t), &logb))
	defer srv.Close()
	types := map[string]string{
		"/sqlite3.wasm": "application/wasm", "/main.dart.js": "text/javascript", "/mod.mjs": "text/javascript", "/manifest.json": "application/json",
		"/": "text/html", "/index.html": "text/html", "/icons/x.png": "image/png", "/assets/fonts/Icons.otf": "font/otf",
	}
	for p, want := range types {
		resp, body := get(t, srv, "GET", p, nil)
		if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), want) {
			t.Errorf("%s: %d %q", p, resp.StatusCode, resp.Header.Get("Content-Type"))
		}
		if p == "/" && body != "<html>root</html>" {
			t.Errorf("/ body %q", body)
		}
	}
	// /index.html is served, not redirected (python's http.server does the same)
	if resp, _ := get(t, srv, "GET", "/index.html", nil); resp.StatusCode != 200 {
		t.Errorf("/index.html: %d", resp.StatusCode)
	}
	if resp, body := get(t, srv, "GET", "/assets/a%20b.txt", nil); resp.StatusCode != 200 || body != "with space" {
		t.Errorf("encoded name: %d %q", resp.StatusCode, body)
	}
	// a directory without the slash redirects, with it serves index.html or lists
	if resp, _ := get(t, srv, "GET", "/sub", nil); resp.StatusCode != 301 || resp.Header.Get("Location") != "/sub/" {
		t.Errorf("/sub: %d %q", resp.StatusCode, resp.Header.Get("Location"))
	}
	if _, body := get(t, srv, "GET", "/sub/", nil); body != "sub index" {
		t.Errorf("/sub/: %q", body)
	}
	if resp, body := get(t, srv, "GET", "/listing/", nil); resp.StatusCode != 200 || !strings.Contains(body, "a.txt") {
		t.Errorf("/listing/: %d %q", resp.StatusCode, body)
	}
	if resp, _ := get(t, srv, "GET", "/missing.js", nil); resp.StatusCode != 404 {
		t.Errorf("missing: %d", resp.StatusCode)
	}
	// HEAD and ranges work, other methods are refused
	if resp, body := get(t, srv, "HEAD", "/main.dart.js", nil); resp.StatusCode != 200 || body != "" || resp.ContentLength != 14 {
		t.Errorf("HEAD: %d %q %d", resp.StatusCode, body, resp.ContentLength)
	}
	if resp, body := get(t, srv, "GET", "/main.dart.js", map[string]string{"Range": "bytes=0-6"}); resp.StatusCode != 206 || body != "console" {
		t.Errorf("range: %d %q", resp.StatusCode, body)
	}
	for _, m := range []string{"POST", "PUT", "DELETE"} {
		if resp, _ := get(t, srv, m, "/index.html", nil); resp.StatusCode != 501 {
			t.Errorf("%s: %d", m, resp.StatusCode)
		}
	}
	if !strings.Contains(logb.String(), `"GET /sqlite3.wasm HTTP/1.1" 200`) || !strings.Contains(logb.String(), `"POST /index.html HTTP/1.1" 501`) {
		t.Errorf("request log:\n%s", logb.String())
	}
}

func TestHandlerStaysInsideTheFolder(t *testing.T) {
	parent := t.TempDir()
	dir := filepath.Join(parent, "web")
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(parent, "secret.txt"), []byte("secret"), 0o644)
	os.WriteFile(filepath.Join(dir, "index.html"), []byte("ok"), 0o644)
	srv := httptest.NewServer(Handler(dir, nil))
	defer srv.Close()
	for _, p := range []string{"/../secret.txt", "/%2e%2e/secret.txt", "/..%2fsecret.txt", "/sub/../../secret.txt", "//secret.txt"} {
		resp, body := get(t, srv, "GET", p, nil)
		if strings.Contains(body, "secret") && !strings.Contains(body, "404") {
			t.Errorf("%s leaked: %d %q", p, resp.StatusCode, body)
		}
	}
	// raw request line: no client-side cleaning
	conn, err := net.Dial("tcp", strings.TrimPrefix(srv.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	io.WriteString(conn, "GET /../secret.txt HTTP/1.0\r\n\r\n")
	b, _ := io.ReadAll(conn)
	if bytes.Contains(b, []byte("secret")) && !bytes.Contains(b, []byte("404")) {
		t.Errorf("raw traversal leaked: %q", b)
	}
}

func TestListenLoopbackOnly(t *testing.T) {
	ln, err := ListenLoopback("0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	addr := ln.Addr().(*net.TCPAddr)
	if !addr.IP.IsLoopback() || addr.IP.String() != "127.0.0.1" {
		t.Errorf("listens on %v", addr)
	}
	// a second server on the same port fails
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	if err := ServeDir(t.TempDir(), port, io.Discard); err == nil {
		t.Error("a busy port was accepted")
	}
}
