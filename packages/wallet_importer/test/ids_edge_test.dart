// Edge cases for transaction ids. The expected hashes were computed with an independent implementation (Python, FNV-1a
// over UTF-16 code units), not with this package. Ids must stay equal to the v1 web app's, so nothing here normalises.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_importer/wallet_importer.dart';

const _hdr = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance';

String _row(String date, String desc, String amount, {String fee = '0.00'}) =>
    'Card Payment,Current,$date,$date,"${desc.replaceAll('"', '""')}",$amount,$fee,EUR,COMPLETED,0';

ImportBatch _imp(List<String> rows) => importBankFile(Uint8List.fromList(utf8.encode('$_hdr\n${rows.join('\n')}\n')));

List<String> _ids(ImportBatch b) => [for (final t in b.transactions) t.id];

void main() {
  group('fnv1a36', () {
    test('known values: empty string is the offset basis, ASCII, BMP and astral characters', () {
      expect(fnv1a36(''), 'ztntfp'); // 0x811c9dc5 in base 36
      expect(fnv1a36('a'), '1r9wi7g');
      expect(fnv1a36('Wolt'), '1s2g5jn');
      expect(fnv1a36('š'), '1r9ualo'); // one UTF-16 unit (0x161), not two UTF-8 bytes
      expect(fnv1a36('\u{1F600}'), '1kdnhdk'); // surrogate pair: two units
    });

    test('is case and whitespace sensitive and never returns an empty string', () {
      expect(fnv1a36('WOLT'), 't68j77');
      expect(fnv1a36('Wolt '), '1dcdqa1');
      expect({fnv1a36('Wolt'), fnv1a36('WOLT'), fnv1a36('Wolt '), fnv1a36(' Wolt'), fnv1a36('wolt')}.length, 5);
      expect(fnv1a36('x' * 100000), isNotEmpty);
    });

    test('composed and decomposed forms of the same letter hash differently (no unicode normalisation, like v1)', () {
      expect(fnv1a36('Café'), '1dq41b0');
      expect(fnv1a36('Café'), 'nnnbyj');
      expect(fnv1a36('š'), '1r9ualo');
      expect(fnv1a36('š'), '1r2oih6');
    });
  });

  group('formatCents', () {
    test('sign, padding, zero and large values', () {
      expect(formatCents(5), '0.05');
      expect(formatCents(-5), '-0.05');
      expect(formatCents(100), '1.00');
      expect(formatCents(-100), '-1.00');
      expect(formatCents(0), '0.00');
      expect(formatCents(99), '0.99');
      expect(formatCents(1000000000000), '10000000000.00');
      expect(formatCents(-1000000000000), '-10000000000.00');
      expect(formatCents(123456789), '1234567.89');
    });
  });

  group('transactionId', () {
    test('shape: yymmdd, hash, optional _n; the hash covers date, amount and description', () {
      expect(transactionId('2026-02-01', 0, 'Free', 0), '260201r05e4');
      expect(transactionId('2026-02-01', -5, 'Fee', 0), '2602011ih7bc6');
      expect(transactionId('2026-12-31', 1000000000000, 'Big', 0), '2612311aa6zkd');
      expect(transactionId('2026-02-01', -100, 'a|b', 0), '2602011j35hzl');
    });

    test('occurrence index: 0 has no suffix, 1 and 10 are _1 and _10', () {
      final base = transactionId('2026-02-01', -5, 'Fee', 0);
      expect(transactionId('2026-02-01', -5, 'Fee', 1), '${base}_1');
      expect(transactionId('2026-02-01', -5, 'Fee', 10), '${base}_10');
      expect(transactionId('2026-02-01', -5, 'Fee', 123), '${base}_123');
    });

    test('any change to date, amount (even 1 cent), sign or description gives another id', () {
      final ids = {
        transactionId('2026-02-01', -500, 'Shop', 0),
        transactionId('2026-02-02', -500, 'Shop', 0),
        transactionId('2026-02-01', -501, 'Shop', 0),
        transactionId('2026-02-01', 500, 'Shop', 0),
        transactionId('2026-02-01', -500, 'shop', 0),
        transactionId('2026-02-01', -500, 'Shop ', 0),
        transactionId('2026-02-01', -500, 'Shop', 1),
      };
      expect(ids.length, 7);
    });

    test('the day-month-year order is fixed: 2026-01-02 and 2026-02-01 do not collide', () {
      expect(transactionId('2026-01-02', -100, 'x', 0), isNot(transactionId('2026-02-01', -100, 'x', 0)));
      expect(transactionId('2026-01-02', -100, 'x', 0), startsWith('260102'));
    });
  });

  group('ids from files', () {
    test('identical rows on one day: distinct ids _1, _2 in file order; the same rows on other days are independent', () {
      final b = _imp([
        _row('2026-02-01 10:00:00', 'Coffee', '-2.50'),
        _row('2026-02-01 11:00:00', 'Coffee', '-2.50'),
        _row('2026-02-02 10:00:00', 'Coffee', '-2.50'),
        _row('2026-02-01 12:00:00', 'Coffee', '-2.50'),
      ]);
      final a = transactionId('2026-02-01', -250, 'Coffee', 0);
      final c = transactionId('2026-02-02', -250, 'Coffee', 0);
      expect(_ids(b), [a, '${a}_1', c, '${a}_2']);
    });

    test('rows that differ by one cent, one letter of case or a trailing space inside quotes are not duplicates', () {
      final b = _imp([
        _row('2026-02-01', 'Coffee', '-2.50'),
        _row('2026-02-01', 'Coffee', '-2.51'),
        _row('2026-02-01', 'COFFEE', '-2.50'),
        _row('2026-02-01', 'Coffee x', '-2.50'),
      ]);
      expect(_ids(b).any((i) => i.contains('_')), isFalse);
      expect(_ids(b).toSet().length, 4);
    });

    test('whitespace around a description is trimmed before hashing, so padded and plain rows are the same transaction', () {
      final b = _imp([_row('2026-02-01', '  Coffee  ', '-2.50'), _row('2026-02-01', 'Coffee', '-2.50')]);
      final a = transactionId('2026-02-01', -250, 'Coffee', 0);
      expect(_ids(b), [a, '${a}_1']);
    });

    test('composed and decomposed descriptions are two different transactions (they came from two different bank texts)', () {
      final b = _imp([_row('2026-02-01', 'Café', '-1.00'), _row('2026-02-01', 'Café', '-1.00')]);
      expect(_ids(b), [transactionId('2026-02-01', -100, 'Café', 0), transactionId('2026-02-01', -100, 'Café', 0)]);
      expect(b.transactions.map((t) => t.description), ['Café', 'Café']);
    });

    test('the id hashes the description after mojibake repair, so a repaired and a clean row match', () {
      final b = _imp([_row('2026-02-01', 'GraÅ¡o', '-1.00'), _row('2026-02-01', 'Grašo', '-1.00')]);
      final a = transactionId('2026-02-01', -100, 'Grašo', 0);
      expect(_ids(b), [a, '${a}_1']);
    });

    test('the amount in the id is amount minus fee, as cents', () {
      final b = _imp([_row('2026-02-01', 'x', '-10.00', fee: '0.50')]);
      expect(b.transactions.single.id, transactionId('2026-02-01', -1050, 'x', 0));
    });

    test('same-day ids are stable when the file is re-exported with more rows later on (overlapping exports)', () {
      final first = _imp([_row('2026-02-01', 'Coffee', '-2.50'), _row('2026-02-01', 'Coffee', '-2.50')]);
      final second = _imp([
        _row('2026-02-01', 'Coffee', '-2.50'),
        _row('2026-02-01', 'Coffee', '-2.50'),
        _row('2026-02-01', 'Coffee', '-2.50'),
        _row('2026-02-03', 'Other', '-1.00'),
      ]);
      expect(_ids(second).take(2), _ids(first), reason: 'the rows both files share keep their ids, so a re-import dedupes them');
      expect(_ids(second).toSet().length, 4);
    });

    test('a different row order on other days does not change ids of the day (ids depend on same-key order only)', () {
      final a = _imp([_row('2026-02-02', 'B', '-1.00'), _row('2026-02-01', 'A', '-1.00'), _row('2026-02-01', 'A', '-1.00')]);
      final b = _imp([_row('2026-02-01', 'A', '-1.00'), _row('2026-02-01', 'A', '-1.00'), _row('2026-02-02', 'B', '-1.00')]);
      expect(_ids(a).toSet(), _ids(b).toSet());
    });

    test('skipped and invalid rows do not use up an occurrence number', () {
      final b = importBankFile(Uint8List.fromList(utf8.encode(
        '$_hdr\n'
        '${_row('2026-02-01', 'Coffee', '-2.50').replaceFirst('COMPLETED', 'PENDING')}\n'
        '${_row('2026-02-30', 'Coffee', '-2.50')}\n'
        '${_row('2026-02-01', 'Coffee', '-2.50')}\n',
      )));
      expect(_ids(b), [transactionId('2026-02-01', -250, 'Coffee', 0)]);
      expect(b.skipped, 1);
      expect(b.invalid, 1);
    });

    test('the date prefix is the booking date even when the time part is just before midnight', () {
      final b = _imp([_row('2026-03-31T23:59:59.999Z', 'Late', '-1.00')]);
      expect(b.transactions.single.id, startsWith('260331'));
    });
  });
}
