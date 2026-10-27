// Small multi-device harness for the relay sync engine specs. Public API only (SyncEngine, MemoryTransport, WalletRepo).
// All data is SYNTHETIC.
import 'dart:convert';
import 'dart:math';

import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'synthetic.dart';

/// One shared fake clock for repos, engines and the transport, so "7 days later" is just [advance].
class SimClock {
  DateTime t = DateTime.utc(2026, 1, 10, 9);
  int get ms => t.millisecondsSinceEpoch;
  void advance(Duration d) => t = t.add(d);
}

class Dev {
  final WalletRepo repo;
  final SyncEngine engine;
  Dev(this.repo, this.engine);

  String get id => repo.deviceId;
  String get short => SyncProblem.shortId(id);
  Future<SyncReport> sync() => engine.run(repo);
  void close() => repo.close();
}

class Sim {
  final SimClock clock = SimClock();
  final VaultKey key;
  late final MemoryTransport transport;
  final List<Dev> all = [];

  Sim([VaultKey? key]) : key = key ?? VaultKey.generate() {
    transport = MemoryTransport(now: () => clock.t);
  }

  Dev device({VaultKey? otherKey}) {
    final repo = WalletRepo.inMemory(now: () => clock.ms);
    final d = Dev(repo, SyncEngine(transport, otherKey ?? key, appVersion: '1.0.0', now: () => clock.t));
    all.add(d);
    return d;
  }

  /// Time passes (distinct HLC times for consecutive edits).
  void tick([Duration d = const Duration(minutes: 1)]) => clock.advance(d);

  Future<void> syncAll(List<Dev> ds, {int rounds = 3}) async {
    for (var i = 0; i < rounds; i++) {
      for (final d in ds) {
        await d.sync();
        tick(const Duration(seconds: 1));
      }
    }
  }

  void closeAll() {
    for (final d in all) {
      d.close();
    }
  }
}

/// Every stored field as `entity|id|field|value`, sorted. [clocks] adds each op's clock.
List<String> canon(WalletRepo r, {bool clocks = false}) {
  final out = <String>[];
  for (final op in r.snapshotOps()) {
    for (final f in op.fields.entries) {
      out.add('${op.entity}|${op.id}|${f.key}|${jsonEncode(f.value)}${clocks ? '|${op.hlc}' : ''}');
    }
  }
  return out..sort();
}

/// What the wallet counts as spending/income: the sum of live rows (matched cash entries are hidden).
int counted(WalletRepo r) => r.transactions().fold(0, (s, t) => s + t.amount);

ImportBatch batch(List<(String, int, String)> rows) =>
    ImportBatch(source: 'pbz', transactions: [for (final (d, c, desc) in rows) n(d, c, 'POS plaćanje', desc)]);

/// The (single) non-manual row dated [date] with [amount] cents.
Tx bankRow(WalletRepo r, String date, int amount) =>
    r.transactions(includeHidden: true).singleWhere((t) => !t.manual && t.date == date && t.amount == amount);

/// A random action on [d]: import, hand entry, category edit or delete.
void randomAction(Random rnd, Dev d) {
  final amounts = [-1200, -2340, -500, -9900];
  final dates = ['2026-01-12', '2026-01-13', '2026-01-14', '2026-01-15'];
  switch (rnd.nextInt(4)) {
    case 0:
      d.repo.importBatch(batch([(dates[rnd.nextInt(4)], amounts[rnd.nextInt(4)], 'POS TESTSHOP ${rnd.nextInt(6)}')]));
    case 1:
      d.repo.addTransaction(date: dates[rnd.nextInt(4)], amount: amounts[rnd.nextInt(4)], category: 'Eating out');
    case 2:
      final txs = d.repo.transactions();
      if (txs.isNotEmpty) d.repo.setCategory(txs[rnd.nextInt(txs.length)].id, ['Groceries', 'Transport', 'Eating out'][rnd.nextInt(3)]);
    default:
      final txs = d.repo.transactions();
      if (txs.length > 3) d.repo.deleteTransaction(txs[rnd.nextInt(txs.length)].id);
  }
}
