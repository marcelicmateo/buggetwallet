#!/usr/bin/env python3
"""Helpers for tools/live.sh: read `flutter run --machine` output and talk to the app's VM service.

  live_vm.py info <machine.jsonl>                 key=value lines: state, app, mode, vm, dtd, devtools, error
  live_vm.py request <id> <method> <app> [full]   one daemon request line for flutter run's stdin
  live_vm.py reply <machine.jsonl> <id> <secs>    wait for the daemon's reply to <id>; exit 1 on error/timeout
  live_vm.py shot <ws uri> <file.png>             screenshot of the app (widget inspector: debug builds only)
  live_vm.py xshot <file.png | ->                 screenshot of the X display in $DISPLAY (Xvfb), in the container
  live_vm.py trace-start <ws uri>                 record the Dart, Embedder and GC timeline streams from now on
  live_vm.py trace-stop <ws uri> <out.json> [mode]  save the timeline (Chrome trace JSON, opens in Perfetto/DevTools)
                                                  and <out>-summary.txt: frames, build/raster p50/p90/max, jank
  live_vm.py summary <trace.json>                 the summary of a saved trace
  live_vm.py forward <port>                       in the container: forward <port> on the pod's own addresses to
                                                  127.0.0.1:<port>, where DDS listens (published pod ports arrive there)

Standard library only (run with python3 -I). The VM service speaks JSON-RPC over a WebSocket; the minimal
client below is enough for it (no extensions, no TLS: the service only listens on 127.0.0.1).
"""
import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.parse
import zlib


# ---- flutter run --machine output ----
def events(path):
    """The JSON messages flutter run printed (each line is `[{...}]`); other lines are skipped."""
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            lines = f.readlines()
    except FileNotFoundError:
        return
    for line in lines:
        line = line.strip()
        if not (line.startswith('[{') and line.endswith('}]')):
            continue
        try:
            yield from json.loads(line)
        except ValueError:
            continue


def info(path):
    out = {'state': 'starting'}
    for e in events(path):
        p = e.get('params') or {}
        ev = e.get('event')
        if ev == 'app.start':
            out.update(state='building', app=p.get('appId', ''), mode=p.get('mode', ''))
        elif ev == 'app.debugPort':
            out['vm'] = p.get('wsUri', '')
        elif ev == 'app.dtd':
            out['dtd'] = p.get('uri', '')
        elif ev == 'app.devTools':
            out['devtools'] = p.get('uri', '')
        elif ev == 'app.started':
            out['state'] = 'started'
        elif ev == 'app.stop':
            out['state'] = 'stopped'
            if p.get('error'):
                out['error'] = str(p['error']).splitlines()[0][:200]
        elif ev == 'daemon.log' and p.get('error'):
            out.setdefault('error', str(p.get('log', '')).splitlines()[0][:200] if p.get('log') else '')
        elif ev == 'daemon.connected' and 'dtd' not in out and p.get('dtdUri'):
            out['dtd'] = p['dtdUri']
    # DevTools opened on this VM service (DevTools server started by flutter run, or the public one by URL)
    if 'devtools' in out and out.get('vm') and '?' not in out['devtools']:
        out['devtools'] = out['devtools'].rstrip('/') + '/?uri=' + urllib.parse.quote(out['vm'], safe='')
    return out


def reply(path, rid, secs):
    end = time.time() + secs
    while time.time() < end:
        for e in events(path):
            if e.get('id') == rid and 'event' not in e:
                if 'error' in e:
                    print(f"error: {e['error']}")
                    return 1
                r = e.get('result')
                code = r.get('code', 0) if isinstance(r, dict) else 0
                msg = r.get('message', '') if isinstance(r, dict) else ''
                print(msg or 'done')
                return 0 if code == 0 else 1
        time.sleep(0.1)
    print('timed out waiting for flutter run')
    return 1


