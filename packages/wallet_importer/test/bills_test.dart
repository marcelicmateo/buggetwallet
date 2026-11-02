// Bill readers against the SYNTHETIC fixtures in test/fixtures/bills (make fixtures ... bills) and their edges.
// pdfText itself (fixtures, edges, fuzz) is in pdf_text_test.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/fuzz.dart';

Map<String, Object?> json(String name) => jsonDecode(File('test/fixtures/bills/$name').readAsStringSync()) as Map<String, Object?>;

Map<String, Object?> billMap(NormalizedBill b) => {
      'externalId': b.externalId,
      'date': b.date,
      'dueDate': b.dueDate,
      'payee': b.payee,
      'iban': b.iban,
      'reference': b.reference,
      'description': b.description,
      'total': b.total,
      'currency': b.currency,
      'unsure': b.unsure,
    };

List<String> strings(NormalizedBill b) => [
      ...[b.externalId, b.date, b.dueDate, b.payee, b.iban, b.reference, b.description].whereType<String>(),
      for (final i in b.items) i.name,
    ];

void main() {
  final codes = json('codes.json');
  final payer = (codes['payer'] as List).cast<String>();
  final ibans = (codes['ibans'] as List).cast<String>();
  final pdfs = json('pdfs.json');

  group('fixtures', () {
    test('fiscal QR payloads', () {
      for (final c in (codes['qr'] as List).cast<Map<String, Object?>>()) {
        final b = readFiscalQr(c['payload'] as String)!;
        final want = c['bill'] as Map<String, Object?>;
        expect((b.externalId, b.date, b.total, b.source, b.unsure),
            (want['externalId'], want['date'], want['total'], BillSource.receiptQr, 0));
      }
    });

    test('HUB-3 payloads; the payer is never read', () {
      for (final c in (codes['hub3'] as List).cast<Map<String, Object?>>()) {
        final b = readHub3(c['payload'] as String)!;
        final m = billMap(b);
        (c['bill'] as Map<String, Object?>).forEach((k, v) => expect(m[k], v, reason: k));
        for (final s in strings(b)) {
          for (final p in payer) {
            expect(s, isNot(contains(p)));
          }
        }
      }
    });

    test('e-invoice with a VAT id, extensions and lines', () {
      final b = readEInvoice(File('test/fixtures/bills/invoice_telekom.xml').readAsStringSync())!;
      expect(billMap(b), {
        'externalId': 'inv:HR00000000001:R-2026-0815',
        'date': '2026-10-01',
        'dueDate': '2026-10-31',
        'payee': 'Primjer Telekom d.o.o.',
        'iban': ibans[2],
        'reference': 'HR01 2026-0815',
        'description': null,
        'total': 2350,
        'currency': 'EUR',
        'unsure': 0,
      });
      expect(b.items, const [
        BillItem(name: 'Mjesečna pretplata', quantity: '1', amount: 1500),
        BillItem(name: 'Dodatni podatkovni paket', quantity: '2', amount: 380),
      ]);
      expect(strings(b).join(), isNot(contains('Pero Probni')));
    });

    test('e-invoice with only a registration name, grouped IBAN, PaymentDueDate, 3-decimal total', () {
      final b = readEInvoice(File('test/fixtures/bills/invoice_servis.xml').readAsStringSync())!;
      expect((
        b.externalId,
        b.payee,
        b.iban,
        b.dueDate,
        b.total,
        b.reference
      ), (
        'inv:${ibans[1]}:77/1/1',
        'Primjer Servis obrt',
        ibans[1],
        '2026-09-20',
        123450,
        'HR00 77-1-1',
      ));
      expect(b.items.map((i) => (i.name, i.quantity, i.amount)),
          [('Servis kotla', '1', 100000), ('Brtva', '1,5', 23450), ('Sitni materijal', '3', 0)]);
    });

    test('bill from the WinAnsi PDF', () {
      final b = billFromText(pdfText(fixture('bills/bill_winansi.pdf'))!, source: BillSource.pdf)!;
      expect(billMap(b), {
        'externalId': 'jir:${(pdfs['bill_winansi.pdf'] as Map)['jir']}',
        'date': '2026-10-03',
        'dueDate': '2026-10-18',
        'payee': 'Primjer Usluge d.o.o.',
        'iban': ibans[0],
        'reference': 'HR01 2026-0042',
        'description': null,
        'total': 2500,
        'currency': 'EUR',
        'unsure': 7,
      });
      expect(b.source, BillSource.pdf);
    });

    test('bill from the Type0 receipt: JIR wins over ZKI', () {
      final b = billFromText(pdfText(fixture('bills/receipt_type0.pdf'))!, source: BillSource.pdf)!;
      expect((
        b.payee,
        b.date,
        b.total,
        b.externalId,
        b.unsure,
        b.iban,
        b.dueDate
      ), (
        'Primjer Trgovina j.d.o.o.',
        '2026-09-14',
        1234,
        'jir:${(pdfs['receipt_type0.pdf'] as Map)['jir']}',
        4,
        null,
        null,
      ));
    });

    test('bill from a printed HUB-3 block: slip fields exact, due date from the text', () {
      final b = billFromText(pdfText(fixture('bills/hub3_printed.pdf'))!, source: BillSource.pdf)!;
      expect(billMap(b), {
        'externalId': 'hub3:${ibans[0]}:HR01 2026-1001-77:4599:RAČUN ZA STRUJU 10/2026',
        'date': null,
        'dueDate': '2026-11-30',
        'payee': 'Primjer Energija d.o.o.',
        'iban': ibans[0],
        'reference': 'HR01 2026-1001-77',
        'description': 'Račun za struju 10/2026',
        'total': 4599,
        'currency': 'EUR',
        'unsure': 1,
      });
      expect(b.source, BillSource.pdf);
      for (final s in strings(b)) {
        for (final p in payer) {
          expect(s, isNot(contains(p)));
        }
      }
    });
  });

  group('readFiscalQr edges', () {
    const jir = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
    String q(String query, {String base = 'https://porezna.gov.hr/rn'}) => '$base?$query';
    test('accepted variants', () {
      expect(readFiscalQr(q('jir=$jir&datv=20261015_1432&izn=1234', base: 'https://www.porezna.gov.hr/rn/'))?.total, 1234);
      expect(readFiscalQr('  ${q('izn=5&datv=20240229_0000&jir=$jir')}\n')?.date, '2024-02-29');
      expect(readFiscalQr(q('jir=$jir&jir=$jir&datv=20261015_1432&izn=1'))?.total, 1, reason: 'a repeated equal value');
    });
    test('refused', () {
      for (final s in [
        q('jir=3f2504e0-4f89-41d3-9a0c-0305e82c330&datv=20261015_1432&izn=1'), // short uuid
        q('jir=$jir&datv=20260230_1200&izn=1'), // 30 February
        q('jir=$jir&datv=20261015_2400&izn=1'),
        q('jir=$jir&datv=2026-10-15&izn=1'),
        q('jir=$jir&datv=20261015_1432&izn=1,234'), // 3 decimals
        q('jir=$jir&datv=20261015_1432&izn=-5'),
        q('jir=$jir&jir=4f2504e0-4f89-41d3-9a0c-0305e82c3301&datv=20261015_1432&izn=1'), // two different jirs
        q('zki=0123&datv=20261015_1432&izn=1'),
        'ftp://porezna.gov.hr/rn?jir=$jir&datv=20261015_1432&izn=1',
        'https://user@evil.example/rn?jir=$jir&datv=20261015_1432&izn=1',
      ]) {
        expect(readFiscalQr(s), isNull, reason: s);
      }
    });
  });

  group('readHub3 edges', () {
    List<String> f({String model = 'HR01', String ref = '1234-5678', String amount = '000000000001000', String iban = ''}) => [
          'HRVHUB30', 'EUR', amount, 'A', 'B', 'C', 'Primjer d.o.o.', 'Ulica 1', '10000 Grad', //
          iban.isEmpty ? ibans[0] : iban, model, ref, 'COST', 'Opis',
        ];
    test('spaces in the IBAN and reference are normalized', () {
      final b = readHub3(f(iban: ibans[0].replaceAllMapped(RegExp(r'(.{4})'), (m) => '${m[1]} '), ref: ' 1234 - 5678 ').join('\n'))!;
      expect((b.iban, b.reference), (ibans[0], 'HR01 1234-5678'));
    });
    test('a bad model or reference: reference null, unsure', () {
      for (final (m, r) in [('XX01', '1'), ('HR1', '1'), ('HR01', '12a4'), ('HR01', '1--2'), ('HR01', '1-'), ('HR01', '1' * 23)]) {
        final b = readHub3(f(model: m, ref: r).join('\n'))!;
        expect((b.reference, b.unsure), (null, 1), reason: '$m $r');
      }
    });
    test('a zero amount (to be filled in) is no total', () {
      expect(readHub3(f(amount: '000000000000000').join('\n'))!.total, isNull);
    });
    test('an amount over 15 digits or empty is refused', () {
      expect(readHub3(f(amount: '0000000000000001').join('\n')), isNull);
      expect(readHub3(f(amount: '').join('\n')), isNull);
    });
    test('trailing empty lines past 14 are fine, oversized payloads are not', () {
      expect(readHub3('${f().join('\n')}\n\n\n'), isNotNull);
      expect(readHub3(f().join('\n') + '\n' * 3000), isNull);
    });
    test('a non-HR or empty IBAN', () {
      final de = readHub3(f(iban: 'DE89370400440532013000').join('\n'))!;
      expect((de.iban, de.unsure, de.externalId), (null, 1, null));
    });
  });

  group('readEInvoice edges', () {
    String inv({String root = 'Invoice', String body = ''}) => '<$root xmlns="urn:oasis:names:specification:ubl:schema:xsd:$root-2" '
        'xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2" '
        'xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"><cbc:ID>1</cbc:ID>$body</$root>';
    String total(String v) => '<cac:LegalMonetaryTotal><cbc:PayableAmount currencyID="EUR">$v</cbc:PayableAmount></cac:LegalMonetaryTotal>';
    test('amounts that are not exact cents are not rounded', () {
      expect(readEInvoice(inv(body: total('12.345')))!.total, isNull);
      expect(readEInvoice(inv(body: total('12.3400')))!.total, 1234);
      expect(readEInvoice(inv(body: total('-5.00')))!.total, -500);
      expect(readEInvoice(inv(body: total('1e3')))!.total, isNull);
      expect(readEInvoice(inv(body: total('12,34')))!.total, isNull, reason: 'UBL amounts use a dot');
    });
    test('a line without an exact amount is dropped', () {
      final b = readEInvoice(inv(
          body: '<cac:InvoiceLine><cbc:LineExtensionAmount>x</cbc:LineExtensionAmount></cac:InvoiceLine>'
              '<cac:InvoiceLine><cbc:LineExtensionAmount>2.00</cbc:LineExtensionAmount><cac:Item><cbc:Name>N</cbc:Name></cac:Item></cac:InvoiceLine>'))!;
      expect(b.items, const [BillItem(name: 'N', amount: 200)]);
    });
    test('a bad account is dropped and unsure', () {
      final b = readEInvoice(inv(
          body:
              '<cac:PaymentMeans><cac:PayeeFinancialAccount><cbc:ID>HR0012345678901234567</cbc:ID></cac:PayeeFinancialAccount></cac:PaymentMeans>'))!;
      expect((b.iban, b.unsure, b.externalId), (null, 1, null));
    });
    test('wrong namespace, other roots, no id and no total, too big', () {
      expect(readEInvoice('<Invoice><ID>1</ID></Invoice>'), isNull);
      expect(readEInvoice(inv(root: 'Order')), isNull);
      expect(readEInvoice(inv().replaceFirst('<cbc:ID>1</cbc:ID>', '')), isNull);
      expect(readEInvoice(inv(body: '<cbc:Note>${'x' * (maxEInvoiceChars + 1)}</cbc:Note>')), isNull);
    });
    test('random mutations of a fixture never throw', () {
      final src = File('test/fixtures/bills/invoice_telekom.xml').readAsStringSync();
      final r = Random(fuzzSeed(21));
      for (var i = 0; i < fuzzIterations(200); i++) {
        final cut = r.nextInt(src.length);
        final s =
            src.substring(0, cut) + String.fromCharCodes(List.generate(r.nextInt(20), (_) => 32 + r.nextInt(95))) + src.substring(cut);
        expect(() => readEInvoice(s), returnsNormally);
      }
    });
  });

  group('billFromText edges', () {
    NormalizedBill? read(String s) => billFromText(s, source: BillSource.pdf);
    test('ambiguous or excluded totals give no total', () {
      expect(read('Ukupno: 25,00 EUR (188,36 kn)\nDatum: 1.1.2026.')!.total, isNull, reason: 'two amounts on the line');
      expect(read('Ukupno bez PDV-a: 20,00\nDatum: 1.1.2026.')!.total, isNull);
      expect(read('Iznos PDV-a: 5,00\nDatum: 1.1.2026.')!.total, isNull);
      expect(read('Za platiti: 1.234\nDatum: 1.1.2026.')!.total, isNull, reason: '1.234 is not clearly money');
      expect(read('Ukupno stavki: 3\nDatum: 1.1.2026.')!.total, isNull);
      expect(read('Ukupno: 10.10.2026.\nDatum: 1.1.2026.')!.total, isNull, reason: 'a date is no amount');
    });
    test('totals with tax included, on the next line, with other currencies', () {
      expect(read('Ukupno s PDV-om: 25,00 EUR')!.total, 2500);
      expect(read('Ukupno za plaćanje (EUR):\n\n  25,00\n')!.total, 2500);
      expect(read('Total due: 1,234.50 USD')!.currency, 'USD');
      expect(read('Ukupno: 100,00 kn')!.currency, 'HRK');
      expect(read('Grand total € 7.5')!.total, 750);
    });
    test('dates: issue and due on one line, invalid days, English labels', () {
      final b = read('Datum računa: 1.10.2026. Datum dospijeća: 15.10.2026.')!;
      expect((b.date, b.dueDate), ('2026-10-01', '2026-10-15'));
      expect(read('Datum: 31.02.2026.\nUkupno: 1,00')!.date, isNull);
      final e = read('Invoice date: 2026-10-01\nDue date: 2026-10-30\nTotal: 9.99')!;
      expect((e.date, e.dueDate, e.total), ('2026-10-01', '2026-10-30', 999));
      expect(read('Rok plaćanja:\n20. 10. 2026.\nUkupno: 1,00')!.dueDate, '2026-10-20');
      expect(read('Datum računa: 1.10.2026.\nDatum računa: 2.10.2026.')?.date, isNull, reason: 'two different dates');
    });
    test('payee only after a seller label; the payer never', () {
      expect(read('Primatelj:\nPrimjer Servis d.o.o.\nUkupno: 1,00')!.payee, 'Primjer Servis d.o.o.');
      expect(read('Seller: Example Ltd, VAT HR00000000001\nTotal: 1.00')!.payee, 'Example Ltd');
      final b = read('Platitelj: Pero Probni\nKupac: Pero Probni\nBuyer: Pero Probni\nIBAN primatelja: x\nUkupno: 1,00')!;
      expect(b.payee, isNull);
      expect(strings(b).join(), isNot(contains('Pero')));
    });
    test('IBANs: the payer line is skipped, a labelled one wins over another', () {
      expect(read('Platitelj: Pero Probni ${ibans[1]}\nIBAN: ${ibans[0]}')!.iban, ibans[0]);
      expect(read('Žiro-račun: ${ibans[0]}\nNapomena ${ibans[1]}')!.iban, ibans[0]);
      expect(read('${ibans[0]}\n${ibans[1]}\nUkupno: 1,00')!.iban, isNull, reason: 'two unlabelled IBANs');
    });
    test('references: separate model and poziv labels, OIB-like numbers are not references', () {
      expect(read('Model: HR01\nPoziv na broj: 1234-5678')!.reference, 'HR01 1234-5678');
      expect(read('OIB: HR12345678901\nUkupno: 1,00')!.reference, isNull);
      expect(read('Poziv na broj: HR01 1-2\nPoziv na broj: HR01 1-3\nUkupno: 1,00')!.reference, isNull, reason: 'two references');
      expect(read('IBAN: ${ibans[0]}')!.reference, isNull, reason: 'an IBAN is no model + reference');
    });
    test('huge input stays fast', () {
      final big = '${'Ukupno ${'x' * 3000} 12,00 7.3.\n' * 2000}Za platiti: 5,00\n${'a' * 3000000}';
      final sw = Stopwatch()..start();
      expect(() => read(big), returnsNormally);
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });
  });
}
