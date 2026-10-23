import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'csv_reader.dart';
import 'limits.dart';
import 'log.dart';
import 'model.dart';
import 'profiles/profile.dart';
import 'profiles/registry.dart';
import 'xls_reader.dart';
import 'xlsx_reader.dart';

export 'profiles/cells.dart' show excelDate, fixMojibake, jsRound;

class ImportException implements Exception {
  final String message;
  const ImportException(this.message);
  @override
  String toString() => message;
}

final _log = Logger('bw.importer');

/// The message for a file no bank profile recognises. Bank names come only from the profiles' labels.
final unknownLayoutMessage = 'This is not a ${bankLabels()} export I recognise.';

/// Reads a bank export into normalized transactions: the container format (.xls, .xlsx, .csv) gives the rows, the
/// first bank profile in [bankProfiles] that recognises them maps them.
///
/// [fileName], when given, is only offered to the profiles' detection; it is never logged or stored.
/// Logs on `bw.importer`: the detected container format, sizes, row counts, the profile id (`source`) and timings.
/// Never cell contents.
///
/// Refused before reading: a file over [maxImportBytes] and an .xlsx unpacking to more than [maxXlsxUnpackedBytes]
/// ([tooLargeMessage]), a password-protected file ([passwordProtectedMessage]).
ImportBatch importBankFile(Uint8List bytes, {String? fileName}) {
  final sw = Stopwatch()..start();
  List<List<Object>> rows;
  if (bytes.length > maxImportBytes) {
    logImporter(_log, Level.WARNING, 'importer.refused', {'reason': 'tooLarge', 'bytes': bytes.length});
    throw const ImportException(tooLargeMessage);
  }
  final format = XlsReader.looksLikeXls(bytes) ? 'xls' : (XlsxReader.looksLikeZip(bytes) ? 'xlsx' : 'csv');
  logImporter(_log, Level.FINE, 'importer.detect', {'format': format, 'bytes': bytes.length});
  try {
    rows = switch (format) {
      'xls' => XlsReader.firstSheet(bytes),
      'xlsx' => XlsxReader.firstSheet(bytes),
      _ => readCsv(utf8.decode(bytes, allowMalformed: true), strict: true),
    };
  } on FileRefused catch (e) {
    logImporter(_log, Level.WARNING, 'importer.refused', {'format': format, 'reason': e.reason, 'bytes': bytes.length});
    throw ImportException(e.message);
  } on FormatException catch (e, st) {
    // Our readers' messages are fixed texts; the formatter drops FormatException.source.
    _log.warning(() => 'importer.readFailed ${jsonEncode({'format': format, 'bytes': bytes.length})}', e, st);
    throw const ImportException('Could not read this file. It may be damaged or not a bank export.');
  } catch (e, st) {
    // A damaged file can fail anywhere in the readers (RangeError on a truncated .xls, archive errors, …).
    _log.warning(() => 'importer.readFailed ${jsonEncode({'format': format, 'bytes': bytes.length})}', e, st);
    throw const ImportException('Could not read this file. It may be damaged.');
  }
  final readMs = sw.elapsedMilliseconds;
  final batch = parseRows(rows, format: format, fileName: fileName);
  if (batch == null) {
    logImporter(_log, Level.WARNING, 'importer.unknown',
        {'format': format, 'rows': rows.length, 'cols': rows.isEmpty ? 0 : rows.first.length, 'readMs': readMs});
    throw ImportException(unknownLayoutMessage);
  }
  logImporter(_log, Level.INFO, 'importer.parse', {
    'format': format,
    'source': batch.source,
    'rows': rows.length,
    'txs': batch.transactions.length,
    'skipped': batch.skipped,
    'invalid': batch.invalid,
    'readMs': readMs,
    'ms': sw.elapsedMilliseconds,
  });
  return batch;
}

/// Turns the rows of a sheet into a batch with the first profile in [bankProfiles] whose `detect` accepts them,
/// or `null` when none does.
ImportBatch? parseRows(List<List<Object>> rows, {String format = '', String? fileName}) {
  final ctx = ImportContext.of(rows, format: format, fileName: fileName);
  for (final profile in bankProfiles) {
    if (profile.detect(ctx)) return profile.parse(rows, ctx);
  }
  return null;
}
