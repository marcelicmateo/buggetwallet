// Package lspq is `wallet-build lsp-query` (port of tools/lsp.py): where is this symbol used or defined? It asks the Dart
// language server (`wallet-build lsp`, which runs in the Podman container) over stdio JSON-RPC instead of grepping.
package lspq

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Usage is the help text (the docstring of lsp.py).
const Usage = `Where is this symbol used or defined? Asks the Dart language server (wallet-build lsp) instead of grep.

  wallet-build lsp-query refs <path>:<line>:<col> [<path>:<line>:<col> ...]
  wallet-build lsp-query def  <path>:<line>:<col> [...]

Line and column are 1-based (as grep -n and editors show them) and point into the symbol. Paths are relative to the repo
root (or absolute). Output: one ` + "`path:line:col`" + ` per result (1-based, relative to the repo); with several positions each block
is headed by ` + "`# <position>`" + `. Exit 0 when every query returned at least one location, 1 otherwise (errors go to stderr).
One server start serves all positions of the call.

Cost: the server runs in the Podman container. Measured wall time on the owner's laptop (warm image and pub cache):
~9 s for ` + "`refs`" + ` of WalletRepo (372 locations over the repo), ~5 s for two ` + "`def`" + ` queries in one call.`

// Server is a started language server.
type Server struct {
	In   io.WriteCloser // the server's stdin
	Out  io.Reader      // the server's stdout
	Wait func() error   // waits for the process to end (nil = nothing to wait for)
	Kill func()         // kills it
}

// Start runs argv as the language server: stdin and stdout piped, stderr passed on.
func Start(argv []string, env []string, stderr io.Writer) (*Server, error) {
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = env
	cmd.Stderr = stderr
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &Server{In: in, Out: out, Wait: cmd.Wait, Kill: func() { _ = cmd.Process.Kill() }}, nil
}

type client struct {
	w      io.Writer
	r      *bufio.Reader
	nextID int
}

func (c *client) send(msg map[string]any) error {
	body, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(c.w, "Content-Length: %d\r\n\r\n%s", len(body), body)
	return err
}

var errClosed = errors.New("language server closed the connection")

