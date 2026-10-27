part of '../pdf_text.dart';

// PDF syntax tokens and the lexer that reads them.

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

String? _nameOf(Object? v) => v is _Name ? v.v : null;
