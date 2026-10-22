// Bank profiles: the refactor into profiles changed nothing about what the importer produces. The golden files in
// test/fixtures/golden/ were captured at commit d632e32 (before the refactor) from the SYNTHETIC fixtures in
// test/fixtures/ with importBankFile(...).toJson(); regenerate them only for a deliberate contract change.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_importer/src/csv_reader.dart';
import 'package:wallet_importer/src/xls_reader.dart';
import 'package:wallet_importer/src/xlsx_reader.dart';
import 'package:wallet_importer/wallet_importer.dart';

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

Map<String, Object?> golden(String name) =>
    jsonDecode(File('test/fixtures/golden/${name.replaceAll('.', '_')}.json').readAsStringSync()) as Map<String, Object?>;

/// The rows of a fixture, as importBankFile reads them.
List<List<Object>> rowsOf(String name) {
  final bytes = fixture(name);
  return switch (name.split('.').last) {
    'xls' => XlsReader.firstSheet(bytes),
    'xlsx' => XlsxReader.firstSheet(bytes),
    _ => readCsv(utf8.decode(bytes), strict: true),
  };
}

/// The v1 fields of a transaction: what the golden files hold.
Map<String, Object?> v1View(NormalizedTransaction t) => {
      'v': 1,
      'id': t.id,
      'source': t.source,
      'date': t.date,
      'amountMinor': t.amountMinor,
      'currency': t.currency,
      'bankType': t.bankType,
      'description': t.description,
    };

const fixtures = {'pbz_synthetic.xls': 'pbz', 'revolut_synthetic.xlsx': 'revolut', 'revolut_synthetic.csv': 'revolut'};

/// A bank the registry does not know, to check the base class on its own.
class _TestProfile extends BankProfile {
  const _TestProfile();
  @override
  String get id => 'testbank';
  @override
  String get label => 'Test Bank';
  @override
  bool detect(ImportContext ctx) => ctx.head.isNotEmpty && ctx.head.first.contains('When');
  @override
  void prepare(ImportContext ctx) {
    ctx.firstRow = 1;
    ctx.columns['When'] = ctx.head.first.indexOf('When');
    ctx.columns['How much'] = ctx.head.first.indexOf('How much');
    ctx.columns['What'] = ctx.head.first.indexOf('What');
  }

  @override
  RowResult mapRow(List<Object> row, ImportContext ctx) {
    final text = row[ctx.column('What')].toString();
    if (text == 'hold') return const RowResult.skipped();
    if (text == 'blank') return const RowResult.ignored();
    final cents = int.tryParse(row[ctx.column('How much')].toString());
    if (cents == null) return const RowResult.invalid();
    final date = row[ctx.column('When')].toString();
    return RowResult.transaction(NormalizedTransaction(
      id: ctx.sourceId(id, date, cents, text),
      source: id,
      date: date,
      amountMinor: cents,
      currency: 'EUR',
      bankType: '',
      description: text,
      kindHint: TxKind.other,
    ));
  }
}

