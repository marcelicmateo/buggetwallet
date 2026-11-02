// pdfText against the SYNTHETIC PDF fixtures in test/fixtures/bills (make fixtures ... bills), hand-built PDFs
// for its edges, and mutated fixtures (fuzz).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/fuzz.dart';

Map<String, Object?> json(String name) => jsonDecode(File('test/fixtures/bills/$name').readAsStringSync()) as Map<String, Object?>;

/// A one-page PDF with [content] (raw stream bytes, [dict] extra stream keys) and Helvetica as /F1; [more] objects from 6.
Uint8List pdf(List<int> content, {String dict = '', List<String> more = const [], bool xref = true}) {
  final objs = <List<int>>[
    latin1.encode('<</Type/Catalog/Pages 2 0 R>>'),
    latin1.encode('<</Type/Pages/Kids[3 0 R]/Count 1>>'),
    latin1.encode('<</Type/Page/Parent 2 0 R/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>/XObject<</X1 6 0 R>>>>>>'),
    [...latin1.encode('<<$dict/Length ${content.length}>>\nstream\n'), ...content, ...latin1.encode('\nendstream')],
    latin1.encode('<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>'),
    for (final m in more) latin1.encode(m),
  ];
  final out = BytesBuilder()..add(latin1.encode('%PDF-1.4\n'));
  final offs = <int>[];
  for (var i = 0; i < objs.length; i++) {
    offs.add(out.length);
    out
      ..add(latin1.encode('${i + 1} 0 obj\n'))
      ..add(objs[i])
      ..add(latin1.encode('\nendobj\n'));
  }
  if (xref) {
    final x = out.length;
    out.add(
        latin1.encode('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n${offs.map((o) => '${'$o'.padLeft(10, '0')} 00000 n \n').join()}'
            'trailer\n<</Size ${objs.length + 1}/Root 1 0 R>>\nstartxref\n$x\n%%EOF\n'));
  }
  return out.toBytes();
}

List<int> t(String s) => latin1.encode(s);

