// Writes the old-build fixtures of one release from the CURRENT code (run it at each release, with the release's
// name, and commit the files; the tests in test/h12_old_builds_test.dart open every set in this folder):
//
//   tools/build.sh shell -c 'cd packages/wallet_core && dart run test/fixtures/old_builds/generate.dart schema7'
//   tools/build.sh shell -c 'cd packages/wallet_core && dart run test/fixtures/old_builds/generate.dart schema7peer peer'
//
// Output (next to this script): <name>_plain.db (as builds before the encrypted local database wrote it),
// <name>_keyed.db (encrypted with the key below), <name>.bwb (a sealed backup), <name>.json (what the files hold).
// With the second argument `peer` only <name>_plain.db is written, holding two rows from another device (`budget:` and
// `pattern:` settings with a clock OLDER than the legacy maps) applied through applyRemote before saving, as a build that
// had synced with a newer one would hold them.
//
// Reproducible except for the ids of rows created by hand (random) and the sealed backup's nonce: the wall clock is fixed
// at 2026-01-02 00:00 UTC (before every simulated clock of the tests, so no clock-drift rule sees these files as ahead) and
// the device id is fixed. Everything is SYNTHETIC: made-up amounts, generic merchants, a throwaway key that protects nothing.
import 'dart:convert';
import 'dart:io';

import 'package:wallet_core/wallet_core.dart';

import '../../support/synthetic.dart';

/// The throwaway wallet key of the fixtures (bytes 1..32).
final fixtureKey = VaultKey(List<int>.generate(32, (i) => i + 1));

/// 2026-01-02 00:00:00 UTC, in milliseconds.
final fixtureNow = DateTime.utc(2026, 1, 2).millisecondsSinceEpoch;

/// The fixed device id of the fixture databases (16 hex).
const fixtureDevice = 'f1d07e5700000001';

/// The clock of the peer rows: 2026-01-01 00:00 UTC, older than the legacy map settings written at [fixtureNow].
const peerClock = '001767225600000:00000:feedfeedfeedfeed';

void populate(WalletRepo r, {bool peer = false}) {
  r.importBatch(january);
  r.updateSettings({'salary': 150000, 'paydayDay': 15});
  // Per-key settings since schema 8 (the schema 7 files were written with the legacy maps and are not regenerated).
  r.setCategoryBudget('Groceries', 30000);
  r.setCategoryBudget('Eating out', 12000);
  r.setMerchantPattern('Shopping', 'synth shop');
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
  if (peer) {
    final patternId = 'pattern:${sha256Hex(utf8.encode('synth shop')).substring(0, 16)}';
    r.applyRemote([
      const Op('setting', 'budget:Groceries', {'value': '45000'}, peerClock),
      Op(
          'setting',
          patternId,
          {
            'value': jsonEncode({'category': 'Groceries', 'pattern': 'synth shop', 'order': 0})
          },
          peerClock),
    ]);
  }
}

/// Opens (creating it) the database at [path] with the fixed device id and the fixed clock.
WalletRepo openFixed(String path, List<int>? key) {
  final first = WalletRepo.open(path, dbKey: key, now: () => fixtureNow);
  first.db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('device_id', ?)", [fixtureDevice]);
  first.close();
  return WalletRepo.open(path, dbKey: key, now: () => fixtureNow);
}

Future<void> main(List<String> args) async {
  final name = args.isEmpty ? 'schema7' : args.first;
  final peer = args.length > 1 && args[1] == 'peer';
  final dir = File.fromUri(Platform.script).parent.path;
  final dbKey = await localDbKey(fixtureKey);
  for (final (file, key) in [('${name}_plain.db', null), if (!peer) ('${name}_keyed.db', dbKey)]) {
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$dir/$file$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    final r = openFixed('$dir/$file', key);
    populate(r, peer: peer);
    if (key == null) {
      // The backup and the expectations come from the plain database, so the same rows and clocks are in all files.
      File('$dir/$name.bwb').writeAsBytesSync(await backupBytes(r, fixtureKey));
      final expect = {
        'schema': WalletRepo.schemaVersion,
        'transactions': r.transactions(includeHidden: true).length,
        'bills': r.bills().length,
        'goals': r.db.select('SELECT COUNT(*) AS n FROM goals').first['n'],
        'ops': r.snapshotOps().length,
        if (peer) 'peerRows': 2,
      };
      File('$dir/$name.json').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(expect)}\n');
      stdout.writeln('wrote $file${peer ? '' : ', ${name}_keyed.db'}, $name.bwb, $name.json: $expect');
    }
    r.close();
  }
}
