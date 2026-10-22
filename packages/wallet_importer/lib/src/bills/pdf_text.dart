// Minimal PDF text-layer extractor for bills: enough of PDF to read the text a bill generator writes.
//
// Supported: objects found by scanning for `N G obj` (xref tables and xref streams are not read, so broken xrefs and
// incremental updates are fine: the last definition of an object wins), compressed object streams (/ObjStm),
// stream data by /Length (direct or indirect) with a fallback scan for `endstream`, filters FlateDecode (zlib or raw
// deflate), ASCIIHexDecode and ASCII85Decode, the page tree in order (inherited /Resources), Form XObjects (`Do`),
// text operators Tj, TJ (large negative offsets become a space), ', ", T*, Td, TD, Tm, inline images skipped,
// literal and hex strings with escapes, ToUnicode CMaps (codespace ranges, bfchar, bfrange incl. the array form,
// 1- to 4-byte codes) and, for simple fonts without a CMap, WinAnsi plus /Differences glyph names.
//
// Not supported (text from these is missing or wrong, never an exception): encrypted files (→ null), PNG/TIFF
// predictors (/DecodeParms /Predictor, only used by some object streams), LZW and RunLength filters, predefined CJK
// CMaps and Type0 fonts without a ToUnicode CMap, MacRoman/Standard encodings (read as WinAnsi), text in annotations
// or form fields, text drawn as images (scans need OCR), reading order beyond "content stream order, new line when the
// baseline moves".
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:logging/logging.dart';

import '../log.dart';
import 'common.dart';

/// Largest PDF read; bigger → `null`.
const maxPdfBytes = 20 * 1024 * 1024;

/// Work budget for one file (tokens, glyphs, inflated KB): past it, the text read so far is returned (or `null`).
const pdfOpBudget = 5000000;

/// Most bytes inflated from one file (all streams together): a compression bomb stops here.
const _maxInflated = 64 * 1024 * 1024;

/// Most characters of text returned.
const _maxChars = 2000000;

/// The text layer of [pdf], pages in order, lines separated by `\n`; `null` when the file is not a PDF, is encrypted,
/// is over [maxPdfBytes], has no text, or is unreadable. Never throws.
String? pdfText(Uint8List pdf) {
  final sw = Stopwatch()..start();
  var reason = 'ok';
  String? text;
  var pages = 0, objects = 0;
  try {
    if (pdf.length > maxPdfBytes) {
      reason = 'tooBig';
    } else if (_indexOf(pdf, _pdfHeader, 0, 1024) < 0) {
      reason = 'notPdf';
    } else if (_hasEncrypt(pdf)) {
      reason = 'encrypted';
    } else {
      final doc = _Pdf(pdf);
      final out = _Out();
      try {
        doc.scan();
        objects = doc.offsets.length;
        final list = doc.pages();
        pages = list.length;
        for (final p in list) {
          out.page();
          try {
            doc.pageText(p.$1, p.$2, out);
          } on _OutOfBudget {
            rethrow;
          } catch (_) {
            // a broken page: keep what the others give
          }
        }
      } on _OutOfBudget {
        reason = 'budget';
      }
      text = out.result();
      if (text == null && reason == 'ok') reason = 'noText';
    }
  } catch (_) {
    reason = 'error';
    text = null;
  }
  if (reason == 'error') {
    logImporter(billsLog, Level.WARNING, 'bills.pdf', {'reason': reason});
  } else {
    logImporter(billsLog, text == null ? Level.INFO : Level.FINE, 'bills.pdf', {
      'reason': reason,
      'bytes': pdf.length,
      'objects': objects,
      'pages': pages,
      'chars': text?.length ?? 0,
      'ms': sw.elapsedMilliseconds,
    });
  }
  return text;
}

final _pdfHeader = '%PDF-'.codeUnits;
final _encrypt = '/Encrypt'.codeUnits;
final _endstream = 'endstream'.codeUnits;
final _trailer = 'trailer'.codeUnits;
final _streamKw = 'stream'.codeUnits;

bool _hasEncrypt(Uint8List b) {
  for (var i = _indexOf(b, _encrypt, 0); i >= 0; i = _indexOf(b, _encrypt, i + 1)) {
    final next = i + _encrypt.length;
    if (next >= b.length || !_isRegular(b[next])) return true;
  }
  return false;
}

