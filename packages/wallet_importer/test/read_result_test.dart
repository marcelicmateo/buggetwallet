// The bill readers' `…Result` twins: the same value as the nullable readers, plus the reason when there is none.
// All data is SYNTHETIC.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_importer/wallet_importer.dart';

void main() {
  group('ReadResult', () {
    test('ok holds the value, failed the reason', () {
      const ok = ReadResult<String>.ok('x');
      const no = ReadResult<String>.failed(ReadFailure.noText);
      expect((ok.ok, ok.value, ok.reason), (true, 'x', null));
      expect((no.ok, no.value, no.reason), (false, null, ReadFailure.noText));
      expect(no.toString(), 'ReadResult.failed(noText)');
    });
  });

  group('readFiscalQrResult', () {
    const good = 'https://porezna.gov.hr/rn?jir=12345678-1234-1234-1234-123456789abc&datv=20260105_1200&izn=1250';
    test('reasons: empty, too big, another URL, a bad field; the value is what readFiscalQr gives', () {
      expect(readFiscalQrResult('').reason, ReadFailure.empty);
      expect(readFiscalQrResult('   ').reason, ReadFailure.empty);
      expect(readFiscalQrResult('x' * 1001).reason, ReadFailure.tooBig);
      expect(readFiscalQrResult('https://example.com/rn?jir=x').reason, ReadFailure.notRecognized);
      expect(readFiscalQrResult('ftp://porezna.gov.hr/rn').reason, ReadFailure.notRecognized);
      expect(readFiscalQrResult('https://porezna.gov.hr/other').reason, ReadFailure.notRecognized);
      expect(readFiscalQrResult('https://porezna.gov.hr/rn?jir=nope&datv=20260105_1200&izn=1250').reason, ReadFailure.malformed);
      expect(readFiscalQrResult('https://porezna.gov.hr/rn?jir=12345678-1234-1234-1234-123456789abc').reason, ReadFailure.malformed);
      expect(readFiscalQrResult('https://porezna.gov.hr/rn?a=%zz').reason, ReadFailure.malformed);
      final r = readFiscalQrResult(good);
      expect(r.ok, isTrue);
      expect(r.reason, isNull);
      expect((r.value!.total, r.value!.date), (readFiscalQr(good)!.total, readFiscalQr(good)!.date));
      expect((r.value!.total, r.value!.date), (1250, '2026-01-05'));
    });
  });

  group('readHub3Result', () {
    test('reasons: too big, no HRVHUB30 block, a bad currency or amount', () {
      expect(readHub3Result('x' * 2001).reason, ReadFailure.tooBig);
      expect(readHub3Result('hello').reason, ReadFailure.notRecognized);
      expect(readHub3Result(List.filled(14, 'HRVHUB30').join('\n')).reason, ReadFailure.malformed, reason: 'currency XXXX');
      for (final p in ['hello', '']) {
        expect(readHub3Result(p).value, readHub3(p));
      }
    });
  });

  group('readEInvoiceResult', () {
    test('reasons: too big, a DOCTYPE, not an invoice, malformed XML', () {
      expect(readEInvoiceResult('x' * (maxEInvoiceChars + 1)).reason, ReadFailure.tooBig);
      expect(readEInvoiceResult('<!DOCTYPE x><Invoice/>').reason, ReadFailure.malformed);
      expect(readEInvoiceResult('<Foo/>').reason, ReadFailure.notRecognized);
      expect(readEInvoiceResult('<Invoice').reason, ReadFailure.malformed);
      expect(readEInvoiceResult('').reason, ReadFailure.malformed);
      expect(readEInvoiceResult('<Foo/>').value, readEInvoice('<Foo/>'));
    });
  });

  group('billFromTextResult', () {
    test('nothing found in plain prose; the value is what billFromText gives', () {
      const prose = 'Synthetic lines with no labelled field at all.\nSecond line.';
      expect(billFromTextResult(prose, source: BillSource.pdf).reason, ReadFailure.nothingFound);
      expect(billFromTextResult('', source: BillSource.pdf).reason, ReadFailure.nothingFound);
      const labelled = 'Primatelj: Synthetic d.o.o.\nIBAN: HR1210010051863000160\nUkupno: 12,50 EUR';
      final r = billFromTextResult(labelled, source: BillSource.pdf);
      final b = billFromText(labelled, source: BillSource.pdf);
      expect(r.ok, b != null);
      expect((r.value?.iban, r.value?.total, r.value?.payee), (b?.iban, b?.total, b?.payee));
    });
  });

  group('pdfTextResult', () {
    test('reasons: not a PDF, encrypted, no text; the value is what pdfText gives', () {
      final notPdf = Uint8List.fromList(List.filled(2000, 0x41)); // bigger than the header window the reader probes
      expect(pdfTextResult(notPdf).reason, ReadFailure.notRecognized);
      expect(pdfTextResult(notPdf).value, pdfText(notPdf));
      final encrypted = Uint8List.fromList('%PDF-1.4\n1 0 obj << /Encrypt 2 0 R >> endobj\n'.codeUnits);
      expect(pdfTextResult(encrypted).reason, ReadFailure.encrypted);
      final empty = Uint8List.fromList('%PDF-1.4\n%%EOF\n'.codeUnits);
      final r = pdfTextResult(empty);
      expect(r.ok, isFalse);
      expect(r.reason, anyOf(ReadFailure.noText, ReadFailure.error));
      expect(r.value, pdfText(empty));
    });
  });
}
