// Spec tests for the bill readers (docs/context/BILLS_API.md §1, DESIGN_DECISIONS §4.2), written from the spec only.
// All inputs are SYNTHETIC: made-up payees, generated IBANs, made-up UUIDs. `// SPEC:` marks a reading of an
// ambiguous spec line (the stricter one is tested).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:wallet_importer/wallet_importer.dart';

/// mod-97 check of an IBAN, written out here (not taken from the implementation).
bool validIban(String iban) {
  final moved = iban.substring(4) + iban.substring(0, 4);
  final digits = moved.runes.map((c) => c >= 65 ? (c - 55).toString() : String.fromCharCode(c)).join();
  return BigInt.parse(digits) % BigInt.from(97) == BigInt.one;
}

/// A Croatian IBAN with a valid mod-97 checksum around [body] (17 digits).
String hrIban(String body) {
  assert(body.length == 17);
  final n = BigInt.parse('${body}172700'); // body + 'HR' (17 27) + '00'
  final check = 98 - (n % BigInt.from(97)).toInt();
  return 'HR${check.toString().padLeft(2, '0')}$body';
}

/// The same IBAN with its check digits changed (never valid).
String brokenIban(String iban) {
  final c = int.parse(iban.substring(2, 4));
  return 'HR${((c % 97) + 1).toString().padLeft(2, '0')}${iban.substring(4)}';
}

final iban = hrIban('23600001101234565');
final iban2 = hrIban('10010051863000160');
const jir = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
const zki = '0123456789abcdef0123456789abcdef';

/// Every string a bill carries, for "must not contain" checks.
List<String> allStrings(NormalizedBill b) => [
      ...[b.externalId, b.date, b.dueDate, b.payee, b.iban, b.reference, b.description, b.currency].whereType<String>(),
      for (final i in b.items) ...[i.name, if (i.quantity != null) i.quantity!],
    ];