int _indexOf(Uint8List b, List<int> pat, int from, [int? limit]) {
  final end = (limit ?? b.length) - pat.length;
  final first = pat[0];
  outer:
  for (var i = from < 0 ? 0 : from; i <= end; i++) {
    if (b[i] != first) continue;
    for (var k = 1; k < pat.length; k++) {
      if (b[i + k] != pat[k]) continue outer;
    }
    return i;
  }
  return -1;
}

bool _isWs(int c) => c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32;
bool _isDelim(int c) =>
    c == 0x28 || c == 0x29 || c == 0x3C || c == 0x3E || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D || c == 0x2F || c == 0x25;
bool _isRegular(int c) => !_isWs(c) && !_isDelim(c);
bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

class _OutOfBudget implements Exception {
  const _OutOfBudget();
}

class _Bad implements Exception {
  const _Bad();
}

class _Name {
  final String v;
  const _Name(this.v);
}

class _Op {
  final String v;
  const _Op(this.v);
}

class _Ref {
  final int n;
  const _Ref(this.n);
}

class _Stream {
  final Map<String, Object?> dict;
  final Uint8List raw;
  _Stream(this.dict, this.raw);
}

const _eof = _Op('\u0000eof');
final _number = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)$');

/// Tokens of PDF syntax: numbers, [_Name], strings (as [Uint8List]), keywords and brackets ([_Op]), [_eof] at the end.
class _Lexer {
  final Uint8List b;
  int pos;
  final _Pdf pdf;
  final bool refs;
  _Lexer(this.b, this.pos, this.pdf, {this.refs = true});

  void skipWs() {
    while (pos < b.length) {
      final c = b[pos];
      if (_isWs(c)) {
        pos++;
      } else if (c == 0x25) {
        while (pos < b.length && b[pos] != 10 && b[pos] != 13) {
          pos++;
        }
      } else {
        break;
      }
    }
  }

  Object token() {
    pdf.tick();
    skipWs();
    if (pos >= b.length) return _eof;
    final c = b[pos];
    switch (c) {
      case 0x2F: // /
        pos++;
        final sb = StringBuffer();
        while (pos < b.length && _isRegular(b[pos])) {
          var ch = b[pos++];
          if (ch == 0x23 && pos + 1 < b.length) {
            final v = int.tryParse(String.fromCharCodes(b, pos, pos + 2), radix: 16);
            if (v != null) {
              ch = v;
              pos += 2;
            }
          }
          sb.writeCharCode(ch);
        }
        return _Name(sb.toString());
      case 0x28: // (
        return _literal();
      case 0x3C: // <
        if (pos + 1 < b.length && b[pos + 1] == 0x3C) {
          pos += 2;
          return const _Op('<<');
        }
        return _hex();
      case 0x3E: // >
        if (pos + 1 < b.length && b[pos + 1] == 0x3E) {
          pos += 2;
          return const _Op('>>');
        }
        pos++;
        return const _Op('>');
      case 0x5B || 0x5D || 0x7B || 0x7D || 0x29:
        pos++;
        return _Op(String.fromCharCode(c));
    }
    final start = pos;
    while (pos < b.length && _isRegular(b[pos])) {
      pos++;
    }
    final s = String.fromCharCodes(b, start, pos);
    if (_number.hasMatch(s)) return int.tryParse(s) ?? double.tryParse(s) ?? 0;
    return _Op(s);
  }

  Uint8List _literal() {
    pos++;
    final out = BytesBuilder(copy: false);
    var depth = 1;
    while (pos < b.length) {
      final c = b[pos++];
      if (c == 0x5C) {
        if (pos >= b.length) break;
        final e = b[pos++];
        switch (e) {
          case 0x6E:
            out.addByte(10);
          case 0x72:
            out.addByte(13);
          case 0x74:
            out.addByte(9);
          case 0x62:
            out.addByte(8);
          case 0x66:
            out.addByte(12);
          case 0x0D:
            if (pos < b.length && b[pos] == 0x0A) pos++;
          case 0x0A:
            break;
          default:
            if (e >= 0x30 && e <= 0x37) {
              var v = e - 0x30;
              for (var k = 0; k < 2 && pos < b.length && b[pos] >= 0x30 && b[pos] <= 0x37; k++) {
                v = v * 8 + b[pos++] - 0x30;
              }
              out.addByte(v & 0xFF);
            } else {
              out.addByte(e);
            }
        }
      } else if (c == 0x28) {
        depth++;
        out.addByte(c);
      } else if (c == 0x29) {
        if (--depth == 0) break;
        out.addByte(c);
      } else if (c == 0x0D) {
        out.addByte(10);
        if (pos < b.length && b[pos] == 0x0A) pos++;
      } else {
        out.addByte(c);
      }
    }
    return out.takeBytes();
  }

