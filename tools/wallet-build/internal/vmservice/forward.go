package vmservice

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// LocalAddrs are this network namespace's own IPv4 addresses except loopback: the '/32 host LOCAL' entries of a fib_trie file
// (/proc/net/fib_trie), sorted.
func LocalAddrs(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	set := map[string]bool{}
	last := ""
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<16), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		if _, after, ok := strings.Cut(line, "|--"); ok {
			last = strings.TrimSpace(after)
			if i := strings.Index(after, "|--"); i >= 0 { // split('|--')[1] is the text up to a second '|--'
				last = strings.TrimSpace(after[:i])
			}
		} else if strings.Contains(line, "/32 host LOCAL") && last != "" && !strings.HasPrefix(last, "127.") {
			set[last] = true
		}
	}
	out := make([]string, 0, len(set))
	for a := range set {
		out = append(out, a)
	}
	sort.Strings(out)
	return out, sc.Err()
}

// Forward listens on port at each of the pod's own addresses and forwards every connection to 127.0.0.1:port, where DDS listens
// (published pod ports arrive on the pod's other address). It runs until ctx ends.
func Forward(ctx context.Context, fibTrie string, port int) error {
	addrs, err := LocalAddrs(fibTrie)
	if err != nil {
		return err
	}
	return ForwardAddrs(ctx, addrs, port, "127.0.0.1")
}

// ForwardAddrs listens on each address:port and forwards to target:port.
func ForwardAddrs(ctx context.Context, addrs []string, port int, target string) error {
	var ls []net.Listener
	for _, a := range addrs {
		l, err := net.Listen("tcp", net.JoinHostPort(a, strconv.Itoa(port)))
		if err != nil {
			for _, o := range ls {
				o.Close()
			}
			return err
		}
		ls = append(ls, l)
	}
	var wg sync.WaitGroup
	for _, l := range ls {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				c, err := l.Accept()
				if err != nil {
					return
				}
				go handle(c, net.JoinHostPort(target, strconv.Itoa(port)))
			}
		}()
	}
	<-ctx.Done()
	for _, l := range ls {
		l.Close()
	}
	wg.Wait()
	return nil
}

func handle(c net.Conn, upstream string) {
	defer c.Close()
	up, err := net.Dial("tcp", upstream)
	if err != nil {
		return
	}
	defer up.Close()
	done := make(chan struct{}, 2)
	pipe := func(dst, src net.Conn) {
		_, _ = io.Copy(dst, src)
		done <- struct{}{}
	}
	go pipe(up, c)
	go pipe(c, up)
	<-done // like the Python pipes: when one direction ends, both sockets close
}

// ErrNoDisplay is returned by XShot when DISPLAY is unusable.
var ErrNoDisplay = fmt.Errorf("DISPLAY is not a local X display")
