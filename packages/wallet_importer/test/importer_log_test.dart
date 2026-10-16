// The importer's log lines: counts, formats and timings only, never cell contents. Fixtures are SYNTHETIC.
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:wallet_importer/wallet_importer.dart';

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

void main() {
  late List<String> lines;
  setUp(() {
    lines = [];
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen((r) => lines.add('${r.level.name} ${r.loggerName} ${r.message} ${r.error ?? ''}'));
    addTearDown(() async {
      await sub.cancel();
      Logger.root.level = Level.INFO;
    });
  });

  const private = ['LIDL', 'Neto pla', 'ATM TEST', 'Revolut**', 'HR0000', 'Naplata', 'POVRAT', 'EXAMPLE SHOP', '1500', '-550', '23.4'];

  for (final name in ['pbz_synthetic.xls', 'revolut_synthetic.xlsx', 'revolut_synthetic.csv']) {
    test('$name: format, sizes and counts are logged, no contents', () {
      final batch = importBankFile(fixture(name));
      final text = lines.join('\n');
      final ext = name.split('.').last;
      expect(text, contains('bw.importer importer.detect {"format":"$ext","bytes":'));
      expect(text, contains('importer.parse {"format":"$ext","source":"${batch.source}"'));
      expect(text, contains('"txs":${batch.transactions.length}'));
      for (final p in private) {
        expect(text, isNot(contains(p)), reason: p);
      }
    });
  }

  test('unknown and broken files log a warning', () {
    expect(() => importBankFile(Uint8List.fromList('a,b\n1,2\n'.codeUnits)), throwsA(isA<ImportException>()));
    expect(
        () => importBankFile(Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0])), throwsA(isA<ImportException>()));
    final text = lines.join('\n');
    expect(text, contains('WARNING bw.importer importer.unknown {"format":"csv","rows":2,"cols":2'));
    expect(text, contains('WARNING bw.importer importer.readFailed {"format":"xls","bytes":10}'));
  });
}
