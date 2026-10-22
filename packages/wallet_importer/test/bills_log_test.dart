// The bill readers' log lines: sources, counts, sizes and reason words only, never a value read from a bill.
// Inputs are the SYNTHETIC fixtures in test/fixtures/bills.
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/fuzz.dart';

void main() {
  late List<String> lines;
  setUp(() {
    lines = [];
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen((r) => lines.add('${r.loggerName} ${r.message}${r.error ?? ''}'));
    addTearDown(() async {
      await sub.cancel();
      Logger.root.level = Level.INFO;
    });
  });

  const words = {
    'receiptQr', 'hub3', 'eInvoice', 'pdf', 'photo', 'manual', // sources
    'ok', 'tooBig', 'notPdf', 'encrypted', 'noText', 'budget', 'error', 'malformed', 'doctype', 'creditNote', 'notInvoice', 'empty',
  };

  test('every bill log line is an event word with counts, flags and reason words', () {
    final codes = jsonDecode(File('test/fixtures/bills/codes.json').readAsStringSync()) as Map<String, Object?>;
    for (final c in [...codes['qr'] as List, ...codes['hub3'] as List]) {
      final p = (c as Map)['payload'] as String;
      readFiscalQr(p);
      readHub3(p);
      billFromText(p, source: BillSource.photo);
    }
    for (final n in ['invoice_telekom.xml', 'invoice_servis.xml']) {
      final xml = File('test/fixtures/bills/$n').readAsStringSync();
      readEInvoice(xml);
      readEInvoice(xml.replaceAll('Invoice', 'CreditNote'));
      readEInvoice(xml.substring(0, 300));
    }
    for (final n in ['bill_winansi.pdf', 'receipt_type0.pdf', 'hub3_printed.pdf', 'encrypted_stub.pdf']) {
      final text = pdfText(fixture('bills/$n'));
      if (text != null) billFromText(text, source: BillSource.pdf);
    }
    pdfText(fixture('pbz_synthetic.xls'));

    final bills = lines.where((l) => l.startsWith('bw.importer.bills ')).toList();
    expect(bills.length, greaterThan(20));
    final events = <String>{};
    for (final l in bills) {
      final m = RegExp(r'^bw\.importer\.bills (bills\.[a-z0-9]+) (\{.*\})$').firstMatch(l);
      expect(m, isNotNull, reason: l);
      events.add(m![1]!);
      final fields = jsonDecode(m[2]!) as Map<String, Object?>;
      fields.forEach((k, v) {
        expect(v is int || v is bool || (v is String && words.contains(v)), isTrue, reason: '$k in $l');
      });
    }
    expect(events, containsAll(['bills.qr', 'bills.hub3', 'bills.invoice', 'bills.pdf', 'bills.text']));
    final all = bills.join('\n');
    for (final private in ['Primjer', 'Pero', 'Probn', 'HR01', 'HR9', 'R-2026', '77/1/1', 'pretplata', 'Brtva', '25,00', 'jir:', 'zki:']) {
      expect(all, isNot(contains(private)), reason: private);
    }
  });
}
