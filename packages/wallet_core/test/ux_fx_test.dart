// UX-FX (docs/context/UX_SPEC.md "UX-FX"): ECB daily rates per payment date. Parser (CSV, XML, zip; damaged files),
// lookup (latest ECB day within 7 days), exact conversion, hand rate precedence, needs, cache + fx_day rows, fetch
// plan, two devices. Rates are the ECB's published reference values of 4 and 8 January 1999 (USD, JPY, GBP, in the
// file's own format); every wallet amount is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

const _t = Timeout(Duration(seconds: 60));
const _now = 1791590400000; // 2026-10-10

/// The ECB history CSV shape (newest first, trailing comma, N/A for a missing value). 1999-01-08 is a Friday.
const _csv = 'Date,USD,JPY,GBP,ISK,\n'
    '1999-01-08,1.1659,130.09,0.7094,N/A,\n'
    '1999-01-04,1.1789,133.73,0.71110,N/A,\n';

/// The same days as the ECB's XML files (`eurofxref-hist-90d.xml` shape).
const _xml = '''<?xml version="1.0" encoding="UTF-8"?>
<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
	<gesmes:subject>Reference rates</gesmes:subject>
	<gesmes:Sender>
		<gesmes:name>European Central Bank</gesmes:name>
	</gesmes:Sender>
	<Cube>
		<Cube time="1999-01-08">
			<Cube currency="USD" rate="1.1659"/>
			<Cube currency="JPY" rate="130.09"/>
			<Cube currency="GBP" rate="0.7094"/>
		</Cube>
		<Cube time="1999-01-04">
			<Cube currency="USD" rate="1.1789"/>
			<Cube currency="JPY" rate="133.73"/>
			<Cube currency="GBP" rate="0.71110"/>
		</Cube>
	</Cube>
</gesmes:Envelope>
''';

List<int> _zip(String name, String text) => ZipEncoder().encodeBytes(Archive()..add(ArchiveFile.string(name, text)));

final _expected = {
  'USD': {'1999-01-08': 1165900, '1999-01-04': 1178900},
  'JPY': {'1999-01-08': 130090000, '1999-01-04': 133730000},
  'GBP': {'1999-01-08': 709400, '1999-01-04': 711100},
};

EcbRates _rates() => EcbRates([
      for (final MapEntry(key: c, value: m) in _expected.entries)
        for (final MapEntry(key: d, value: p) in m.entries) FxDay(c, d, p)
    ]);

Tx _row(String date, int amount, String currency, {String id = 'r'}) =>
    Tx(id: id, source: 'pbz', date: date, amount: amount, currency: currency);

