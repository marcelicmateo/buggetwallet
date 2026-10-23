// Writes the old-build fixtures of one release from the CURRENT code (run it at each release, with the release's
// name, and commit the files; the tests in test/h12_old_builds_test.dart open every set in this folder):
//
//   tools/build.sh shell -c 'cd packages/wallet_core && dart run test/fixtures/old_builds/generate.dart schema7'
//
// Output (next to this script): <name>_plain.db (as builds before the encrypted local database wrote it),
// <name>_keyed.db (encrypted with the key below), <name>.bwb (a sealed backup), <name>.json (what the files hold).
// Everything is SYNTHETIC: made-up amounts, generic merchants, a fixed throwaway key that protects nothing real.
import 'dart:convert';
import 'dart:io';

import 'package:wallet_core/wallet_core.dart';

import '../../support/synthetic.dart';

/// The throwaway wallet key of the fixtures (bytes 1..32).
final fixtureKey = VaultKey(List<int>.generate(32, (i) => i + 1));

void populate(WalletRepo r) {
  r.importBatch(january);
  r.updateSettings({
    'salary': 150000,
    'paydayDay': 15,
    'categoryBudgets': {'Groceries': 30000, 'Eating out': 12000},
    'merchantPatterns': [
      ['Shopping', 'synth shop']
    ],
  });
  r.saveGoal(name: 'Synthetic fund', target: 100000, saved: 2500, monthly: 5000);
  r.addWish('Synthetic gadget', 12000);
  r.addTransaction(date: '2026-01-21', amount: -450, category: 'Eating out', note: 'synthetic');
  final (bill, _) = r.importBill(const NormalizedBill(
      source: BillSource.hub3,
      externalId: 'jir:fixture-1',
      date: '2026-02-01',
      dueDate: '2026-02-20',
      total: 4500,
      payee: 'Synth Utility'));
  r.updateBill(bill, category: 'Bills & one-offs');
  r.confirmBill(bill);
}

Future<void> main(List<String> args) async {
  final name = args.isEmpty ? 'schema7' : args.first;
  final dir = File.fromUri(Platform.script).parent.path;
  final dbKey = await localDbKey(fixtureKey);
  for (final (file, key) in [('${name}_plain.db', null), ('${name}_keyed.db', dbKey)]) {
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$dir/$file$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    final r = WalletRepo.open('$dir/$file', dbKey: key);
    populate(r);
    if (key == null) {
      // The backup and the expectations come from the plain database, so the same rows and clocks are in all files.
      File('$dir/$name.bwb').writeAsBytesSync(await backupBytes(r, fixtureKey));
      final expect = {
        'schema': WalletRepo.schemaVersion,
        'transactions': r.transactions(includeHidden: true).length,
        'bills': r.bills().length,
        'goals': r.db.select('SELECT COUNT(*) AS n FROM goals').first['n'],
        'ops': r.snapshotOps().length,
      };
      File('$dir/$name.json').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(expect)}\n');
      stdout.writeln('wrote ${name}_plain.db, ${name}_keyed.db, $name.bwb, $name.json: $expect');
    }
    r.close();
  }
}
