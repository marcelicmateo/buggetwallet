// Package vmservice ports tools/live_vm.py: a minimal RFC 6455 WebSocket client and JSON-RPC calls to the Dart VM service,
// the flutter daemon request/reply over `flutter run --machine`, the TCP forwarder, the X11 screenshot and the timeline summary.
// Standard library only (the service listens on 127.0.0.1, so no TLS and no extensions).
package vmservice

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"strings"
	"time"
)

// IOTimeout is the time one read or write on the socket may take (live_vm.py: socket timeout 120 s).
var IOTimeout = 120 * time.Second

// ErrClosed is returned when the server closes the connection (or sends a close frame).
var ErrClosed = errors.New("VM service closed the connection")

const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// Conn is a WebSocket client connection.
type Conn struct {
	nc     net.Conn
	br     *bufio.Reader
	nextID int
	// Rand supplies the handshake key and the masks; crypto/rand unless a test replaces it.
	Rand io.Reader
}

// Dial connects to a ws:// URI and performs the opening handshake.
func Dial(uri string) (*Conn, error) {
	u, err := url.Parse(uri)
	if err != nil {
		return nil, err
	}
	host, port := u.Hostname(), u.Port()
	if port == "" {
		port = "80"
	}
	nc, err := net.DialTimeout("tcp", net.JoinHostPort(host, port), IOTimeout)
	if err != nil {
		return nil, err
	}
	c := &Conn{nc: nc, br: bufio.NewReader(nc), Rand: rand.Reader}
	if err := c.handshake(u, host, port); err != nil {
		nc.Close()
		return nil, err
	}
	return c, nil
}

// NewConn wraps an established connection after the handshake (tests).
func NewConn(nc net.Conn, br *bufio.Reader) *Conn { return &Conn{nc: nc, br: br, Rand: rand.Reader} }

// Close closes the socket.
func (c *Conn) Close() error { return c.nc.Close() }

func (c *Conn) handshake(u *url.URL, host, port string) error {
	var k [16]byte
	if _, err := io.ReadFull(c.Rand, k[:]); err != nil {
		return err
	}
	key := base64.StdEncoding.EncodeToString(k[:])
	path := u.Path
	if path == "" {
		path = "/"
	}
	req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s:%s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
		path, host, port, key)
	c.nc.SetDeadline(time.Now().Add(IOTimeout))
	if _, err := c.nc.Write([]byte(req)); err != nil {
		return err
	}
	status, err := c.br.ReadString('\n')
	if err != nil {
		return ErrClosed
	}
	status = strings.TrimRight(status, "\r\n")
	var accept string
	for {
		line, err := c.br.ReadString('\n')
		if err != nil {
			return ErrClosed
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		if k, v, ok := strings.Cut(line, ":"); ok && strings.EqualFold(strings.TrimSpace(k), "Sec-WebSocket-Accept") {
			accept = strings.TrimSpace(v)
		}
	}
	if !strings.Contains(status+" ", " 101 ") {
		return fmt.Errorf("VM service refused the WebSocket: %s", status)
	}
	sum := sha1.Sum([]byte(key + wsGUID))
	if accept != "" && accept != base64.StdEncoding.EncodeToString(sum[:]) {
		return errors.New("VM service sent a wrong Sec-WebSocket-Accept")
	}
	return nil
}

// WriteText sends one masked text frame (raw JSON for protocols other than the VM service's JSON-RPC 2.0, e.g. DevTools).
func (c *Conn) WriteText(data []byte) error { return c.send(opText, data) }

// ReadMessage reads the next data message: the whole text of a JSON reply or event.
func (c *Conn) ReadMessage() ([]byte, error) { return c.message() }

// Opcodes.
const (
	opCont  = 0
	opText  = 1
	opBin   = 2
	opClose = 8
	opPing  = 9
	opPong  = 10
)

// send writes one final frame, masked as a client must.
func (c *Conn) send(opcode byte, data []byte) error {
	n := len(data)
	hdr := []byte{0x80 | opcode}
	switch {
	case n < 126:
		hdr = append(hdr, 0x80|byte(n))
	case n < 1<<16:
		hdr = append(hdr, 0x80|126, byte(n>>8), byte(n))
	default:
		hdr = append(hdr, 0x80|127)
		hdr = binary.BigEndian.AppendUint64(hdr, uint64(n))
	}
	var mask [4]byte
	if _, err := io.ReadFull(c.Rand, mask[:]); err != nil {
		return err
	}
	frame := append(hdr, mask[:]...)
	body := make([]byte, n)
	for i, b := range data {
		body[i] = b ^ mask[i%4]
	}
	frame = append(frame, body...)
	c.nc.SetWriteDeadline(time.Now().Add(IOTimeout))
	_, err := c.nc.Write(frame)
	return err
}

// maxMessage bounds a message (a timeline of a long recording is tens of MB).
const maxMessage = 1 << 30

// message reads the next data message: fragments are joined, pings answered with pongs, pongs ignored, a close frame is an error.
func (c *Conn) message() ([]byte, error) {
	var parts []byte
	for {
		c.nc.SetReadDeadline(time.Now().Add(IOTimeout))
		var h [2]byte
		if _, err := io.ReadFull(c.br, h[:]); err != nil {
			return nil, closedOr(err)
		}
		n := uint64(h[1] & 0x7F)
		switch n {
		case 126:
			var b [2]byte
			if _, err := io.ReadFull(c.br, b[:]); err != nil {
				return nil, closedOr(err)
			}
			n = uint64(binary.BigEndian.Uint16(b[:]))
		case 127:
			var b [8]byte
			if _, err := io.ReadFull(c.br, b[:]); err != nil {
				return nil, closedOr(err)
			}
			n = binary.BigEndian.Uint64(b[:])
		}
		if n > maxMessage {
			return nil, fmt.Errorf("VM service sent a %d byte frame", n)
		}
		var mask [4]byte
		masked := h[1]&0x80 != 0
		if masked {
			if _, err := io.ReadFull(c.br, mask[:]); err != nil {
				return nil, closedOr(err)
			}
		}
		data := make([]byte, n)
		if _, err := io.ReadFull(c.br, data); err != nil {
			return nil, closedOr(err)
		}
		if masked {
			for i := range data {
				data[i] ^= mask[i%4]
			}
		}
		switch op := h[0] & 0x0F; op {
		case opClose:
			return nil, ErrClosed
		case opPing:
			if err := c.send(opPong, data); err != nil {
				return nil, err
			}
		case opCont, opText, opBin:
			parts = append(parts, data...)
			if h[0]&0x80 != 0 {
				return parts, nil
			}
		}
	}
}

func closedOr(err error) error {
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return ErrClosed
	}
	return err
}