void main() {
  group('no behaviour change against the golden files from d632e32', () {
    for (final MapEntry(key: name, value: source) in fixtures.entries) {
      test(name, () {
        final g = golden(name);
        final b = importBankFile(fixture(name));
        expect(b.source, source);
        expect(b.source, g['source']);
        expect(b.skipped, g['skipped']);
        expect(b.invalid, g['invalid']);
        expect(b.transactions.map(v1View).toList(), g['transactions']);
        expect(b.transactions.map(v1View).toList(), isNotEmpty);
      });
    }

    test('toJson keeps the v1 shape when no hint is set and adds kindHint and account only when they are', () {
      const t = NormalizedTransaction(
          id: 'x', source: 'pbz', date: '2026-01-01', amountMinor: -100, currency: 'EUR', bankType: 'T', description: 'd');
      expect(t.toJson().keys, ['v', 'id', 'source', 'date', 'amountMinor', 'currency', 'bankType', 'description']);
      const h = NormalizedTransaction(
          id: 'x',
          source: 'pbz',
          date: '2026-01-01',
          amountMinor: -100,
          currency: 'EUR',
          bankType: 'T',
          description: 'd',
          kindHint: TxKind.atm,
          account: 'A');
      expect(h.toJson()['kindHint'], 'atm');
      expect(h.toJson()['account'], 'A');
    });

    test('the unknown-layout message still names every bank, from their labels', () {
      expect(unknownLayoutMessage, contains('I recognise'));
      for (final p in bankProfiles) {
        expect(unknownLayoutMessage, contains(p.label));
      }
      expect(() => importBankFile(Uint8List.fromList('hello,world\n1,2\n'.codeUnits)),
          throwsA(isA<ImportException>().having((e) => e.message, 'message', unknownLayoutMessage)));
    });
  });

  group('detect', () {
    test('registry holds PBZ and Revolut with distinct ids and labels', () {
      expect(bankProfiles.map((p) => p.id), containsAll(['pbz', 'revolut']));
      expect(bankProfiles.map((p) => p.label), containsAll(['PBZ', 'Revolut']));
      expect(bankProfiles.map((p) => p.id).toSet().length, bankProfiles.length);
      expect(bankProfiles.map((p) => p.label).toSet().length, bankProfiles.length);
    });

    for (final MapEntry(key: name, value: source) in fixtures.entries) {
      test('$name: exactly one profile, $source, accepts it', () {
        final ctx = ImportContext.of(rowsOf(name), format: name.split('.').last, fileName: name);
        expect([
          for (final p in bankProfiles)
            if (p.detect(ctx)) p.id
        ], [
          source
        ]);
        expect(ctx.firstRow, 0, reason: 'detect must not change the context');
        expect(ctx.columns, isEmpty, reason: 'detect must not change the context');
      });
    }

    test('a foreign file: nothing detects it, parseRows gives null', () {
      final rows = readCsv('hello,world\n1,2\n', strict: true);
      final ctx = ImportContext.of(rows, format: 'csv');
      expect([
        for (final p in bankProfiles)
          if (p.detect(ctx)) p.id
      ], isEmpty);
      expect(parseRows(rows), isNull);
    });

    test('the head is the first $headRows rows as trimmed text', () {
      final ctx = ImportContext.of([
        [' a ', 1.0, 2.5],
        for (var i = 0; i < 20; i++) ['r$i'],
      ]);
      expect(ctx.head.length, headRows);
      expect(ctx.head.first, ['a', '1', '2.5']);
    });
  });

  group('kindHint and account (additive, from what each profile knows)', () {
    test('PBZ: type gives the kind, a POS payment to Revolut is an own transfer, the IBAN under the label is the account', () {
      final b = importBankFile(fixture('pbz_synthetic.xls'));
      TxKind? kind(String desc) => b.transactions.firstWhere((t) => t.description.startsWith(desc)).kindHint;
      expect(kind('Neto plaća'), TxKind.salary);
      expect(kind('PBZ ATM'), TxKind.atm);
      expect(kind('POS Revolut'), TxKind.ownTransfer);
      expect(kind('PBZ POS'), TxKind.card);
      expect(kind('Naplata kredita'), TxKind.standingOrder);
      expect(kind('Naknada'), TxKind.fee);
      expect(kind('VAL_'), TxKind.other);
      expect(kind('Plaćanje po računu'), TxKind.other);
      expect(b.transactions.map((t) => t.account).toSet(), {'HR0000000000000000000'});
    });

    test('PBZ: an unknown type gives no hint; no account label, no account', () {
      final b = parseRows([
        ['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'],
        [46037.0, 'Nešto novo', 'x', -1.0, 'EUR'],
        [46037.0, 'Isplata u poslovnici', 'y', -1.0, 'EUR'],
      ])!;
      expect(b.transactions.map((t) => t.kindHint), [null, TxKind.other]);
      expect(b.transactions.map((t) => t.account), [null, null]);
    });

    test('Revolut: card payments, top-ups as own transfers, transfers other; Product is the account', () {
      final b = importBankFile(fixture('revolut_synthetic.xlsx'));
      expect(b.transactions.map((t) => (t.bankType, t.kindHint)).toSet(), {
        ('Topup', TxKind.ownTransfer),
        ('Card Payment', TxKind.card),
        ('Transfer', TxKind.other),
      });
      expect(b.transactions.map((t) => t.account).toSet(), {'Current'});
      final csv = importBankFile(fixture('revolut_synthetic.csv'));
      expect(csv.transactions.map((t) => t.kindHint), [TxKind.card, TxKind.ownTransfer]);
    });

    test('Revolut: fees, ATM, exchange and refunds; unknown types give no hint; no Product column, no account', () {
      final b = parseRows([
        ['Type', 'Started Date', 'Description', 'Amount', 'Fee', 'State'],
        ['Fee', '2026-01-01', 'a', -1.0, 0.0, 'COMPLETED'],
        ['ATM', '2026-01-01', 'b', -1.0, 0.0, 'COMPLETED'],
        ['Exchange', '2026-01-01', 'c', -1.0, 0.0, 'COMPLETED'],
        ['Card Refund', '2026-01-01', 'd', 1.0, 0.0, 'COMPLETED'],
        ['Something Else', '2026-01-01', 'e', 1.0, 0.0, 'COMPLETED'],
      ])!;
      expect(b.transactions.map((t) => t.kindHint), [TxKind.fee, TxKind.atm, TxKind.exchange, TxKind.card, null]);
      expect(b.transactions.map((t) => t.account), everyElement(isNull));
    });
  });

  group('ids', () {
    test('PBZ and Revolut rows carry v1 ids (transactionId), never source-hashed ones', () {
      for (final name in fixtures.keys) {
        final seen = <String, int>{};
        for (final t in importBankFile(fixture(name)).transactions) {
          final key = '${t.date}|${t.amountMinor}|${t.description}';
          final n = seen[key] ?? 0;
          seen[key] = n + 1;
          expect(t.id, transactionId(t.date, t.amountMinor, t.description, n), reason: '$name ${t.date}');
        }
      }
    });

    test('sourceTransactionId: same shape as v1 ids, differs by source, stable, numbered for identical rows', () {
      final a = sourceTransactionId('banka', '2026-01-03', -1450, 'Wolt', 0);
      final b = sourceTransactionId('bankb', '2026-01-03', -1450, 'Wolt', 0);
      expect(a, matches(RegExp(r'^260103[0-9a-z]+$')));
      expect(a, isNot(b));
      expect(a, isNot(transactionId('2026-01-03', -1450, 'Wolt', 0)));
      expect(sourceTransactionId('banka', '2026-01-03', -1450, 'Wolt', 0), a);
      expect(sourceTransactionId('banka', '2026-01-03', -1450, 'Wolt', 2), '${a}_2');
    });

    test('ImportContext numbers identical rows in file order, separately per (date, amount, description)', () {
      final ctx = ImportContext(head: const []);
      expect(ctx.v1Id('2026-01-03', -1450, 'Wolt'), transactionId('2026-01-03', -1450, 'Wolt', 0));
      expect(ctx.v1Id('2026-01-03', -1450, 'Wolt'), transactionId('2026-01-03', -1450, 'Wolt', 1));
      expect(ctx.v1Id('2026-01-03', -1450, 'Other'), transactionId('2026-01-03', -1450, 'Other', 0));
      expect(ctx.sourceId('x', '2026-01-03', -1450, 'Wolt'), sourceTransactionId('x', '2026-01-03', -1450, 'Wolt', 2));
    });
  });

  group('BankProfile base class', () {
    test('parse runs prepare, starts at firstRow and counts skipped and invalid rows, ignored ones not at all', () {
      const p = _TestProfile();
      final rows = <List<Object>>[
        ['When', 'How much', 'What'],
        ['2026-01-01', '-100', 'coffee'],
        ['2026-01-01', '-100', 'coffee'],
        ['2026-01-02', 'x', 'broken'],
        ['2026-01-03', '-5', 'hold'],
        ['', '', 'blank'],
      ];
      final ctx = ImportContext.of(rows, format: 'csv');
      expect(p.detect(ctx), isTrue);
      final b = p.parse(rows, ctx);
      expect(b.source, 'testbank');
      expect((b.skipped, b.invalid), (1, 1));
      expect(b.transactions.map((t) => t.id).toList(), [
        sourceTransactionId('testbank', '2026-01-01', -100, 'coffee', 0),
        sourceTransactionId('testbank', '2026-01-01', -100, 'coffee', 1),
      ]);
      expect(b.transactions.first.kindHint, TxKind.other);
    });

    test('a profile outside the registry is not consulted by parseRows', () {
      expect(
          parseRows([
            ['When', 'How much', 'What'],
            ['2026-01-01', '-100', 'coffee']
          ]),
          isNull);
    });
  });
}
