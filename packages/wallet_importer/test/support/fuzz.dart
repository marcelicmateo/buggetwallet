// Helpers for the importer's robustness tests. All data is SYNTHETIC.
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:wallet_importer/wallet_importer.dart';

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

/// Iterations for randomized tests: [base] by default, `BW_FUZZ_ITERATIONS` to run longer (or shorter).
int fuzzIterations(int base) => int.tryParse(Platform.environment['BW_FUZZ_ITERATIONS'] ?? '') ?? base;

/// Base seed: fixed by default so runs are reproducible; `BW_FUZZ_SEED` to explore.
int fuzzSeed(int base) => int.tryParse(Platform.environment['BW_FUZZ_SEED'] ?? '') ?? base;

/// Texts from the synthetic fixtures that must never reach a log line.
const privateTexts = [
  'LIDL',
  'Neto pla',
  'ATM TEST',
  'Revolut**',
  'HR0000',
  'Naplata',
  'POVRAT',
  'EXAMPLE SHOP',
  'Shop, with comma',
  'Pending Shop',
  'Top-up by',
  'Wolt',
  'Grašo',
  'GraÅ¡o',
];

final _id = RegExp(r'^\d{6}[0-9a-z]+(_\d+)?$');
final _date = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Problems with a batch the importer returned (empty = valid).
List<String> batchProblems(ImportBatch b) {
  final out = <String>[];
  if (b.source != 'pbz' && b.source != 'revolut') out.add('source ${b.source}');
  if (b.skipped < 0) out.add('skipped ${b.skipped}');
  final ids = <String>{};
  for (final t in b.transactions) {
    if (!_date.hasMatch(t.date)) out.add('date "${t.date}"');
    if (!_id.hasMatch(t.id)) out.add('id "${t.id}"');
    if (_date.hasMatch(t.date) && !t.id.startsWith(t.date.replaceAll('-', '').substring(2))) out.add('id prefix ${t.id} ${t.date}');
    if (!ids.add(t.id)) out.add('duplicate id ${t.id}');
    if (t.source != b.source) out.add('row source ${t.source}');
    if (t.currency.isEmpty) out.add('empty currency');
  }
  return out;
}

/// Outcome of one import: `null` when it returned a valid batch or threw [ImportException], else a description.
String? checkImport(Uint8List bytes, {int maxMs = 5000}) {
  final sw = Stopwatch()..start();
  try {
    final b = importBankFile(bytes);
    final p = batchProblems(b);
    if (sw.elapsedMilliseconds > maxMs) return 'slow: ${sw.elapsedMilliseconds} ms';
    return p.isEmpty ? null : 'invalid batch: ${p.take(3).join('; ')}';
  } on ImportException {
    if (sw.elapsedMilliseconds > maxMs) return 'slow: ${sw.elapsedMilliseconds} ms';
    return null;
  } catch (e) {
    return 'threw ${e.runtimeType}: ${e.toString().split('\n').first}';
  }
}

/// Starts collecting log lines (message + error text) in the current isolate. Returns the list and a stop function.
(List<String>, void Function()) captureLogs() {
  final lines = <String>[];
  final was = Logger.root.level;
  Logger.root.level = Level.ALL;
  final sub = Logger.root.onRecord.listen((r) {
    final e = r.error;
    // wallet_core's formatter drops FormatException.source, so only the message of a FormatException is ever written.
    final err = e == null ? '' : (e is FormatException ? e.message : e.toString());
    lines.add('${r.level.name} ${r.loggerName} ${r.message} $err');
  });
  return (
    lines,
    () {
      sub.cancel();
      Logger.root.level = was;
    }
  );
}

/// Private fixture texts found in [lines].
List<String> leaks(List<String> lines) {
  final text = lines.join('\n');
  return [
    for (final p in privateTexts)
      if (text.contains(p)) p
  ];
}