void main() {
  group('parseEcbRates', () {
    test('the history CSV, its zip and the XML give the same exact rates; N/A is no value', () {
      for (final bytes in [utf8.encode(_csv), _zip('eurofxref-hist.csv', _csv), utf8.encode(_xml), _zip('x.xml', _xml)]) {
        final h = parseEcbRates(bytes);
        expect(h.rates, _expected);
        expect((h.days, h.oldest, h.newest), (2, '1999-01-04', '1999-01-08'));
        expect(h.currencies, ['GBP', 'JPY', 'USD']);
      }
    });

    test('the daily CSV dates ("04 January 1999") and a BOM are read', () {
      final h = parseEcbRates(utf8.encode('﻿Date, USD, JPY, \n04 January 1999, 1.1789, 133.73, \n'));
      expect(h.rates, {
        'USD': {'1999-01-04': 1178900},
        'JPY': {'1999-01-04': 133730000}
      });
    });

    test('damaged, cut or foreign files are refused', () {
      final cutCsv = _csv.substring(0, _csv.length - 6); // inside the last row
      final cutXml = _xml.substring(0, _xml.length - 40);
      final zip = _zip('eurofxref-hist.csv', _csv);
      final cases = <String, List<int>>{
        'cut CSV row': utf8.encode(cutCsv),
        'cut XML': utf8.encode(cutXml),
        'cut zip': zip.sublist(0, zip.length - 10),
        'zip, flipped byte': [...zip]..[zip.length ~/ 2] ^= 0xff,
        'garbage': [0, 1, 2, 3, 250, 251],
        'empty': const [],
        'other CSV': utf8.encode('Datum,Iznos\n2026-01-01,5\n'),
        'bad value': utf8.encode('Date,USD,\n1999-01-04,1.17x9,\n'),
        'zero rate': utf8.encode('Date,USD,\n1999-01-04,0,\n'),
        'bad date': utf8.encode('Date,USD,\n1999-02-30,1.1,\n'),
        'too many decimals': utf8.encode('Date,USD,\n1999-01-04,1.1234567,\n'),
        'two values one day': utf8.encode('Date,USD,\n1999-01-04,1.1,\n1999-01-04,1.2,\n'),
        'no rates': utf8.encode('Date,USD,\n'),
        'zip without a rates file': _zip('readme.txt', 'x'),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(() => parseEcbRates(value), throwsFormatException, reason: key);
      }
      expect(parseEcbRates(utf8.encode('Date,USD,\n1999-01-04,1.1789000,\n')).rates['USD'], {'1999-01-04': 1178900},
          reason: 'trailing zeros past 6 decimals are exact');
    });
  });

  group('conversion per payment date', () {
    final eur = WalletSettings(ecb: _rates());
    final usd = WalletSettings(currency: 'USD', ecb: _rates());

    test('known ECB values: USD, JPY, GBP into EUR; EUR and GBP into a USD wallet; exact, rounded once', () {
      expect(homeAmount(_row('1999-01-04', 10000, 'USD'), eur), 8482); // 100 USD / 1.1789
      expect(homeAmount(_row('1999-01-04', -10000, 'USD'), eur), -8482);
      expect(homeAmount(_row('1999-01-04', 1000000, 'JPY'), eur), 7478); // 10,000 JPY / 133.73
      expect(homeAmount(_row('1999-01-04', 5000, 'GBP'), eur), 7031); // 50 GBP / 0.7111
      expect(homeAmount(_row('1999-01-04', 10000, 'EUR'), usd), 11789);
      expect(homeAmount(_row('1999-01-04', 5000, 'GBP'), usd), 8289); // 50 × 1.1789 / 0.7111
      expect(homeAmount(_row('1999-01-04', 100, 'EUR'), WalletSettings(currency: 'JPY', ecb: _rates())), 13373);
      expect(fxUsed(_row('1999-01-04', 1, 'USD'), eur), const FxUsed(ecb: true, date: '1999-01-04'));
    });

    test('ecbConvert rounds half away from zero, also negative, and scales storage digits', () {
      expect(ecbConvert(5, perFrom: 2000000, perTo: 1000000), 3);
      expect(ecbConvert(-5, perFrom: 2000000, perTo: 1000000), -3);
      expect(ecbConvert(4, perFrom: 3000000, perTo: 1000000), 1);
      expect(ecbConvert(100, perFrom: 1000000, perTo: 1000000, fromDigits: 2, toDigits: 8), 100000000);
      expect(() => ecbConvert(1, perFrom: 0, perTo: 1), throwsArgumentError);
    });

    test('weekend and holiday fallback to the latest ECB day within 7 days; an 8-day gap is not counted', () {
      expect(homeAmount(_row('1999-01-10', 10000, 'USD'), eur), 8577, reason: 'Sunday -> Friday 8 Jan');
      expect(homeAmount(_row('1999-01-07', 10000, 'USD'), eur), 8482, reason: 'no row that day -> 4 Jan');
      expect(fxUsed(_row('1999-01-15', 1, 'USD'), eur)?.date, '1999-01-08', reason: '7 days');
      expect(homeAmount(_row('1999-01-16', 10000, 'USD'), eur), isNull, reason: '8 days');
      expect(homeAmount(_row('1999-01-03', 10000, 'USD'), eur), isNull, reason: 'before the first day');
      expect(homeAmount(_row('1999-01-04', 10000, 'CHF'), eur), isNull, reason: 'a currency the file has not');
      expect(homeAmount(_row('1999-01-04', 10000, 'ISK'), eur), isNull, reason: 'N/A');
    });

    test('a hand-set rate wins over the ECB; BTC is hand-set only', () {
      final st = WalletSettings(fxRates: {'USD': const FxRate(900000, '2026-10-01', home: 'EUR')}, ecb: _rates());
      expect(homeAmount(_row('1999-01-04', 10000, 'USD'), st), 9000);
      expect(fxUsed(_row('1999-01-04', 1, 'USD'), st), const FxUsed(ecb: false, date: '2026-10-01'));
      expect(homeAmount(_row('1999-01-04', 100000000, 'BTC'), eur), isNull);
    });

    test('inHomeCurrency converts each row at its own date', () {
      final rows = [
        CategorizedTx(_row('1999-01-04', -10000, 'USD', id: 'a'), 'Groceries', BudgetKind.flex),
        CategorizedTx(_row('1999-01-08', -10000, 'USD', id: 'b'), 'Groceries', BudgetKind.flex),
        CategorizedTx(_row('1999-01-30', -10000, 'USD', id: 'c'), 'Groceries', BudgetKind.flex),
      ];
      final got = inHomeCurrency(rows, eur);
      expect([for (final r in got) (r.tx.currency, r.amount)], [('EUR', -8482), ('EUR', -8577), ('USD', -10000)]);
    });
  });

  group('fxNeeds', () {
    test('foreign fiat amounts without a hand rate, unique and sorted; not the wallet currency, BTC or bad dates', () {
      const st = WalletSettings(fxRates: {'CHF': FxRate(1000000, '2026-10-01', home: 'EUR')});
      final got = fxNeeds([
        ('USD', '2026-10-02'),
        ('USD', '2026-10-02'),
        ('EUR', '2026-10-02'),
        ('CHF', '2026-10-02'),
        ('BTC', '2026-10-02'),
        ('GBP', null),
        ('GBP', '2026-13-01'),
        ('GBP', '2026-10-01'),
      ], st);
      expect(got, const [FxNeed('GBP', '2026-10-01'), FxNeed('USD', '2026-10-02')]);
    });
  });

  group('repo', () {
    late WalletRepo repo;
    setUp(() => repo = WalletRepo.inMemory(now: () => _now));
    tearDown(() => repo.close());

    void seed(WalletRepo r) {
      r.addTransaction(date: '1999-01-10', amount: 10000, category: 'Groceries', currency: 'USD');
      r.addTransaction(date: '1999-01-04', amount: 5000, category: 'Groceries', currency: 'GBP');
      r.addTransaction(date: '1999-01-05', amount: 700, category: 'Groceries');
    }

    test('import: the cache holds the file, fx_day rows only what the wallet needs; settings() converts by them', () {
      seed(repo);
      final ops = repo.pendingOps().length;
      final got = repo.importEcbHistory(_zip('eurofxref-hist.csv', _csv));
      expect((got.days, got.currencies, got.oldest, got.newest, got.written), (2, 3, '1999-01-04', '1999-01-08', 2));
      expect(repo.db.select('SELECT COUNT(*) AS n FROM ecb_rates').first['n'], 6);
      final fx = [for (final r in repo.db.select('SELECT id, cur, date, per_eur, source FROM fx_days ORDER BY id')) r.values];
      expect(fx, [
        ['GBP:1999-01-04', 'GBP', '1999-01-04', 711100, 'ecb'],
        ['USD:1999-01-08', 'USD', '1999-01-08', 1165900, 'ecb'],
      ]);
      expect(repo.pendingOps().length, ops + 2, reason: 'fx_day rows are synced ops; the cache is not');
      final st = repo.settings();
      final usd = repo.transactions().firstWhere((t) => t.currency == 'USD');
      expect(homeAmount(usd, st), -8577);
      expect(repo.fxMissing(), isEmpty);
      expect(repo.fillFxDays(), 0, reason: 'nothing left to write');
      expect(repo.ecbCacheInfo().importedOn, '2026-10-10');
    });

    test('needs come from payments, bills, IOUs and openings; a damaged download writes nothing', () async {
      seed(repo);
      await repo.addAccount(name: 'US', source: 'revolut', currency: 'USD', opening: 100, openingDate: '1999-01-06');
      expect(repo.walletFxNeeds(), const [FxNeed('GBP', '1999-01-04'), FxNeed('USD', '1999-01-06'), FxNeed('USD', '1999-01-10')]);
      final ops = repo.pendingOps().length;
      for (final bad in [utf8.encode(_csv.substring(0, _csv.length - 6)), _zip('a.csv', _csv).sublist(0, 30)]) {
        expect(() => repo.importEcbHistory(bad), throwsFormatException);
      }
      expect(repo.db.select('SELECT COUNT(*) AS n FROM ecb_rates').first['n'], 0);
      expect(repo.db.select('SELECT COUNT(*) AS n FROM fx_days').first['n'], 0);
      expect(repo.pendingOps().length, ops);
      expect(repo.ecbCacheInfo().importedOn, isNull);
    });

    test('fetch plan: history when empty, nothing once tried today, recent for a new date; force always', () {
      expect(repo.ecbFetchPlan(), isNull, reason: 'nothing needed');
      repo.addTransaction(date: '2026-10-08', amount: 100, category: 'Groceries', currency: 'USD');
      expect(repo.ecbFetchPlan(), EcbFile.history);
      repo.noteEcbAttempt();
      expect(repo.ecbFetchPlan(), isNull, reason: 'once a day');
      expect(repo.ecbFetchPlan(force: true), EcbFile.history);
      repo.importEcbHistory(utf8.encode('Date,USD,\n2026-10-01,1.1,\n2026-09-30,1.1,\n2026-08-01,1.1,\n'));
      expect(repo.fxMissing(), isEmpty, reason: '1 Oct is within 7 days of 8 Oct');
      repo.setLocalValue('ecbAttempt', '2026-10-09');
      repo.addTransaction(date: '2026-10-10', amount: 100, category: 'Groceries', currency: 'USD');
      expect(repo.ecbFetchPlan(), EcbFile.recent);
      repo.addTransaction(date: '2026-10-09', amount: 100, category: 'Groceries', currency: 'CHF');
      repo.addTransaction(date: '2026-09-01', amount: 100, category: 'Groceries', currency: 'CHF');
      expect(repo.ecbFetchPlan(), EcbFile.recent, reason: 'CHF inside the cached range is not published, never a reason');
      expect(repo.ecbFetchPlan(force: true), EcbFile.recent);
    });

    test('the cache is device-local: not in a backup; fx_day rows are', () async {
      seed(repo);
      repo.importEcbHistory(utf8.encode(_csv));
      final key = VaultKey(List<int>.filled(32, 5));
      final fresh = WalletRepo.inMemory(now: () => _now);
      addTearDown(fresh.close);
      await restoreBackupBytes(fresh, await backupBytes(repo, key), key);
      expect(fresh.db.select('SELECT COUNT(*) AS n FROM ecb_rates').first['n'], 0);
      expect(fresh.db.select('SELECT COUNT(*) AS n FROM fx_days').first['n'], 2);
      expect(homeAmount(fresh.transactions().firstWhere((t) => t.currency == 'GBP'), fresh.settings()), -7031);
    });

    test('logs carry counts and outcomes only', () {
      seed(repo);
      final lines = <String>[];
      final was = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
      try {
        repo.importEcbHistory(utf8.encode(_csv));
        expect(() => repo.importEcbHistory(utf8.encode(_csv.substring(0, 40))), throwsFormatException);
        repo.ecbFetchPlan();
      } finally {
        sub.cancel();
        Logger.root.level = was;
      }
      final all = lines.where((l) => l.contains('fx.')).join('\n');
      expect(all, contains('fx.ecbImport'));
      for (final s in ['USD', 'GBP', '1.1659', '1165900', '1999-01-']) {
        expect(all, isNot(contains(s)));
      }
    });
  });

  group('two devices', () {
    late Directory tmp;
    late Net net;
    final devices = <Device>[];
    final key = VaultKey(List<int>.generate(32, (i) => 40 + i));
    var now = _now;

    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
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
      tmp = Directory.systemTemp.createTempSync('bw-uxfx-');
      net = Net();
    });
    tearDown(() {
      for (final d in devices) {
        d.repo.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });

    test('both fetch: the same fx_day rows, no conflict, the same totals', () async {
      final a = device('a'), b = device('b');
      a.repo.addTransaction(date: '1999-01-10', amount: 10000, category: 'Groceries', currency: 'USD');
      await syncAll([a, b]);
      a.repo.importEcbHistory(utf8.encode(_csv));
      now += 1000;
      b.repo.importEcbHistory(utf8.encode(_xml));
      await syncAll([a, b]);
      expect(dump(a.repo, clocks: false), dump(b.repo, clocks: false));
      expect(a.repo.syncConflicts(), isEmpty);
      expect(b.repo.syncConflicts(), isEmpty);
      for (final d in [a, b]) {
        expect(homeAmount(d.repo.transactions().single, d.repo.settings()), -8577);
      }
    }, timeout: _t);

    test('an offline device shows the payment as not counted until the rates arrive by sync', () async {
      final a = device('a'), b = device('b');
      a.repo.addTransaction(date: '1999-01-04', amount: 5000, category: 'Groceries', currency: 'GBP');
      await syncAll([a, b]);
      expect(homeAmount(b.repo.transactions().single, b.repo.settings()), isNull, reason: 'not counted yet');
      expect(b.repo.fxMissing(), const [FxNeed('GBP', '1999-01-04')]);
      a.repo.importEcbHistory(utf8.encode(_csv));
      await syncAll([a, b]);
      expect(homeAmount(b.repo.transactions().single, b.repo.settings()), -7031);
      expect(b.repo.fxMissing(), isEmpty);
      expect(b.repo.ecbCacheInfo().days, 0, reason: 'only the needed rows travel');
    }, timeout: _t);
  });
}
