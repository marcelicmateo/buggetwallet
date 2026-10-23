import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'grid.dart';
import 'limits.dart';
import 'log.dart';

final _log = Logger('bw.importer.xls');

/// Minimal reader for legacy Excel 97-2003 (.xls, BIFF8) files.
///
/// Reads the first worksheet's cell values: strings (shared and inline),
/// numbers (NUMBER, RK, MULRK) and cached numeric formula results.
/// Formatting, dates styles and other sheets are ignored.
class XlsReader {
  static const _magic = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

  static bool looksLikeXls(Uint8List b) {
    if (b.length < 8) return false;
    for (var i = 0; i < 8; i++) {
      if (b[i] != _magic[i]) return false;
    }
    return true;
  }

  /// Rows of the first sheet. Empty cells are `''`, numbers are `double`. A password-protected file throws
  /// [FileRefused] ([passwordProtectedMessage]): an .xls whose workbook globals hold a FILEPASS record, or an Office
  /// file encrypted as a whole (an `EncryptedPackage` stream, which is how a protected .xlsx is stored).
  static List<List<Object>> firstSheet(Uint8List bytes) {
    final cf = _CompoundFile(bytes);
    if (cf.entries.any((e) => e.type == 2 && e.name == 'EncryptedPackage')) {
      throw const FileRefused(passwordProtectedMessage, 'encryptedPackage');
    }
    final wb = cf.stream(const ['Workbook', 'Book']);
    logImporter(_log, Level.FINE, 'xls.container',
        {'bytes': bytes.length, 'sector': cf.sectorSize, 'entries': cf.entries.length, 'workbookBytes': wb.length});
    return _Biff(wb).firstSheet();
  }
}

const _endOfChain = 0xFFFFFFFA; // values >= this mark free / end-of-chain sectors

class _CompoundFile {
  final Uint8List data;
  final ByteData bd;
  late final int sectorSize;
  late final int miniSectorSize;
  late final int miniCutoff;
  late final List<int> fat;
  late final List<_DirEntry> entries;
  late final int miniFatStart;

  _CompoundFile(this.data) : bd = ByteData.sublistView(data) {
    if (!XlsReader.looksLikeXls(data)) {
      throw const FormatException('Not an OLE2 compound file');
    }
    sectorSize = 1 << bd.getUint16(0x1E, Endian.little);
    miniSectorSize = 1 << bd.getUint16(0x20, Endian.little);
    final numFat = bd.getUint32(0x2C, Endian.little);
    final dirStart = bd.getUint32(0x30, Endian.little);
    miniCutoff = bd.getUint32(0x38, Endian.little);
    miniFatStart = bd.getUint32(0x3C, Endian.little);
    var difatSector = bd.getUint32(0x44, Endian.little);
    final numDifat = bd.getUint32(0x48, Endian.little);

    final difat = <int>[];
    for (var i = 0; i < 109; i++) {
      difat.add(bd.getUint32(0x4C + i * 4, Endian.little));
    }
    final perSector = sectorSize ~/ 4;
    for (var k = 0; k < numDifat && difatSector < _endOfChain; k++) {
      final off = _offset(difatSector);
      for (var i = 0; i < perSector - 1; i++) {
        difat.add(bd.getUint32(off + i * 4, Endian.little));
      }
      difatSector = bd.getUint32(off + (perSector - 1) * 4, Endian.little);
    }
    fat = <int>[];
    for (final s in difat.take(numFat)) {
      if (s >= _endOfChain) continue;
      final off = _offset(s);
      for (var i = 0; i < perSector; i++) {
        fat.add(bd.getUint32(off + i * 4, Endian.little));
      }
    }
    final dir = _readChain(dirStart);
    final dbd = ByteData.sublistView(dir);
    entries = [];
    for (var i = 0; i + 128 <= dir.length; i += 128) {
      final nameLen = dbd.getUint16(i + 0x40, Endian.little);
      final units = <int>[];
      for (var j = 0; j + 2 <= nameLen - 2 && j < 64; j += 2) {
        units.add(dbd.getUint16(i + j, Endian.little));
      }
      entries.add(_DirEntry(
        String.fromCharCodes(units),
        dir[i + 0x42],
        dbd.getUint32(i + 0x74, Endian.little),
        dbd.getUint32(i + 0x78, Endian.little),
      ));
    }
  }

  int _offset(int sector) => (sector + 1) * sectorSize;

