// Stage P6 review fixes (core): a dead part category falls back to the payment's own main tag, a split read through
// the match onto the bank row (two devices), search returns whole payments with the matched part, and counts are per
// payment. SYNTHETIC data only.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

const _parts2 = [
  SplitPart(amount: -5000, category: 'Groceries'),
  SplitPart(amount: -5000, category: 'Groceries', note: 'quorvant', tags: ['ta'])
];

void main() {
  test('MED 1: a dead part category falls back to the payment main tag, never to a transfer', () {
    // PBZ text with "revolut" is an Internal transfer automatically; the owner overrode it to Shopping.
    const t = Tx(
        id: 'p',
        source: 'pbz',
        date: '2026-03-12',
        amount: -3000,
        bankType: 'POS plaćanje',
        description: 'REVOLUT ZORBLEX',
        category: 'Shopping');
    final cz = Categorizer(splits: {
      'p': const [SplitPart(amount: -1000, category: 'kdeadbeef0000'), SplitPart(amount: -2000, category: 'Groceries')]
    });
    expect(cz.autoCategory(t), 'Internal transfer');
    final rows = cz.expand(t);
    expect(rows.map((x) => x.category), ['Shopping', 'Groceries']);
    expect(monthSummary(rows, '2026-03', currency: 'EUR').out, 3000, reason: 'the whole payment stays spending');
  });

  group('LOW 3 and 4', () {
    const t = Tx(id: 'p', source: 'pbz', date: '2026-03-12', amount: -10000, bankType: 'POS plaćanje', description: 'PBZ POS ZORBLEX');
    final tags = TagTable.from(const [TagRow(id: 'ta', name: 'Trip', position: 0)]);
    final cz = Categorizer(splits: {'p': _parts2}, tagContext: TagContext(tags: tags));
    final rows = cz.expand(t);

    test('searchAll returns the whole payment (whole amount and main tag) and the part that matched', () {
      final s = searchAll('quorvant', txs: rows, goals: const [], wishlist: const [], bills: const [], tags: tags);
      expect(s.txs, hasLength(1));
      expect((s.txs.single.amount, s.txs.single.category, s.txs.single.isPart), (-10000, cz.categorize(t).category, false));
      expect(s.matchedPart, {'p': 1});
      final whole = searchAll('zorblex', txs: rows, goals: const [], wishlist: const [], bills: const [], tags: tags);
      expect((whole.txs.single.amount, whole.matchedPart), (-10000, const <String, int>{}));
      expect(whole.matchedPart, isEmpty, reason: 'the payment text matched, not one part');
    });

    test('merchantsIn and tagShare count payments, not parts', () {
      final r = DateRange(start: '2026-03-01', end: '2026-03-31');
      final m = merchantsIn('Groceries', rows, r, currency: 'EUR').single;
      expect((m.spent, m.count), (10000, 1));
      final both = Categorizer(splits: {
        'p': const [
          SplitPart(amount: -4000, category: 'Groceries', tags: ['ta']),
          SplitPart(amount: -6000, category: 'Shopping', tags: ['ta'])
        ]
      }, tagContext: TagContext(tags: tags))
          .expand(t);
      final s = tagShare(both, r, currency: 'EUR').slices.single;
      expect((s.spent, s.count), (10000, 1));
    });
  });

  group('MED 2: two devices, split read through the match', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    var clock = 0;
    final devices = <Device>[];
    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => clock);
      devices.add(d);
      return d;
    }

    Future<void> syncAll(List<Device> ds) async {
      for (var round = 0; round < 2; round++) {
        for (final d in ds) {
          d.deliver(net, Random(round));
          await d.run();
        }
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-p6-review-');
      key = VaultKey.generate();
      net = Net();
      clock = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });

    List<CategorizedTx> expanded(WalletRepo r) => r.categorizer().expandAll(r.transactions());

    test('an entry split offline after another device matched it: the bank row counts the parts on both', () async {
      final a = device('a'), b = device('b');
      final e = a.repo.addTransaction(date: '2026-03-12', amount: 5000, category: 'Shopping');
      await syncAll([a, b]);
      clock += 1000;
      final row = n('2026-03-13', -5000, 'POS plaćanje', 'ZORBLEX SHOP');
      expect(b.repo.importBatch(ImportBatch(source: 'pbz', transactions: [row])).matched, 1);
      clock += 1000;
      a.repo.setSplit(e, const [SplitPart(amount: -3000, category: 'Groceries'), SplitPart(amount: -2000, category: 'Eating out')]);
      await syncAll([b, a]);
      for (final d in [a, b]) {
        final rows = expanded(d.repo);
        expect(rows.where((x) => x.tx.id == row.id).map((x) => x.amount), [-3000, -2000], reason: d.name);
        expect(monthSummary(rows, '2026-03', currency: 'EUR').byCategory, {'Groceries': 3000, 'Eating out': 2000}, reason: d.name);
        expect(d.repo.splitOf(row.id)?.map((p) => p.amount), [-3000, -2000], reason: 'the editor pre-fills it: ${d.name}');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('the bank row own split wins over the entry; removing it on the bank row stops the read-through', () async {
      final a = device('a');
      final e = a.repo.addTransaction(date: '2026-03-12', amount: 5000, category: 'Shopping');
      clock += 1000;
      a.repo.setSplit(e, const [SplitPart(amount: -3000, category: 'Groceries'), SplitPart(amount: -2000, category: 'Shopping')]);
      final row = n('2026-03-13', -5000, 'POS plaćanje', 'ZORBLEX SHOP');
      a.repo.importBatch(ImportBatch(source: 'pbz', transactions: [row]));
      expect(a.repo.transaction(e)!.matchedTo, row.id);
      expect(expanded(a.repo).where((x) => x.tx.id == row.id).map((x) => x.amount), [-3000, -2000]);
      expect(a.repo.categorizer().expand(a.repo.transaction(e)!), hasLength(1), reason: 'the replaced entry is one dead row');
      a.repo.setSplit(row.id, const [SplitPart(amount: -1000, category: 'Groceries'), SplitPart(amount: -4000, category: 'Shopping')]);
      expect(expanded(a.repo).where((x) => x.tx.id == row.id).map((x) => x.amount), [-1000, -4000]);
      a.repo.removeSplit(row.id);
      expect(expanded(a.repo).where((x) => x.tx.id == row.id).map((x) => x.isPart), [false]);
      expect(a.repo.splitOf(row.id), isNull);
    });

    test('removeSplit on a bank row that only reads its entry split hides it there', () async {
      final a = device('a');
      final e = a.repo.addTransaction(date: '2026-03-12', amount: 5000, category: 'Shopping');
      clock += 1000;
      a.repo.setSplit(e, const [SplitPart(amount: -3000, category: 'Groceries'), SplitPart(amount: -2000, category: 'Shopping')]);
      final row = n('2026-03-13', -5000, 'POS plaćanje', 'ZORBLEX SHOP');
      a.repo.importBatch(ImportBatch(source: 'pbz', transactions: [row]));
      expect(a.repo.splitOf(row.id)?.map((p) => p.amount), [-3000, -2000]);
      a.repo.removeSplit(row.id);
      expect(a.repo.splitOf(row.id), isNull);
      expect(expanded(a.repo).where((x) => x.tx.id == row.id), hasLength(1));
    });
  });
}