# ---- VM service over a WebSocket ----
class VmService:
    def __init__(self, uri):
        u = urllib.parse.urlparse(uri)
        self.sock = socket.create_connection((u.hostname, u.port), timeout=120)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f'GET {u.path or "/"} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\nUpgrade: websocket\r\n'
                           f'Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        head = b''
        while b'\r\n\r\n' not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError('VM service closed the connection')
            head += chunk
        head, rest = head.split(b'\r\n\r\n', 1)
        if b' 101 ' not in head.split(b'\r\n', 1)[0] + b' ':
            raise ConnectionError('VM service refused the WebSocket: ' + head.split(b'\r\n', 1)[0].decode(errors='replace'))
        self.buf = bytearray(rest)
        self.next_id = 0

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(max(1 << 16, n - len(self.buf)))
            if not chunk:
                raise ConnectionError('VM service closed the connection')
            self.buf.extend(chunk)
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out

    def _send(self, opcode, data):
        n = len(data)
        hdr = bytearray([0x80 | opcode])
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 1 << 16:
            hdr += bytes([0x80 | 126]) + struct.pack('>H', n)
        else:
            hdr += bytes([0x80 | 127]) + struct.pack('>Q', n)
        mask = os.urandom(4)
        self.sock.sendall(bytes(hdr) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _message(self):
        parts = []
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack('>H', self._read(2))[0]
            elif n == 127:
                n = struct.unpack('>Q', self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            data = self._read(n)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            op = b0 & 0x0F
            if op == 8:
                raise ConnectionError('VM service closed the connection')
            if op == 9:
                self._send(10, data)
                continue
            if op in (0, 1, 2):
                parts.append(data)
                if b0 & 0x80:
                    return b''.join(parts)

    def call(self, method, **params):
        self.next_id += 1
        rid = str(self.next_id)
        self._send(1, json.dumps({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params}).encode())
        while True:
            msg = json.loads(self._message())
            if msg.get('id') == rid:
                if 'error' in msg:
                    raise RuntimeError(f"{method}: {msg['error'].get('message')} {msg['error'].get('data', '')}")
                return msg['result']

    def main_isolate(self):
        vm = self.call('getVM')
        for iso in vm.get('isolates', []):
            if iso.get('name', '').startswith('main'):
                return iso['id']
        return vm['isolates'][0]['id']


def screenshot(vm):
    """PNG of the whole app: the widget inspector's screenshot of the root widget (debug builds), else the engine's
    rasterizer screenshot (fails with Impeller on Linux in 3.47)."""
    iso = vm.main_isolate()
    try:
        root = vm.call('ext.flutter.inspector.getRootWidgetTree', isolateId=iso, groupName='bw-shot', isSummaryTree='true',
                       withPreviews='false', fullDetails='false')['result']
        try:
            # width/height are an upper bound: the root is drawn at its own size (pixel ratio 1)
            png = vm.call('ext.flutter.inspector.screenshot', isolateId=iso, id=root['valueId'], width='10000',
                          height='10000', margin='0', maxPixelRatio='1', debugPaint='false')['result']
        finally:
            vm.call('ext.flutter.inspector.disposeGroup', isolateId=iso, objectGroup='bw-shot')
        if png:
            return base64.b64decode(png)
    except RuntimeError as e:
        first = e
    else:
        first = RuntimeError('the inspector returned no image')
    try:
        return base64.b64decode(vm.call('_flutter.screenshot')['screenshot'])
    except RuntimeError as e:
        raise RuntimeError(f'no screenshot: {first}; {e}') from None


def png(width, height, rgb):
    """8-bit RGB PNG from packed rows."""
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    stride = width * 3
    raw = b''.join(b'\0' + rgb[y * stride:(y + 1) * stride] for y in range(height))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))


