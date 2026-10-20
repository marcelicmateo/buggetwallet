// Spec tests for M5 CSV export (DESIGN_DECISIONS §4.7), written from the spec only. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

const _header = 'date,amount,category,description,source,note';

CategorizedTx _tx(String id, String date, int cents,
        {String cat = 'Shopping', String desc = 'Test shop', String? note, String source = 'pbz'}) =>
    CategorizedTx(Tx(id: id, source: source, date: date, amount: cents, description: desc, category: cat, note: note), cat, kindOf(cat));

/// Minimal RFC 4180 reader for the round-trip checks.
List<List<String>> _parse(String csv) {
  final rows = <List<String>>[];
  var row = <String>[], f = StringBuffer(), q = false, any = false;
  for (var i = 0; i < csv.length; i++) {
    final c = csv[i];
    if (q) {
      if (c == '"') {
        if (i + 1 < csv.length && csv[i + 1] == '"') {
          f.write('"');
          i++;
        } else {
          q = false;
        }
      } else {
        f.write(c);
      }
    } else if (c == '"') {
      q = true;
      any = true;
    } else if (c == ',') {
      row.add(f.toString());
      f = StringBuffer();
      any = true;
    } else if (c == '\n') {
      row.add(f.toString());
      rows.add(row);
      row = [];
      f = StringBuffer();
      any = false;
    } else {
      f.write(c);
      any = true;
    }
  }
  if (any) {
    row.add(f.toString());
    rows.add(row);
  }
  return rows;
}