  Uint8List _hex() {
    pos++;
    final out = BytesBuilder(copy: false);
    int? hi;
    while (pos < b.length) {
      final c = b[pos++];
      if (c == 0x3E) break;
      final v = _hexVal(c);
      if (v < 0) continue;
      if (hi == null) {
        hi = v;
      } else {
        out.addByte(hi * 16 + v);
        hi = null;
      }
    }
    if (hi != null) out.addByte(hi * 16);
    return out.takeBytes();
  }

  /// A full value starting with [t] (arrays and dictionaries recursively; `N G R` → [_Ref] when [refs]).
  Object? value(Object t, [int depth = 0]) {
    if (depth > 64) throw const _Bad();
    if (t is _Op) {
      switch (t.v) {
        case '[':
          final list = <Object?>[];
          while (true) {
            final n = token();
            if (n == _eof || (n is _Op && n.v == ']')) break;
            list.add(value(n, depth + 1));
          }
          return list;
        case '<<':
          final map = <String, Object?>{};
          while (true) {
            final k = token();
            if (k == _eof || (k is _Op && k.v == '>>')) break;
            if (k is! _Name) continue;
            final v = token();
            if (v is _Op && v.v == '>>') break;
            map[k.v] = value(v, depth + 1);
          }
          return map;
        case 'true':
          return true;
        case 'false':
          return false;
        case 'null':
          return null;
      }
      return t;
    }
    if (refs && t is int) {
      final save = pos;
      final g = token();
      if (g is int) {
        final r = token();
        if (r is _Op && r.v == 'R') return _Ref(t);
      }
      pos = save;
    }
    return t;
  }
}

int _hexVal(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}

String? _nameOf(Object? v) => v is _Name ? v.v : null;

class _Out {
  final sb = StringBuffer();
  int last = 10; // last char written; 10 = at a line start
  double? textY;

  void page() {
    newline();
    textY = null;
  }

  void newline() {
    if (sb.isNotEmpty && last != 10) _put(10);
  }

  void space() {
    if (sb.isNotEmpty && last != 10 && last != 32) _put(32);
  }

  void write(String s) {
    for (final c in s.runes) {
      if (c == 9 || c == 0xA0) {
        space();
      } else if (c == 10 || c == 13) {
        newline();
      } else if (c >= 0x20 && c != 0xFEFF && (c < 0x7F || c >= 0xA0)) {
        _put(c);
      }
    }
  }

  void _put(int c) {
    if (sb.length >= _maxChars) throw const _OutOfBudget();
    sb.writeCharCode(c);
    last = c;
  }

  String? result() {
    final lines = sb.toString().split('\n').map((l) => l.trimRight()).toList();
    final text = lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    return text.isEmpty ? null : text;
  }
}

class _CappedOutput extends OutputMemoryStream {
  final int cap;
  _CappedOutput(this.cap);
  void _check(int n) {
    if (length + n > cap) throw const _Bad();
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}

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

