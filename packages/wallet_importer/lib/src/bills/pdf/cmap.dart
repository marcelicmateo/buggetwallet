part of '../pdf_text.dart';

// ToUnicode CMaps.

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
