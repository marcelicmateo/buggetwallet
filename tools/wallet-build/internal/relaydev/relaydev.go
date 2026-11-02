// Package relaydev ports tools/relay.sh: the relay (relay/) running locally in a rootless Podman container, for development and
// the local web build. Dev mode: plain HTTP on 127.0.0.1, wallet creation open. The real deployment (Caddy + HTTPS + create
// token) is relay/deploy/native/.
package relaydev

import (
	"bufio"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"golang.org/x/term"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

// Usage is what `relay` prints for an unknown command (the header of tools/relay.sh).
const Usage = `Run the relay (relay/) locally in a rootless Podman container, for development and the local web build.

  wallet-build relay start     build the image if missing (dev/Containerfile.relay), run it on 127.0.0.1:$BW_RELAY_PORT (8787)
  wallet-build relay stop      stop and remove the container (data stays)
  wallet-build relay status    running? health answer
  wallet-build relay logs [-f] container log (no tokens, bodies or addresses are logged)
  wallet-build relay reset     stop and delete the data folder (asks first; BW_YES=1 skips the question)
  wallet-build relay image     (re)build the image
`

// Commands are the words that make "relay <word>" this helper; plain "relay" is the relay package's test suite.
var Commands = []string{"start", "stop", "status", "logs", "reset", "image"}

// IsCommand reports whether word selects the dev relay container.
func IsCommand(word string) bool {
	for _, c := range Commands {
		if c == word {
			return true
		}
	}
	return false
}

const containerName = "bw-relay"

// Relay is one invocation of `wallet-build relay`.
type Relay struct {
	C *run.Ctx
	// In answers the question of reset.
	In io.Reader
	// IsTTY says whether In is a terminal: bash's `read -p` shows its question only then.
	IsTTY func() bool
	// Get fetches one URL with a time limit and returns the body (curl -fsS --max-time 3): an HTTP status >= 400 is an error.
	Get func(url string) (string, error)
	// Sleep is a variable for the tests.
	Sleep func(time.Duration)
}

// New returns a Relay with the real HTTP client, stdin and sleep.
func New(c *run.Ctx) *Relay {
	return &Relay{C: c, In: os.Stdin, IsTTY: func() bool { return term.IsTerminal(int(os.Stdin.Fd())) }, Get: httpGet, Sleep: time.Sleep}
}

func httpGet(url string) (string, error) {
	cl := &http.Client{Timeout: 3 * time.Second}
	resp, err := cl.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return string(b), nil
}

// ImageTag is localhost/budget-wallet-relay:<8 hex of sha256 over the image inputs>, so editing the relay or its Containerfile
// rebuilds the image: the Containerfile, relay/pubspec.lock, then the .dart files of relay/bin, relay/lib and relay/lib/src.
func ImageTag(root string) string {
	h := sha256.New()
	add := func(p string) {
		if b, err := os.ReadFile(p); err == nil {
			h.Write(b)
		}
	}
	add(filepath.Join(root, "dev", "Containerfile.relay"))
	add(filepath.Join(root, "relay", "pubspec.lock"))
	for _, dir := range []string{"relay/bin", "relay/lib", "relay/lib/src"} {
		files, _ := filepath.Glob(filepath.Join(root, dir, "*.dart"))
		sort.Strings(files)
		for _, f := range files {
			add(f)
		}
	}
	return fmt.Sprintf("localhost/budget-wallet-relay:%x", h.Sum(nil))[:len("localhost/budget-wallet-relay:")+8]
}

var rePort = regexp.MustCompile(`^[0-9]+$`)

type config struct {
	port, origins, data, image string
}

func (r *Relay) config() (config, bool) {
	c := r.C
	cfg := config{port: c.Getenv("BW_RELAY_PORT"), origins: c.Getenv("BW_RELAY_ORIGINS")}
	if cfg.port == "" {
		cfg.port = "8787"
	}
	if cfg.origins == "" {
		cfg.origins = "http://127.0.0.1:8080,http://localhost:8080"
	}
	cfg.data = filepath.Join(c.Data, "relay")
	cfg.image = ImageTag(c.Root)
	return cfg, rePort.MatchString(cfg.port)
}

func (r *Relay) podman(stdout, stderr io.Writer, stdin io.Reader, args ...string) int {
	c := r.C
	return c.R.Run(c.Ctx, sys.Cmd{Argv: append([]string{"podman"}, args...), Env: c.Env, Stdin: stdin, Stdout: stdout, Stderr: stderr})
}

func (r *Relay) running() bool {
	var b strings.Builder
	rc := r.podman(&b, nil, nil, "inspect", "-f", "{{.State.Running}}", containerName)
	return rc == 0 && strings.TrimSpace(b.String()) == "true"
}

func (r *Relay) buildImage(cfg config) int {
	c := r.C
	c.Eprintf("building %s\n", cfg.image)
	return r.podman(c.ChildErr, c.ChildErr, nil, "build", "-f", filepath.Join(c.Root, "dev", "Containerfile.relay"), "-t", cfg.image, c.Root)
}

// health asks /v2/health; retries is curl's --retry (1 s apart, every error retried).
func (r *Relay) health(cfg config, retries int) (string, bool) {
	url := "http://127.0.0.1:" + cfg.port + "/v2/health"
	for i := 0; ; i++ {
		body, err := r.Get(url)
		if err == nil {
			return strings.TrimRight(body, "\n"), true
		}
		if i >= retries || r.C.Ctx.Err() != nil {
			return "", false
		}
		r.Sleep(time.Second)
	}
}

// Main is `relay <cmd> [args]` (default status). It returns the exit code of the script: 0, 1, 2 (usage), or the exit code of
// the failing podman command.
func (r *Relay) Main(args []string) int {
	c := r.C
	cmd := "status"
	if len(args) > 0 {
		cmd = args[0]
	}
	cfg, portOK := r.config()
	if !portOK {
		c.Eprintf("BW_RELAY_PORT must be a number\n")
		return 2
	}
	switch cmd {
	case "image":
		return r.buildImage(cfg)
	case "start":
		return r.start(cfg)
	case "stop":
		r.podman(nil, nil, nil, "rm", "-f", containerName)
		c.Printf("stopped\n")
		return 0
	case "status":
		if r.running() {
			body, ok := r.health(cfg, 0)
			if !ok {
				body = "no health answer"
			}
			c.Printf("running on 127.0.0.1:%s: %s\n", cfg.port, body)
		} else {
			c.Printf("not running\n")
		}
		return 0
	case "logs":
		return r.podman(c.ChildOut, c.ChildErr, nil, append([]string{"logs"}, append(args[1:], containerName)...)...)
	case "reset":
		return r.reset(cfg)
	}
	c.Printf("%s", Usage)
	return 2
}

func (r *Relay) start(cfg config) int {
	c := r.C
	if r.running() {
		c.Printf("already running on 127.0.0.1:%s\n", cfg.port)
		return 0
	}
	if r.podman(nil, nil, nil, "image", "exists", cfg.image) != 0 {
		if rc := r.buildImage(cfg); rc != 0 {
			return rc
		}
	}
	r.podman(nil, nil, nil, "rm", "-f", containerName)
	if err := os.MkdirAll(cfg.data, 0o755); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	// The container user (uid 10001) is mapped to the host user, so the data folder stays yours.
	if rc := r.podman(nil, c.ChildErr, nil, "run", "-d", "--name", containerName, "--read-only", "--userns=keep-id:uid=10001,gid=10001",
		"--health-cmd", "relay --health-check", "--health-interval", "30s",
		"-p", "127.0.0.1:"+cfg.port+":8787", "-v", cfg.data+":/data:z",
		"-e", "BW_RELAY_ORIGINS="+cfg.origins, cfg.image); rc != 0 {
		return rc
	}
	if _, ok := r.health(cfg, 15); ok {
		c.Printf("relay up on http://127.0.0.1:%s (data: %s)\n", cfg.port, cfg.data)
		return 0
	}
	c.Eprintf("relay did not answer; log:\n")
	r.podman(c.ChildErr, c.ChildErr, nil, "logs", containerName)
	return 1
}

func (r *Relay) reset(cfg config) int {
	c := r.C
	if c.Getenv("BW_YES") != "1" {
		if r.IsTTY != nil && r.IsTTY() { // M6: rename with the scripts
			c.Eprintf("Delete %s (all relay wallets)? [y/N] ", cfg.data)
		}
		line, err := bufio.NewReader(r.In).ReadString('\n')
		if err != nil && line == "" { // read fails at end of input: the script stops with status 1
			return 1
		}
		if strings.TrimRight(line, "\r\n") != "y" {
			c.Printf("aborted\n")
			return 1
		}
	}
	r.podman(nil, nil, nil, "rm", "-f", containerName)
	if err := os.RemoveAll(cfg.data); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	c.Printf("relay data deleted\n")
	return 0
}