void main() {
  test('the IBAN helpers produce valid and broken numbers', () {
    expect(iban, hasLength(21));
    expect(validIban(iban), isTrue);
    expect(validIban(iban2), isTrue);
    expect(validIban(brokenIban(iban)), isFalse);
    expect(brokenIban(iban), isNot(iban));
  });

  group('readFiscalQr', () {
    String qr({String host = 'porezna.gov.hr', String q = 'jir=$jir&datv=20261015_1432&izn=1234'}) => 'https://$host/rn?$q';

    test('jir, date and cents amount', () {
      final b = readFiscalQr(qr())!;
      expect(b.source, BillSource.receiptQr);
      expect(b.externalId, 'jir:$jir');
      expect(b.date, '2026-10-15');
      expect(b.total, 1234, reason: 'a plain number is cents');
      expect(b.currency, 'EUR');
      expect(b.items, isEmpty);
    });

    test('izn as decimal with comma or dot is euros', () {
      expect(readFiscalQr(qr(q: 'jir=$jir&datv=20261015_1432&izn=12,34'))!.total, 1234);
      expect(readFiscalQr(qr(q: 'jir=$jir&datv=20261015_1432&izn=12.34'))!.total, 1234);
      expect(readFiscalQr(qr(q: 'jir=$jir&datv=20261015_1432&izn=0,07'))!.total, 7);
      expect(readFiscalQr(qr(q: 'jir=$jir&datv=20261015_1432&izn=19.99'))!.total, 1999, reason: 'no float truncation');
    });

    test('zki when there is no jir (offline receipt)', () {
      final b = readFiscalQr(qr(q: 'zki=$zki&datv=20261015_1432&izn=500'))!;
      expect(b.externalId, 'zki:$zki');
      expect(b.total, 500);
    });

    test('both jir and zki: jir identifies the receipt', () {
      // SPEC: which wins is not written; the JIR is the tax office's id, read here as the identity.
      final b = readFiscalQr(qr(q: 'jir=$jir&zki=$zki&datv=20261015_1432&izn=500'))!;
      expect(b.externalId, 'jir:$jir');
    });

    test('other hosts and shapes give null', () {
      expect(readFiscalQr(qr(host: 'example.com')), isNull);
      expect(readFiscalQr(qr(host: 'porezna.gov.hr.evil.example')), isNull);
      expect(readFiscalQr(qr(host: 'evil.example/porezna.gov.hr')), isNull);
      expect(readFiscalQr(''), isNull);
      expect(readFiscalQr('not a url'), isNull);
      expect(readFiscalQr('HRVHUB30\nEUR'), isNull);
      expect(readFiscalQr('https://porezna.gov.hr/other?jir=$jir&datv=20261015_1432&izn=1234'), isNull);
    });

    test('missing params give null', () {
      expect(readFiscalQr(qr(q: 'datv=20261015_1432&izn=1234')), isNull, reason: 'neither jir nor zki');
      expect(readFiscalQr(qr(q: 'jir=$jir&datv=20261015_1432')), isNull, reason: 'no amount');
      expect(readFiscalQr(qr(q: 'jir=$jir&datv=20261015_1432&izn=')), isNull);
      expect(readFiscalQr(qr(q: 'jir=$jir&datv=20261015_1432&izn=abc')), isNull);
      expect(readFiscalQr(qr(q: '')), isNull);
    });

    test('never throws on junk', () {
      for (final s in ['https://', 'https://porezna.gov.hr/rn?', 'https://porezna.gov.hr/rn?izn=%ZZ', '\u0000', '?' * 5000]) {
        expect(() => readFiscalQr(s), returnsNormally);
      }
    });
  });

  group('readHub3', () {
    const payer = ['Zzpayer Testovic', 'Payerova ulica 99', '10000 PAYERGRAD'];
    List<String> fields({
      String header = 'HRVHUB30',
      String amount = '000000000012345',
      String? ibanValue,
      String model = 'HR01',
      String reference = '1234-5678',
      String description = 'Racun za struju 10/2026',
    }) =>
        [
          header,
          'EUR',
          amount,
          ...payer,
          'Test Elektra d.o.o.',
          'Ulica primatelja 1',
          '21000 Split',
          ibanValue ?? iban,
          model,
          reference,
          'COST',
          description,
        ];
    String lf(List<String> f) => f.join('\n');

    test('LF payload: payee, iban, cents, reference, description', () {
      final b = readHub3(lf(fields()))!;
      expect(b.source, BillSource.hub3);
      expect(b.payee, 'Test Elektra d.o.o.');
      expect(b.iban, iban);
      expect(b.total, 12345);
      expect(b.currency, 'EUR');
      expect(b.reference, 'HR01 1234-5678');
      expect(b.description, 'Racun za struju 10/2026');
      expect(b.unsure, 0, reason: 'a barcode is exact, nothing is guessed');
      expect(b.items, isEmpty);
    });

    test('CRLF payload reads the same', () {
      final a = readHub3(lf(fields()))!, c = readHub3(fields().join('\r\n'))!;
      expect((c.payee, c.iban, c.total, c.reference, c.description), (a.payee, a.iban, a.total, a.reference, a.description));
      expect(c.externalId, a.externalId);
    });

    test('externalId is hub3:<IBAN>:<model reference>:<amount> and differs per amount or reference', () {
      final a = readHub3(lf(fields()))!;
      expect(a.externalId, startsWith('hub3:$iban:'));
      expect(a.externalId, contains('HR01'));
      expect(a.externalId, contains('1234-5678'));
      // SPEC: the amount part is cents (the slip's own unit); only that the id ends with it is relied on.
      expect(a.externalId, endsWith('12345'));
      expect(readHub3(lf(fields(amount: '000000000012346')))!.externalId, isNot(a.externalId));
      expect(readHub3(lf(fields(reference: '1234-5679')))!.externalId, isNot(a.externalId));
    });

    test('payer fields appear nowhere in the result', () {
      for (final payload in [lf(fields()), fields().join('\r\n')]) {
        final b = readHub3(payload)!;
        for (final s in allStrings(b)) {
          for (final p in payer) {
            expect(s.toLowerCase(), isNot(contains(p.toLowerCase())), reason: 'field "$s"');
          }
          expect(s.toLowerCase(), isNot(contains('zzpayer')));
          expect(s.toLowerCase(), isNot(contains('payergrad')));
        }
      }
    });

    test('amount: 15 digits are cents; small and large boundaries', () {
      expect(readHub3(lf(fields(amount: '000000000000001')))!.total, 1);
      expect(readHub3(lf(fields(amount: '000000000000099')))!.total, 99);
      expect(readHub3(lf(fields(amount: '000000000100000')))!.total, 100000);
      expect(readHub3(lf(fields(amount: '999999999999999')))!.total, 999999999999999);
    });

    test('bad checksum IBAN: no iban, counted as unsure; the rest is still read', () {
      final b = readHub3(lf(fields(ibanValue: brokenIban(iban))))!;
      expect(b.iban, isNull);
      expect(b.unsure, greaterThanOrEqualTo(1));
      expect(b.total, 12345);
      expect(b.payee, 'Test Elektra d.o.o.');
    });

    test('wrong header or field count gives null', () {
      expect(readHub3(lf(fields(header: 'HRVHUB31'))), isNull);
      expect(readHub3(lf(fields(header: 'hrvhub30'))), isNull);
      expect(readHub3(lf(fields()..removeLast())), isNull, reason: '13 fields');
      expect(readHub3(lf([...fields(), 'extra'])), isNull, reason: '15 fields');
      expect(readHub3(''), isNull);
      expect(readHub3('HRVHUB30'), isNull);
      expect(readHub3('https://porezna.gov.hr/rn?jir=$jir&izn=1'), isNull);
    });

    test('a non-numeric amount does not become a number', () {
      final b = readHub3(lf(fields(amount: '00000000001234X')));
      // SPEC: either the whole payload is refused or the total is unknown; never a guessed number.
      expect(b?.total, isNull);
    });

    test('never throws', () {
      final r = Random(7);
      for (var i = 0; i < 200; i++) {
        final s = 'HRVHUB30\n${String.fromCharCodes(List.generate(r.nextInt(300), (_) => r.nextInt(255)))}';
        expect(() => readHub3(s), returnsNormally);
      }
    });
  });

  group('readEInvoice', () {
    String ubl({
      String root = 'Invoice',
      String id = '2026-0042',
      String? due = '2026-10-31',
      String? payDue,
      String payable = '1234.50',
      String currency = 'EUR',
      String? lines,
      String? payee = 'Test Dobavljac d.o.o.',
      String paymentId = 'HR01 1234-5678',
      String prologue = '',
    }) {
      return '''<?xml version="1.0" encoding="UTF-8"?>
$prologue<$root xmlns="urn:oasis:names:specification:ubl:schema:xsd:$root-2" xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2" xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
  <cbc:ID>$id</cbc:ID>
  <cbc:IssueDate>2026-10-01</cbc:IssueDate>
  ${due == null ? '' : '<cbc:DueDate>$due</cbc:DueDate>'}
  <cac:AccountingSupplierParty><cac:Party>
    ${payee == null ? '' : '<cac:PartyLegalEntity><cbc:RegistrationName>$payee</cbc:RegistrationName></cac:PartyLegalEntity>'}
  </cac:Party></cac:AccountingSupplierParty>
  <cac:AccountingCustomerParty><cac:Party><cac:PartyLegalEntity><cbc:RegistrationName>Zzbuyer Testovic</cbc:RegistrationName></cac:PartyLegalEntity></cac:Party></cac:AccountingCustomerParty>
  <cac:PaymentMeans>
    <cbc:PaymentMeansCode>30</cbc:PaymentMeansCode>
    ${payDue == null ? '' : '<cbc:PaymentDueDate>$payDue</cbc:PaymentDueDate>'}
    <cbc:PaymentID>$paymentId</cbc:PaymentID>
    <cac:PayeeFinancialAccount><cbc:ID>$iban</cbc:ID></cac:PayeeFinancialAccount>
  </cac:PaymentMeans>
  <cac:LegalMonetaryTotal><cbc:PayableAmount currencyID="$currency">$payable</cbc:PayableAmount></cac:LegalMonetaryTotal>
  ${lines ?? ''}
</$root>''';
    }

    String line(String id, String name, String qty, String amount) =>
        '<cac:InvoiceLine><cbc:ID>$id</cbc:ID><cbc:InvoicedQuantity unitCode="C62">$qty</cbc:InvoicedQuantity>'
        '<cbc:LineExtensionAmount currencyID="EUR">$amount</cbc:LineExtensionAmount><cac:Item><cbc:Name>$name</cbc:Name></cac:Item></cac:InvoiceLine>';

    test('header fields', () {
      final b = readEInvoice(ubl())!;
      expect(b.source, BillSource.eInvoice);
      expect(b.date, '2026-10-01');
      expect(b.dueDate, '2026-10-31');
      expect(b.payee, 'Test Dobavljac d.o.o.');
      expect(b.iban, iban);
      expect(b.reference, 'HR01 1234-5678');
      expect(b.total, 123450);
      expect(b.currency, 'EUR');
      expect(b.externalId, startsWith('inv:'));
      expect(b.externalId, endsWith(':2026-0042'));
      expect(b.externalId, contains(iban), reason: 'no supplier id in the file: the IBAN identifies the supplier');
    });

    test('the buyer is never read as payee', () {
      for (final s in allStrings(readEInvoice(ubl())!)) {
        expect(s, isNot(contains('Zzbuyer')));
      }
    });

    test('totals are exact from decimal strings', () {
      const cases = {
        '1234.50': 123450,
        '19.99': 1999,
        '4.35': 435,
        '1.15': 115,
        '0.07': 7,
        '0.10': 10,
        '100': 10000,
        '1234567.89': 123456789,
        '0.01': 1,
      };
      for (final e in cases.entries) {
        expect(readEInvoice(ubl(payable: e.key))!.total, e.value, reason: e.key);
      }
    });

    test('currencyID is kept', () {
      expect(readEInvoice(ubl(currency: 'USD'))!.currency, 'USD');
    });

    test('lines: names, quantity, exact line totals in order', () {
      final b = readEInvoice(ubl(lines: line('1', 'Widget', '2', '100.10') + line('2', 'Gadget', '1', '2.35')))!;
      expect(b.items, hasLength(2));
      expect(b.items[0].name, 'Widget');
      expect(b.items[0].amount, 10010);
      expect(b.items[0].quantity, '2');
      expect(b.items[1].name, 'Gadget');
      expect(b.items[1].amount, 235);
    });

    test('no lines: empty list', () {
      expect(readEInvoice(ubl())!.items, isEmpty);
    });

    test('DueDate, else PaymentDueDate, else none', () {
      expect(readEInvoice(ubl(due: null, payDue: '2026-11-15'))!.dueDate, '2026-11-15');
      expect(readEInvoice(ubl(due: null))!.dueDate, isNull);
      // SPEC: with both present, DueDate (the invoice's own) wins.
      expect(readEInvoice(ubl(due: '2026-10-31', payDue: '2026-11-15'))!.dueDate, '2026-10-31');
    });

    test('a supplier without a name is not invented', () {
      expect(readEInvoice(ubl(payee: null))?.payee, isNull);
    });

    test('CreditNote gives null', () {
      expect(readEInvoice(ubl(root: 'CreditNote')), isNull);
    });

    test('malformed or foreign XML gives null', () {
      expect(readEInvoice(''), isNull);
      expect(readEInvoice('not xml'), isNull);
      expect(readEInvoice('<Invoice><cbc:ID>'), isNull);
      expect(readEInvoice('<html><body>hi</body></html>'), isNull);
      expect(readEInvoice(ubl().substring(0, 400)), isNull, reason: 'truncated');
      expect(readEInvoice(ubl(payable: 'abc'))?.total, isNull, reason: 'no number invented');
    });

    test('entities are not expanded (no file reads, no blow-up)', () {
      final ext = readEInvoice(ubl(prologue: '<!DOCTYPE Invoice [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>\n', payee: '&xxe;', id: 'X1'));
      for (final s in ext == null ? <String>[] : allStrings(ext)) {
        expect(s, isNot(contains('root:')));
      }
      final laughs = StringBuffer('<!DOCTYPE Invoice [<!ENTITY a0 "lol">');
      for (var i = 1; i < 10; i++) {
        laughs.write('<!ENTITY a$i "${'&a${i - 1};' * 10}">');
      }
      laughs.write(']>\n');
      final sw = Stopwatch()..start();
      final bomb = readEInvoice(ubl(prologue: laughs.toString(), payee: '&a9;'));
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(5000));
      for (final s in bomb == null ? <String>[] : allStrings(bomb)) {
        expect(s.length, lessThan(1000), reason: 'a billion-laughs payee must not appear expanded');
        expect(s, isNot(contains('lollol')));
      }
    });
  });

  group('billFromText', () {
    NormalizedBill? read(String t, {BillSource source = BillSource.pdf}) => billFromText(t, source: source);
    final bill = '''
Test Trgovina d.o.o.
Ulica 1, 10000 Zagreb
Racun br. 2026/55
Datum računa: 05.10.2026
Rok plaćanja: 20.10.2026
IBAN: $iban
Poziv na broj: HR01 5555-1234
Ukupno za platiti: 1.234,56 EUR
''';

    test('Croatian labels', () {
      final b = read(bill)!;
      expect(b.source, BillSource.pdf);
      expect(b.date, '2026-10-05');
      expect(b.dueDate, '2026-10-20');
      expect(b.iban, iban);
      expect(b.reference, 'HR01 5555-1234');
      expect(b.total, 123456);
      expect(b.currency, 'EUR');
      expect(b.unsure, greaterThan(0), reason: 'free text is always a guess');
    });

    test('source is kept (photo)', () {
      expect(read(bill, source: BillSource.photo)!.source, BillSource.photo);
    });

    test('amount formats', () {
      expect(read('Za platiti: 1.234,56 EUR')!.total, 123456);
      expect(read('Total: 1,234.56 EUR')!.total, 123456);
      expect(read('Ukupno: 12,50')!.total, 1250);
      expect(read('Ukupno: 0,99 EUR')!.total, 99);
      expect(read('Iznos: 25.00 EUR')!.total, 2500);
      expect(read('Sveukupno 7,05 EUR')!.total, 705);
      expect(read('UKUPNO EUR 15,30')!.total, 1530);
    });

    test('two different payable totals: total is null', () {
      final b = read('Datum računa: 05.10.2026\nUkupno: 10,00 EUR\nZa platiti: 12,00 EUR\n');
      expect(b?.total, isNull);
      expect(b?.date, '2026-10-05', reason: 'the rest is still read');
    });

    test('the same total twice is one total', () {
      expect(read('Ukupno: 10,00 EUR\nZa platiti: 10,00 EUR\n')!.total, 1000);
    });

    test('dates: Croatian and ISO forms', () {
      expect(read('Datum izdavanja: 5.10.2026.\nUkupno: 1,00')!.date, '2026-10-05');
      expect(read('Datum računa: 2026-10-05\nUkupno: 1,00')!.date, '2026-10-05');
      expect(read('Datum dospijeća: 01.11.2026\nUkupno: 1,00')!.dueDate, '2026-11-01');
      expect(read('Dospijeće: 2026-11-01\nUkupno: 1,00')!.dueDate, '2026-11-01');
    });

    test('a checksum-invalid IBAN is not taken', () {
      expect(read('IBAN: ${brokenIban(iban)}\nUkupno: 1,00 EUR')?.iban, isNull);
    });

    test('a non-HR IBAN is not taken as the payee account', () {
      expect(read('IBAN: DE89370400440532013000\nUkupno: 1,00 EUR')?.iban, isNull);
    });

    test('payer / Kupac is not the payee, and never appears', () {
      final b = read('''
Test Trgovina d.o.o.
Kupac: Zzpayer Testovic
Adresa kupca: Payerova ulica 99, 10000 Payergrad
Platitelj: Zzpayer Testovic
Racun br. 7
Ukupno: 5,00 EUR
''')!;
      for (final s in allStrings(b)) {
        expect(s.toLowerCase(), isNot(contains('zzpayer')));
        expect(s.toLowerCase(), isNot(contains('payerova')));
      }
    });

    test('JIR and ZKI after their labels', () {
      expect(read('JIR: $jir\nZKI: $zki\nUkupno: 3,00 EUR')!.externalId, 'jir:$jir');
      expect(read('ZKI: $zki\nUkupno: 3,00 EUR')!.externalId, 'zki:$zki');
    });

    test('a HUB-3 block printed as text is read like the barcode', () {
      final block = [
        'HRVHUB30',
        'EUR',
        '000000000002550',
        'Zzpayer Testovic',
        'Payerova ulica 99',
        '10000 PAYERGRAD',
        'Test Vodovod d.o.o.',
        'Ulica 3',
        '31000 Osijek',
        iban2,
        'HR01',
        '99-1000',
        'COST',
        'Voda 09/2026',
      ].join('\n');
      final b = read('Neki tekst prije\nUkupno: 99,00 EUR\n$block\nTekst poslije\n')!;
      // SPEC: the barcode block wins over free-text amounts (it is exact): "read like readHub3".
      expect(b.payee, 'Test Vodovod d.o.o.');
      expect(b.iban, iban2);
      expect(b.total, 2550);
      expect(b.reference, 'HR01 99-1000');
      for (final s in allStrings(b)) {
        expect(s.toLowerCase(), isNot(contains('zzpayer')));
      }
    });

    test('nothing recognisable gives null', () {
      // SPEC: no amount, date, IBAN, reference or id found means nothing to suggest.
      expect(read(''), isNull);
      expect(read('Hello world, nothing to see here'), isNull);
    });

    test('never throws, also on random text', () {
      final r = Random(3);
      for (var i = 0; i < 300; i++) {
        final s = String.fromCharCodes(List.generate(r.nextInt(400), (_) => 9 + r.nextInt(300)));
        expect(() => read(s), returnsNormally);
        expect(() => read('Ukupno: $s\nHR$s'), returnsNormally);
      }
    });
  });

  group('pdfText', () {
    /// A tiny PDF with a proper xref. [objs] are object bodies (String or bytes), numbered from 1.
    Uint8List pdf(List<Object> objs, {String trailerExtra = ''}) {
      final out = BytesBuilder();
      final offsets = <int>[];
      void w(List<int> b) => out.add(b);
      w(latin1.encode('%PDF-1.4\n'));
      for (var i = 0; i < objs.length; i++) {
        offsets.add(out.length);
        w(latin1.encode('${i + 1} 0 obj\n'));
        final o = objs[i];
        w(o is String ? latin1.encode(o) : o as List<int>);
        w(latin1.encode('\nendobj\n'));
      }
      final xref = out.length;
      w(latin1.encode('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n'));
      for (final o in offsets) {
        w(latin1.encode('${o.toString().padLeft(10, '0')} 00000 n \n'));
      }
      w(latin1.encode('trailer\n<</Size ${objs.length + 1}/Root 1 0 R$trailerExtra>>\nstartxref\n$xref\n%%EOF\n'));
      return out.toBytes();
    }

    List<int> stream(String dict, List<int> data) =>
        [...latin1.encode('<<$dict/Length ${data.length}>>\nstream\n'), ...data, ...latin1.encode('\nendstream')];

    List<int> text(String s) => latin1.encode(s);

    /// One page with [content] and a Type1 font /F1 (+ [fontExtra] in its dictionary, [more] objects from number 6).
    Uint8List onePage(List<int> content,
            {String fontExtra = '', String filter = '', List<Object> more = const [], String trailerExtra = ''}) =>
        pdf([
          '<</Type/Catalog/Pages 2 0 R>>',
          '<</Type/Pages/Kids[3 0 R]/Count 1>>',
          '<</Type/Page/Parent 2 0 R/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>',
          stream(filter, content),
          '<</Type/Font/Subtype/Type1/BaseFont/Helvetica$fontExtra>>',
          ...more,
        ], trailerExtra: trailerExtra);

    String? read(Uint8List b) => pdfText(b);

    test('uncompressed Tj', () {
      expect(read(onePage(text('BT /F1 12 Tf 72 700 Td (Hello Racun) Tj ET'))), contains('Hello Racun'));
    });

    test('string escapes and octal', () {
      final t = read(onePage(text(r'BT /F1 12 Tf (Rac\(un\) \\ \101BC) Tj ET')))!;
      expect(t, contains('Rac(un)'));
      expect(t, contains(r'\'));
      expect(t, contains('ABC'));
    });

    test('TJ with kerning: small kerns do not split words', () {
      final t = read(onePage(text('BT /F1 12 Tf [(Hel) -20 (lo) 15 (Wor) -300 (ld)] TJ ET')))!;
      expect(t, contains('Hello'));
      expect(t, contains('Wor'));
      expect(t, contains('ld'));
      expect(t, isNot(contains('Hel lo')));
    });

    test("' and \" operators put text on new lines", () {
      final t = read(onePage(text('BT /F1 12 Tf 14 TL (Line one) Tj (Line two) \' 1 2 (Line three) " ET')))!;
      expect(t, contains('Line one'));
      expect(t, contains('Line two'));
      expect(t, contains('Line three'));
      expect(t.indexOf('Line one'), lessThan(t.indexOf('Line two')));
      expect(t.indexOf('Line two'), lessThan(t.indexOf('Line three')));
    });

    test('FlateDecode stream', () {
      final z = ZLibEncoder().encodeBytes(text('BT /F1 12 Tf (Compressed Total 12,50) Tj ET'));
      expect(read(onePage(z, filter: '/Filter/FlateDecode')), contains('Compressed Total 12,50'));
    });

    test('a corrupt Flate stream never throws', () {
      final z = ZLibEncoder().encodeBytes(text('BT /F1 12 Tf (Zed) Tj ET'));
      final bad = [...z]..setRange(2, z.length - 2, List.filled(z.length - 4, 0xAB));
      expect(() => read(onePage(bad, filter: '/Filter/FlateDecode')), returnsNormally);
    });

    test('WinAnsi fallback: bytes above 0x7F', () {
      final t = read(onePage(text('BT /F1 12 Tf (Caf\\351 \\200) Tj ET'), fontExtra: '/Encoding/WinAnsiEncoding'))!;
      expect(t, contains('Café'));
      expect(t, contains('€'), reason: '0x80 is the euro sign in WinAnsi');
    });

    test('ToUnicode CMap: bfchar and bfrange with 2-byte codes', () {
      const cmap = '''
/CIDInit /ProcSet findresource begin 12 dict begin begincmap
1 begincodespacerange <0000> <FFFF> endcodespacerange
2 beginbfchar
<0001> <0048>
<0004> <010D>
endbfchar
1 beginbfrange
<0002> <0003> <0065>
endbfrange
endcmap end end''';
      final b = onePage(
        text('BT /F1 12 Tf <00010002000300040001> Tj ET'),
        fontExtra: '/ToUnicode 6 0 R',
        more: [stream('', text(cmap))],
      );
      expect(read(b), contains('HefčH'), reason: '0001=H, 0002..0003=e,f, 0004=č');
    });

    test('pages are read in page order, not object order', () {
      final b = pdf([
        '<</Type/Catalog/Pages 2 0 R>>',
        '<</Type/Pages/Kids[5 0 R 3 0 R]/Count 2>>',
        '<</Type/Page/Parent 2 0 R/Contents 4 0 R/Resources<</Font<</F1 7 0 R>>>>>>',
        stream('', text('BT /F1 12 Tf (SECONDPAGE) Tj ET')),
        '<</Type/Page/Parent 2 0 R/Contents 6 0 R/Resources<</Font<</F1 7 0 R>>>>>>',
        stream('', text('BT /F1 12 Tf (FIRSTPAGE) Tj ET')),
        '<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>',
      ]);
      final t = read(b)!;
      expect(t.indexOf('FIRSTPAGE'), greaterThanOrEqualTo(0));
      expect(t.indexOf('FIRSTPAGE'), lessThan(t.indexOf('SECONDPAGE')));
    });

    test('encrypted gives null', () {
      final b = onePage(text('BT /F1 12 Tf (Secret) Tj ET'),
          more: ['<</Filter/Standard/V 2/R 3/O(x)/U(y)/P -4>>'], trailerExtra: '/Encrypt 6 0 R');
      expect(read(b), isNull);
    });

    test('no text layer gives null', () {
      expect(read(onePage(text('0 0 100 100 re f'))), isNull);
    });

    test('garbage, empty and truncated never throw', () {
      expect(read(Uint8List(0)), isNull);
      expect(read(Uint8List.fromList(utf8.encode('this is not a pdf'))), isNull);
      expect(read(Uint8List.fromList(utf8.encode('%PDF-1.4\n'))), isNull);
      final good = onePage(text('BT /F1 12 Tf (Half) Tj ET'));
      for (var cut = 0; cut < good.length; cut += 7) {
        expect(() => read(Uint8List.sublistView(good, 0, cut)), returnsNormally, reason: 'cut at $cut');
      }
    });

    test('random bytes (also behind a PDF header) never throw', () {
      final r = Random(11);
      for (var i = 0; i < 200; i++) {
        final body = List.generate(r.nextInt(2000), (_) => r.nextInt(256));
        expect(() => read(Uint8List.fromList(body)), returnsNormally);
        expect(() => read(Uint8List.fromList([...latin1.encode('%PDF-1.4\n1 0 obj\n'), ...body])), returnsNormally);
      }
    });

    test('flipped bytes of a valid compressed file never throw', () {
      final good = onePage(ZLibEncoder().encodeBytes(text('BT /F1 12 Tf (Flip) Tj ET')), filter: '/Filter/FlateDecode');
      final r = Random(5);
      for (var i = 0; i < 200; i++) {
        final c = Uint8List.fromList(good);
        for (var k = 0; k < 1 + r.nextInt(4); k++) {
          c[r.nextInt(c.length)] = r.nextInt(256);
        }
        expect(() => read(c), returnsNormally);
      }
    });

    test('over 20 MB gives null', () {
      final big = Uint8List(20 * 1024 * 1024 + 1)..setRange(0, 8, latin1.encode('%PDF-1.4'));
      expect(read(big), isNull);
    });

    test('a huge operator count stops within the budget (quickly, no throw)', () {
      final ops = StringBuffer('BT /F1 12 Tf ');
      for (var i = 0; i < 700000; i++) {
        ops.write('(a) Tj ');
      }
      ops.write('ET');
      final sw = Stopwatch()..start();
      expect(() => read(onePage(text(ops.toString()))), returnsNormally);
      expect(sw.elapsedMilliseconds, lessThan(30000));
    });

    test('billFromText works on the text of a PDF', () {
      final t = read(onePage(text('BT /F1 12 Tf (Ukupno: 12,50 EUR) Tj ET')))!;
      expect(billFromText(t, source: BillSource.pdf)!.total, 1250);
    });
  });
}