void main() {
  group('transactionsCsv', () {
    test('empty list is the header only', () {
      expect(transactionsCsv(const []), anyOf('$_header\n', _header));
      expect(transactionsCsv(const []).startsWith(_header), isTrue);
    });

    test('LF only, no BOM, header first', () {
      final s = transactionsCsv([_tx('a', '2026-01-02', -100)]);
      expect(s.codeUnitAt(0), isNot(0xFEFF));
      expect(s.startsWith('$_header\n'), isTrue);
      expect(s.contains('\r'), isFalse);
    });

    test('exact decimals: 0.01, 1000000.00, negative and positive, no thousands separator, no rounding', () {
      final rows = _parse(transactionsCsv([
        _tx('a', '2026-01-01', -1),
        _tx('b', '2026-01-02', 100000000),
        _tx('c', '2026-01-03', -123456),
        _tx('d', '2026-01-04', 5),
        _tx('e', '2026-01-05', 10),
        _tx('f', '2026-01-06', -99),
      ]));
      expect([for (final r in rows.skip(1)) r[1]], ['-0.01', '1000000.00', '-1234.56', '0.05', '0.10', '-0.99']);
    });

    test('zero is 0.00 and negative zero is never printed', () {
      final s = transactionsCsv([_tx('a', '2026-01-01', 0)]);
      final r = _parse(s)[1];
      expect(r[1], '0.00');
      expect(r[1].contains('-'), isFalse, reason: 'the date column always holds -0 (2026-01-01); only the amount matters');
      expect(transactionsCsv([_tx('a', '2026-01-01', -1), _tx('b', '2026-01-02', 1)]).contains('-0.00'), isFalse);
    });

    test('sorted by date then id, regardless of input order', () {
      final rows = _parse(transactionsCsv([
        _tx('z', '2026-01-02', -300),
        _tx('b', '2026-01-03', -400),
        _tx('b', '2026-01-02', -200),
        _tx('a', '2026-01-02', -100),
      ]));
      expect([for (final r in rows.skip(1)) r[1]], ['-1.00', '-2.00', '-3.00', '-4.00']);
      expect([for (final r in rows.skip(1)) r[0]], ['2026-01-02', '2026-01-02', '2026-01-02', '2026-01-03']);
    });

    test('quotes, commas and newlines in text fields survive a round trip (RFC 4180)', () {
      final txs = [
        _tx('a', '2026-01-01', -100, desc: 'Shop, Zagreb', note: 'with "quotes"'),
        _tx('b', '2026-01-02', -200, desc: 'Line one\nLine two', note: 'a,b,"c"\nd'),
        _tx('c', '2026-01-03', -300, desc: 'plain', note: null),
      ];
      final csv = transactionsCsv(txs);
      expect(csv.contains('"Shop, Zagreb"'), isTrue);
      expect(csv.contains('"with ""quotes"""'), isTrue);
      final rows = _parse(csv);
      expect(rows, hasLength(4));
      for (final r in rows) {
        expect(r, hasLength(6), reason: 'every record has six fields: $r');
      }
      expect(rows[1][3], 'Shop, Zagreb');
      expect(rows[1][5], 'with "quotes"');
      expect(rows[2][3], 'Line one\nLine two');
      expect(rows[2][5], 'a,b,"c"\nd');
      expect(rows[3][5], '');
    });

    test('category, source and date columns carry the row values', () {
      final r = _parse(transactionsCsv([_tx('a', '2026-01-09', -250, cat: 'Groceries', source: 'revolut')]))[1];
      expect(r[0], '2026-01-09');
      expect(r[2], 'Groceries');
      expect(r[4], 'revolut');
    });

    test('a thousand rows keep one line per record and the sum of amounts', () {
      final txs = [for (var i = 0; i < 1000; i++) _tx('t$i', '2026-01-${(i % 28 + 1).toString().padLeft(2, '0')}', -(i * 7 + 1))];
      final rows = _parse(transactionsCsv(txs));
      expect(rows, hasLength(1001));
      final cents = rows.skip(1).fold<int>(0, (s, r) => s + (double.parse(r[1]) * 100).round());
      expect(cents, txs.fold<int>(0, (s, t) => s + t.amount));
    });
  });

  group('monthlySummaryCsv', () {
    final cats = spendingCategories;
    final header = 'month,${cats.join(',')},total';
    List<String> row(String month, Map<String, String> v, String total) => [month, for (final c in cats) v[c] ?? '0.00', total];

    test('empty list is the header only', () {
      final s = monthlySummaryCsv(const []);
      expect(s.trim(), header);
      expect(s.contains('\r'), isFalse);
    });

    test('one row per month ascending, outflows positive, total equals the row sum', () {
      final rows = _parse(monthlySummaryCsv([
        _tx('1', '2026-03-02', -1050, cat: 'Groceries'),
        _tx('2', '2026-01-31', -2000, cat: 'Groceries'),
        _tx('3', '2026-01-05', -1, cat: 'Eating out'),
        _tx('4', '2026-03-31', -4999, cat: 'Rent'),
        _tx('5', '2026-01-10', -333, cat: 'Groceries'),
      ]));
      expect(rows.first.join(','), header);
      expect(rows, hasLength(3), reason: 'February has no rows, so no line');
      expect(rows[1], row('2026-01', {'Groceries': '23.33', 'Eating out': '0.01'}, '23.34'));
      expect(rows[2], row('2026-03', {'Groceries': '10.50', 'Rent': '49.99'}, '60.49'));
    });

    test('income, transfers and deleted rows are not spending', () {
      final rows = _parse(monthlySummaryCsv([
        _tx('1', '2026-01-02', -1000, cat: 'Groceries'),
        _tx('2', '2026-01-03', 150000, cat: 'Salary'),
        _tx('3', '2026-01-04', -5000, cat: 'Internal transfer'),
        const CategorizedTx(
            Tx(id: '4', source: 'pbz', date: '2026-01-05', amount: -7777, category: 'Groceries', deleted: true), 'Groceries', Kind.flex),
      ]));
      expect(rows[1], row('2026-01', {'Groceries': '10.00'}, '10.00'));
    });

    test('refund inside a category reduces it (exact cents, no float drift)', () {
      final rows = _parse(monthlySummaryCsv([
        _tx('1', '2026-01-02', -1010, cat: 'Shopping'),
        _tx('2', '2026-01-03', -2020, cat: 'Shopping'),
        _tx('3', '2026-01-04', 505, cat: 'Shopping'),
      ]));
      expect(rows[1], row('2026-01', {'Shopping': '25.25'}, '25.25'));
    });

    test('summary grand total equals the sum of outflows in the transactions export', () {
      final txs = [
        for (var i = 0; i < 60; i++) _tx('t$i', '2026-0${i % 4 + 1}-1${i % 9}', -(i * 137 + 11), cat: cats[i % cats.length]),
      ];
      final sum = _parse(monthlySummaryCsv(txs)).skip(1).fold<int>(0, (s, r) => s + (double.parse(r.last) * 100).round());
      expect(sum, -txs.fold<int>(0, (s, t) => s + t.amount));
    });
  });
}