void main() {
  final pdfs = json('pdfs.json');

  group('fixtures', () {
    for (final name in ['bill_winansi.pdf', 'receipt_type0.pdf', 'hub3_printed.pdf']) {
      test('$name: text lines in order', () {
        final text = pdfText(fixture('bills/$name'))!;
        expect(text.split('\n'), (pdfs[name] as Map)['lines']);
      });
    }

    test('encrypted stub gives null', () {
      expect(pdfText(fixture('bills/encrypted_stub.pdf')), isNull);
    });
  });

  group('pdfText edges', () {
    test('no xref and no trailer: objects are found by scanning', () {
      expect(pdfText(pdf(t('BT /F1 9 Tf (Bez xref) Tj ET'), xref: false)), 'Bez xref');
    });
    test('a wrong /Length falls back to endstream; an indirect /Length works', () {
      final good = t('BT /F1 9 Tf (Duljina) Tj ET');
      final wrong = String.fromCharCodes(pdf(good)).replaceFirst('/Length ${good.length}', '/Length 3');
      expect(pdfText(Uint8List.fromList(latin1.encode(wrong))), 'Duljina');
      final indirect =
          String.fromCharCodes(pdf(good, more: ['<<>>', '${good.length}'])).replaceFirst('/Length ${good.length}', '/Length 7 0 R');
      expect(pdfText(Uint8List.fromList(latin1.encode(indirect))), 'Duljina');
    });
    test('ASCIIHex, ASCII85 and a filter chain', () {
      final hex = t('4254 202f4631203920546620284865782920546a20\n4554>');
      expect(pdfText(pdf(hex, dict: '/Filter/ASCIIHexDecode')), 'Hex');
      // "BT /F1 9 Tf (A85) Tj ET" in ASCII85
      final a85 = t(r'''<~6<#'\7PQ#G+B2qq-p]gM.3MT)+@T6~>''');
      expect(pdfText(pdf(a85, dict: '/Filter/ASCII85Decode')), 'A85');
      final z = const ZLibEncoder().encodeBytes(t('BT /F1 9 Tf (Lanac) Tj ET'));
      final hexOfZ = t('${z.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}>');
      expect(pdfText(pdf(hexOfZ, dict: '/Filter[/AHx/Fl]')), 'Lanac');
    });
    test('an unsupported filter gives no text', () {
      expect(pdfText(pdf(t('xx'), dict: '/Filter/LZWDecode')), isNull);
    });
    test('a form XObject is read once, also when it calls itself', () {
      const form = '<</Type/XObject/Subtype/Form/BBox[0 0 9 9]/Resources<</Font<</F1 5 0 R>>/XObject<</X1 6 0 R>>>>/Length 32>>\n'
          'stream\nBT /F1 9 Tf (Forma) Tj ET /X1 Do\nendstream';
      expect(pdfText(pdf(t('/X1 Do /X1 Do'), more: [form])), 'Forma');
    });
    test('a page tree that loops ends', () {
      final s = String.fromCharCodes(pdf(t('BT /F1 9 Tf (Petlja) Tj ET'))).replaceFirst('/Kids[3 0 R]', '/Kids[3 0 R 2 0 R 1 0 R]');
      expect(pdfText(Uint8List.fromList(latin1.encode(s))), 'Petlja');
    });
    test('a /Length that refers to itself ends', () {
      final s = String.fromCharCodes(pdf(t('BT /F1 9 Tf (Sam) Tj ET'))).replaceFirst(RegExp(r'/Length \d+'), '/Length 4 0 R');
      expect(pdfText(Uint8List.fromList(latin1.encode(s))), 'Sam');
    });
    test('deep nesting does not overflow the stack', () {
      expect(() => pdfText(pdf(t('${'[' * 100000} BT /F1 9 Tf (D) Tj ET'))), returnsNormally);
      expect(() => pdfText(pdf(t('BT /F1 9 Tf (D) Tj ET'), more: ['<<${'/A <<' * 50000}'])), returnsNormally);
    });
    test('Td on the same baseline is a space, a new baseline a new line, unknown fonts give nothing', () {
      expect(pdfText(pdf(t('BT /F1 9 Tf 10 10 Td (Iznos:) Tj 50 0 Td (5,00) Tj 0 -12 Td (Dalje) Tj /F9 9 Tf (Nema) Tj ET'))),
          'Iznos: 5,00\nDalje');
    });
    test('a compression bomb stops at the inflate cap', () {
      final z = const ZLibEncoder().encodeBytes(Uint8List(80 << 20));
      final sw = Stopwatch()..start();
      expect(pdfText(pdf(z, dict: '/Filter/FlateDecode')), isNull);
      expect(sw.elapsed, lessThan(const Duration(seconds: 20)));
    });
    test('past the op budget: the text read so far', () {
      final sb = StringBuffer('BT /F1 9 Tf (Prvi) Tj T* ');
      for (var i = 0; i < 1300000; i++) {
        sb.write('1 2 3 Td ');
      }
      sb.write('(Kasni) Tj ET');
      final sw = Stopwatch()..start();
      expect(pdfText(pdf(t(sb.toString()))), 'Prvi');
      expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
    });
    test('mutated fixtures never throw and finish quickly', () {
      final r = Random(fuzzSeed(17));
      final files = [
        for (final n in ['bill_winansi.pdf', 'receipt_type0.pdf', 'hub3_printed.pdf']) fixture('bills/$n')
      ];
      final sw = Stopwatch()..start();
      for (var i = 0; i < fuzzIterations(300); i++) {
        final c = Uint8List.fromList(files[i % files.length]);
        for (var k = 0; k < 1 + r.nextInt(8); k++) {
          c[r.nextInt(c.length)] = r.nextInt(256);
        }
        final cut = r.nextInt(c.length + 1);
        expect(() => pdfText(Uint8List.sublistView(c, 0, cut)), returnsNormally);
        expect(() => pdfText(c), returnsNormally);
      }
      expect(sw.elapsed, lessThan(const Duration(seconds: 60)));
    });
  });
}