func (c *client) read() (map[string]any, error) {
	length := -1
	for {
		line, err := c.r.ReadBytes('\n')
		if len(line) == 0 && err != nil {
			return nil, errClosed
		}
		line = bytes.TrimSpace(line)
		if len(line) == 0 {
			break
		}
		if len(line) >= 15 && strings.EqualFold(string(line[:15]), "content-length:") {
			n, perr := strconv.Atoi(strings.TrimSpace(string(line[15:])))
			if perr != nil {
				return nil, fmt.Errorf("language server sent a bad Content-Length: %q", line)
			}
			length = n
		}
	}
	if length < 0 {
		return nil, errors.New("language server sent a header without Content-Length")
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(c.r, body); err != nil {
		return nil, errClosed
	}
	var msg map[string]any
	if err := json.Unmarshal(body, &msg); err != nil {
		return nil, fmt.Errorf("language server sent bad JSON: %v", err)
	}
	return msg, nil
}

func (c *client) notify(method string, params map[string]any) error {
	return c.send(map[string]any{"jsonrpc": "2.0", "method": method, "params": params})
}

func (c *client) call(method string, params map[string]any) (any, error) {
	c.nextID++
	rid := c.nextID
	if err := c.send(map[string]any{"jsonrpc": "2.0", "id": rid, "method": method, "params": params}); err != nil {
		return nil, err
	}
	for {
		msg, err := c.read()
		if err != nil {
			return nil, err
		}
		_, hasMethod := msg["method"]
		id, hasID := msg["id"]
		switch {
		case hasMethod && hasID: // a request from the server (configuration, registerCapability...)
			var result any
			if msg["method"] == "workspace/configuration" {
				p, _ := msg["params"].(map[string]any)
				items, _ := p["items"].([]any)
				result = make([]any, len(items)) // one null per item
			}
			if err := c.send(map[string]any{"jsonrpc": "2.0", "id": id, "result": result}); err != nil {
				return nil, err
			}
		case hasID && id == float64(rid):
			if e, ok := msg["error"].(map[string]any); ok {
				return nil, fmt.Errorf("%s: %v", method, pyStr(e["message"]))
			}
			return msg["result"], nil
		}
	}
}

func pyStr(v any) string {
	if v == nil {
		return "None"
	}
	return fmt.Sprint(v)
}

// close asks the server to shut down, then waits up to ten seconds for it.
func (c *client) close(s *Server) {
	if _, err := c.call("shutdown", map[string]any{}); err == nil {
		_ = c.notify("exit", map[string]any{})
	}
	_ = s.In.Close()
	if s.Wait == nil {
		return
	}
	done := make(chan struct{})
	go func() { _ = s.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		if s.Kill != nil {
			s.Kill()
		}
	}
}

// quote is urllib.parse.quote(path): everything but letters, digits and _.-~/ is percent-encoded.
func quote(path string) string {
	var sb strings.Builder
	for _, b := range []byte(path) {
		switch {
		case b >= 'a' && b <= 'z', b >= 'A' && b <= 'Z', b >= '0' && b <= '9', strings.IndexByte("_.-~/", b) >= 0:
			sb.WriteByte(b)
		default:
			fmt.Fprintf(&sb, "%%%02X", b)
		}
	}
	return sb.String()
}

func uriOf(path string) string { return "file://" + quote(path) }

// pathOf is url2pathname(urlparse(uri).path).
func pathOf(uri string) string {
	rest := strings.TrimPrefix(uri, "file:")
	if strings.HasPrefix(rest, "//") {
		rest = rest[2:]
		if i := strings.IndexByte(rest, '/'); i >= 0 {
			rest = rest[i:]
		} else {
			rest = ""
		}
	}
	if i := strings.IndexAny(rest, "?#"); i >= 0 {
		rest = rest[:i]
	}
	if p, err := url.PathUnescape(rest); err == nil {
		return p
	}
	return rest
}

type position struct {
	path      string
	line, col int
}

func parsePos(root, arg string) (position, error) {
	bad := fmt.Errorf("bad position %s: expected <path>:<line>:<col>", pyRepr(arg))
	parts := strings.Split(arg, ":")
	if len(parts) < 3 {
		return position{}, bad
	}
	col, e1 := strconv.Atoi(strings.TrimSpace(parts[len(parts)-1]))
	line, e2 := strconv.Atoi(strings.TrimSpace(parts[len(parts)-2]))
	if e1 != nil || e2 != nil {
		return position{}, bad
	}
	path := strings.Join(parts[:len(parts)-2], ":")
	if !filepath.IsAbs(path) {
		path = filepath.Join(root, path)
	}
	return position{filepath.Clean(path), line, col}, nil
}

func pyRepr(s string) string {
	q := "'"
	if strings.Contains(s, "'") && !strings.Contains(s, `"`) {
		q = `"`
	}
	return q + strings.ReplaceAll(strings.ReplaceAll(s, `\`, `\\`), q, `\`+q) + q
}

// readText reads like Python's text mode: \r\n and \r become \n.
func readText(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	s := strings.ReplaceAll(string(b), "\r\n", "\n")
	return strings.ReplaceAll(s, "\r", "\n"), nil
}

// Main runs one lsp-query. args are the arguments after the command name; root is the repository; start launches the language
// server. It returns the exit code: 0 every query had a location, 1 one had none or failed, 2 usage.
func Main(args []string, root string, start func() (*Server, error), out, errw io.Writer) int {
	if len(args) < 2 || args[0] == "-h" || args[0] == "--help" || (args[0] != "refs" && args[0] != "def") {
		fmt.Fprintln(out, Usage)
		if len(args) > 0 && (args[0] == "-h" || args[0] == "--help") {
			return 0
		}
		return 2
	}
	kind := args[0]
	var positions []position
	for _, a := range args[1:] {
		p, err := parsePos(root, a)
		if err != nil {
			fmt.Fprintln(errw, err)
			return 1
		}
		positions = append(positions, p)
	}
	for _, p := range positions {
		if st, err := os.Stat(p.path); err != nil || !st.Mode().IsRegular() {
			fmt.Fprintf(errw, "no such file: %s\n", p.path)
			return 1
		}
	}
	srv, err := start()
	if err != nil {
		fmt.Fprintf(errw, "lsp-query: %v\n", err)
		return 1
	}
	c := &client{w: srv.In, r: bufio.NewReaderSize(srv.Out, 1<<20)}
	status := 0
	defer c.close(srv)
	fail := func(err error) int {
		fmt.Fprintf(errw, "lsp-query: %v\n", err)
		return 1
	}
	if _, err := c.call("initialize", map[string]any{"processId": os.Getpid(), "rootUri": uriOf(root),
		"workspaceFolders": []any{map[string]any{"uri": uriOf(root), "name": "repo"}},
		"capabilities":     map[string]any{"workspace": map[string]any{"configuration": true}}, "initializationOptions": map[string]any{}}); err != nil {
		return fail(err)
	}
	if err := c.notify("initialized", map[string]any{}); err != nil {
		return fail(err)
	}
	opened := map[string]bool{}
	for _, p := range positions {
		if !opened[p.path] {
			text, err := readText(p.path)
			if err != nil {
				return fail(err)
			}
			if err := c.notify("textDocument/didOpen", map[string]any{"textDocument": map[string]any{"uri": uriOf(p.path), "languageId": "dart", "version": 1, "text": text}}); err != nil {
				return fail(err)
			}
			opened[p.path] = true
		}
		params := map[string]any{"textDocument": map[string]any{"uri": uriOf(p.path)}, "position": map[string]any{"line": p.line - 1, "character": p.col - 1}}
		var res any
		if kind == "refs" {
			params["context"] = map[string]any{"includeDeclaration": true}
			res, err = c.call("textDocument/references", params)
		} else {
			res, err = c.call("textDocument/definition", params)
		}
		if err != nil {
			return fail(err)
		}
		locs, _ := res.([]any)
		if m, ok := res.(map[string]any); ok {
			locs = []any{m}
		}
		type loc struct {
			rel       string
			line, col int
		}
		seen := map[loc]bool{}
		var found []loc
		for _, l := range locs {
			m, _ := l.(map[string]any)
			uri, _ := m["uri"].(string)
			if uri == "" {
				uri, _ = m["targetUri"].(string)
			}
			rng, _ := m["range"].(map[string]any)
			if rng == nil {
				rng, _ = m["targetSelectionRange"].(map[string]any)
			}
			st, _ := rng["start"].(map[string]any)
			ln, _ := st["line"].(float64)
			ch, _ := st["character"].(float64)
			target := pathOf(uri)
			rel := target
			if strings.HasPrefix(target, root) {
				rel, _ = filepath.Rel(root, target)
			}
			k := loc{rel, int(ln) + 1, int(ch) + 1}
			if !seen[k] {
				seen[k] = true
				found = append(found, k)
			}
		}
		sort.Slice(found, func(i, j int) bool {
			a, b := found[i], found[j]
			if a.rel != b.rel {
				return a.rel < b.rel
			}
			if a.line != b.line {
				return a.line < b.line
			}
			return a.col < b.col
		})
		if len(positions) > 1 {
			rel, _ := filepath.Rel(root, p.path)
			fmt.Fprintf(out, "# %s:%d:%d\n", rel, p.line, p.col)
		}
		for _, f := range found {
			fmt.Fprintf(out, "%s:%d:%d\n", f.rel, f.line, f.col)
		}
		if len(found) == 0 {
			status = 1
		}
	}
	return status
}
