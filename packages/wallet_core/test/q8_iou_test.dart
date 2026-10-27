// Q8 IOU list (schema 17): the repo API, the money exclusion of linked payments, logs, and two devices.
// All data is SYNTHETIC: made-up people, amounts and generic merchants.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

const _t = Timeout(Duration(seconds: 60));
const _today = '2026-03-25';
final _now = DateTime.utc(2026, 3, 25, 9).millisecondsSinceEpoch;

final _salary = n('2026-03-15', 200000, 'Plaća/Mirovina', 'Neto plaća za 02/2026');
final _lend = n('2026-03-16', -4000, 'POS plaćanje', 'PBZ POS PBZ7KONZUM ZAGREB');
final _shop = n('2026-03-17', -2500, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB');
final _back = n('2026-03-20', 1500, 'Ostalo', 'UPLATA SYNTH OSOBA');
final _back2 = n('2026-03-22', 2500, 'Ostalo', 'UPLATA SYNTH OSOBA DRUGA');
final _usd = NormalizedTransaction(
    id: transactionId('2026-03-18', -4000, 'SYNTH USD SHOP', 0),
    source: 'pbz',
    date: '2026-03-18',
    amountMinor: -4000,
    currency: 'USD',
    bankType: 'POS plaćanje',
    description: 'SYNTH USD SHOP');

WalletRepo _wallet() {
  final r = WalletRepo.inMemory(now: () => _now);
  addTearDown(r.close);
  r.importBatch(ImportBatch(source: 'pbz', transactions: [_salary, _lend, _shop, _back, _back2, _usd]));
  r.updateSettings({'salary': 200000, 'paydayDay': 15, 'periodStart': '2026-03-15'});
  return r;
}

/// The numbers the owner sees: the pay period, the calendar month, one insight and the bank balance.
({int spent, int extras, int out, int income, int share, String byCategory, int balance}) _numbers(WalletRepo r) {
  final cz = r.categorizer();
  final txs = cz.expandAll(r.transactions());
  final p = computePeriod(txs, r.settings(), const [], _today, table: cz.table);
  final m = monthSummary(txs, '2026-03', currency: 'EUR');
  final share = categoryShare(txs, DateRange(start: '2026-03-01', end: '2026-03-31'), currency: 'EUR');
  final bal = accountBalances(r.accounts(), r.transactions()).single.balance;
  return (spent: p.spent, extras: p.extras, out: m.out, income: m.income, share: share.total, byCategory: '${m.byCategory}', balance: bal);
}

String _id(NormalizedTransaction t) => t.id;

void main() {
  group('repo API', () {
    test('add, list, repay: outstanding = amount minus the live parts; closed ones listed only with includeClosed', () {
      final r = _wallet();
      final a = r.addIou(person: ' Ana ', direction: IouDirection.lent, amount: 4000, currency: 'EUR', date: '2026-03-16', note: ' lunch ');
      final b = r.addIou(person: 'Ben', direction: IouDirection.borrowed, amount: 1000, currency: 'EUR', date: '2026-03-10');
      expect([for (final v in r.ious()) v.iou.id], [a, b], reason: 'newest first');
      final v = r.ious().first;
      expect((v.iou.person, v.iou.note, v.iou.direction, v.outstanding), ('Ana', 'lunch', IouDirection.lent, 4000));
      expect(v.parts, isEmpty);
      final p1 = r.addIouPart(a, amount: 1500, date: '2026-03-20');
      r.addIouPart(a, amount: 500, date: '2026-03-18');
      final after = r.ious().first;
      expect(after.outstanding, 2000);
      expect(after.repaid, 2000);
      expect([for (final p in after.parts) p.date], ['2026-03-18', '2026-03-20'], reason: 'oldest first');
      r.deleteIouPart(p1);
      expect(r.ious().first.outstanding, 3500);
      r.undeleteIouPart(p1);
      expect(r.ious().first.outstanding, 2000);
      r.closeIou(b);
      expect([for (final v in r.ious(includeClosed: false)) v.iou.id], [a]);
      expect(r.ious().map((v) => v.iou.id), contains(b));
      expect(r.ious().firstWhere((v) => v.iou.id == b).iou.closed, isTrue);
      r.closeIou(b, closed: false);
      expect(r.ious(includeClosed: false).length, 2);
    });

    test('outstanding is never shown below 0 when two devices overpaid', () {
      final r = _wallet();
      final a = r.addIou(person: 'Ana', direction: IouDirection.lent, amount: 1000, currency: 'EUR', date: '2026-03-16');
      r.addIouPart(a, amount: 800, date: '2026-03-18');
      // Another device's repayment of the same debt, arriving by sync: never refused.
      expect(
          r.applyRemote([
            Op('iou_part', 'rpeer', {'iou_id': a, 'amount': 800, 'date': '2026-03-19', 'deleted': 0}, Hlc(_now, 0, 'peer').toString())
          ]),
          1);
      final v = r.ious().single;
      expect((v.outstanding, v.repaid, v.parts.length), (0, 1600, 2));
    });

    test('validation: person, amount, currency, date, note; unknown ids; overpaying', () {
      final r = _wallet();
      void bad(void Function() f, String text) =>
          expect(f, throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains(text))));
      String add({String person = 'Ana', int amount = 1000, String currency = 'EUR', String date = '2026-03-16', String? note}) =>
          r.addIou(person: person, direction: IouDirection.lent, amount: amount, currency: currency, date: date, note: note);
      bad(() => add(person: '   '), 'who');
      bad(() => add(person: 'x' * (Iou.maxPerson + 1)), '${Iou.maxPerson}');
      expect(add(person: 'x' * Iou.maxPerson), isNotEmpty);
      bad(() => add(amount: 0), 'above zero');
      bad(() => add(amount: -5), 'above zero');
      bad(() => add(amount: WalletSettings.maxAmount + 1), 'allowed');
      expect(add(amount: WalletSettings.maxAmount), isNotEmpty);
      bad(() => add(currency: 'eur'), 'currency');
      bad(() => add(date: '2026-02-30'), 'date');
      bad(() => add(date: '16.03.2026'), 'date');
      bad(() => add(note: 'n' * (Iou.maxNote + 1)), '${Iou.maxNote}');
      final id = add(amount: 1000);
      bad(() => r.addIouPart(id, amount: 1001, date: '2026-03-20'), 'more than');
      final p = r.addIouPart(id, amount: 1000, date: '2026-03-20');
      bad(() => r.addIouPart(id, amount: 1, date: '2026-03-20'), 'more than');
      bad(() => r.addIouPart(id, amount: 0, date: '2026-03-20'), 'above zero');
      bad(() => r.addIouPart('nope', amount: 1, date: '2026-03-20'), 'No such IOU');
      bad(() => r.updateIou(id, amount: 999), 'less than');
      r.deleteIouPart(p);
      r.addIouPart(id, amount: 600, date: '2026-03-21');
      bad(() => r.undeleteIouPart(p), 'more than');
      bad(() => r.undeleteIou('nope'), 'No such IOU');
      bad(() => r.deleteIou('nope'), 'No such IOU');
      bad(() => r.closeIou('nope'), 'No such IOU');
      bad(() => r.deleteIouPart('nope'), 'No such repayment');
      bad(() => r.undeleteIouPart('nope'), 'No such repayment');
      r.deleteIou(id);
      bad(() => r.addIouPart(id, amount: 1, date: '2026-03-20'), 'No such IOU');
      bad(() => r.updateIou(id, person: 'Bo'), 'No such IOU');
      bad(() => r.closeIou(id), 'No such IOU');
    });

    test('delete + undelete (undo): the parts come back; no write for a no-op', () {
      final r = _wallet();
      final a = r.addIou(person: 'Ana', direction: IouDirection.lent, amount: 4000, currency: 'EUR', date: '2026-03-16');
      r.addIouPart(a, amount: 1000, date: '2026-03-20');
      final ops = r.pendingOps().length;
      r.undeleteIou(a);
      r.closeIou(a, closed: false);
      r.updateIou(a, person: 'Ana', amount: 4000);
      expect(r.pendingOps().length, ops, reason: 'nothing changed, nothing written');
      r.deleteIou(a);
      expect(r.ious(), isEmpty);
      r.deleteIou(a);
      r.undeleteIou(a);
      final v = r.ious().single;
      expect((v.outstanding, v.parts.length), (3000, 1));
    });

    test('updateIou changes only the given fields; clearNote and clearTx remove them', () {
      final r = _wallet();
      final a = r.addIou(
          person: 'Ana', direction: IouDirection.lent, amount: 4000, currency: 'EUR', date: '2026-03-16', note: 'n', tx: _id(_lend));
      r.updateIou(a, person: 'Ana B', date: '2026-03-17');
      var i = r.ious().single.iou;
      expect((i.person, i.date, i.note, i.tx, i.amount), ('Ana B', '2026-03-17', 'n', _id(_lend), 4000));
      r.updateIou(a, clearNote: true, clearTx: true);
      i = r.ious().single.iou;
      expect((i.note, i.tx), (null, null));
      r.updateIou(a, direction: IouDirection.borrowed, amount: 1500, tx: _id(_back));
      i = r.ious().single.iou;
      expect((i.direction, i.amount, i.tx), (IouDirection.borrowed, 1500, _id(_back)));
    });
  });

  group('links', () {
    void bad(void Function() f, String text) =>
        expect(f, throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains(text))));

    test('a linked payment must exist, be live, in the same currency, of the right sign and exactly the amount', () {
      final r = _wallet();
      String lent(String tx, {int amount = 4000, String currency = 'EUR'}) =>
          r.addIou(person: 'Ana', direction: IouDirection.lent, amount: amount, currency: currency, date: '2026-03-16', tx: tx);
      bad(() => lent('nope'), 'No such payment');
      bad(() => lent(_id(_back), amount: 1500), 'went out');
      bad(() => lent(_id(_lend), amount: 3999), 'exactly');
      bad(() => lent(_id(_lend), amount: 3999), 'partly a loan');
      bad(() => lent(_id(_usd)), 'USD');
      expect(lent(_id(_usd), currency: 'USD'), isNotEmpty, reason: 'an IOU in the payment currency');
      bad(() => r.addIou(person: 'Bo', direction: IouDirection.borrowed, amount: 4000, currency: 'EUR', date: '2026-03-16', tx: _id(_lend)),
          'came in');
      r.deleteTransaction(_id(_shop));
      bad(() => lent(_id(_shop), amount: 2500), 'No such payment');
      expect(r.ious().length, 1, reason: 'nothing written by a refused add');
    });

    test('repayments: lent → money in, borrowed → money out; one link per payment across IOUs and parts', () {
      final r = _wallet();
      final a = r.addIou(person: 'Ana', direction: IouDirection.lent, amount: 4000, currency: 'EUR', date: '2026-03-16', tx: _id(_lend));
      bad(() => r.addIouPart(a, amount: 2500, date: '2026-03-17', tx: _id(_shop)), 'came in');
      r.addIouPart(a, amount: 1500, date: '2026-03-20', tx: _id(_back));
      bad(() => r.addIouPart(a, amount: 1500, date: '2026-03-20', tx: _id(_back)), 'already linked');
      bad(() => r.addIou(person: 'Bo', direction: IouDirection.lent, amount: 4000, currency: 'EUR', date: '2026-03-16', tx: _id(_lend)),
          'already linked');
      final b = r.addIou(person: 'Bo', direction: IouDirection.borrowed, amount: 9000, currency: 'EUR', date: '2026-03-01');
      bad(() => r.addIouPart(b, amount: 2500, date: '2026-03-22', tx: _id(_back2)), 'went out');
      r.addIouPart(b, amount: 2500, date: '2026-03-17', tx: _id(_shop));
      bad(
        () => r.updateIou(b, direction: IouDirection.lent),
        'came in',
      );
      // A deleted IOU frees its links (and those of its parts).
      r.deleteIou(a);
      expect(r.addIou(person: 'Cy', direction: IouDirection.lent, amount: 4000, currency: 'EUR', date: '2026-03-16', tx: _id(_lend)),
          isNotEmpty);
    });

    test('own transfers and split payments cannot be linked; a linked payment cannot be split', () {
      final r = WalletRepo.inMemory(now: () => _now);
      addTearDown(r.close);
      final out = n('2026-03-16', -5000, 'POS plaćanje', 'POS Revolut**0000* Dublin', kind: TxKind.ownTransfer);
      r.importBatch(ImportBatch(source: 'pbz', transactions: [out, _lend, _shop]));
      bad(() => r.addIou(person: 'Ana', direction: IouDirection.lent, amount: 5000, currency: 'EUR', date: '2026-03-16', tx: _id(out)),
          'own transfer');
      r.setSplit(_id(_shop), const [SplitPart(amount: -1000, category: 'Groceries'), SplitPart(amount: -1500, category: 'Shopping')]);
      bad(() => r.addIou(person: 'Ana', direction: IouDirection.lent, amount: 2500, currency: 'EUR', date: '2026-03-16', tx: _id(_shop)),
          'split');
      r.addIou(person: 'Ana', direction: IouDirection.lent, amount: 4000, currency: 'EUR', date: '2026-03-16', tx: _id(_lend));
      bad(
          () => r.setSplit(
              _id(_lend), const [SplitPart(amount: -1000, category: 'Groceries'), SplitPart(amount: -3000, category: 'Shopping')]),
          'IOU');
    });

    test('iouLinkedTx: live IOUs (closed too) and live parts of live IOUs, plus the bank row that replaced a linked entry', () {
      final r = _wallet();
      final a = r.addIou(person: 'Ana', direction: IouDirection.lent, amount: 4000, currency: 'EUR', date: '2026-03-16', tx: _id(_lend));
      final p = r.addIouPart(a, amount: 1500, date: '2026-03-20', tx: _id(_back));
      final b = r.addIou(person: 'Bo', direction: IouDirection.lent, amount: 9000, currency: 'EUR', date: '2026-03-01');
      final q = r.addIouPart(b, amount: 2500, date: '2026-03-22', tx: _id(_back2));
      expect(r.iouLinkedTx(), {_id(_lend), _id(_back), _id(_back2)});
      r.closeIou(a);
      expect(r.iouLinkedTx(), {_id(_lend), _id(_back), _id(_back2)}, reason: 'closed keeps its links');
      r.deleteIouPart(p);
      r.deleteIou(b);
      expect(r.iouLinkedTx(), {_id(_lend)});
      r.undeleteIou(b);
      expect(r.iouLinkedTx(), {_id(_lend), _id(_back2)});
      r.deleteIouPart(q);
      expect(r.iouLinkedTx(), {_id(_lend)});

      // A hand-added loan, then its bank row arrives and replaces it: the link follows.
      final m = WalletRepo.inMemory(now: () => _now);
      addTearDown(m.close);
      m.updateSettings({'salary': 200000, 'paydayDay': 15, 'periodStart': '2026-03-15'});
      final cash = m.addTransaction(date: '2026-03-16', amount: 3000, category: 'Shopping', note: 'lent');
      m.addIou(person: 'Ana', direction: IouDirection.lent, amount: 3000, currency: 'EUR', date: '2026-03-16', tx: cash);
      final bank = n('2026-03-17', -3000, 'POS plaćanje', 'PBZ POS PBZ7KONZUM ZAGREB');
      m.importBatch(ImportBatch(source: 'pbz', transactions: [bank]));
      expect(m.transaction(cash)!.matchedTo, bank.id);
      expect(m.iouLinkedTx(), {cash, bank.id});
      final cz = m.categorizer();
      final p2 = computePeriod(cz.expandAll(m.transactions()), m.settings(), const [], _today, table: cz.table);
      expect(p2.spent, 0, reason: 'the bank row that replaced the linked entry is not spending either');
    });
  });

  group('money: a linked payment is neither spending nor income (like a transfer); unlinked IOUs change nothing', () {
    test('computePeriod, monthSummary and categoryShare leave the linked rows out; the account balance keeps them', () async {
      final r = _wallet();
      await r.addAccount(name: 'Bank', source: 'pbz', currency: 'EUR', opening: 0, openingDate: '2026-03-01');
      final base = _numbers(r);
      expect(base.spent, 6500);
      expect(base.out, 6500);

      // Unlinked IOUs (and unlinked parts): every number exactly as before.
      final u = r.addIou(person: 'Ana', direction: IouDirection.lent, amount: 4000, currency: 'EUR', date: '2026-03-16');
      r.addIouPart(u, amount: 1500, date: '2026-03-20');
      r.addIou(person: 'Bo', direction: IouDirection.borrowed, amount: 7000, currency: 'EUR', date: '2026-03-02');
      expect(_numbers(r), base);

      // Linked: the 40.00 lent and the 15.00 paid back drop out of every total.
      final a = r.addIou(person: 'Cy', direction: IouDirection.lent, amount: 4000, currency: 'EUR', date: '2026-03-16', tx: _id(_lend));
      r.addIouPart(a, amount: 1500, date: '2026-03-20', tx: _id(_back));
      final linked = _numbers(r);
      expect(linked.spent, base.spent - 4000);
      expect(linked.out, base.out - 4000);
      expect(linked.share, base.share - 4000);
      expect(linked.extras, base.extras - 1500);
      expect(linked.income, base.income - 1500);
      expect(linked.balance, base.balance, reason: 'the money did leave and come back to the account');

      // The rows keep their main tag; only the kind is a transfer's.
      final cz = r.categorizer();
      final row = cz.categorize(r.transaction(_id(_lend))!);
      expect(row.category, isNot('Internal transfer'));
      expect(row.category, r.categorizer(withTags: false).categoryOf(r.transaction(_id(_lend))!));
      expect(row.kind, BudgetKind.transfer);
      expect(cz.categorize(r.transaction(_id(_shop))!).kind, isNot(BudgetKind.transfer));

      // Deleting the IOU puts the money back exactly; an undo takes it out again.
      r.deleteIou(a);
      expect(_numbers(r), base);
      r.undeleteIou(a);
      expect(_numbers(r), linked);
    });

    test('a linked foreign-currency payment is not listed among the other currencies either', () {
      final r = _wallet();
      List<CategorizedTx> txs() => r.categorizer().expandAll(r.transactions());
      expect(monthSummary(txs(), '2026-03', currency: 'EUR').foreignByCurrency, {'USD': -4000});
      r.addIou(person: 'Ana', direction: IouDirection.lent, amount: 4000, currency: 'USD', date: '2026-03-18', tx: _id(_usd));
      expect(monthSummary(txs(), '2026-03', currency: 'EUR').foreignByCurrency, isEmpty);
    });
  });

  test('logs carry counts and enum words only: never the person, the note or amounts', () {
    final lines = <String>[];
    final was = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen((rec) => lines.add(formatLogRecord(rec)));
    addTearDown(() {
      sub.cancel();
      Logger.root.level = was;
    });
    final r = _wallet();
    lines.clear();
    final a = r.addIou(
        person: 'Zorislava',
        direction: IouDirection.lent,
        amount: 4000,
        currency: 'EUR',
        date: '2026-03-16',
        note: 'secretnote',
        tx: _id(_lend));
    final p = r.addIouPart(a, amount: 1500, date: '2026-03-20', tx: _id(_back));
    r.updateIou(a, person: 'Zorislavka', note: 'othernote');
    r.closeIou(a);
    r.deleteIouPart(p);
    r.undeleteIouPart(p);
    r.deleteIou(a);
    r.undeleteIou(a);
    r.ious();
    expect(lines.where((l) => l.contains('iou.')), isNotEmpty);
    for (final l in lines) {
      for (final s in ['Zorislav', 'secretnote', 'othernote', '4000', '40.00', '1500', '15.00', _id(_lend), _id(_back)]) {
        expect(l, isNot(contains(s)), reason: l);
      }
    }
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    final devices = <Device>[];
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-q8-');
      key = VaultKey.generate();
      net = Net();
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });
    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => _now);
      devices.add(d);
      return d;
    }

    Future<void> syncAll(List<Device> ds) async {
      for (var round = 0; round < 3; round++) {
        for (final d in ds) {
          d.deliver(net, Random(round));
          await d.run();
        }
      }
    }

    test('create, repay, delete + undelete, close: both devices hold the same IOUs, links and totals', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_salary, _lend, _shop, _back]));
      a.repo.updateSettings({'salary': 200000, 'paydayDay': 15, 'periodStart': '2026-03-15'});
      final id =
          a.repo.addIou(person: 'Ana', direction: IouDirection.lent, amount: 4000, currency: 'EUR', date: '2026-03-16', tx: _id(_lend));
      await syncAll([a, b]);
      expect(b.repo.ious().single.iou.person, 'Ana');
      expect(b.repo.iouLinkedTx(), {_id(_lend)});
      expect(_numbers2(b.repo), _numbers2(a.repo));

      final part = b.repo.addIouPart(id, amount: 1500, date: '2026-03-20', tx: _id(_back));
      await syncAll([a, b]);
      expect(a.repo.ious().single.outstanding, 2500);
      expect(a.repo.iouLinkedTx(), {_id(_lend), _id(_back)});

      a.repo.deleteIou(id);
      await syncAll([a, b]);
      expect(b.repo.ious(), isEmpty);
      expect(b.repo.iouLinkedTx(), isEmpty);

      b.repo.undeleteIou(id);
      await syncAll([a, b]);
      expect(a.repo.ious().single.parts.single.id, part);

      a.repo.closeIou(id);
      await syncAll([a, b]);
      expect(b.repo.ious(includeClosed: false), isEmpty);
      expect(b.repo.ious().single.iou.closed, isTrue);
      expect(dump(a.repo, clocks: false), dump(b.repo, clocks: false));
      expect(_numbers2(b.repo), _numbers2(a.repo));
    }, timeout: _t);
  });
}

/// Pay-period spending and extras, for comparing two devices.
(int, int) _numbers2(WalletRepo r) {
  final cz = r.categorizer();
  final p = computePeriod(cz.expandAll(r.transactions()), r.settings(), const [], _today, table: cz.table);
  return (p.spent, p.extras);
}