  void _run(Uint8List data, Map<String, Object?>? res, _Out out, int depth, Set<Object> forms) {
    final lx = _Lexer(data, 0, this, refs: false);
    final ops = <Object?>[];
    _Font? font;
    var leading = 0.0, y = 0.0;
    var moved = false;
    double arg(int back) {
      final i = ops.length - back;
      final v = i >= 0 ? ops[i] : null;
      return v is num ? v.toDouble() : 0;
    }

    void show(Object? s) {
      final f = font;
      if (s is! Uint8List || f == null) return;
      final text = f.decode(s, this);
      if (text.isEmpty) return;
      final ty = out.textY;
      if (ty != null && (y - ty).abs() > 1) {
        out.newline();
      } else if (moved) {
        out.space();
      }
      out.write(text);
      out.textY = y;
      moved = false;
    }

    void nextLine() {
      out.newline();
      y -= leading;
      out.textY = y;
      moved = false;
    }

    while (true) {
      final t = lx.token();
      if (t == _eof) break;
      if (t is! _Op) {
        ops.add(t);
        if (ops.length > 64) ops.removeAt(0);
        continue;
      }
      switch (t.v) {
        case '[' || '<<' || 'true' || 'false' || 'null':
          ops.add(lx.value(t));
          continue;
        case 'BI':
          _skipInlineImage(lx);
        case 'BT':
          y = 0;
          moved = true;
        case 'Tf':
          font = _font(res, ops.length >= 2 ? ops[ops.length - 2] : null);
        case 'TL':
          leading = arg(1);
        case 'Td':
          y += arg(1);
          moved = true;
        case 'TD':
          leading = -arg(1);
          y += arg(1);
          moved = true;
        case 'Tm':
          y = arg(1);
          moved = true;
        case 'T*':
          nextLine();
        case 'Tj':
          show(ops.isEmpty ? null : ops.last);
        case "'":
          nextLine();
          show(ops.isEmpty ? null : ops.last);
        case '"':
          nextLine();
          show(ops.isEmpty ? null : ops.last);
        case 'TJ':
          final arr = ops.isEmpty ? null : ops.last;
          if (arr is List) {
            for (final e in arr) {
              if (e is Uint8List) {
                show(e);
              } else if (e is num && e < -200) {
                out.space();
              }
            }
          }
        case 'Do':
          final name = _nameOf(ops.isEmpty ? null : ops.last);
          final xo = dict(res?['XObject']);
          final ref = xo?[name];
          final form = resolve(ref);
          if (depth < 8 && form is _Stream && _nameOf(form.dict['Subtype']) == 'Form' && forms.add(form)) {
            final fd = decode(form);
            if (fd != null) _run(fd, dict(form.dict['Resources']) ?? res, out, depth + 1, forms);
          }
      }
      ops.clear();
    }
  }

  void _skipInlineImage(_Lexer lx) {
    // dictionary up to ID, then binary data up to a whitespace-delimited EI
    while (true) {
      final t = lx.token();
      if (t == _eof) return;
      if (t is _Op && t.v == 'ID') break;
    }
    final d = lx.b;
    for (var i = lx.pos + 1; i + 1 < d.length; i++) {
      if (d[i] == 0x45 && d[i + 1] == 0x49 && _isWs(d[i - 1]) && (i + 2 >= d.length || _isWs(d[i + 2]))) {
        lx.pos = i + 2;
        return;
      }
    }
    lx.pos = d.length;
  }
}

Uint8List _asciiHex(Uint8List d) {
  final out = BytesBuilder(copy: false);
  int? hi;
  for (final c in d) {
    if (c == 0x3E) break;
    final v = _hexVal(c);
    if (v < 0) continue;
    if (hi == null) {
      hi = v;
    } else {
      out.addByte(hi * 16 + v);
      hi = null;
    }
  }
  if (hi != null) out.addByte(hi * 16);
  return out.takeBytes();
}

Uint8List _ascii85(Uint8List d) {
  final out = BytesBuilder(copy: false);
  final group = <int>[];
  var i = 0;
  if (d.length >= 2 && d[0] == 0x3C && d[1] == 0x7E) i = 2;
  void flush(int n) {
    var v = 0;
    for (var k = 0; k < 5; k++) {
      v = v * 85 + (k < group.length ? group[k] : 84);
    }
    for (var k = 0; k < n - 1; k++) {
      out.addByte((v >> (24 - 8 * k)) & 0xFF);
    }
    group.clear();
  }

  for (; i < d.length; i++) {
    final c = d[i];
    if (c == 0x7E) break;
    if (_isWs(c)) continue;
    if (c == 0x7A && group.isEmpty) {
      out.add(const [0, 0, 0, 0]);
      continue;
    }
    if (c < 0x21 || c > 0x75) continue;
    group.add(c - 0x21);
    if (group.length == 5) flush(5);
  }
  if (group.isNotEmpty) flush(group.length);
  return out.takeBytes();
}

/// A ToUnicode CMap: codespace ranges, single codes and ranges of codes mapped to Unicode text.
class _CMap {
  final space = <(int, int, int)>[]; // (bytes, lo, hi)
  final chars = <int, String>{}; // code * 8 + bytes → text
  final ranges = <(int, int, int, List<int>?, List<String>?)>[]; // (bytes, lo, hi, first UTF-16 units, or one text per code)

