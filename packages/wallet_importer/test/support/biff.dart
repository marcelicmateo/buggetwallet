// Builders for tiny SYNTHETIC .xls (OLE2 + BIFF8) files, so tests can create the odd shapes the real fixture does not have.
import 'dart:convert';
import 'dart:typed_data';

List<int> u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> u32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
List<int> f64(double v) => (ByteData(8)..setFloat64(0, v, Endian.little)).buffer.asUint8List().toList();

/// One BIFF record: type, length, data.
List<int> rec(int type, List<int> data) => [...u16(type), ...u16(data.length), ...data];

List<int> bof() => rec(0x0809, [...u16(0x0600), ...u16(0x0005), ...List.filled(12, 0)]);
List<int> eof() => rec(0x000A, const []);
List<int> number(int row, int col, double v) => rec(0x0203, [...u16(row), ...u16(col), ...u16(0), ...f64(v)]);
List<int> labelSst(int row, int col, int idx) => rec(0x00FD, [...u16(row), ...u16(col), ...u16(0), ...u32(idx)]);

/// RK cell holding the integer [i] (or [i] / 100 when [div100]).
List<int> rk(int row, int col, int i, {bool div100 = false}) =>
    rec(0x027E, [...u16(row), ...u16(col), ...u16(0), ...u32(((i << 2) | 2 | (div100 ? 1 : 0)) & 0xFFFFFFFF)]);

/// MULRK: integers [vals] in consecutive columns starting at [col].
List<int> mulRk(int row, int col, List<int> vals) => rec(0x00BD, [
      ...u16(row),
      ...u16(col),
      for (final v in vals) ...[...u16(0), ...u32(((v << 2) | 2) & 0xFFFFFFFF)],
      ...u16(col + vals.length - 1),
    ]);

/// FORMULA cell with a cached numeric result, or a string-result marker when [value] is null.
List<int> formula(int row, int col, double? value) => rec(0x0006, [
      ...u16(row),
      ...u16(col),
      ...u16(0),
      ...(value == null ? [0, 0, 0, 0, 0, 0, 0xFF, 0xFF] : f64(value)),
      ...u16(0),
      ...u32(0),
      ...u16(0),
    ]);

/// LABEL cell (inline string, compressed Latin-1 or UTF-16).
List<int> label(int row, int col, String s, {bool wide = false}) {
  wide = wide || s.codeUnits.any((c) => c > 0xFF);
  return rec(0x0204, [
    ...u16(row),
    ...u16(col),
    ...u16(0),
    ...u16(s.length),
    wide ? 1 : 0,
    ...(wide ? [for (final c in s.codeUnits) ...u16(c)] : latin1.encode(s)),
  ]);
}

/// An SST string body: char count, option byte, characters. Option bit 0 = UTF-16, 3 = rich text runs, 2 = phonetic data.
List<int> sstString(String s, {bool wide = false, int runs = -1, List<int>? phonetic}) {
  wide = wide || s.codeUnits.any((c) => c > 0xFF);
  var flags = wide ? 1 : 0;
  if (runs >= 0) flags |= 8;
  if (phonetic != null) flags |= 4;
  return [
    ...u16(s.length),
    flags,
    if (runs >= 0) ...u16(runs),
    if (phonetic != null) ...u32(phonetic.length),
    ...(wide ? [for (final c in s.codeUnits) ...u16(c)] : latin1.encode(s)),
    if (runs >= 0) ...List.filled(4 * runs, 0x55),
    if (phonetic != null) ...phonetic,
  ];
}

/// SST header (total, unique) followed by [body], split into SST + CONTINUE records at the given byte offsets of [body].
List<int> sst(int unique, List<int> body, {List<int> splits = const []}) {
  final out = <int>[];
  var from = 0;
  var first = true;
  for (final at in [...splits, body.length]) {
    final part = body.sublist(from, at);
    out.addAll(first ? rec(0x00FC, [...u32(unique), ...u32(unique), ...part]) : rec(0x003C, part));
    first = false;
    from = at;
  }
  return out;
}

