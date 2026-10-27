// Matching only when caught up (stage R review M1): local imports and deletes pair transfers and match cash entries at
// once only while the last sync run was caught up (or the device never synced); otherwise they wait for the next
// caught-up run, because a pair made against an incomplete row set is never re-planned. All data is SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

void main() {
  late Directory tmp;
  late VaultKey key;
  late Net net;
  var now = 1791590400000; // 2026-10-10
  final devices = <Device>[];

  Device device(String name) {
    final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
    devices.add(d);
    return d;
  }

  Future<SyncReport> run(Device d) {
    now += 1000;
    d.deliver(net, Random(1));
    return d.run();
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-match-gate-');
    key = VaultKey.generate();
    net = Net();
    devices.clear();
  });
  tearDown(() {
    for (final d in devices) {
      d.close();
    }
    tmp.deleteSync(recursive: true);
  });

  // The hinted card payment PBZ → Revolut (10 Oct), an unhinted shop purchase of the same amount (12 Oct), and the
  // Revolut top-up it belongs to (10 Oct).
  final cardPayment = ImportBatch(source: 'pbz', transactions: [
    n('2026-10-10', -5000, 'Plaćanje karticom', 'REVOLUT TOP UP', kind: TxKind.ownTransfer),
  ]);
  final shop = ImportBatch(source: 'pbz', transactions: [
    n('2026-10-12', -5000, 'POS plaćanje', 'PBZ POS SYNTHETIC SHOP ZAGREB', kind: TxKind.card),
  ]);
  final topup = ImportBatch(source: 'revolut', transactions: [
    n('2026-10-10', 5000, 'Topup', 'Top-Up by *0000', source: 'revolut', kind: TxKind.ownTransfer),
  ]);
  final cardId = cardPayment.transactions.single.id, shopId = shop.transactions.single.id, topupId = topup.transactions.single.id;

  Map<String, String?> links(WalletRepo r) => {for (final t in r.transactions(includeHidden: true)) t.id: t.transferTo};

  test('an import while a peer file is waiting does not pair; the next caught-up run pairs the right rows', () async {
    final p = device('P'), l = device('L');
    p.repo.importBatch(cardPayment);
    await run(p);
    l.repo.importBatch(shop);
    net.relay.failGet(p.repo.deviceId, 1);
    final r = await run(l);
    expect(r.caughtUp, isFalse);
    expect(l.repo.syncCaughtUp, isFalse);

    final s = l.repo.importBatch(topup);
    expect(s.transfers, 0, reason: 'deferred: the hinted card payment is still on its way');
    expect(links(l.repo), {shopId: null, topupId: null});

    final r2 = await run(l);
    expect(r2.caughtUp, isTrue);
    expect(l.repo.syncCaughtUp, isTrue);
    expect(links(l.repo), {cardId: topupId, topupId: cardId, shopId: null});
    final shopRow = l.repo.transactions().singleWhere((t) => t.id == shopId);
    expect(l.repo.categorizer().categoryOf(shopRow), isNot('Internal transfer'));

    await run(p);
    expect(links(p.repo), links(l.repo));
  });

  test('caught up: an import pairs at once (what the owner sees right after importing)', () async {
    final p = device('P'), l = device('L');
    p.repo.importBatch(cardPayment);
    await run(p);
    expect((await run(l)).caughtUp, isTrue);
    final s = l.repo.importBatch(topup);
    expect(s.transfers, 1);
    expect(links(l.repo), {cardId: topupId, topupId: cardId});
  });

  test('a device that never synced pairs and matches at once', () {
    final l = device('L');
    expect(l.repo.syncCaughtUp, isTrue);
    l.repo.importBatch(cardPayment);
    expect(l.repo.importBatch(topup).transfers, 1);
  });

  test('a delete while not caught up reopens the cash entry it replaced at once; no new match until caught up', () async {
    final p = device('P'), l = device('L');
    final cash = l.repo.addTransaction(date: '2026-10-11', amount: 3000, category: 'Eating out', note: 'synthetic cash');
    now += 1000;
    final first =
        ImportBatch(source: 'pbz', transactions: [n('2026-10-12', -3000, 'POS plaćanje', 'PBZ POS SYNTHETIC CAFE', kind: TxKind.card)]);
    expect(l.repo.importBatch(first).matched, 1, reason: 'never synced: matched at once');
    final bankId = first.transactions.single.id;
    bool counts() => l.repo.transactions().any((t) => t.id == cash && t.live);
    expect(counts(), isFalse);

    p.repo.updateSettings({'rent': 1});
    await run(p);
    net.relay.failGet(p.repo.deviceId, 1);
    expect((await run(l)).caughtUp, isFalse);
    now += 1000;
    final second =
        ImportBatch(source: 'pbz', transactions: [n('2026-10-13', -3000, 'POS plaćanje', 'PBZ POS SYNTHETIC CAFE TWO', kind: TxKind.card)]);
    expect(l.repo.importBatch(second).matched, 0);

    l.repo.deleteTransaction(bankId);
    expect(counts(), isTrue, reason: 'the entry counts again at once: undoing its link needs only this deletion');
    expect(l.repo.transaction(cash)!.matchedTo, isNull, reason: 'no new match while not caught up');

    expect((await run(l)).caughtUp, isTrue);
    expect(l.repo.transaction(cash)!.matchedTo, second.transactions.single.id, reason: 'matching goes on as usual');
    expect(counts(), isFalse);
  });

  test('a delete while not caught up also unhides the own-transfer partner at once; re-pairing waits', () async {
    final p = device('P'), l = device('L');
    p.repo.importBatch(cardPayment);
    await run(p);
    expect((await run(l)).caughtUp, isTrue);
    l.repo.importBatch(topup);
    expect(links(l.repo)[topupId], cardId);
    p.repo.importBatch(shop);
    await run(p);
    net.relay.failGet(p.repo.deviceId, 2);
    expect((await run(l)).caughtUp, isFalse);
    l.repo.deleteTransaction(cardId);
    expect(links(l.repo)[topupId], isNull, reason: 'the link to the deleted row is undone at once');
    expect((await run(l)).caughtUp, isTrue);
    expect(links(l.repo)[topupId], isNot(cardId));
  });
}
