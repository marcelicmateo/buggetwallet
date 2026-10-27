// J3 mutation gaps in the generic CSV separator detection: the plurality of consistent rows beats a wider but rarer
// layout (SYNTHETIC inputs built in code).
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_importer/wallet_importer.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('separator detection', () {
    test('the separator with the most rows of one width wins over a rarer wider row (mode, not widest)', () {
      // ';' gives width 3 on 10 rows and width 6 on one row; ',' gives width 2 on 6 rows (score 6002 < 10003).
      final rows = [
        for (var i = 0; i < 6; i++) 'a$i,x;b;c',
        for (var i = 0; i < 4; i++) 'd$i;e;f',
        'p;q;r;s;t;u',
      ];
      expect(csvShape(_b('${rows.join('\n')}\n'), headerRow: 0).delimiter, ';');
    });

    test('the separator with more consistent rows wins over one with wider but fewer rows (count before width)', () {
      // ';' : width 2 on 7 rows (7002). ',' : width 4 on 6 rows (6004). Count outweighs width.
      final rows = [
        for (var i = 0; i < 6; i++) 'a$i;b,c,d,e',
        'g;h',
      ];
      expect(csvShape(_b('${rows.join('\n')}\n'), headerRow: 0).delimiter, ';');
    });

    test('with the same row count the wider layout wins', () {
      final rows = [for (var i = 0; i < 6; i++) 'a$i;b,c,d,e'];
      expect(csvShape(_b('${rows.join('\n')}\n'), headerRow: 0).delimiter, ',');
    });
  });
}
