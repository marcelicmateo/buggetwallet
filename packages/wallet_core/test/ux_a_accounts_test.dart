// Stage UX-A core, point 3 (docs/context/UX_SPEC.md): account kinds, institution, schema 20 migration, updateAccount.
// Written from the spec, not the implementation. All data SYNTHETIC.
//
// Assumed signatures (spec names): addAccount(..., kind:, institution:), updateAccount(id, name:, kind:, institution:,
// source:, clearSource:), Account.kind / Account.institution.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

const _t = Timeout(Duration(seconds: 30));

/// 2026-10-10 00:00 UTC in ms.
const _now = 1791590400000;

void main() {
  late WalletRepo repo;
  setUp(() => repo = WalletRepo.inMemory(now: () => _now));
  tearDown(() => repo.close());

  Future<String> add(
          {String name = 'Acc',
          String? source,
          String currency = 'EUR',
          AccountKind kind = AccountKind.cash,
          String? institution,
          int opening = 1000}) =>
      repo.addAccount(
          name: name,
          source: source,
          currency: currency,
          opening: opening,
          openingDate: '2026-09-30',
          kind: kind,
          institution: institution);

  Account byId(String id) => repo.accounts().firstWhere((a) => a.id == id);

  test('schema version is at least 20', () {
    expect(WalletRepo.schemaVersion, greaterThanOrEqualTo(20));
  }, timeout: _t);

  group('kinds', () {
    test('every kind with its allowed shape is stored as given; isCash only for cash', () async {
      final cash = await add(name: 'Wallet');
      final bank = await add(name: 'Main', kind: AccountKind.bank, source: 'pbz', institution: 'Synthetic Bank');
      final card = await add(name: 'Card', kind: AccountKind.card, source: 'revolut');
      final sav = await add(name: 'Savings', kind: AccountKind.savings, source: 'pbz', currency: 'USD');
      final inv = await add(name: 'Broker', kind: AccountKind.investment, institution: 'Synthetic Broker');
      final cry = await add(name: 'Coins', kind: AccountKind.crypto, currency: 'BTC', opening: 250000000);
      final oth = await add(name: 'Other', kind: AccountKind.other, currency: 'GBP');
      expect(byId(cash).kind, AccountKind.cash);
      expect(byId(cash).isCash, isTrue);
      for (final id in [bank, card, sav, inv, cry, oth]) {
        expect(byId(id).isCash, isFalse, reason: byId(id).name);
      }
      expect(byId(bank).institution, 'Synthetic Bank');
      expect(byId(bank).source, 'pbz');
      expect(byId(card).kind, AccountKind.card);
      expect(byId(cry).currency, 'BTC');
      expect(byId(cry).opening, 250000000, reason: 'crypto balance is in its own minor units');
      expect(byId(card).institution, isNull);
    }, timeout: _t);

    test('a source (import format) is refused for cash, investment, crypto and other', () async {
      for (final (k, cur) in [
        (AccountKind.cash, 'EUR'),
        (AccountKind.investment, 'EUR'),
        (AccountKind.crypto, 'BTC'),
        (AccountKind.other, 'EUR'),
      ]) {
        expect(() => add(kind: k, source: 'pbz', currency: cur), throwsArgumentError, reason: k.name);
      }
      expect(repo.accounts(), isEmpty, reason: 'refusals write nothing');
    }, timeout: _t);

    test('a source is allowed for bank, card and savings', () async {
      await add(name: 'a', kind: AccountKind.bank, source: 'pbz');
      await add(name: 'b', kind: AccountKind.card, source: 'revolut');
      await add(name: 'c', kind: AccountKind.savings, source: 'pbz', currency: 'USD');
      expect(repo.accounts(), hasLength(3));
    }, timeout: _t);

    test('crypto refuses a fiat currency, and accepts BTC', () async {
      expect(() => add(kind: AccountKind.crypto, currency: 'EUR'), throwsArgumentError);
      expect(() => add(kind: AccountKind.crypto, currency: 'USD'), throwsArgumentError);
      expect(repo.accounts(), isEmpty);
      await add(kind: AccountKind.crypto, currency: 'BTC');
      expect(repo.accounts(), hasLength(1));
    }, timeout: _t);

    test('a fiat kind with the crypto currency BTC is allowed only as crypto: bank in BTC is refused', () async {
      expect(() => add(kind: AccountKind.bank, source: 'pbz', currency: 'BTC'), throwsArgumentError);
      expect(() => add(kind: AccountKind.cash, currency: 'BTC'), throwsArgumentError);
    }, timeout: _t, skip: 'AMBIGUOUS: spec only says crypto needs a crypto currency, not the reverse');
  });

  group('updateAccount', () {
    test('round-trips name, kind, institution and source', () async {
      final id = await add(name: 'Old', kind: AccountKind.bank, source: 'pbz', institution: 'A');
      await _run(() => repo.updateAccount(id, name: '  New  ', kind: AccountKind.savings, institution: 'B'));
      final a = byId(id);
      expect((a.name, a.kind, a.institution, a.source), ('New', AccountKind.savings, 'B', 'pbz'));
    }, timeout: _t);

    test('clearSource drops the source; changing to a kind that forbids a source without clearing is refused', () async {
      final id = await add(kind: AccountKind.bank, source: 'pbz');
      expect(() => _run(() => repo.updateAccount(id, kind: AccountKind.cash)), throwsArgumentError, reason: 'cash with source pbz');
      expect(byId(id).kind, AccountKind.bank, reason: 'refused update changes nothing');
      await _run(() => repo.updateAccount(id, kind: AccountKind.cash, clearSource: true));
      final a = byId(id);
      expect((a.kind, a.source, a.isCash), (AccountKind.cash, null, true));
    }, timeout: _t);

    test('refusals: unknown id, crypto on a fiat account, source on investment, empty name', () async {
      final id = await add(kind: AccountKind.bank, source: 'pbz');
      expect(() => _run(() => repo.updateAccount('nope', name: 'x')), throwsArgumentError);
      expect(() => _run(() => repo.updateAccount(id, kind: AccountKind.crypto, clearSource: true)), throwsArgumentError);
      expect(() => _run(() => repo.updateAccount(id, kind: AccountKind.investment)), throwsArgumentError);
      expect(() => _run(() => repo.updateAccount(id, name: '   ')), throwsArgumentError);
      final a = byId(id);
      expect((a.kind, a.source, a.name), (AccountKind.bank, 'pbz', 'Acc'));
    }, timeout: _t);

    test('an update that changes nothing writes no op', () async {
      final id = await add(name: 'Same', kind: AccountKind.bank, source: 'pbz');
      final before = repo.pendingOps().length;
      await _run(() => repo.updateAccount(id, name: 'Same'));
      expect(repo.pendingOps().length, before);
    }, timeout: _t);

    test('one live (source, currency) per bank still holds when a kind changes', () async {
      await add(name: 'One', kind: AccountKind.bank, source: 'pbz');
      final cash = await add(name: 'Cash');
      expect(() => _run(() => repo.updateAccount(cash, kind: AccountKind.bank, source: 'pbz')), throwsArgumentError);
    }, timeout: _t);
  });

  group('migration from schema 19', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('bw-uxa-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('source null becomes cash, any source becomes bank; institution stays empty', () async {
      final path = '${tmp.path}/old.db';
      final r = WalletRepo.open(path, now: () => _now);
      await add0(r, 'Wallet', null);
      await add0(r, 'Main', 'pbz');
      await add0(r, 'Rev', 'revolut');
      r.close();
      final db = sqlite3.open(path);
      for (final c in ['kind', 'institution']) {
        if (db.select('PRAGMA table_info(accounts)').any((x) => x['name'] == c)) db.execute('ALTER TABLE accounts DROP COLUMN $c');
      }
      db.execute("UPDATE meta SET value = '19' WHERE key = 'schema'");
      db.close();

      final again = WalletRepo.open(path, now: () => _now);
      addTearDown(again.close);
      final m = {for (final a in again.accounts()) a.name: a};
      expect(m['Wallet']!.kind, AccountKind.cash);
      expect(m['Wallet']!.isCash, isTrue);
      expect(m['Main']!.kind, AccountKind.bank);
      expect(m['Rev']!.kind, AccountKind.bank);
      expect(m['Main']!.source, 'pbz');
      expect(m['Main']!.institution, isNull);
      expect(again.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '${WalletRepo.schemaVersion}');
    }, timeout: _t);

    test('balances of migrated accounts are unchanged', () async {
      final path = '${tmp.path}/old2.db';
      final r = WalletRepo.open(path, now: () => _now);
      await add0(r, 'Main', 'pbz');
      final before = r.accounts().single.opening;
      r.close();
      final db = sqlite3.open(path);
      for (final c in ['kind', 'institution']) {
        if (db.select('PRAGMA table_info(accounts)').any((x) => x['name'] == c)) db.execute('ALTER TABLE accounts DROP COLUMN $c');
      }
      db.execute("UPDATE meta SET value = '19' WHERE key = 'schema'");
      db.close();
      final again = WalletRepo.open(path, now: () => _now);
      addTearDown(again.close);
      expect(again.accounts().single.opening, before);
    }, timeout: _t);
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    final devices = <Device>[];

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
          d.upload(net);
        }
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-uxa-sync-');
      key = VaultKey.generate();
      net = Net();
    });
    tearDown(() {
      for (final d in devices) {
        d.repo.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });

    test('kind, institution and an update reach the other device', () async {
      final a = device('a'), b = device('b');
      final id = await a.repo.addAccount(
          name: 'Main', source: 'pbz', currency: 'EUR', opening: 500, openingDate: '2026-09-30', kind: AccountKind.bank, institution: 'X');
      await syncAll([a, b]);
      var got = b.repo.accounts().single;
      expect((got.kind, got.institution, got.source), (AccountKind.bank, 'X', 'pbz'));
      await _run(() => b.repo.updateAccount(id, kind: AccountKind.savings, institution: 'Y'));
      await syncAll([a, b]);
      got = a.repo.accounts().single;
      expect((got.kind, got.institution), (AccountKind.savings, 'Y'));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

Future<void> add0(WalletRepo r, String name, String? source) =>
    r.addAccount(name: name, source: source, currency: 'EUR', opening: 12345, openingDate: '2026-09-30');

/// Runs a call that may be sync (void) or async (Future) and awaits it.
Future<void> _run(FutureOr<void> Function() f) async {
  await f();
}