/// A workbook stream: globals (BOF, sheet directory, [sstRecords], EOF) then the given sheets (each a list of cell
/// records; BOF and EOF are added). [boundSheets] false leaves out the sheet directory.
List<int> workbook(List<List<int>> sheets, {List<int> sstRecords = const [], bool boundSheets = true}) {
  List<int> globals(List<int> offsets) => [
        ...bof(),
        if (boundSheets)
          for (var i = 0; i < sheets.length; i++) ...rec(0x0085, [...u32(offsets[i]), 0, 0, 2, 0, 0x53, 0x31 + i]),
        ...sstRecords,
        ...eof(),
      ];
  final g = globals(List.filled(sheets.length, 0));
  final offsets = <int>[];
  var p = g.length;
  for (final s in sheets) {
    offsets.add(p);
    p += bof().length + s.length + eof().length;
  }
  return [
    ...globals(offsets),
    for (final s in sheets) ...[...bof(), ...s, ...eof()],
  ];
}

/// Wraps a workbook stream into an OLE2 compound file (512-byte sectors, one FAT sector, no mini stream).
/// The stream is padded with zero bytes to 4096 so it lives in regular sectors. [streamName] is the directory name,
/// [declaredSize] overrides the size in the directory, [chainOverride] the FAT entry after the last stream sector.
Uint8List ole2(List<int> stream, {String streamName = 'Workbook', int? declaredSize, int? chainOverride}) {
  final data = [...stream, ...List.filled(stream.length < 4096 ? 4096 - stream.length : 0, 0)];
  final sectors = (data.length + 511) ~/ 512;
  if (sectors > 126) throw ArgumentError('too big for one FAT sector');
  final padded = [...data, ...List.filled(sectors * 512 - data.length, 0)];
  final header = Uint8List(512);
  final hb = ByteData.sublistView(header);
  header.setRange(0, 8, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]);
  hb.setUint16(0x18, 0x3E, Endian.little);
  hb.setUint16(0x1A, 3, Endian.little);
  hb.setUint16(0x1C, 0xFFFE, Endian.little);
  hb.setUint16(0x1E, 9, Endian.little);
  hb.setUint16(0x20, 6, Endian.little);
  hb.setUint32(0x2C, 1, Endian.little); // one FAT sector
  hb.setUint32(0x30, 1, Endian.little); // directory at sector 1
  hb.setUint32(0x38, 4096, Endian.little);
  hb.setUint32(0x3C, 0xFFFFFFFE, Endian.little);
  hb.setUint32(0x44, 0xFFFFFFFE, Endian.little);
  for (var i = 0; i < 109; i++) {
    hb.setUint32(0x4C + 4 * i, i == 0 ? 0 : 0xFFFFFFFF, Endian.little);
  }
  final fat = Uint8List(512)..fillRange(0, 512, 0xFF);
  final fb = ByteData.sublistView(fat);
  fb.setUint32(0, 0xFFFFFFFD, Endian.little); // the FAT sector itself
  fb.setUint32(4, 0xFFFFFFFE, Endian.little); // directory: one sector
  for (var i = 0; i < sectors; i++) {
    fb.setUint32(4 * (2 + i), i == sectors - 1 ? (chainOverride ?? 0xFFFFFFFE) : 2 + i + 1, Endian.little);
  }
  final dir = Uint8List(512);
  final db = ByteData.sublistView(dir);
  void entry(int idx, String name, int type, int start, int size) {
    final o = idx * 128;
    for (var i = 0; i < name.length; i++) {
      db.setUint16(o + 2 * i, name.codeUnitAt(i), Endian.little);
    }
    db.setUint16(o + 0x40, (name.length + 1) * 2, Endian.little);
    dir[o + 0x42] = type;
    db.setUint32(o + 0x74, start, Endian.little);
    db.setUint32(o + 0x78, size, Endian.little);
  }

  entry(0, 'Root Entry', 5, 0xFFFFFFFE, 0);
  entry(1, streamName, 2, 2, declaredSize ?? data.length);
  return Uint8List.fromList([...header, ...fat, ...dir, ...padded]);
}
