#!/usr/bin/env python3
"""Screenshot a Flutter web page with headless Chrome (runs in the build container; used by tools/web.sh shot).

    web_shot.py <url> <out.png> <width>x<height> [wait-seconds]

Chrome's own --screenshot fires at the load event, before Flutter has drawn anything, so this drives Chrome over the
DevTools protocol (a minimal stdlib WebSocket client), waits until Flutter's <flt-glass-pane> exists plus a settle time,
and captures then.
"""
import base64
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request


class WS:
    def __init__(self, host, port, path):
        self.s = socket.create_connection((host, port), timeout=60)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f'GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                        f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        buf = b''
        while b'\r\n\r\n' not in buf:
            buf += self.s.recv(1)
        if b' 101 ' not in buf.split(b'\r\n')[0]:
            raise RuntimeError(buf.decode(errors='replace'))
        self.n = 0

    def _read(self, n):
        d = b''
        while len(d) < n:
            c = self.s.recv(n - len(d))
            if not c:
                raise EOFError
            d += c
        return d

    def _frame(self):
        h = self._read(2)
        ln = h[1] & 0x7F
        if ln == 126:
            ln = struct.unpack('>H', self._read(2))[0]
        elif ln == 127:
            ln = struct.unpack('>Q', self._read(8))[0]
        return h[0] & 0x0F, self._read(ln)

    def call(self, method, **params):
        self.n += 1
        data = json.dumps({'id': self.n, 'method': method, 'params': params}).encode()
        mask = os.urandom(4)
        n = len(data)
        head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack('>H', n) if n < 65536
                                else bytes([0x80 | 127]) + struct.pack('>Q', n))
        self.s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))
        text = b''
        while True:
            op, payload = self._frame()
            if op == 1:
                text = payload
            elif op == 0:
                text += payload
            else:
                continue
            msg = json.loads(text)
            if msg.get('id') == self.n:
                if 'error' in msg:
                    raise RuntimeError(msg['error'])
                return msg.get('result', {})


def main():
    url, out, size = sys.argv[1:4]
    wait = float(sys.argv[4]) if len(sys.argv) > 4 else 20
    w, h = (int(x) for x in size.split('x'))
    prof = tempfile.mkdtemp()
    chrome = subprocess.Popen(
        ['chrome-bw', '--headless=new', '--remote-debugging-port=9222', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
         f'--user-data-dir={prof}', f'--window-size={w},{h}', '--hide-scrollbars', 'about:blank'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            try:
                tabs = json.load(urllib.request.urlopen('http://127.0.0.1:9222/json'))
                page = next(t for t in tabs if t['type'] == 'page')
                break
            except Exception:
                time.sleep(0.2)
        else:
            sys.exit('chrome did not start')
        ws = WS('127.0.0.1', 9222, page['webSocketDebuggerUrl'].split('9222', 1)[1])
        ws.call('Emulation.setDeviceMetricsOverride', width=w, height=h, deviceScaleFactor=1, mobile=False)
        ws.call('Page.navigate', url=url)
        deadline = time.time() + wait
        while time.time() < deadline:
            r = ws.call('Runtime.evaluate', expression="!!document.querySelector('flt-glass-pane')", returnByValue=True)
            if r['result'].get('value'):
                break
            time.sleep(0.5)
        else:
            print('warning: no flt-glass-pane after %ds' % wait, file=sys.stderr)
        time.sleep(3)  # fonts and first frames
        shot = ws.call('Page.captureScreenshot', format='png')
        with open(out, 'wb') as f:
            f.write(base64.b64decode(shot['data']))
    finally:
        chrome.terminate()


main()
