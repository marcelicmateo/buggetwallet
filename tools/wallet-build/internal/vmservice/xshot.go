package vmservice

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/png"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
)

// XOpts say where the X display is. The zero value reads DISPLAY, XAUTHORITY and HOME from the process environment.
type XOpts struct {
	Display   string // $DISPLAY, ":99" or ":99.0"
	Xauth     string // path of the Xauthority file ("" = ~/.Xauthority)
	Home      string
	SocketDir string // "/tmp/.X11-unix"
}

// XShot is the root window of a local Xvfb as a PNG, through the X11 protocol itself (24-bit TrueColor, little endian), so the
// image needs no X tools. Profile builds have no inspector screenshot; this covers them when headless. The container's own
// display only: a unix socket under /tmp/.X11-unix.
func XShot(o XOpts) ([]byte, error) {
	if o.SocketDir == "" {
		o.SocketDir = "/tmp/.X11-unix"
	}
	_, after, ok := strings.Cut(o.Display, ":")
	if !ok {
		return nil, ErrNoDisplay
	}
	num, _, _ := strings.Cut(after, ".")
	conn, err := net.Dial("unix", filepath.Join(o.SocketDir, "X"+num))
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	name, data := cookie(o, num)

	pad := func(b []byte) []byte { return append(b, make([]byte, (4-len(b)%4)%4)...) }
	setup := []byte{0x6C, 0}
	setup = binary.LittleEndian.AppendUint16(setup, 11)
	setup = binary.LittleEndian.AppendUint16(setup, 0)
	setup = binary.LittleEndian.AppendUint16(setup, uint16(len(name)))
	setup = binary.LittleEndian.AppendUint16(setup, uint16(len(data)))
	setup = append(setup, 0, 0)
	setup = append(setup, pad(append([]byte(nil), name...))...)
	setup = append(setup, pad(append([]byte(nil), data...))...)
	if _, err := conn.Write(setup); err != nil {
		return nil, err
	}
	read := func(n int) ([]byte, error) {
		b := make([]byte, n)
		if _, err := io.ReadFull(conn, b); err != nil {
			return nil, errors.New("X server closed the connection")
		}
		return b, nil
	}
	head, err := read(8)
	if err != nil {
		return nil, err
	}
	body, err := read(int(binary.LittleEndian.Uint16(head[6:8])) * 4)
	if err != nil {
		return nil, err
	}
	if head[0] != 1 {
		reason := body
		if int(head[1]) < len(reason) {
			reason = reason[:head[1]]
		}
		return nil, fmt.Errorf("X server refused the connection: %s", strings.ToValidUTF8(string(reason), "?"))
	}
	if len(body) < 32 {
		return nil, errors.New("X server sent a short setup reply")
	}
	vendorLen := int(binary.LittleEndian.Uint16(body[16:18]))
	nFormats := int(body[21])
	screen := 32 + vendorLen + (4-vendorLen%4)%4 + 8*nFormats
	if len(body) < screen+24 {
		return nil, errors.New("X server sent a short setup reply")
	}
	root := binary.LittleEndian.Uint32(body[screen : screen+4])
	width := int(binary.LittleEndian.Uint16(body[screen+20 : screen+22]))
	height := int(binary.LittleEndian.Uint16(body[screen+22 : screen+24]))
	// GetImage (73), ZPixmap, the whole root window, all planes
	req := []byte{73, 2}
	req = binary.LittleEndian.AppendUint16(req, 5)
	req = binary.LittleEndian.AppendUint32(req, root)
	req = binary.LittleEndian.AppendUint16(req, 0) // x
	req = binary.LittleEndian.AppendUint16(req, 0) // y
	req = binary.LittleEndian.AppendUint16(req, uint16(width))
	req = binary.LittleEndian.AppendUint16(req, uint16(height))
	req = binary.LittleEndian.AppendUint32(req, 0xFFFFFFFF)
	if _, err := conn.Write(req); err != nil {
		return nil, err
	}
	reply, err := read(32)
	if err != nil {
		return nil, err
	}
	if reply[0] != 1 {
		return nil, fmt.Errorf("GetImage failed (X error %d)", reply[1])
	}
	pix, err := read(int(binary.LittleEndian.Uint32(reply[4:8])) * 4)
	if err != nil {
		return nil, err
	}
	if len(pix) < width*height*4 {
		return nil, errors.New("X server sent a short image")
	}
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	for i := 0; i < width*height; i++ { // BGRX -> RGBA
		img.Pix[i*4], img.Pix[i*4+1], img.Pix[i*4+2], img.Pix[i*4+3] = pix[i*4+2], pix[i*4+1], pix[i*4], 0xFF
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// cookie is the MIT-MAGIC-COOKIE-1 of display num in the Xauthority file: family, address, number, name, data (big-endian
// lengths). No file or no entry: an empty cookie.
func cookie(o XOpts, num string) (name, data []byte) {
	path := o.Xauth
	if path == "" {
		path = filepath.Join(o.Home, ".Xauthority")
	}
	auth, err := os.ReadFile(path)
	if err != nil {
		return nil, nil
	}
	i := 0
	for i+2 <= len(auth) {
		var fields [4][]byte
		i += 2
		for k := 0; k < 4; k++ {
			if i+2 > len(auth) {
				return nil, nil
			}
			n := int(binary.BigEndian.Uint16(auth[i : i+2]))
			end := min(i+2+n, len(auth))
			fields[k] = auth[i+2 : end]
			i += 2 + n
		}
		if (string(fields[1]) == num || len(fields[1]) == 0) && string(fields[2]) == "MIT-MAGIC-COOKIE-1" {
			return fields[2], fields[3]
		}
	}
	return nil, nil
}