  static _CMap parse(Uint8List data, _Pdf pdf) {
    final m = _CMap();
    final lx = _Lexer(data, 0, pdf, refs: false);
    final ops = <Object?>[];
    while (true) {
      final t = lx.token();
      if (t == _eof) break;
      if (t is _Op) {
        switch (t.v) {
          case '[':
            ops.add(lx.value(t));
            continue;
          case 'endcodespacerange':
            for (var i = 0; i + 1 < ops.length; i += 2) {
              final lo = ops[i], hi = ops[i + 1];
              if (lo is Uint8List && hi is Uint8List && lo.isNotEmpty && lo.length <= 4 && lo.length == hi.length) {
                m.space.add((lo.length, _code(lo), _code(hi)));
              }
            }
          case 'endbfchar':
            for (var i = 0; i + 1 < ops.length; i += 2) {
              final src = ops[i], dst = ops[i + 1];
              if (src is Uint8List && src.isNotEmpty && src.length <= 4) {
                final text = dst is Uint8List ? _utf16(dst) : _glyphText(_nameOf(dst));
                if (text != null) m.chars[_code(src) * 8 + src.length] = text;
              }
            }
          case 'endbfrange':
            for (var i = 0; i + 2 < ops.length; i += 3) {
              final lo = ops[i], hi = ops[i + 1], dst = ops[i + 2];
              if (lo is! Uint8List || hi is! Uint8List || lo.isEmpty || lo.length > 4 || lo.length != hi.length) continue;
              final l = _code(lo), h = _code(hi);
              if (h < l) continue;
              if (dst is Uint8List && dst.length >= 2) {
                m.ranges.add((lo.length, l, h, _units(dst), null));
              } else if (dst is List) {
                m.ranges.add((lo.length, l, h, null, [for (final e in dst) e is Uint8List ? _utf16(e) : '']));
              }
            }
        }
        ops.clear();
      } else {
        ops.add(t);
        if (ops.length > 3000) ops.removeRange(0, 1500);
      }
    }
    return m;
  }

  /// Bytes of the code at [i] by the codespace ranges, else by the lengths the mappings use; `null` = unknown.
  int? length(Uint8List s, int i) {
    for (final (n, lo, hi) in space) {
      if (i + n > s.length) continue;
      final c = _code(Uint8List.sublistView(s, i, i + n));
      if (c >= lo && c <= hi) return n;
    }
    if (space.isEmpty) {
      if (chars.isNotEmpty) return chars.keys.first % 8;
      if (ranges.isNotEmpty) return ranges.first.$1;
    }
    return null;
  }

  String? lookup(int bytes, int code) {
    final c = chars[code * 8 + bytes];
    if (c != null) return c;
    for (final (n, lo, hi, units, list) in ranges) {
      if (n != bytes || code < lo || code > hi) continue;
      if (list != null) return code - lo < list.length ? list[code - lo] : null;
      final u = [...units!];
      u[u.length - 1] += code - lo;
      return String.fromCharCodes(u);
    }
    return null;
  }
}

int _code(Uint8List b) {
  var v = 0;
  for (final x in b) {
    v = v * 256 + x;
  }
  return v;
}

List<int> _units(Uint8List b) => [for (var i = 0; i + 1 < b.length; i += 2) b[i] << 8 | b[i + 1]];

String _utf16(Uint8List b) => String.fromCharCodes(_units(b));

class _Font {
  final bool twoByte;
  final _CMap? cmap;
  final List<String> enc;
  _Font(this.twoByte, this.cmap, this.enc);

  static _Font from(_Pdf pdf, Map<String, Object?> d) {
    final type0 = _nameOf(d['Subtype']) == 'Type0';
    _CMap? cmap;
    final tu = pdf.resolve(d['ToUnicode']);
    if (tu is _Stream) {
      final data = pdf.decode(tu);
      if (data != null) cmap = _CMap.parse(data, pdf);
    }
    final enc = [..._winAnsi];
    final e = pdf.dict(d['Encoding']);
    final diffs = e == null ? null : pdf.resolve(e['Differences']);
    if (!type0 && diffs is List) {
      var code = 0;
      for (final x in diffs) {
        if (x is int) {
          code = x;
        } else if (x is _Name) {
          if (code >= 0 && code < 256) enc[code] = _glyphText(x.v) ?? enc[code];
          code++;
        }
      }
    }
    return _Font(type0, cmap, enc);
  }

