part of '../pdf_text.dart';

// Content streams: text operators into [_Out] (lines and spaces), Form XObjects, inline images skipped.

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

/// Runs page content streams on a [_Pdf].
extension _Content on _Pdf {
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
