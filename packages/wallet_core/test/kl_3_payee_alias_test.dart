// KL-A item 3: a slip whose payee is spelled differently from its recurring bill's payee is linked once by the owner
// ("Belongs to bill…", `linkSlipToBill`); the spelling is remembered as a synced payee alias (schema 19
// `payee_aliases`) and coverage, history and category suggestions read it, exactly and one step only.
// Synthetic data only.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/bill_helpers.dart';
import 'support/sim.dart';

NormalizedBill slip(String ext, String payee, {String due = '2026-03-20', int total = 5400}) =>
    NormalizedBill(source: BillSource.hub3, externalId: ext, date: '2026-03-05', dueDate: due, total: total, payee: payee);

Bill bare(String payee) => Bill(id: 'x', payee: payee);

final _st = WalletSettings.fromMap({'salary': 100000, 'periodStart': '2026-03-15', 'paydayDay': 15});

void main() {
  final energy = billPayeeKey(bare('Synth Energy'))!;
  final power = billPayeeKey(bare('Synth Power Co'))!;

  group('pure', () {
    test('billPayeeKey reads an alias, exactly and one step only', () {
      expect(power, isNot(energy));
      expect(billPayeeKey(bare('Synth Power Co'), payeeAliases: {power: energy}), energy);
      expect(billPayeeKey(bare('Synth Power Co Ltd'), payeeAliases: {power: energy}), isNot(energy), reason: 'no similar-name guessing');
      expect(resolvePayeeAlias('a', {'a': 'b', 'b': 'c'}), 'b', reason: 'never a chain');
      expect(resolvePayeeAlias(null, {'a': 'b'}), isNull);
      expect(billPayeeKey(const Bill(id: 'x')), isNull);
    });

    test('payeeAliasId is pa: + 16 hex of the key, the same on every device', () {
      expect(payeeAliasId(power), matches(RegExp(r'^pa:[0-9a-f]{16}$')));
      expect(payeeAliasId(power), payeeAliasId(power));
      expect(payeeAliasId(power), isNot(payeeAliasId(energy)));
    });
  });

  group('WalletRepo', () {
    late WalletRepo r;
    late String recurring, slipId;
    setUp(() {
      r = WalletRepo.inMemory(now: () => DateTime.utc(2026, 3, 16, 10).millisecondsSinceEpoch);
      recurring = r.addRecurring(
          label: 'Synth energy', category: 'Bills & one-offs', amount: 5400, intervalDays: 30, firstDue: '2026-03-20', payee: energy);
      (slipId, _) = r.importBill(slip('slip-1', 'Synth Power Co'));
      r.confirmWithCategory(slipId);
    });
    tearDown(() => r.close());

    test('setPayeeAlias refuses an empty key, an alias of itself and chains', () {
      expect(() => r.setPayeeAlias('', energy), throwsArgumentError);
      expect(() => r.setPayeeAlias(power, '  '), throwsArgumentError);
      expect(() => r.setPayeeAlias(energy, energy), throwsArgumentError);
      r.setPayeeAlias(power, energy);
      expect(() => r.setPayeeAlias('synth_other', power), throwsArgumentError, reason: 'the target is itself an alias');
      expect(() => r.setPayeeAlias(energy, 'synth_third'), throwsArgumentError, reason: 'the alias is what another alias maps to');
      expect(r.payeeAliases(), {power: energy});
    });

    test('remove forgets it; removing an unknown alias does nothing', () {
      r.setPayeeAlias(power, energy);
      final ops = r.pendingOps().length;
      r.removePayeeAlias('synth_unknown');
      expect(r.pendingOps().length, ops);
      r.removePayeeAlias(power);
      expect(r.payeeAliases(), isEmpty);
      r.setPayeeAlias(power, energy);
      expect(r.payeeAliases(), {power: energy}, reason: 'set again after a remove');
    });

    test('linkSlipToBill: the slip is covered by its recurring bill and reserved once', () {
      PeriodBudget period(Map<String, String> aliases) => computePeriod(const [], _st, const [], '2026-03-16',
          bills: r.recurringBills(), planned: r.plannedCosts(), table: r.categoryTable(), payeeAliases: aliases);
      final slipBill = r.bill(slipId)!;
      expect(billCoveredBy(slipBill, r.recurringBills(), payeeAliases: r.payeeAliases()), isNull);
      expect(period(r.payeeAliases()).beforePayday, 10800, reason: 'before the link: counted twice');

      r.linkSlipToBill(slipId, recurring);
      expect(r.payeeAliases(), {power: energy});
      final aliases = r.payeeAliases();
      expect(billCoveredBy(slipBill, r.recurringBills(), payeeAliases: aliases)?.id, recurring);
      final row = r.plannedCosts().singleWhere((p) => p.isBill);
      expect(plannedCoveredBy(row, r.recurringBills(), payeeAliases: aliases)?.id, recurring);
      expect(period(aliases).beforePayday, 5400, reason: 'the recurring bill holds the slip');
      expect(period(const {}).beforePayday, 10800, reason: 'pure: only the map passed counts');

      final items = upcoming(
          planned: r.plannedCosts(),
          bills: r.recurringBills(),
          events: const [],
          from: '2026-03-16',
          to: '2026-04-14',
          payeeAliases: aliases);
      expect(items.where((i) => i.kind == UpcomingKind.planned), isEmpty);
      expect(plannedIcs(r.plannedCosts(), r.recurringBills(), from: '2026-03-16', to: '2026-04-14', payeeAliases: aliases),
          isNot(contains('planned-')));
    });

    test('bill history lists the slip under its recurring bill; the category is suggested from it', () {
      r.linkSlipToBill(slipId, recurring);
      final rb = r.recurringBills().singleWhere((b) => b.id == recurring);
      List<BillMonth> hist(Map<String, String> a) =>
          billHistory(rb, const [], r.bills(), today: '2026-03-16', currency: 'EUR', payeeAliases: a);
      expect(hist(const {}).expand((m) => m.slips), isEmpty);
      expect(hist(r.payeeAliases()).expand((m) => m.slips).map((s) => s.id), [slipId]);
      final (other, _) = r.importBill(slip('slip-2', 'Synth Power Co', due: '2026-04-20'));
      expect(suggestBillCategory(r.bill(other)!, recurring: r.recurringBills(), txs: const [], payeeAliases: r.payeeAliases()),
          'Bills & one-offs');
    });

    test('linkSlipToBill refuses an unknown bill, a slip without a payee and an unknown or income recurring', () {
      expect(() => r.linkSlipToBill('bill:none', recurring), throwsArgumentError);
      final (noPayee, _) = r.importBill(const NormalizedBill(source: BillSource.hub3, externalId: 'slip-np', total: 100));
      expect(() => r.linkSlipToBill(noPayee, recurring), throwsArgumentError);
      expect(() => r.linkSlipToBill(slipId, 'r-none'), throwsArgumentError);
      final income = r.addRecurring(
          label: 'Synth pay',
          category: 'Extra income',
          amount: 100,
          intervalDays: 30,
          firstDue: '2026-03-25',
          payee: 'synth_payer',
          direction: 'in');
      expect(() => r.linkSlipToBill(slipId, income), throwsArgumentError);
      expect(r.payeeAliases(), isEmpty);
    });

    test('a slip already spelled like the bill only drops an alias it had', () {
      final (same, _) = r.importBill(slip('slip-3', 'Synth Energy'));
      r.setPayeeAlias(energy, 'synth_elsewhere');
      r.linkSlipToBill(same, recurring);
      expect(r.payeeAliases(), isEmpty);
    });
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    var now = 0;
    final devices = <Device>[];
    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
      devices.add(d);
      return d;
    }

    Future<void> round(Net net) async {
      for (final d in devices) {
        now += 1000;
        d.deliver(net, Random(1));
        await d.run();
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-kl3-');
      key = VaultKey.generate();
      devices.clear();
      now = DateTime.utc(2026, 3, 16, 12).millisecondsSinceEpoch;
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      tmp.deleteSync(recursive: true);
    });

    test('an alias set on A reaches B; the same alias set on both is one row; a remove syncs', () async {
      final net = Net();
      final a = device('a'), b = device('b');
      a.repo.setPayeeAlias(power, energy);
      now += 10;
      b.repo.setPayeeAlias(power, energy);
      await round(net);
      await round(net);
      for (final d in [a, b]) {
        expect(d.repo.payeeAliases(), {power: energy}, reason: d.name);
        expect(d.repo.db.select('SELECT COUNT(*) AS n FROM payee_aliases').first['n'], 1, reason: d.name);
      }
      b.repo.removePayeeAlias(power);
      await round(net);
      await round(net);
      expect(a.repo.payeeAliases(), isEmpty);
    });
  });
}