def x11_screenshot():
    """The root window of $DISPLAY (a local Xvfb: 24-bit TrueColor, little endian) through the X11 protocol itself,
    so the image needs no X tools. Profile builds have no inspector screenshot; this covers them when headless."""
    display = os.environ['DISPLAY']
    num = display.split(':', 1)[1].split('.')[0]
    sock = socket.socket(socket.AF_UNIX)
    sock.connect(f'/tmp/.X11-unix/X{num}')
    name = data = b''
    try:  # MIT-MAGIC-COOKIE-1 from the Xauthority file: family, address, number, name, data (big-endian lengths)
        with open(os.environ.get('XAUTHORITY', os.path.expanduser('~/.Xauthority')), 'rb') as f:
            auth = f.read()
        i = 0
        while i + 2 <= len(auth):
            fields = []
            i += 2
            for _ in range(4):
                n = struct.unpack('>H', auth[i:i + 2])[0]
                fields.append(auth[i + 2:i + 2 + n])
                i += 2 + n
            if fields[1].decode(errors='replace') in (num, '') and fields[2] == b'MIT-MAGIC-COOKIE-1':
                name, data = fields[2], fields[3]
                break
    except OSError:
        pass

    def pad(b):
        return b + b'\0' * (-len(b) % 4)

    def read(n):
        out = bytearray()
        while len(out) < n:
            chunk = sock.recv(min(1 << 20, n - len(out)))
            if not chunk:
                raise ConnectionError('X server closed the connection')
            out.extend(chunk)
        return bytes(out)

    sock.sendall(struct.pack('<BxHHHHxx', 0x6C, 11, 0, len(name), len(data)) + pad(name) + pad(data))
    head = read(8)
    setup = read(struct.unpack('<H', head[6:8])[0] * 4)
    if head[0] != 1:
        raise ConnectionError('X server refused the connection: ' + setup[:head[1]].decode(errors='replace'))
    vendor_len, _, _, n_formats = struct.unpack('<HHBB', setup[16:22])
    screen = 32 + vendor_len + (-vendor_len % 4) + 8 * n_formats
    root = struct.unpack('<I', setup[screen:screen + 4])[0]
    width, height = struct.unpack('<HH', setup[screen + 20:screen + 24])
    # GetImage (73), ZPixmap, whole root window, all planes
    sock.sendall(struct.pack('<BBHIhhHHI', 73, 2, 5, root, 0, 0, width, height, 0xFFFFFFFF))
    reply = read(32)
    if reply[0] != 1:
        raise ConnectionError(f'GetImage failed (X error {reply[1]})')
    pixels = read(struct.unpack('<I', reply[4:8])[0] * 4)[:width * height * 4]
    rgb = bytearray(width * height * 3)
    rgb[0::3], rgb[1::3], rgb[2::3] = pixels[2::4], pixels[1::4], pixels[0::4]  # BGRX -> RGB
    return png(width, height, bytes(rgb))


# ---- timeline summary ----
def pct(values, p):
    if not values:
        return 0.0
    s = sorted(values)
    return s[min(len(s) - 1, int(round(p / 100 * (len(s) - 1))))]


def spans(trace, names):
    """Durations (ms) of the named events: complete events (ph X) and begin/end pairs per thread."""
    out, open_ = [], {}
    for e in trace:
        name = e.get('name')
        if name not in names:
            continue
        ph = e.get('ph')
        if ph == 'X' and 'dur' in e:
            out.append((e['ts'], e['dur'] / 1000))
        elif ph == 'B':
            open_.setdefault((e.get('tid'), name), []).append(e['ts'])
        elif ph == 'E':
            stack = open_.get((e.get('tid'), name))
            if stack:
                start = stack.pop()
                out.append((start, (e['ts'] - start) / 1000))
    return [d for _, d in sorted(out)]


# UI thread: one per frame, the framework's build/layout/paint. Raster thread: drawing that frame.
BUILD_EVENTS = {'Animator::BeginFrame'}
RASTER_EVENTS = {'GPURasterizer::Draw'}  # Rasterizer::DoDraw is nested inside it


