#!/usr/bin/env python3
"""Where is this symbol used or defined? Asks the Dart language server (tools/build.sh lsp) instead of grep.

  python3 -I tools/lsp.py refs <path>:<line>:<col> [<path>:<line>:<col> ...]
  python3 -I tools/lsp.py def  <path>:<line>:<col> [...]

Line and column are 1-based (as grep -n and editors show them) and point into the symbol. Paths are relative to the repo
root (or absolute). Output: one `path:line:col` per result (1-based, relative to the repo); with several positions each block
is headed by `# <position>`. Exit 0 when every query returned at least one location, 1 otherwise (errors go to stderr).
One server start serves all positions of the call.

Cost: the server runs in the Podman container. Measured wall time on the owner's laptop (warm image and pub cache):
~9 s for `refs` of WalletRepo (372 locations over the repo), ~5 s for two `def` queries in one call.
"""
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Lsp:
    def __init__(self):
        self.proc = subprocess.Popen([os.path.join(ROOT, "tools", "build.sh"), "lsp"], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=sys.stderr)
        self.next_id = 0

    def _send(self, msg):
        body = json.dumps(msg).encode()
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.proc.stdin.flush()

    def _read(self):
        length = None
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise ConnectionError("language server closed the connection")
            line = line.strip()
            if not line:
                break
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":", 1)[1])
        if length is None:
            raise ConnectionError("language server sent a header without Content-Length")
        return json.loads(self.proc.stdout.read(length))

    def notify(self, method, **params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def call(self, method, **params):
        self.next_id += 1
        rid = self.next_id
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        while True:
            msg = self._read()
            if "method" in msg and "id" in msg:  # a request from the server (configuration, registerCapability...)
                result = [None] * len(msg.get("params", {}).get("items", [])) if msg["method"] == "workspace/configuration" else None
                self._send({"jsonrpc": "2.0", "id": msg["id"], "result": result})
            elif msg.get("id") == rid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error'].get('message')}")
                return msg.get("result")

    def close(self):
        try:
            self.call("shutdown")
            self.notify("exit")
        except Exception:
            pass
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


def uri_of(path):
    return "file://" + urllib.parse.quote(path)


def path_of(uri):
    return urllib.request.url2pathname(urllib.parse.urlparse(uri).path)


def parse_pos(arg):
    try:
        path, line, col = arg.rsplit(":", 2)
        path = path if os.path.isabs(path) else os.path.join(ROOT, path)
        return os.path.normpath(path), int(line), int(col)
    except ValueError:
        raise SystemExit(f"bad position {arg!r}: expected <path>:<line>:<col>")


def main(argv):
    if len(argv) < 2 or argv[0] in ("-h", "--help") or argv[0] not in ("refs", "def"):
        print(__doc__.rstrip())
        return 0 if argv and argv[0] in ("-h", "--help") else 2
    kind, positions = argv[0], [parse_pos(a) for a in argv[1:]]
    for path, _, _ in positions:
        if not os.path.isfile(path):
            raise SystemExit(f"no such file: {path}")
    srv = Lsp()
    status = 0
    try:
        srv.call("initialize", processId=os.getpid(), rootUri=uri_of(ROOT),
                 workspaceFolders=[{"uri": uri_of(ROOT), "name": "repo"}],
                 capabilities={"workspace": {"configuration": True}}, initializationOptions={})
        srv.notify("initialized")
        opened = set()
        for i, (path, line, col) in enumerate(positions):
            if path not in opened:
                with open(path, encoding="utf-8") as f:
                    srv.notify("textDocument/didOpen", textDocument={"uri": uri_of(path), "languageId": "dart", "version": 1,
                                                                     "text": f.read()})
                opened.add(path)
            params = {"textDocument": {"uri": uri_of(path)}, "position": {"line": line - 1, "character": col - 1}}
            if kind == "refs":
                res = srv.call("textDocument/references", context={"includeDeclaration": True}, **params)
            else:
                res = srv.call("textDocument/definition", **params)
            if isinstance(res, dict):
                res = [res]
            out = []
            for loc in res or []:
                uri = loc.get("uri") or loc.get("targetUri")
                rng = loc.get("range") or loc.get("targetSelectionRange")
                p = path_of(uri)
                rel = os.path.relpath(p, ROOT) if p.startswith(ROOT) else p
                out.append((rel, rng["start"]["line"] + 1, rng["start"]["character"] + 1))
            if len(positions) > 1:
                print(f"# {os.path.relpath(path, ROOT)}:{line}:{col}")
            for rel, ln, c in sorted(set(out)):
                print(f"{rel}:{ln}:{c}")
            if not out:
                status = 1
    except (RuntimeError, ConnectionError) as e:
        print(f"lsp.py: {e}", file=sys.stderr)
        status = 1
    finally:
        srv.close()
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
