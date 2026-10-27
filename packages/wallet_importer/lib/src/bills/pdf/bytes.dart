part of '../pdf_text.dart';

// Byte helpers shared by the PDF reader parts: keyword patterns, searching, character classes, hex digits and
// big-endian code / UTF-16 conversion.

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
  final end = (limit == null || limit > b.length ? b.length : limit) - pat.length; // never past the data (short files)
  final first = pat[0];
  if (end < from) return -1;
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

int _hexVal(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
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