  Uint8List _readChain(int start) {
    final out = BytesBuilder(copy: false);
    var s = start;
    var guard = 0;
    while (s < _endOfChain && guard <= fat.length) {
      final off = _offset(s);
      if (off + sectorSize > data.length) break;
      out.add(Uint8List.sublistView(data, off, off + sectorSize));
      s = s < fat.length ? fat[s] : _endOfChain;
      guard++;
    }
    return out.takeBytes();
  }

  Uint8List stream(List<String> names) {
    if (entries.isEmpty) throw const FormatException('Empty directory');
    final root = entries.first;
    for (final e in entries) {
      if (e.type != 2 || !names.contains(e.name)) continue;
      if (e.size >= miniCutoff) {
        final all = _readChain(e.start);
        return Uint8List.sublistView(all, 0, e.size.clamp(0, all.length));
      }
      final mini = _readChain(root.start);
      final miniFatBytes = _readChain(miniFatStart);
      final mbd = ByteData.sublistView(miniFatBytes);
      final miniFat = [for (var i = 0; i + 4 <= miniFatBytes.length; i += 4) mbd.getUint32(i, Endian.little)];
      final out = BytesBuilder(copy: false);
      var s = e.start;
      var guard = 0;
      while (s < _endOfChain && guard <= miniFat.length) {
        final off = s * miniSectorSize;
        if (off + miniSectorSize > mini.length) break;
        out.add(Uint8List.sublistView(mini, off, off + miniSectorSize));
        s = s < miniFat.length ? miniFat[s] : _endOfChain;
        guard++;
      }
      final all = out.takeBytes();
      return Uint8List.sublistView(all, 0, e.size.clamp(0, all.length));
    }
    throw const FormatException('No Workbook stream found');
  }
}

class _DirEntry {
  final String name;
  final int type;
  final int start;
  final int size;
  _DirEntry(this.name, this.type, this.start, this.size);
}

class _Record {
  final int offset;
  final int type;
  final Uint8List data;
  _Record(this.offset, this.type, this.data);
}

class _Biff {
  final Uint8List wb;
  _Biff(this.wb);

  static const _bof = 0x0809, _eof = 0x000A, _boundSheet = 0x0085, _sst = 0x00FC, _continue = 0x003C;
  static const _labelSst = 0x00FD, _number = 0x0203, _rk = 0x027E, _mulRk = 0x00BD, _label = 0x0204, _formula = 0x0006;

  /// FILEPASS: the workbook is encrypted from here on (record headers stay readable, their data does not).
  static const _filepass = 0x002F;

  List<_Record> _records() {
    final bd = ByteData.sublistView(wb);
    final out = <_Record>[];
    var p = 0;
    while (p + 4 <= wb.length) {
      final t = bd.getUint16(p, Endian.little);
      final l = bd.getUint16(p + 2, Endian.little);
      final end = (p + 4 + l).clamp(0, wb.length);
      out.add(_Record(p, t, Uint8List.sublistView(wb, p + 4, end)));
      p += 4 + l;
    }
    return out;
  }

  static double _rkValue(int v) {
    double x;
    if (v & 2 != 0) {
      var i = v >> 2;
      if (i & (1 << 29) != 0) i -= 1 << 30;
      x = i.toDouble();
    } else {
      final b = ByteData(8)..setUint32(4, v & 0xFFFFFFFC, Endian.little);
      x = b.getFloat64(0, Endian.little);
    }
    return v & 1 != 0 ? x / 100 : x;
  }