  String decode(Uint8List s, _Pdf pdf) {
    pdf.tick(s.length);
    final m = cmap;
    if (m == null) {
      if (twoByte) return ''; // Identity-H without ToUnicode: glyph ids only
      return s.map((c) => enc[c]).join();
    }
    final sb = StringBuffer();
    var i = 0;
    while (i < s.length) {
      var n = m.length(s, i) ?? (twoByte ? 2 : 1);
      if (i + n > s.length) n = s.length - i;
      final code = _code(Uint8List.sublistView(s, i, i + n));
      final t = m.lookup(n, code);
      if (t != null) {
        sb.write(t);
      } else if (!twoByte && n == 1) {
        sb.write(enc[code]);
      }
      i += n;
    }
    return sb.toString();
  }
}

/// WinAnsiEncoding (cp1252) as text per byte; control bytes are empty.
final List<String> _winAnsi = () {
  const high = '€\u0000‚ƒ„…†‡ˆ‰Š‹Œ\u0000Ž\u0000\u0000‘’“”•–—˜™š›œ\u0000žŸ';
  return List<String>.generate(256, (c) {
    if (c < 0x20 || c == 0x7F) return c == 9 || c == 10 || c == 13 ? ' ' : '';
    if (c < 0x80) return String.fromCharCode(c);
    if (c < 0xA0) {
      final s = high[c - 0x80];
      return s == '\u0000' ? '' : s;
    }
    if (c == 0xA0) return ' ';
    if (c == 0xAD) return '-';
    return String.fromCharCode(c);
  });
}();

const _glyphs = {
  'space': ' ', 'exclam': '!', 'quotedbl': '"', 'numbersign': '#', 'dollar': r'$', 'percent': '%', 'ampersand': '&', //
  'quotesingle': "'", 'quoteright': '’', 'quoteleft': '‘', 'parenleft': '(', 'parenright': ')', 'asterisk': '*',
  'plus': '+', 'comma': ',', 'hyphen': '-', 'minus': '-', 'period': '.', 'slash': '/', 'zero': '0', 'one': '1',
  'two': '2', 'three': '3', 'four': '4', 'five': '5', 'six': '6', 'seven': '7', 'eight': '8', 'nine': '9',
  'colon': ':', 'semicolon': ';', 'less': '<', 'equal': '=', 'greater': '>', 'question': '?', 'at': '@',
  'bracketleft': '[', 'backslash': r'\', 'bracketright': ']', 'asciicircum': '^', 'underscore': '_', 'grave': '`',
  'braceleft': '{', 'bar': '|', 'braceright': '}', 'asciitilde': '~', 'endash': '–', 'emdash': '—', 'bullet': '•',
  'ellipsis': '…', 'quotedblleft': '“', 'quotedblright': '”', 'quotedblbase': '„', 'quotesinglbase': '‚',
  'Euro': '€', 'euro': '€', 'degree': '°', 'section': '§', 'copyright': '©', 'registered': '®', 'nbspace': ' ',
  'nonbreakingspace': ' ', 'Scaron': 'Š', 'scaron': 'š', 'Zcaron': 'Ž', 'zcaron': 'ž', 'Ccaron': 'Č', 'ccaron': 'č',
  'Cacute': 'Ć', 'cacute': 'ć', 'Dcroat': 'Đ', 'dcroat': 'đ', 'Dslash': 'Đ', 'dmacron': 'đ', 'multiply': '×',
};

String? _glyphText(String? name) {
  if (name == null) return null;
  final base = name.split('.').first;
  if (base.length == 1 && RegExp('[A-Za-z]').hasMatch(base)) return base;
  final g = _glyphs[base];
  if (g != null) return g;
  final m = RegExp(r'^(?:uni([0-9A-Fa-f]{4})|u([0-9A-Fa-f]{4,6}))$').firstMatch(base);
  if (m != null) {
    final v = int.parse(m[1] ?? m[2]!, radix: 16);
    if (v <= 0x10FFFF && (v < 0xD800 || v > 0xDFFF)) return String.fromCharCode(v);
  }
  return null;
}
