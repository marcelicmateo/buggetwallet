// Sync convergence, randomized: 2-4 simulated devices (in-memory repos + SyncEngine on one MemoryTransport relay)
// do random interleaved edits; fetches fail at random (a device then stops at that file of that device until a later
// run). After a final full sync every device must hold identical tables, equal to "highest HLC wins per field"
// over every op ever written. All data is SYNTHETIC. Seeds are fixed; BW_FUZZ_ITERATIONS / BW_FUZZ_SEED run more.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';

const _cats = ['Groceries', 'Eating out', 'Shopping', 'Car & transport', 'Food delivery', 'Bills & subscriptions', 'Cash', 'Rent'];
const _merchants = [
  'PBZ POS PBZ7LIDL HRVATSKA ZAGREB',
  'POS SPAR 0001',
  'POS KONZUM 12',
  'POS IKEA ZAGREB',
  'POS MCDONALDS 3',
  'Example Shop'
];

/// A pool of synthetic bank rows; devices import overlapping random slices of it (like exports of overlapping months).
List<NormalizedTransaction> _pool(Random r) {
  final out = <NormalizedTransaction>[];
  for (var i = 0; i < 60; i++) {
    final date = addDays('2026-01-01', r.nextInt(90));
    final kind = r.nextInt(10);
    if (kind == 0) {
      out.add(bankRow(date, 150000 + i, 'Plaća/Mirovina', 'Neto plaća $i'));
    } else if (kind == 1) {
      out.add(bankRow(date, -5000, 'POS plaćanje', 'POS Revolut**0000* Dublin $i'));
    } else if (kind == 2) {
      out.add(bankRow(date, -(1000 + r.nextInt(5000)), 'Card Payment', 'Wolt $i', source: 'revolut'));
    } else {
      out.add(bankRow(date, -(100 + r.nextInt(9000)), 'POS plaćanje', '${_merchants[r.nextInt(_merchants.length)]} #$i'));
    }
  }
  return out;
}

ImportBatch _slice(List<NormalizedTransaction> pool, Random r) {
  final a = r.nextInt(pool.length), len = 1 + r.nextInt(25);
  final rows = pool.sublist(a, min(pool.length, a + len));
  final pbz = rows.where((t) => t.source == 'pbz').toList();
  return ImportBatch(source: 'pbz', transactions: pbz.isEmpty ? rows : pbz);
}

String _randomTx(WalletRepo repo, Random r) {
  final all = repo.transactions(includeHidden: true);
  return all.isEmpty ? 'missing-${r.nextInt(5)}' : all[r.nextInt(all.length)].id;
}

/// One random local edit on [d]. Returns a short label for the failure log.
String _edit(Device d, Random r, List<NormalizedTransaction> pool) {
  final repo = d.repo;
  switch (r.nextInt(14)) {
    case 0 || 1:
      final s = repo.importBatch(_slice(pool, r));
      return 'import+${s.added}';
    case 2 || 3:
      // Same amount as a pool row now and then, so matching to bank rows happens.
      final p = pool[r.nextInt(pool.length)];
      final amount = r.nextBool() && p.amountMinor < 0 ? -p.amountMinor : 100 + r.nextInt(5000);
      repo.addManual(date: addDays(p.date, r.nextInt(7) - 3), amount: amount, category: _cats[r.nextInt(_cats.length)], note: 'n');
      return 'manual';
    case 4 || 5:
      repo.setCategory(_randomTx(repo, r), r.nextInt(5) == 0 ? null : _cats[r.nextInt(_cats.length)]);
      return 'category';
    case 6:
      repo.deleteTransaction(_randomTx(repo, r));
      return 'delete';
    case 7:
      repo.setMerchantRule(['lidl', 'spar', 'konzum', 'example_shop'][r.nextInt(4)], _cats[r.nextInt(_cats.length)]);
      return 'rule';
    case 8:
      final goals = repo.goals();
      final id = goals.isNotEmpty && r.nextBool() ? goals[r.nextInt(goals.length)].id : null;
      repo.saveGoal(
          id: id,
          name: 'Goal ${r.nextInt(9)}',
          target: 10000 * r.nextInt(50),
          saved: 100 * r.nextInt(100),
          monthly: 500 * r.nextInt(20),
          sort: r.nextInt(9));
      return 'goal';
    case 9:
      final goals = repo.goals();
      if (goals.isEmpty) return 'noop';
      if (r.nextBool()) {
        repo.deleteGoal(goals[r.nextInt(goals.length)].id);
        return 'deleteGoal';
      }
      repo.payGoals();
      return 'payGoals';
    case 10:
      repo.addWish('Wish ${r.nextInt(9)}', 1000 + r.nextInt(20000));
      return 'wish';
    case 11:
      final w = repo.wishlist();
      if (w.isEmpty) return 'noop';
      repo.decideWish(w[r.nextInt(w.length)].id, ['bought', 'skipped', 'waiting'][r.nextInt(3)]);
      return 'decideWish';
    default:
      final keys = {
        'salary': 100000 + 1000 * r.nextInt(100),
        'rent': 1000 * r.nextInt(100),
        'paydayDay': 1 + r.nextInt(31),
        'periodStart': addDays('2026-01-10', r.nextInt(60)),
        'impulse': 1000 * r.nextInt(10),
        'incomeMode': r.nextBool() ? 'planned' : 'received',
        'merchantPatterns': [
          ['Groceries', 'shop ${r.nextInt(3)}']
        ],
      };
      final pick = {
        for (final k in keys.keys)
          if (r.nextBool()) k: keys[k]
      };
      if (pick.isEmpty) return 'noop';
      repo.updateSettings(pick);
      return 'settings ${pick.keys.join(',')}';
  }
}