  List<String> _sstStrings(List<Uint8List> parts) {
    final strings = <String>[];
    if (parts.isEmpty || parts.first.length < 8) return strings;
    final unique = ByteData.sublistView(parts.first).getUint32(4, Endian.little);
    var ri = 0;
    var buf = parts[0];
    var pos = 8;
    bool nextPart() {
      ri++;
      if (ri >= parts.length) return false;
      buf = parts[ri];
      pos = 0;
      return true;
    }

    int u8() => buf[pos++];
    int u16() {
      final v = buf[pos] | (buf[pos + 1] << 8);
      pos += 2;
      return v;
    }

    int u32() {
      final v = buf[pos] | (buf[pos + 1] << 8) | (buf[pos + 2] << 16) | (buf[pos + 3] << 24);
      pos += 4;
      return v;
    }

    while (strings.length < unique) {
      if (pos >= buf.length && !nextPart()) break;
      final cch = u16();
      final flags = u8();
      var wide = flags & 1 != 0;
      final rich = flags & 8 != 0;
      final ext = flags & 4 != 0;
      final runs = rich ? u16() : 0;
      final extLen = ext ? u32() : 0;
      final sb = StringBuffer();
      var left = cch;
      while (left > 0) {
        if (pos >= buf.length) {
          if (!nextPart()) break;
          wide = u8() & 1 != 0; // a CONTINUE inside character data restarts with an option byte
        }
        final avail = (buf.length - pos) ~/ (wide ? 2 : 1);
        final take = left < avail ? left : avail;
        if (wide) {
          final units = <int>[];
          for (var k = 0; k < take; k++) {
            units.add(buf[pos] | (buf[pos + 1] << 8));
            pos += 2;
          }
          sb.write(String.fromCharCodes(units));
        } else {
          sb.write(latin1.decode(Uint8List.sublistView(buf, pos, pos + take)));
          pos += take;
        }
        left -= take;
        if (take == 0) pos = buf.length; // a lone byte that can't hold a UTF-16 unit
      }
      var skip = 4 * runs + extLen;
      while (skip > 0) {
        if (pos >= buf.length && !nextPart()) break;
        final k = (buf.length - pos) < skip ? (buf.length - pos) : skip;
        pos += k;
        skip -= k;
      }
      strings.add(sb.toString());
    }
    return strings;
  }

  List<List<Object>> firstSheet() {
    final recs = _records();
    for (final r in recs) {
      if (r.type == _eof) break; // the end of the workbook globals
      if (r.type == _filepass) throw const FileRefused(passwordProtectedMessage, 'filepass');
    }

    var sst = <String>[];
    int? sheetOffset;
    for (var i = 0; i < recs.length; i++) {
      final r = recs[i];
      if (r.type == _boundSheet && sheetOffset == null && r.data.length >= 4) {
        sheetOffset = ByteData.sublistView(r.data).getUint32(0, Endian.little);
      } else if (r.type == _sst) {
        final parts = [r.data];
        var j = i + 1;
        while (j < recs.length && recs[j].type == _continue) {
          parts.add(recs[j].data);
          j++;
        }
        sst = _sstStrings(parts);
      }
    }
    if (sheetOffset == null) {
      // No sheet directory: fall back to the second BOF in the stream.
      final bofs = recs.where((r) => r.type == _bof).toList();
      sheetOffset = bofs.length > 1 ? bofs[1].offset : 0;
    }
    final cells = <int, Map<int, Object>>{};
    var maxCol = -1;
    void put(int r, int c, Object v) {
      (cells[r] ??= {})[c] = v;
      if (c > maxCol) maxCol = c;
    }

    var started = false;
    for (final rec in recs) {
      if (rec.offset < sheetOffset) continue;
      if (rec.type == _eof && started) break;
      started = true;
      final d = rec.data;
      if (d.length < 6) continue;
      final bd = ByteData.sublistView(d);
      final row = bd.getUint16(0, Endian.little);
      final col = bd.getUint16(2, Endian.little);
      switch (rec.type) {
        case _labelSst:
          if (d.length >= 10) {
            final i = bd.getUint32(6, Endian.little);
            put(row, col, i < sst.length ? sst[i] : '');
          }
        case _number:
          if (d.length >= 14) put(row, col, bd.getFloat64(6, Endian.little));
        case _rk:
          if (d.length >= 10) put(row, col, _rkValue(bd.getUint32(6, Endian.little)));
        case _mulRk:
          final n = (d.length - 6) ~/ 6;
          for (var k = 0; k < n; k++) {
            put(row, col + k, _rkValue(bd.getUint32(4 + 6 * k + 2, Endian.little)));
          }
        case _label:
          if (d.length >= 9) {
            final cch = bd.getUint16(6, Endian.little);
            final wide = d[8] & 1 != 0;
            if (wide) {
              final units = [for (var k = 0; k < cch && 9 + 2 * k + 1 < d.length; k++) bd.getUint16(9 + 2 * k, Endian.little)];
              put(row, col, String.fromCharCodes(units));
            } else {
              final end = (9 + cch).clamp(9, d.length);
              put(row, col, latin1.decode(Uint8List.sublistView(d, 9, end)));
            }
          }
        case _formula:
          if (d.length >= 14 && !(d[12] == 0xFF && d[13] == 0xFF)) {
            put(row, col, bd.getFloat64(6, Endian.little));
          }
      }
    }
    // Counts only: cell contents are bank data.
    logImporter(_log, Level.FINE, 'xls.sheet',
        {'records': recs.length, 'strings': sst.length, 'rows': cells.length, 'cols': maxCol + 1, 'sheetDir': started});
    return sparseRows(cells);
  }
}
