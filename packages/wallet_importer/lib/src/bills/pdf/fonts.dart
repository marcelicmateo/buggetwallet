part of '../pdf_text.dart';

// Fonts: ToUnicode CMap or simple-font encoding with /Differences.

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