Future<void> _scenario(int seed, Directory tmp) async {
  final r = Random(seed);
  final key = VaultKey.generate();
  final net = Net();
  var now = 1767225600000 + r.nextInt(1 << 30); // around 2026
  final nDevices = 2 + r.nextInt(3);
  final lateJoiner = nDevices > 2 && r.nextBool();
  final devices = <Device>[];
  for (var i = 0; i < nDevices; i++) {
    // Clock skew: up to ±2 hours, and now and then a device far in the future or the past.
    final skew = switch (r.nextInt(6)) { 0 => 365 * 86400000, 1 => -30 * 86400000, _ => r.nextInt(4 * 3600000) - 2 * 3600000 };
    final dir = Directory('${tmp.path}/s$seed-d$i')..createSync(recursive: true);
    devices.add(Device('d$i', dir, key, () => now + skew));
  }
  final active = lateJoiner ? devices.sublist(0, nDevices - 1) : devices;
  final pool = _pool(r);
  final log = <String>[];
  final steps = 30 + r.nextInt(40);
  for (var s = 0; s < steps; s++) {
    now += r.nextInt(r.nextInt(10) == 0 ? 3600000 : 5000);
    final d = active[r.nextInt(active.length)];
    if (r.nextInt(4) == 0) {
      d.deliver(net, r, p: r.nextDouble());
      final rep = await d.run();
      d.upload(net);
      log.add('${d.name}:sync(${rep.sent}/${rep.filesRead})');
    } else {
      log.add('${d.name}:${_edit(d, r, pool)}');
    }
  }
  // Final full sync: everyone exports, every file reaches everyone (late joiner included), everyone applies. Applying
  // can add writes of its own (a manual entry matched to a bank row that arrived from another device), which every
  // device computes the same way; they need a few more rounds to settle.
  // A run uploads before it applies, so the round is over only when no run sent anything (everyone then saw it all).
  var rounds = 0;
  while (true) {
    var sent = 0;
    for (final d in devices) {
      sent += (await d.run()).sent;
    }
    for (final d in devices) {
      d.deliver(net, r);
      sent += (await d.run()).sent;
    }
    rounds++;
    if (sent == 0 && devices.every((d) => d.repo.pendingOps().isEmpty)) break;
    expect(rounds, lessThan(4), reason: 'seed $seed: sync does not settle');
  }
  final reason = 'seed $seed, $nDevices devices${lateJoiner ? ' (last joins late)' : ''}, steps: ${log.join(' ')}';
  final want = lastWriterWins(await opsInNet(net, key));
  final first = dump(devices.first.repo);
  for (final d in devices) {
    expect(d.repo.pendingOps(), isEmpty, reason: reason);
    expect(dump(d.repo), first, reason: '${d.name} differs from d0; $reason');
    expect(lwwDiff(d.repo, want), isEmpty, reason: '${d.name} vs last-writer-wins; $reason');
    // Every bank row any device imported is present exactly once.
    final ids = d.repo.transactions(includeHidden: true).map((t) => t.id).toList();
    expect(ids.toSet().length, ids.length, reason: reason);
    // A matched manual entry points at a bank row that exists.
    for (final t in d.repo.transactions(includeHidden: true).where((t) => t.matchedTo != null)) {
      expect(d.repo.transaction(t.matchedTo!), isNotNull, reason: reason);
    }
  }
  // Another full round changes nothing (idempotent).
  for (final d in devices) {
    d.deliver(net, r);
    final rep = await d.run();
    expect(rep.sent, 0, reason: reason);
    expect(rep.received, 0, reason: reason);
    expect(rep.caughtUp, isTrue, reason: reason);
  }
  expect(dump(devices.last.repo), first, reason: reason);
  for (final d in devices) {
    d.close();
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('bw-conv-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  final base = fuzzSeed(1016);
  final n = fuzzIterations(60);
  test('random edits on 2-4 devices converge to last-writer-wins ($n seeds from $base)', () async {
    for (var i = 0; i < n; i++) {
      final seed = base + i;
      try {
        await _scenario(seed, tmp);
      } on TestFailure {
        rethrow;
      } catch (e, st) {
        fail('seed $seed threw $e\n$st');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