def summary(trace, mode='', budget_ms=16.0):
    build = spans(trace, BUILD_EVENTS)
    raster = spans(trace, RASTER_EVENTS)
    frames = max(len(build), len(raster))
    stamps = [e['ts'] for e in trace if 'ts' in e and e.get('ph') != 'M']
    secs = (max(stamps) - min(stamps)) / 1e6 if stamps else 0
    # A frame is janky when its build or its raster time is over budget; pair them by order (same frame count).
    janky = sum(1 for i in range(frames)
                if (i < len(build) and build[i] > budget_ms) or (i < len(raster) and raster[i] > budget_ms))
    lines = [f'timeline: {secs:.1f} s, {len(trace)} events, {frames} frames, {janky} over {budget_ms:.0f} ms (build or raster)']
    for label, values in (('build', build), ('raster', raster)):
        lines.append(f'{label:7s} n={len(values):<5d} p50={pct(values, 50):6.1f} ms  p90={pct(values, 90):6.1f} ms  '
                     f'max={max(values, default=0):6.1f} ms')
    if mode and mode != 'profile':
        lines.append(f'({mode} build: timings are not representative; tools/live.sh start --profile for real numbers)')
    return '\n'.join(lines) + '\n'


def forward(port):
    import asyncio

    # This network namespace's own IPv4 addresses except loopback (/proc/net/fib_trie: '/32 host LOCAL' entries)
    addrs, last = set(), None
    with open('/proc/net/fib_trie', encoding='ascii') as f:
        for line in f:
            if '|--' in line:
                last = line.split('|--')[1].strip()
            elif '/32 host LOCAL' in line and last and not last.startswith('127.'):
                addrs.add(last)

    async def pipe(reader, writer):
        try:
            while data := await reader.read(1 << 16):
                writer.write(data)
                await writer.drain()
        except OSError:
            pass
        finally:
            writer.close()

    async def handle(reader, writer):
        try:
            up_reader, up_writer = await asyncio.open_connection('127.0.0.1', port)
        except OSError:
            writer.close()
            return
        await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))

    async def serve():
        servers = [await asyncio.start_server(handle, a, port) for a in sorted(addrs)]
        await asyncio.gather(*(s.serve_forever() for s in servers))

    asyncio.run(serve())


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == 'info':
        for k, v in info(args[0]).items():
            print(f'{k}={v}')
        return 0
    if cmd == 'request':
        rid, method, app = int(args[0]), args[1], args[2]
        params = {'appId': app}
        if method == 'app.restart':
            params.update(fullRestart=len(args) > 3 and args[3] == 'full', pause=False, reason='manual')
        print(json.dumps([{'id': rid, 'method': method, 'params': params}]))
        return 0
    if cmd == 'reply':
        return reply(args[0], int(args[1]), float(args[2]))
    if cmd == 'summary':
        with open(args[0], encoding='utf-8') as f:
            print(summary(json.load(f)['traceEvents']), end='')
        return 0
    if cmd == 'forward':
        forward(int(args[0]))
        return 0
    if cmd == 'xshot':
        data = x11_screenshot()
        if args[0] == '-':
            sys.stdout.buffer.write(data)
        else:
            with open(args[0], 'wb') as f:
                f.write(data)
        return 0
    vm = VmService(args[0])
    if cmd == 'shot':
        data = screenshot(vm)
        with open(args[1], 'wb') as f:
            f.write(data)
        print(f'{args[1]} ({len(data) // 1024} KB)')
        return 0
    if cmd == 'trace-start':
        vm.call('setVMTimelineFlags', recordedStreams=['Dart', 'Embedder', 'GC'])
        vm.call('clearVMTimeline')
        print('recording the timeline (Dart, Embedder, GC)')
        return 0
    if cmd == 'trace-stop':
        tl = vm.call('getVMTimeline')
        vm.call('setVMTimelineFlags', recordedStreams=[])
        trace = tl.get('traceEvents', [])
        with open(args[1], 'w', encoding='utf-8') as f:
            json.dump({'traceEvents': trace, 'displayTimeUnit': 'ms'}, f)
        text = summary(trace, args[2] if len(args) > 2 else '')
        with open(os.path.splitext(args[1])[0] + '-summary.txt', 'w', encoding='utf-8') as f:
            f.write(text)
        print(text, end='')
        print(f'saved {args[1]}')
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
