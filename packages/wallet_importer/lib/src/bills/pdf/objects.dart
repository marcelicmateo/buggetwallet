part of '../pdf_text.dart';

// The document: `N G obj` scan, object streams, stream data and decoding, the page tree, fonts per resource dict.

class _Pdf {
  final Uint8List b;
  int ops = 0;
  int inflated = 0;
  final offsets = <int, int>{};
  final _cache = <int, Object?>{};
  final _compressed = <int, Object?>{};
  final _resolving = <int>{};
  bool _objStmsLoaded = false;
  final _fonts = Map<Object, _Font>.identity();
  _Pdf(this.b);

  void tick([int n = 1]) {
    ops += n;
    if (ops > pdfOpBudget) throw const _OutOfBudget();
  }

  /// Finds every `N G obj` (outside stream data); the last definition of a number wins.
  void scan() {
    final n = b.length;
    for (var i = 0; i + 3 <= n; i++) {
      final c = b[i];
      if (c == 0x6F && b[i + 1] == 0x62 && b[i + 2] == 0x6A) {
        if (i + 3 < n && _isRegular(b[i + 3])) continue;
        var j = i - 1;
        if (j < 0 || !_isWs(b[j])) continue;
        while (j >= 0 && _isWs(b[j])) {
          j--;
        }
        final genEnd = j + 1;
        while (j >= 0 && _isDigit(b[j])) {
          j--;
        }
        if (j + 1 == genEnd || j < 0 || !_isWs(b[j])) continue;
        while (j >= 0 && _isWs(b[j])) {
          j--;
        }
        final numEnd = j + 1;
        while (j >= 0 && _isDigit(b[j])) {
          j--;
        }
        final numStart = j + 1;
        if (numStart == numEnd || numEnd - numStart > 9) continue;
        if (j >= 0 && _isRegular(b[j])) continue;
        offsets[int.parse(String.fromCharCodes(b, numStart, numEnd))] = numStart;
        i += 2;
      } else if (c == 0x73 && i + 6 < n && _startsWith(i, _streamKw) && (b[i + 6] == 10 || b[i + 6] == 13)) {
        var j = i - 1;
        while (j >= 0 && _isWs(b[j])) {
          j--;
        }
        if (j < 0 || b[j] != 0x3E) continue;
        final end = _indexOf(b, _endstream, i + 6);
        if (end < 0) break;
        i = end + _endstream.length - 1;
      }
    }
  }

  bool _startsWith(int i, List<int> pat) {
    if (i < 0 || i + pat.length > b.length) return false;
    for (var k = 0; k < pat.length; k++) {
      if (b[i + k] != pat[k]) return false;
    }
    return true;
  }

  Object? resolve(Object? v) => v is _Ref ? obj(v.n) : v;

  Map<String, Object?>? dict(Object? v) {
    final r = resolve(v);
    if (r is Map<String, Object?>) return r;
    if (r is _Stream) return r.dict;
    return null;
  }

  Object? obj(int n) {
    if (_cache.containsKey(n)) return _cache[n];
    if (!_resolving.add(n)) return null;
    try {
      Object? v;
      final off = offsets[n];
      if (off != null) {
        try {
          v = _parseAt(off);
        } on _OutOfBudget {
          rethrow;
        } catch (_) {
          v = null;
        }
      } else {
        _loadObjStms();
        v = _compressed[n];
      }
      _cache[n] = v;
      return v;
    } finally {
      _resolving.remove(n);
    }
  }

  Object? _parseAt(int off) {
    final lx = _Lexer(b, off, this);
    final num = lx.token(), gen = lx.token(), kw = lx.token();
    if (num is! int || gen is! int || kw is! _Op || kw.v != 'obj') return null;
    final v = lx.value(lx.token());
    if (v is Map<String, Object?>) {
      final t = lx.token();
      if (t is _Op && t.v == 'stream') {
        var start = lx.pos;
        if (start < b.length && b[start] == 13) start++;
        if (start < b.length && b[start] == 10) start++;
        return _Stream(v, _streamData(v, start));
      }
    }
    return v;
  }

  Uint8List _streamData(Map<String, Object?> d, int start) {
    final len = resolve(d['Length']);
    if (len is int && len >= 0 && start + len <= b.length) {
      var k = start + len;
      while (k < b.length && _isWs(b[k])) {
        k++;
      }
      if (_startsWith(k, _endstream)) return Uint8List.sublistView(b, start, start + len);
    }
    final end = _indexOf(b, _endstream, start);
    var e = end < 0 ? b.length : end;
    if (e > start && b[e - 1] == 10) e--;
    if (e > start && b[e - 1] == 13) e--;
    return Uint8List.sublistView(b, start, e);
  }

  void _loadObjStms() {
    if (_objStmsLoaded) return;
    _objStmsLoaded = true;
    for (final n in offsets.keys.toList()) {
      final o = obj(n);
      if (o is! _Stream || _nameOf(o.dict['Type']) != 'ObjStm') continue;
      final count = resolve(o.dict['N']), first = resolve(o.dict['First']);
      if (count is! int || first is! int || count < 0 || count > 1000000) continue;
      final data = decode(o);
      if (data == null) continue;
      final lx = _Lexer(data, 0, this);
      final pairs = <(int, int)>[];
      for (var k = 0; k < count; k++) {
        final a = lx.token(), off = lx.token();
        if (a is! int || off is! int) break;
        pairs.add((a, off));
      }
      for (final (num, off) in pairs) {
        if (offsets.containsKey(num) || _compressed.containsKey(num) || first + off >= data.length || off < 0) continue;
        try {
          final vl = _Lexer(data, first + off, this);
          _compressed[num] = vl.value(vl.token());
        } on _OutOfBudget {
          rethrow;
        } catch (_) {
          // skip a broken object
        }
      }
    }
  }

