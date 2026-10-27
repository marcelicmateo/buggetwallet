part of '../pdf_text.dart';

// WinAnsi encoding and the glyph names /Differences may use.

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
