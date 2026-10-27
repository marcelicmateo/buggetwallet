part of '../pdf_text.dart';

// Stream filters other than Flate (ASCIIHex, ASCII85) and the capped inflate output.

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