  /// Decoded stream data; `null` for an unsupported filter. A corrupt deflate stream gives what inflated before the error.
  Uint8List? decode(_Stream s) {
    var data = s.raw;
    final f = resolve(s.dict['Filter']);
    final filters = f is List ? f.map(resolve).toList() : [f];
    for (final filter in filters) {
      switch (_nameOf(filter)) {
        case null:
          if (filter != null) return null;
        case 'FlateDecode' || 'Fl':
          data = _inflate(data);
        case 'ASCIIHexDecode' || 'AHx':
          data = _asciiHex(data);
        case 'ASCII85Decode' || 'A85':
          data = _ascii85(data);
        default:
          return null;
      }
    }
    return data;
  }

  Uint8List _inflate(Uint8List data) {
    var start = 0;
    if (data.length >= 2 && (data[0] & 0x0F) == 8 && ((data[0] << 8) | data[1]) % 31 == 0) start = 2;
    final out = _CappedOutput(_maxInflated - inflated);
    try {
      Inflate(Uint8List.sublistView(data, start), output: out);
    } catch (_) {
      // truncated or corrupt: keep what came out
    }
    inflated += out.length;
    tick(out.length >> 8);
    return Uint8List.fromList(out.getBytes());
  }

  /// Pages in page-tree order, each with its (inherited) resources.
  List<(Map<String, Object?>, Map<String, Object?>?)> pages() {
    final out = <(Map<String, Object?>, Map<String, Object?>?)>[];
    final seen = <Object>{};
    void walk(Object? node, Map<String, Object?>? inherited, int depth) {
      if (depth > 64) return;
      if (node is _Ref && !seen.add(node.n)) return;
      final d = dict(node);
      if (d == null || !seen.add(d)) return;
      final res = dict(d['Resources']) ?? inherited;
      final kids = resolve(d['Kids']);
      final type = _nameOf(d['Type']);
      if (type == 'Pages' || (type != 'Page' && kids is List)) {
        if (kids is List) {
          for (final k in kids) {
            walk(k, res, depth + 1);
          }
        }
      } else if (type == 'Page' || d.containsKey('Contents')) {
        out.add((d, res));
      }
    }

    final root = _catalog();
    if (root != null) walk(root['Pages'], null, 0);
    if (out.isEmpty) {
      // no usable page tree: every page object, by object number
      _loadObjStms();
      final nums = {...offsets.keys, ..._compressed.keys}.toList()..sort();
      for (final n in nums) {
        final d = dict(obj(n));
        if (d != null && _nameOf(d['Type']) == 'Page') out.add((d, dict(d['Resources'])));
      }
    }
    return out;
  }

  Map<String, Object?>? _catalog() {
    Map<String, Object?>? fromRoot(Object? root) {
      final d = dict(root);
      return d != null && d['Pages'] != null ? d : null;
    }

    // the last classic trailer
    for (var i = _lastIndexOf(_trailer); i >= 0; i = i > 0 ? _lastIndexOf(_trailer, i - 1) : -1) {
      final lx = _Lexer(b, i + _trailer.length, this);
      final t = lx.value(lx.token());
      if (t is Map<String, Object?>) {
        final c = fromRoot(t['Root']);
        if (c != null) return c;
      }
    }
    // xref streams carry /Root; else any catalog
    final byOffset = offsets.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in byOffset) {
      final o = obj(e.key);
      if (o is _Stream && _nameOf(o.dict['Type']) == 'XRef') {
        final c = fromRoot(o.dict['Root']);
        if (c != null) return c;
      }
    }
    _loadObjStms();
    for (final n in [...offsets.keys, ..._compressed.keys]) {
      final d = dict(obj(n));
      if (d != null && _nameOf(d['Type']) == 'Catalog' && d['Pages'] != null) return d;
    }
    return null;
  }

  int _lastIndexOf(List<int> pat, [int? from]) {
    for (var i = (from ?? b.length - pat.length).clamp(-1, b.length - pat.length); i >= 0; i--) {
      if (b[i] == pat[0] && _startsWith(i, pat)) return i;
    }
    return -1;
  }

  void pageText(Map<String, Object?> page, Map<String, Object?>? res, _Out out) {
    final c = resolve(page['Contents']);
    final parts = c is List ? c.map(resolve).toList() : [c];
    final bb = BytesBuilder(copy: false);
    for (final p in parts) {
      if (p is! _Stream) continue;
      final data = decode(p);
      if (data == null) continue;
      bb
        ..add(data)
        ..addByte(10);
    }
    _run(bb.takeBytes(), res, out, 0, <Object>{});
  }

  _Font? _font(Map<String, Object?>? res, Object? name) {
    final n = _nameOf(name);
    if (n == null) return null;
    final fonts = dict(res?['Font']);
    final d = dict(fonts?[n]);
    if (d == null) return null;
    return _fonts[d] ??= _Font.from(this, d);
  }
}
