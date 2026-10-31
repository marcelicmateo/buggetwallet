// Stage B4: the bills database in the app. Adding bills (camera codes, photos, PDFs, e-invoices, Share to app) through fakes,
// Plan › Bills, the bill sheet, "Paid by…", Today's "to review" line, Spending's receipt mark, Upcoming's warranty and return-by
// rows, search, reminders, log privacy and layout. All data is SYNTHETIC (billsWallet: Tuesday 20 Oct 2026).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:budget_wallet/src/bill_inputs.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/nudges.dart';
import 'package:budget_wallet/src/pdf_parse.dart';
import 'package:budget_wallet/src/screens/bill_sheet.dart';
import 'package:budget_wallet/src/screens/bills_panel.dart';
import 'package:budget_wallet/src/screens/scan_bill.dart';
import 'package:budget_wallet/src/screens/search.dart';
import 'package:budget_wallet/src/screens/sync_panel.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/screens/upcoming.dart';
import 'package:budget_wallet/src/screens/upcoming_view.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show ImportBatch;
import 'package:wallet_sync/wallet_sync.dart';

import 'support/bills.dart';
import 'support/layout.dart';
import 'support/plan_page.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

WalletController bw({FakeBillInputs? inputs, FakeNudges? nudges}) {
  final wc = billsWallet(inputs: inputs, nudges: nudges);
  addTearDown(wc.dispose);
  return wc;
}

/// A widget test that lets the controller's 3 s sync debounce run out before it ends (no timer may be pending).
void tw(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 4));
    }, timeout: const Timeout(Duration(seconds: 60))); // a stuck test fails in a minute, never hangs for ten

Finder key(String k) => find.byKey(ValueKey(k));
Finder snack(String text) => find.descendant(of: find.byType(SnackBar), matching: find.text(text));

/// A 1x1 PNG, so Image.memory has something real to show.
final tinyPng = base64.decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

class _Picked extends PickedFile {
  _Picked(String name, Uint8List data) : super(name, () async => data, length: () async => data.length);
}

/// A picked file that says it is [size] bytes long and must never be read.
class _Huge extends PickedFile {
  _Huge(String name, int size)
      : super(name, () async => throw StateError('a file over the limit must not be read'), length: () async => size);
}

class _Chooser extends FileChooser {
  List<PickedFile> picks = [];
  bool fail = false;
  final saved = <({String name, Uint8List bytes})>[];
  @override
  Future<List<PickedFile>> pickBillFiles() async {
    if (fail) throw StateError('no portal');
    return picks;
  }

  @override
  Future<Uri?> saveBillFile({required String fileName, required Uint8List bytes, required String title}) async {
    saved.add((name: fileName, bytes: bytes));
    return Uri(path: fileName);
  }
}

const eInvoice = '''<?xml version="1.0" encoding="UTF-8"?>
<Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2" xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2" xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
  <cbc:ID>SYN-2026-001</cbc:ID>
  <cbc:IssueDate>2026-10-10</cbc:IssueDate>
  <cbc:DueDate>2026-10-25</cbc:DueDate>
  <cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>
  <cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>
  <cac:AccountingSupplierParty><cac:Party><cac:PartyLegalEntity><cbc:RegistrationName>Synthetic Supplier Ltd</cbc:RegistrationName></cac:PartyLegalEntity></cac:Party></cac:AccountingSupplierParty>
  <cac:LegalMonetaryTotal><cbc:PayableAmount currencyID="EUR">125.00</cbc:PayableAmount></cac:LegalMonetaryTotal>
</Invoice>''';

/// Adds a bill read by the readers straight into the repo and returns its id (review status).
String addBill(WalletController wc, NormalizedBill b, {bool confirm = false, String? category}) {
  final (id, _) = wc.repo.importBill(b);
  // A slip still to be paid needs a category before it is confirmed (it would count twice otherwise).
  if (confirm && b.dueDate != null) wc.repo.updateBill(id, category: category ?? 'Bills & subscriptions');
  wc.reload();
  if (confirm) wc.confirmBill(id);
  return id;
}

Future<void> openSheetFor(WidgetTester tester, WalletController wc, String id,
    {Size size = const Size(400, 900), double scale = 1, FileChooser chooser = const FileChooser()}) async {
  await pumpApp(
      tester,
      Scaffold(
          body: Builder(
              builder: (c) =>
                  Center(child: TextButton(onPressed: () => openBill(c, wc, id, chooser: chooser), child: const Text('open'))))),
      size: size,
      textScale: scale);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Widget todayOf(WalletController wc, {VoidCallback? openBillsReview}) =>
    Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, openBillsReview: openBillsReview, clock: () => budgetToday));

void main() {
  late List<String> lines;
  setUp(() {
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });

  group('adding bills: codes', () {
    test('a receipt QR becomes a bill to review with its date and total, and no file', () async {
      final wc = bw();
      final r = await wc.importScannedCode(const ScannedCode(CodeKind.qr, receiptQr));
      expect(r.kind, BillImportKind.added);
      final b = wc.bill(r.billId!)!;
      expect(b.status, BillStatus.review);
      expect(b.source, BillSource.receiptQr);
      expect(b.total, 1234);
      expect(b.date, '2026-10-18');
      expect(b.blob, isNull);
      expect(wc.billsToReview(), 1);
    });

    test('a HUB-3 slip is read from a PDF417 code; the same code twice is "Already in your bills"', () async {
      final wc = bw();
      final first = await wc.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip));
      expect(first.kind, BillImportKind.added);
      expect(wc.bill(first.billId!)!.total, 4560);
      final second = await wc.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip));
      expect(second.kind, BillImportKind.duplicate);
      expect(second.message, 'Already in your bills');
      expect(second.billId, first.billId);
      expect(wc.billsAll(), hasLength(1));
    });

    test('a code that is not a bill adds nothing', () async {
      final wc = bw();
      final r = await wc.importScannedCode(const ScannedCode(CodeKind.qr, 'https://example.org/not-a-bill'));
      expect(r.kind, BillImportKind.unreadable);
      expect(wc.billsAll(), isEmpty);
    });
  });

  group('adding bills: files', () {
    test('a PDF with a text layer is read; its original is kept and opens again', () async {
      final wc = bw(inputs: FakeBillInputs(pictures: FakePictures(canRead: false), pdf: FakePdf(canRender: false)));
      final pdf = smallPdf(['Datum racuna: 18.10.2026', 'Ukupno: 45,60 EUR']);
      final r = await wc.importBillFile(pdf, 'pdf');
      expect(r.kind, BillImportKind.added);
      expect(r.fileKept, isTrue);
      final b = wc.bill(r.billId!)!;
      expect(b.source, BillSource.pdf);
      expect(b.total, 4560);
      expect(b.date, '2026-10-18');
      expect(b.blobType, 'pdf');
      final f = await wc.billFile(b);
      expect(f.state, BillFileState.ready);
      expect(f.bytes, pdf);
    });

    test('on Android the pages are scanned for a code and the code wins over the text', () async {
      final fakes = FakeBillInputs();
      fakes.pictures.codeList = const [ScannedCode(CodeKind.pdf417, hub3Slip)];
      final wc = bw(inputs: fakes);
      final r = await wc.importBillFile(smallPdf(['Ukupno: 99,99 EUR']), 'pdf');
      expect(fakes.pdf.renders, 1);
      final b = wc.bill(r.billId!)!;
      expect(b.source, BillSource.hub3);
      expect(b.total, 4560, reason: 'the slip says 45.60, the text 99.99: the code is exact');
    });

    test('a PDF with no text and no code is kept unread, to be typed', () async {
      final wc = bw(inputs: FakeBillInputs(pdf: FakePdf(canRender: false), pictures: FakePictures(canRead: false)));
      final r = await wc.importBillFile(bytesOfString('%PDF-1.4 nothing readable'), 'pdf');
      expect(r.kind, BillImportKind.added);
      final b = wc.bill(r.billId!)!;
      expect(b.total, isNull);
      expect(b.date, isNull);
      expect(b.blob, isNotNull);
      expect(wc.confirmBill(b.id), isFalse, reason: 'a date and a total are needed');
    });

    test('an e-invoice XML is read and kept; a bad XML adds nothing', () async {
      final wc = bw();
      final r = await wc.importBillFile(bytesOfString(eInvoice), 'xml');
      expect(r.kind, BillImportKind.added);
      final b = wc.bill(r.billId!)!;
      expect(b.source, BillSource.eInvoice);
      expect(b.total, 12500);
      expect(b.dueDate, '2026-10-25');
      expect(b.blobType, 'xml');
      expect((await wc.importBillFile(bytesOfString('<nope/>'), 'xml')).kind, BillImportKind.unreadable);
      expect(wc.billsAll(), hasLength(1));
    });

    test('a photo: codes first, else text; the sized JPEG is what is kept', () async {
      final fakes = FakeBillInputs(pdf: FakePdf(jpeg: Uint8List.fromList([9, 9, 9])));
      fakes.pictures.codeList = const [ScannedCode(CodeKind.qr, receiptQr)];
      final wc = bw(inputs: fakes);
      final r = await wc.importBillFile(tinyPng, 'png');
      final b = wc.bill(r.billId!)!;
      expect(b.source, BillSource.receiptQr);
      expect(b.blobType, 'jpg');
      expect((await wc.billFile(b)).bytes, [9, 9, 9]);
      expect(fakes.pictures.textCalls, 0, reason: 'a code was found, no need to read text');

      fakes.pictures.codeList = const [];
      fakes.pictures.textResult = 'Datum racuna 05.10.2026\nUkupno 12,50';
      final r2 = await wc.importBillFile(Uint8List.fromList([7, 7]), 'jpg');
      final b2 = wc.bill(r2.billId!)!;
      expect(b2.source, BillSource.photo);
      expect(b2.total, 1250);
      expect(b2.date, '2026-10-05');
    });

    test('on Linux and web a photo is kept unread; the same file twice is one bill', () async {
      final wc = bw(inputs: FakeBillInputs(pictures: FakePictures(canRead: false), pdf: FakePdf(canRender: false)));
      final a = await wc.importBillFile(tinyPng, 'jpg');
      expect(a.kind, BillImportKind.added);
      final b = wc.bill(a.billId!)!;
      expect(b.source, BillSource.photo);
      expect(b.total, isNull);
      expect(b.blob, isNotNull);
      final again = await wc.importBillFile(tinyPng, 'jpg');
      expect(again.kind, BillImportKind.duplicate);
      expect(wc.billsAll(), hasLength(1));
    });

    test('other file types and a file over 15 MB add nothing', () async {
      final wc = bw();
      expect((await wc.importBillFile(Uint8List(10), 'docx')).kind, BillImportKind.unreadable);
      final big = Uint8List(15 * 1024 * 1024 + 1);
      expect((await wc.importBillFile(big, 'jpg')).kind, BillImportKind.tooBig);
      expect(wc.billsAll(), isEmpty);
    });

    test('Take photo keeps the frame and reads its text', () async {
      final fakes = FakeBillInputs();
      fakes.pictures.textResult = 'Datum racuna 05.10.2026\nUkupno 12,50';
      final wc = bw(inputs: fakes);
      final r = await wc.importPhoto(Uint8List.fromList([1, 2, 3, 4]));
      final b = wc.bill(r.billId!)!;
      expect(b.source, BillSource.photo);
      expect(b.blob, isNotNull);
      expect(b.total, 1250);
    });
  });

  group('share to app', () {
    test('files shared before the app opened and while it runs become bills to review', () async {
      final fakes = FakeBillInputs(
          share: FakeShare(initialFiles: [
        SharedFile(smallPdf(['Ukupno: 10,00 EUR', '01.10.2026']), 'pdf')
      ]));
      final wc = bw(inputs: fakes);
      final results = <BillImport>[];
      final sub = wc.sharedBillResults.listen(results.add);
      addTearDown(sub.cancel);
      await wc.startSharing();
      await wc.startSharing(); // twice is safe
      expect(wc.billsToReview(), 1);
      fakes.share.send([
        SharedFile(smallPdf(['Ukupno: 20,00 EUR', '02.10.2026']), 'pdf')
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(wc.billsToReview(), 2);
      expect(results.map((r) => r.kind), [BillImportKind.added, BillImportKind.added]);
      expect(results.first.message, 'Bill added to review');
    });

    test('nothing is listened to where Share does not exist', () async {
      final wc = bw(inputs: FakeBillInputs(share: FakeShare(canShare: false)));
      await wc.startSharing();
      expect(wc.billsToReview(), 0);
    });
  });

  group('the bill: confirm, pay, delete', () {
    test('Confirm needs a date and a total; editing them makes it work; it moves to Unpaid', () async {
      final wc = bw();
      final id = addBill(wc, const NormalizedBill(source: BillSource.pdf, externalId: 'file:x', payee: 'Synthetic Water'));
      expect(wc.confirmBill(id), isFalse);
      expect(wc.billLists().review.map((b) => b.id), [id]);
      wc.updateBill(id, date: '2026-10-18', total: 4560, dueDate: '2026-10-30', category: 'Bills & subscriptions');
      expect(wc.confirmBill(id), isTrue);
      expect(wc.billLists().review, isEmpty);
      expect(wc.billLists().unpaid.map((b) => b.id), [id]);
    });

    test('"Paid by…" lists payments near the date, the payee-word match first; link and unlink move the bill', () {
      final wc = bw();
      final id = addBill(wc, syntheticBill('hub3:x', due: '2026-10-30'), confirm: true);
      final c = wc.billCandidatesFor(wc.bill(id)!);
      expect(c, hasLength(2));
      expect(c.first.tx.description, contains('SYNTHETIC WATER'));
      expect(wc.linkBill(id, c.first.tx.id), isTrue);
      expect(wc.billLists().paid.map((b) => b.id), [id]);
      expect(wc.billForTx(c.first.tx.id)!.id, id);
      expect(wc.billCandidatesFor(wc.bill(addBill(wc, syntheticBill('hub3:y', payee: 'Other')))!).map((t) => t.tx.id),
          isNot(contains(c.first.tx.id)),
          reason: 'a payment of another bill is not offered');
      wc.unlinkBill(id);
      expect(wc.billLists().unpaid.map((b) => b.id), [id]);
      expect(wc.billForTx(c.first.tx.id), isNull);
    });

    test('a deleted bill read again comes back as a new bill to review', () async {
      final wc = bw();
      final first = await wc.importScannedCode(const ScannedCode(CodeKind.qr, receiptQr));
      wc.deleteBill(first.billId!);
      expect(wc.billsAll(), isEmpty);
      final again = await wc.importScannedCode(const ScannedCode(CodeKind.qr, receiptQr));
      expect(again.kind, BillImportKind.added);
      expect(wc.billLists().review, hasLength(1));
    });

    test('deleting the paying payment makes the bill unpaid again', () {
      final wc = bw();
      final id = addBill(wc, syntheticBill('dp'), confirm: true);
      final tx = wc.billCandidatesFor(wc.bill(id)!).first.tx;
      wc.linkBill(id, tx.id);
      wc.addExpense(amount: 100, category: 'Groceries', note: '', date: '2026-10-19'); // another payment, not linked
      wc.repo.deleteTransaction(tx.id);
      wc.reload();
      expect(wc.bill(id)!.paid, isFalse);
      expect(wc.billLists().unpaid.map((b) => b.id), [id]);
    });

    test('a slip whose amount is 0 has no total and cannot be confirmed until one is typed', () async {
      final wc = bw();
      final r = await wc.importScannedCode(ScannedCode(CodeKind.pdf417, hub3Slip.replaceFirst('000000000004560', '000000000000000')));
      final b = wc.bill(r.billId!)!;
      expect(b.total, isNull);
      wc.updateBill(b.id, date: '2026-10-18');
      expect(wc.confirmBill(b.id), isFalse);
      wc.updateBill(b.id, total: 4560);
      expect(wc.confirmBill(b.id), isTrue);
    });

    test('one payment cannot pay two bills', () {
      final wc = bw();
      final a = addBill(wc, syntheticBill('a'), confirm: true);
      final b = addBill(wc, syntheticBill('b'), confirm: true);
      final tx = wc.billCandidatesFor(wc.bill(a)!).first.tx.id;
      expect(wc.linkBill(a, tx), isTrue);
      expect(wc.linkBill(b, tx), isFalse);
    });

    test('paid in cash adds a hand-made expense for the total and links it', () {
      final wc = bw();
      final id = addBill(wc, syntheticBill('cash', total: 2000, date: '2026-10-17'), confirm: true);
      final before = wc.txs.length;
      wc.addBillAsExpense(id, category: 'Groceries');
      expect(wc.txs.length, before + 1);
      final b = wc.bill(id)!;
      expect(b.paid, isTrue);
      final tx = wc.txs.firstWhere((t) => t.tx.id == b.linkedTx);
      expect(tx.amount, -2000);
      expect(tx.date, '2026-10-17');
    });

    test('delete takes the bill out of every list', () {
      final wc = bw();
      final id = addBill(wc, syntheticBill('d'));
      wc.deleteBill(id);
      expect(wc.billsAll(), isEmpty);
      expect(wc.billsToReview(), 0);
    });

    test('the original is "none" without a file and "missing" when it is not on this device', () async {
      final wc = bw();
      final id = addBill(wc, syntheticBill('nofile'));
      expect((await wc.billFile(wc.bill(id)!)).state, BillFileState.none);
      final r = await wc.importBillFile(tinyPng, 'jpg');
      final b = wc.bill(r.billId!)!;
      expect((await wc.billFile(b)).state, BillFileState.ready);
      final gone = Bill(id: 'g', source: BillSource.photo, blob: 'f' * 64, blobType: 'jpg');
      expect((await wc.billFile(gone)).state, BillFileState.missing);
    });

    test('search finds bills by payee, description and total', () {
      final wc = bw();
      addBill(wc, syntheticBill('s1'));
      expect(wc.searchBills('synthetic').single.payee, 'Synthetic Water');
      expect(wc.searchBills('water bill'), hasLength(1));
      expect(wc.searchBills('45,60'), hasLength(1));
      expect(wc.searchBills('zzz'), isEmpty);
    });
  });

  group('Upcoming and reminders', () {
    test('a confirmed bill with warranty and return-by dates lists them without amounts; a bill in review does not', () {
      final wc = bw();
      final id = addBill(wc, syntheticBill('w'), confirm: true);
      wc.setBillDates(id, warrantyUntil: '2026-10-28', returnBy: '2026-10-25');
      addBill(wc, syntheticBill('r', payee: 'Review only'));
      final items = wc.upcomingItems('2026-10-20', '2026-10-31');
      final dates = items.where((i) => i.key.startsWith('w:') || i.key.startsWith('r:')).toList();
      expect(dates.map((i) => i.key), ['r:$id', 'w:$id']);
      expect(dates.every((i) => i.amount == null), isTrue);
      expect(wc.countedIn(items).count, 0, reason: 'dates are never counted');
      wc.setBillDates(id, clearWarranty: true);
      expect(wc.upcomingItems('2026-10-20', '2026-10-31').where((i) => i.key.startsWith('w:')), isEmpty);
    });

    test('reminders are scheduled at 09:00, say how many days are left, and name no payee or amount', () async {
      final nudges = FakeNudges();
      final wc = bw(nudges: nudges);
      expect(await wc.setHeadsUpNotify(true), isTrue);
      final id = addBill(wc, syntheticBill('rem', payee: 'Zzyzx Shop', total: 98765), confirm: true);
      wc.setBillDates(id, returnBy: '2026-10-25', warrantyUntil: '2027-01-10');
      await wc.rescheduleHeadsUps();
      final slots = nudges.billReminders.last;
      expect(slots.map((s) => (s.date, s.hour, s.body)),
          [('2026-10-22', 9, 'A return window ends in 3 days'), ('2026-12-27', 9, 'A warranty ends in 14 days')]);
      for (final s in slots) {
        expect('${s.title} ${s.body}', isNot(anyOf(contains('Zzyzx'), contains('987'), contains('Water'))));
      }
    });

    test('rescheduleNudges ends by scheduling the bill reminders too, and they stop when the switch is off', () async {
      final nudges = FakeNudges();
      final wc = bw(nudges: nudges);
      final id = addBill(wc, syntheticBill('rem2'), confirm: true);
      wc.setBillDates(id, returnBy: '2026-10-25');
      await wc.setHeadsUpNotify(true);
      nudges.billReminders.clear();
      await wc.rescheduleNudges();
      expect(nudges.billReminders, isNotEmpty);
      final cancelled = nudges.billReminderCancelled;
      await wc.setHeadsUpNotify(false);
      await wc.rescheduleHeadsUps();
      expect(nudges.billReminderCancelled, greaterThan(cancelled));
    });

    test('billReminderSlots: the next 09:00 when the day has passed, none after the end date; at most 20', () {
      final now = DateTime(2026, 10, 20, 12);
      final s = billReminderSlots(now, [('2026-10-21', false, 3), ('2026-10-20', true, 14), ('2026-11-30', true, 14)]);
      expect(s.map((x) => (x.date, x.body)), [('2026-10-21', 'A return window ends today'), ('2026-11-16', 'A warranty ends in 14 days')]);
      final many = billReminderSlots(now, [for (var i = 0; i < 30; i++) (addDays('2026-11-01', i), true, 0)]);
      expect(many, hasLength(billMax));
      expect(billFirstId, 1020);
      expect(billReminderBody(warranty: false, daysLeft: 1), 'A return window ends tomorrow');
    });
  });

  group('Plan › Bills', () {
    tw('an empty list says what to do and offers the import button; Scan bill only where there is a camera', (tester) async {
      final wc = bw(inputs: FakeBillInputs(camera: FakeCamera(canShow: false)));
      await pumpApp(tester, Scaffold(body: BillsPanel(wc: wc)), size: const Size(400, 900));
      expect(find.textContaining('No bills yet'), findsOneWidget);
      expect(key('importBill'), findsOneWidget);
      expect(key('scanBillPlan'), findsNothing);
      final wc2 = bw();
      await pumpApp(tester, Scaffold(body: BillsPanel(wc: wc2)), size: const Size(400, 900));
      expect(key('scanBillPlan'), findsOneWidget);
    });

    tw('To review, Unpaid and Paid lists with their counts; a tap opens the bill', (tester) async {
      final wc = bw();
      addBill(wc, syntheticBill('r1', payee: 'Review Shop'));
      final unpaid = addBill(wc, syntheticBill('u1', payee: 'Unpaid Utility', due: '2026-10-15'), confirm: true);
      final paid = addBill(wc, syntheticBill('p1', payee: 'Paid Store'), confirm: true);
      wc.linkBill(paid, wc.billCandidatesFor(wc.bill(paid)!).first.tx.id);
      await pumpApp(tester, Scaffold(body: BillsPanel(wc: wc)), size: const Size(400, 1400));
      expect(find.text('To review (1)'), findsOneWidget);
      expect(find.text('Unpaid (1)'), findsOneWidget);
      expect(find.text('Paid (1)'), findsOneWidget);
      expect(find.textContaining('Overdue'), findsOneWidget, reason: 'the unpaid slip is past its due date');
      await tester.tap(key('bill:$unpaid'));
      await tester.pumpAndSettle();
      expect(find.text('Bill'), findsWidgets);
      expect(key('paidBy'), findsOneWidget);
    });

    tw('Import bill file: a PDF becomes a bill and its sheet opens; a second pick says it is already there', (tester) async {
      final wc = bw(inputs: FakeBillInputs(pictures: FakePictures(canRead: false), pdf: FakePdf(canRender: false)));
      final chooser = _Chooser()
        ..picks = [
          _Picked('a.pdf', smallPdf(['Datum racuna: 18.10.2026', 'Ukupno: 45,60 EUR']))
        ];
      await pumpApp(tester, Scaffold(body: BillsPanel(wc: wc, chooser: chooser)), size: const Size(400, 1000));
      await tester.tap(key('importBill'));
      await tester.pumpAndSettle();
      expect(wc.billsToReview(), 1);
      expect(key('confirmBill'), findsOneWidget, reason: 'the sheet of the new bill is open');
      Navigator.of(tester.element(key('confirmBill'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(key('importBill'));
      await tester.pumpAndSettle();
      expect(snack('Already in your bills'), findsOneWidget);
      expect(wc.billsAll(), hasLength(1));
    });

    tw('Import bill file: several files give one summary line; a failing chooser shows the usual message', (tester) async {
      final wc = bw();
      final chooser = _Chooser()
        ..picks = [
          _Picked('a.xml', bytesOfString(eInvoice)),
          _Picked('b.xml', bytesOfString(eInvoice)),
          _Picked('c.xml', bytesOfString('<nope/>')),
        ];
      await pumpApp(tester, Scaffold(body: BillsPanel(wc: wc, chooser: chooser)), size: const Size(400, 1000));
      await tester.tap(key('importBill'));
      await tester.pumpAndSettle();
      expect(snack("1 bill added to review · 1 already in your bills · 1 couldn't be read"), findsOneWidget);
      chooser.fail = true;
      await tester.tap(key('importBill'));
      await tester.pumpAndSettle();
      expect(snack(chooserFailedMessage), findsOneWidget);
      expect(lines.where((l) => l.contains('bills.pickerFailed')), hasLength(1));
    });

    test('billImportMessage', () {
      expect(billImportMessage([const BillImport(BillImportKind.added)]), 'Bill added to review');
      expect(
          billImportMessage([const BillImport(BillImportKind.added), const BillImport(BillImportKind.added)]), '2 bills added to review');
    });
  });

  group('the bill sheet', () {
    tw('a bill read from text marks its fields as unsure; one read from a code does not', (tester) async {
      final wc = bw();
      final text = addBill(wc, syntheticBill('t1', source: BillSource.pdf));
      await openSheetFor(tester, wc, text);
      expect(find.textContaining('Unsure'), findsWidgets);
      expect(find.byIcon(Icons.help_outline), findsWidgets);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      final code = addBill(wc, syntheticBill('c1'));
      await openSheetFor(tester, wc, code);
      expect(find.textContaining('Unsure'), findsNothing);
    });

    tw('Confirm without a total says so and keeps the sheet; with one it confirms and says so', (tester) async {
      final wc = bw();
      final id = addBill(wc, const NormalizedBill(source: BillSource.photo, externalId: 'file:y', date: '2026-10-18', unsure: 1));
      await openSheetFor(tester, wc, id);
      await tester.ensureVisible(key('confirmBill'));
      await tester.tap(key('confirmBill'));
      await tester.pumpAndSettle();
      expect(key('billError'), findsOneWidget);
      expect(wc.bill(id)!.status, BillStatus.review);
      await tester.enterText(key('billTotal'), '12.50');
      await tester.enterText(key('billPayee'), 'Typed Shop');
      await tester.ensureVisible(key('confirmBill'));
      await tester.tap(key('confirmBill'));
      await tester.pumpAndSettle();
      expect(snack('Bill confirmed'), findsOneWidget);
      final b = wc.bill(id)!;
      expect((b.status, b.total, b.payee), (BillStatus.confirmed, 1250, 'Typed Shop'));
    });

    tw('an IBAN that does not check out is refused; a valid one is kept', (tester) async {
      final wc = bw();
      final id = addBill(wc, syntheticBill('ib'));
      await openSheetFor(tester, wc, id);
      await tester.enterText(key('billIban'), 'HR1210010051863000161');
      await tester.ensureVisible(key('confirmBill'));
      await tester.tap(key('confirmBill'));
      await tester.pumpAndSettle();
      expect(find.textContaining('IBAN: check the number'), findsOneWidget);
      expect(wc.bill(id)!.iban, isNull);
      await tester.enterText(key('billIban'), 'hr12 1001 0051 8630 0016 0');
      await tester.ensureVisible(key('confirmBill'));
      await tester.tap(key('confirmBill'));
      await tester.pumpAndSettle();
      expect(wc.bill(id)!.iban, 'HR1210010051863000160');
    });

    tw('a total that is not an amount is refused and nothing is saved', (tester) async {
      final wc = bw();
      final id = addBill(wc, syntheticBill('bad'));
      await openSheetFor(tester, wc, id);
      await tester.enterText(key('billTotal'), 'abc');
      await tester.ensureVisible(key('confirmBill'));
      await tester.tap(key('confirmBill'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Total: enter an amount'), findsOneWidget);
      expect(wc.bill(id)!.total, 4560);
    });

    tw('items are listed', (tester) async {
      final wc = bw();
      final id = addBill(
          wc,
          const NormalizedBill(
              source: BillSource.eInvoice,
              externalId: 'inv:it',
              date: '2026-10-10',
              total: 3000,
              items: [BillItem(name: 'Synthetic pipe', quantity: '2', amount: 1000), BillItem(name: 'Synthetic tap', amount: 2000)]));
      await openSheetFor(tester, wc, id);
      expect(find.text('Synthetic pipe'), findsOneWidget);
      expect(find.text('Quantity 2'), findsOneWidget);
      expect(find.text('Synthetic tap'), findsOneWidget);
    });

    tw('"Paid by…" shows the payee match first and links the one tapped', (tester) async {
      final wc = bw();
      final id = addBill(wc, syntheticBill('pb'), confirm: true);
      await openSheetFor(tester, wc, id);
      await tester.ensureVisible(key('paidBy'));
      await tester.tap(key('paidBy'));
      await tester.pumpAndSettle();
      final ids = wc.billCandidatesFor(wc.bill(id)!).map((t) => t.tx.id).toList();
      expect(tester.getTopLeft(key('cand:${ids.first}')).dy, lessThan(tester.getTopLeft(key('cand:${ids.last}')).dy));
      await tester.tap(key('cand:${ids.first}'));
      await tester.pumpAndSettle();
      expect(snack('Marked as paid'), findsOneWidget);
      expect(wc.bill(id)!.linkedTx, ids.first);
    });

    tw('a paid bill shows the payment and Unlink; "Paid in cash" asks for a category and adds the expense', (tester) async {
      final wc = bw();
      final id = addBill(wc, syntheticBill('pc', total: 2000), confirm: true);
      await openSheetFor(tester, wc, id);
      await tester.ensureVisible(key('paidCash'));
      await tester.tap(key('paidCash'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Eating out'));
      await tester.pump();
      await tester.tap(key('addCashExpense'));
      await tester.pumpAndSettle();
      expect(wc.bill(id)!.paid, isTrue);
      expect(wc.txs.where((t) => t.amount == -2000 && t.category == 'Eating out'), hasLength(1));
      await openSheetFor(tester, wc, id);
      expect(find.textContaining('Paid'), findsWidgets);
      await tester.ensureVisible(key('unlinkBill'));
      await tester.tap(key('unlinkBill'));
      await tester.pumpAndSettle();
      expect(wc.bill(id)!.paid, isFalse);
    });

    tw('warranty and return-by can be cleared', (tester) async {
      final wc = bw();
      final id = addBill(wc, syntheticBill('wr'), confirm: true);
      wc.setBillDates(id, warrantyUntil: '2027-01-10', returnBy: '2026-11-01');
      await openSheetFor(tester, wc, id);
      await tester.ensureVisible(find.byTooltip('Clear Warranty until'));
      await tester.tap(find.byTooltip('Clear Warranty until'));
      await tester.pumpAndSettle();
      expect(wc.bill(id)!.warrantyUntil, isNull);
      expect(wc.bill(id)!.returnBy, '2026-11-01');
      await tester.tap(find.byTooltip('Clear Return by'));
      await tester.pumpAndSettle();
      expect(wc.bill(id)!.returnBy, isNull);
    });

    tw('Delete asks first; Keep keeps it, Delete removes it', (tester) async {
      final wc = bw();
      final id = addBill(wc, syntheticBill('del'));
      await openSheetFor(tester, wc, id);
      await tester.ensureVisible(key('deleteBill'));
      await tester.tap(key('deleteBill'));
      await tester.pumpAndSettle();
      await tester.tap(key('deleteBillKeep'));
      await tester.pumpAndSettle();
      expect(wc.billsAll(), hasLength(1));
      await tester.tap(key('deleteBill'));
      await tester.pumpAndSettle();
      await tester.tap(key('deleteBillYes'));
      await tester.pumpAndSettle();
      expect(wc.billsAll(), isEmpty);
      expect(snack('Bill deleted'), findsOneWidget);
    });

    tw('Show photo opens the picture; Show PDF on Linux offers Save file…; a file only on the relay says to sync', (tester) async {
      final wc = bw(inputs: FakeBillInputs(pdf: FakePdf(canRender: false, jpeg: tinyPng)));
      final photo = (await tester.runAsync(() => wc.importBillFile(tinyPng, 'png')))!;
      await openSheetFor(tester, wc, photo.billId!);
      await tester.ensureVisible(key('showBillFile'));
      expect(find.descendant(of: key('showBillFile'), matching: find.text('Show photo')), findsOneWidget);
      await tester.tap(key('showBillFile'));
      await tester.pumpAndSettle();
      expect(key('billImage'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      Navigator.of(tester.element(key('billImage'))).pop();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(key('showBillFile'))).pop();
      await tester.pumpAndSettle();

      final chooser = _Chooser();
      final pdf = (await tester.runAsync(() => wc.importBillFile(smallPdf(['Ukupno: 5,00 EUR']), 'pdf')))!;
      await openSheetFor(tester, wc, pdf.billId!, chooser: chooser);
      await tester.ensureVisible(key('showBillFile'));
      expect(find.descendant(of: key('showBillFile'), matching: find.text('Show PDF')), findsOneWidget);
      await tester.tap(key('showBillFile'));
      await tester.pumpAndSettle();
      await tester.tap(key('saveBillFile'));
      await tester.pumpAndSettle();
      expect(chooser.saved, hasLength(1));
      expect(chooser.saved.single.name, endsWith('.pdf'));
      Navigator.of(tester.element(key('saveBillFile'))).pop();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(key('showBillFile'))).pop();
      await tester.pumpAndSettle();

      final far = Bill(id: 'far', source: BillSource.photo, blob: 'a' * 64, blobType: 'jpg');
      await pumpApp(tester, BillFileScreen(wc: wc, bill: far));
      await tester.pumpAndSettle();
      expect(key('fileOnRelay'), findsOneWidget);
    });

    tw('on Android a PDF is shown page by page from the rendered pages', (tester) async {
      final wc = bw(inputs: FakeBillInputs(pdf: FakePdf(pages: [tinyPng, tinyPng])));
      final r = (await tester.runAsync(() => wc.importBillFile(smallPdf(['Ukupno: 5,00 EUR']), 'pdf')))!;
      await pumpApp(tester, BillFileScreen(wc: wc, bill: wc.bill(r.billId!)!));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNWidgets(2));
    });
  });

  group('Scan bill', () {
    tw('Add expense offers Scan bill only where there is a camera', (tester) async {
      final none = bw(inputs: FakeBillInputs(camera: FakeCamera(canShow: false)));
      await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: AddExpenseSheet(wc: none))), size: const Size(400, 1400));
      expect(key('scanBill'), findsNothing);
      final wc = bw();
      await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: AddExpenseSheet(wc: wc))), size: const Size(400, 1400));
      expect(key('scanBill'), findsOneWidget);
    });

    tw('a QR seen by the camera closes the camera and opens the bill to review', (tester) async {
      final fakes = FakeBillInputs();
      final wc = bw(inputs: fakes);
      await pumpApp(
          tester, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => scanBillFlow(c, wc), child: const Text('go')))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(key('fakeCamera'), findsOneWidget);
      await tester.runAsync(() async {
        fakes.camera.emit(const ScannedCode(CodeKind.qr, receiptQr));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(key('confirmBill'), findsOneWidget);
      expect(wc.billsToReview(), 1);
    });

    tw('a code that is not a bill gives a hint and the camera stays; the same code seen again is ignored', (tester) async {
      final fakes = FakeBillInputs();
      final wc = bw(inputs: fakes);
      await pumpApp(tester, ScanBillScreen(wc: wc));
      await tester.runAsync(() async {
        fakes.camera.emit(const ScannedCode(CodeKind.qr, 'https://example.org/x'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(key('scanHint'), findsOneWidget);
      expect(wc.billsAll(), isEmpty);
    });

    tw('Take photo keeps the frame, reads its text and opens the bill with unsure marks', (tester) async {
      final fakes = FakeBillInputs(camera: FakeCamera(photo: tinyPng));
      fakes.pictures.textResult = 'Datum racuna 05.10.2026\nUkupno 12,50';
      final wc = bw(inputs: fakes);
      await pumpApp(
          tester, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => scanBillFlow(c, wc), child: const Text('go')))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(key('takePhoto'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(key('confirmBill'), findsOneWidget);
      final b = wc.billLists().review.single;
      expect((b.source, b.total, b.date), (BillSource.photo, 1250, '2026-10-05'));
      expect(b.blob, isNotNull);
      expect(find.textContaining('Unsure'), findsWidgets);
    });

    tw('a photo that fails says so; a refused camera permission has its own words', (tester) async {
      final fakes = FakeBillInputs(camera: FakeCamera()..photoError = 'failed');
      final wc = bw(inputs: fakes);
      await pumpApp(tester, ScanBillScreen(wc: wc));
      await tester.runAsync(() async {
        await tester.tap(key('takePhoto'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(key('scanHint'), findsOneWidget);
      expect(find.textContaining("Couldn't take the photo"), findsOneWidget);
      fakes.camera.photoError = 'permission';
      await tester.runAsync(() async {
        await tester.tap(key('takePhoto'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.textContaining('camera is off'), findsOneWidget);
      expect(wc.billsAll(), isEmpty);
    });

    tw('an unexpected crash while taking the photo says so and logs the type only', (tester) async {
      final fakes = FakeBillInputs(camera: FakeCamera()..crash = true);
      final wc = bw(inputs: fakes);
      await pumpApp(tester, ScanBillScreen(wc: wc));
      await tester.runAsync(() async {
        await tester.tap(key('takePhoto'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.textContaining("Couldn't take the photo"), findsOneWidget);
      final logged = lines.where((l) => l.contains('scan.photoFailed')).toList();
      expect(logged, isNotEmpty, reason: 'the catch logs instead of swallowing');
      expect(logged.join(), allOf(contains('SyntheticCrash'), isNot(contains('SYNTHETIC-SECRET-TEXT'))));
    });

    tw('cancelling the system camera comes back to the scanner with nothing said and nothing added', (tester) async {
      final fakes = FakeBillInputs(); // photo stays null = cancelled
      final wc = bw(inputs: fakes);
      await pumpApp(tester, ScanBillScreen(wc: wc));
      await tester.runAsync(() async {
        await tester.tap(key('takePhoto'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(fakes.camera.photoCalls, 1);
      expect(key('scanHint'), findsNothing);
      expect(key('fakeCamera'), findsOneWidget);
      expect(tester.widget<FilledButton>(key('takePhoto')).onPressed, isNotNull, reason: 'the button works again');
      expect(wc.billsAll(), isEmpty);
    });
  });

  group('Today, Spending, Upcoming, Search', () {
    tw('Today shows "N bills to review" only when there are some, and the tap opens Plan › Bills', (tester) async {
      final wc = bw();
      await pumpApp(tester, todayOf(wc), size: const Size(400, 1400));
      expect(key('billsToReview'), findsNothing);
      addBill(wc, syntheticBill('t1'));
      addBill(wc, syntheticBill('t2', payee: 'Second'));
      var opened = 0;
      await pumpApp(tester, todayOf(wc, openBillsReview: () => opened++), size: const Size(400, 1400));
      expect(find.descendant(of: key('billsToReview'), matching: find.text('2')), findsOneWidget);
      expect(find.descendant(of: key('billsToReview'), matching: find.text('bills')), findsOneWidget);
      await tester.tap(key('billsToReview'));
      expect(opened, 1);
      wc.confirmBill(wc.billLists().review.first.id);
      await pumpApp(tester, todayOf(wc), size: const Size(400, 1400));
      expect(find.descendant(of: key('billsToReview'), matching: find.text('bill')), findsOneWidget);
    });

    tw('a payment with a linked bill shows the receipt mark and "Open bill"', (tester) async {
      final wc = bw();
      final id = addBill(wc, syntheticBill('l'), confirm: true);
      final tx = wc.billCandidatesFor(wc.bill(id)!).first;
      await pumpApp(tester, todayOf(wc), size: const Size(400, 1800));
      expect(key('billMark'), findsNothing);
      wc.linkBill(id, tx.tx.id);
      await pumpApp(tester, todayOf(wc), size: const Size(400, 1800));
      expect(key('billMark'), findsOneWidget);
      await pumpApp(
          tester,
          Scaffold(
              body: Builder(
                  builder: (c) => TextButton(onPressed: () => showSheet<String>(c, TxSheet(wc: wc, t: tx)), child: const Text('tx')))));
      await tester.tap(find.text('tx'));
      await tester.pumpAndSettle();
      await tester.tap(key('openBill'));
      await tester.pumpAndSettle();
      expect(find.text('Bill'), findsWidgets);
      expect(key('paidBy'), findsNothing, reason: 'the bill is paid: Unlink, not Paid by');
      expect(key('unlinkBill'), findsOneWidget);
    });

    tw('a payment without a bill has no Open bill', (tester) async {
      final wc = bw();
      final tx = wc.txs.first;
      await pumpApp(
          tester,
          Scaffold(
              body: Builder(
                  builder: (c) => TextButton(onPressed: () => showSheet<String>(c, TxSheet(wc: wc, t: tx)), child: const Text('tx')))));
      await tester.tap(find.text('tx'));
      await tester.pumpAndSettle();
      expect(key('openBill'), findsNothing);
    });

    tw('Upcoming lists warranty and return-by rows with their words, no amount, and opens the bill', (tester) async {
      final wc = bw();
      final id = addBill(wc, syntheticBill('up', payee: 'Gadget Shop'), confirm: true);
      wc.setBillDates(id, warrantyUntil: '2026-10-28', returnBy: '2026-10-24');
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1800));
      expect(key('up:w:$id'), findsOneWidget);
      expect(key('up:r:$id'), findsOneWidget);
      expect(find.descendant(of: key('up:w:$id'), matching: find.text('Warranty')), findsOneWidget);
      expect(find.descendant(of: key('up:r:$id'), matching: find.text('Return by')), findsOneWidget);
      expect(find.descendant(of: key('up:w:$id'), matching: find.text('No amount')), findsNothing);
      expect(find.text('Return by'), findsWidgets, reason: 'the legend');
      await tester.tap(key('up:r:$id'));
      await tester.pumpAndSettle();
      expect(key('saveBill'), findsOneWidget);
    });

    tw('an unpaid bill with a due date is a planned row labelled Bill; paying the bill closes it', (tester) async {
      final wc = bw();
      final id = addBill(wc, syntheticBill('pl', due: '2026-10-25'), confirm: true, category: 'Bills & one-offs'); // flex: reserves money
      final row = key('up:p:${WalletRepo.billPlannedId(id)}');
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1800));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Bill')), findsOneWidget);
      expect(wc.comingUp().count, 1, reason: 'the slip reserves its money like any planned cost');
      wc.linkBill(id, wc.billCandidatesFor(wc.bill(id)!).first.tx.id);
      expect(wc.comingUp().count, 0);
    });

    tw('search has a Bills section; a tap opens the bill', (tester) async {
      final wc = bw();
      final id = addBill(wc, syntheticBill('sr', payee: 'Findable Plumbing'));
      await pumpApp(tester, Scaffold(body: SearchPane(wc: wc, onClose: () {}, onOpenTab: (_) {}, onOpenBills: () {})),
          size: const Size(400, 900));
      await tester.enterText(key('searchField'), 'plumb');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('BILLS'), findsOneWidget);
      expect(find.text('Findable Plumbing'), findsOneWidget);
      expect(find.text('Nothing found'), findsNothing);
      await tester.tap(find.text('Findable Plumbing'));
      await tester.pumpAndSettle();
      expect(key('confirmBill'), findsOneWidget);
      expect(wc.bill(id), isNotNull);
    });
  });

  group('review fixes (B5b)', () {
    // ---- 1. category before Confirm ----
    test('a slip still to be paid cannot be confirmed without a category; once it has one it can', () {
      final wc = bw();
      final (id, _) = wc.repo.importBill(syntheticBill('cat1', due: '2026-10-25'));
      wc.reload();
      expect(wc.billNeedsCategory(wc.bill(id)!), isTrue);
      expect(wc.confirmBill(id), isFalse);
      expect(wc.bill(id)!.status, BillStatus.review);
      wc.updateBill(id, category: 'Bills & subscriptions');
      expect(wc.confirmBill(id), isTrue);
    });

    test('a due date in the past, or none, needs no category', () {
      final wc = bw();
      final late = addBill(wc, syntheticBill('cat2', due: '2026-10-10'));
      final none = addBill(wc, syntheticBill('cat3'));
      expect(wc.confirmBill(late), isTrue);
      expect(wc.confirmBill(none), isTrue);
    });

    tw('Confirm on the sheet asks for the category first, says why, and works after picking one', (tester) async {
      final wc = bw();
      wc.seams.billCategorySuggester = (b) => null; // the real core would offer one from the water payment
      final id = addBill(wc, syntheticBill('cat4', due: '2026-10-25'));
      await openSheetFor(tester, wc, id, size: const Size(400, 1600));
      expect(find.text("Pick the category so Budget Wallet doesn't count this bill twice."), findsOneWidget);
      await tester.ensureVisible(key('confirmBill'));
      await tester.tap(key('confirmBill'));
      await tester.pumpAndSettle();
      expect(key('billError'), findsOneWidget);
      expect(wc.bill(id)!.status, BillStatus.review);
      await tester.ensureVisible(key('billCategory:'));
      await tester.tap(key('billCategory:'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bills & subscriptions').last);
      await tester.pumpAndSettle();
      expect(key('billError'), findsNothing, reason: 'picking clears the message');
      await tester.ensureVisible(key('confirmBill'));
      await tester.tap(key('confirmBill'));
      await tester.pumpAndSettle();
      final b = wc.bill(id)!;
      expect((b.status, b.category), (BillStatus.confirmed, 'Bills & subscriptions'));
    });

    tw('the category is prefilled from the suggestion and marked as one; Confirm then works as it is', (tester) async {
      final wc = bw();
      wc.seams.billCategorySuggester = (b) => 'Bills & subscriptions';
      final id = addBill(wc, syntheticBill('cat5', due: '2026-10-25'));
      await openSheetFor(tester, wc, id, size: const Size(400, 1600));
      expect(find.text('Suggested from your earlier bills. Check it.'), findsOneWidget);
      expect(find.text("Pick the category so Budget Wallet doesn't count this bill twice."), findsNothing);
      await tester.ensureVisible(key('confirmBill'));
      await tester.tap(key('confirmBill'));
      await tester.pumpAndSettle();
      expect(wc.bill(id)!.category, 'Bills & subscriptions');
      expect(wc.bill(id)!.status, BillStatus.confirmed);
    });

    tw('a bill that already has a category is not marked as suggested; no suggestion leaves the field empty', (tester) async {
      final wc = bw();
      wc.seams.billCategorySuggester = (b) => 'Groceries';
      final id = addBill(wc, syntheticBill('cat6', due: '2026-10-25'));
      wc.updateBill(id, category: 'Rent');
      await openSheetFor(tester, wc, id, size: const Size(400, 1600));
      expect(find.text('Suggested from your earlier bills. Check it.'), findsNothing);
      expect(wc.bill(id)!.category, 'Rent');
    });

    // ---- 2. "Already in your bills" is not a dead end ----
    test('the same slip again says it is already there and offers to add it as a new bill', () async {
      final wc = bw();
      final first = await wc.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip));
      final again = await wc.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip));
      expect(again.kind, BillImportKind.duplicate);
      expect(again.message, 'Already in your bills');
      expect(again.addAsNew, isNotNull);
      final added = await again.addAsNew!();
      expect(added.kind, BillImportKind.added);
      expect(added.billId, isNot(first.billId));
      expect(wc.billsAll(), hasLength(2));
    });

    test('when the bill there is paid, or past its due date, the words ask about a new one', () async {
      final wc = bw();
      final first = await wc.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip));
      wc.updateBill(first.billId!, date: '2026-10-18', dueDate: '2026-10-25', category: 'Bills & subscriptions');
      wc.confirmBill(first.billId!);
      wc.unlinkBill(first.billId!); // confirming linked it to the water payment on its own
      expect((await wc.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip))).message, 'Already in your bills',
          reason: 'still open and not late');
      wc.linkBill(first.billId!, wc.billCandidatesFor(wc.bill(first.billId!)!).first.tx.id);
      final paid = await wc.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip));
      expect(paid.message, 'You already paid a bill like this. Add it as a new one?');
      final other = bw();
      final f2 = await other.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip));
      other.updateBill(f2.billId!, date: '2026-09-18', dueDate: '2026-10-05');
      other.confirmBill(f2.billId!);
      final late = await other.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip));
      expect(late.message, 'You already paid a bill like this. Add it as a new one?');
    });

    tw('the message has an "Add as new bill" action that adds it and opens the new bill', (tester) async {
      final wc = bw();
      await wc.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip));
      final again = await wc.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip));
      await pumpApp(tester,
          Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => showBillImport(c, wc, again), child: const Text('go')))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(snack('Already in your bills'), findsOneWidget);
      await tester.tap(find.text('Add as new bill'));
      await tester.pumpAndSettle();
      expect(wc.billsAll(), hasLength(2));
      expect(key('confirmBill'), findsOneWidget, reason: 'the new bill opens');
    });

    // ---- 3. a bill's planned row is the bill ----
    tw('Upcoming opens a bill row as the bill, not as a planned cost', (tester) async {
      final wc = bw();
      final id = addBill(wc, syntheticBill('up1', due: '2026-10-25'), confirm: true);
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1800));
      await tester.tap(key('up:p:${WalletRepo.billPlannedId(id)}'));
      await tester.pumpAndSettle();
      expect(key('paidBy'), findsOneWidget);
      expect(key('entrySkip'), findsNothing);
    });

    tw('a heads-up line for a bill opens the bill', (tester) async {
      final wc = bw();
      wc.saveHeadsUp(cents: 0, days: 14);
      final id = addBill(wc, syntheticBill('up2', due: '2026-10-25'), confirm: true);
      final h = wc.headsUpLines().single;
      await pumpApp(tester, todayOf(wc), size: const Size(400, 1800));
      await tester.ensureVisible(key('headsUp:${h.item.key}'));
      await tester.tap(key('headsUp:${h.item.key}'));
      await tester.pumpAndSettle();
      expect(key('paidBy'), findsOneWidget);
      expect(wc.bill(id), isNotNull);
    });

    tw('a planned-cost search result for a bill opens the bill', (tester) async {
      final wc = bw();
      final id = addBill(wc, syntheticBill('up3', due: '2026-10-25', payee: 'Findable Plumbing'), confirm: true);
      await pumpApp(tester, Scaffold(body: SearchPane(wc: wc, onClose: () {}, onOpenTab: (_) {}, onOpenBills: () {})),
          size: const Size(400, 1200));
      await tester.enterText(key('searchField'), 'plumb');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('PLANNED COSTS'), findsOneWidget);
      await tester.tap(find.textContaining('Bills & subscriptions'));
      await tester.pumpAndSettle();
      expect(key('paidBy'), findsOneWidget);
      expect(wc.bill(id), isNotNull);
    });

    // ---- 4. size checks before reading ----
    test('a PDF over 15 MB is refused before it is read; a picture up to 40 MB is sized down first', () async {
      var parsed = 0;
      final fakes = FakeBillInputs(pdf: FakePdf(jpeg: Uint8List.fromList([1, 2, 3])));
      final wc = bw(inputs: fakes);
      wc.seams.pdfParser = (pdf) async {
        parsed++;
        return (text: null, bill: null);
      };
      final r = await wc.importBillFile(Uint8List(15 * 1024 * 1024 + 1), 'pdf');
      expect(r.kind, BillImportKind.tooBig);
      expect(r.message, 'This file is too big for a bill (max 15 MB).');
      expect(parsed, 0, reason: 'refused before any reading');
      final pic = await wc.importBillFile(Uint8List(20 * 1024 * 1024), 'jpg');
      expect(pic.kind, BillImportKind.added);
      expect((await wc.importBillFile(Uint8List(40 * 1024 * 1024 + 1), 'jpg')).kind, BillImportKind.tooBig);
    });

    test('a picture that is still over 15 MB after sizing down is refused', () async {
      final wc = bw(inputs: FakeBillInputs(pdf: FakePdf(jpeg: Uint8List(15 * 1024 * 1024 + 1))));
      expect((await wc.importBillFile(Uint8List(20 * 1024 * 1024), 'jpg')).kind, BillImportKind.tooBig);
      expect(wc.billsAll(), isEmpty);
    });

    test('the byte limits per type', () {
      expect(maxBillFileBytes('pdf'), 15 * 1024 * 1024);
      expect(maxBillFileBytes('.xml'), 15 * 1024 * 1024);
      expect(maxBillFileBytes('JPG'), 40 * 1024 * 1024);
      expect(maxBillFileBytes('png'), 40 * 1024 * 1024);
    });

    tw('Import bill file asks the size first: a huge file is never read and says so', (tester) async {
      final wc = bw();
      final chooser = _Chooser()..picks = [_Huge('big.pdf', 16 * 1024 * 1024)];
      await pumpApp(tester, Scaffold(body: BillsPanel(wc: wc, chooser: chooser)), size: const Size(400, 1000));
      await tester.tap(key('importBill'));
      await tester.pumpAndSettle();
      expect(snack('This file is too big for a bill (max 15 MB).'), findsOneWidget);
      expect(wc.billsAll(), isEmpty);
    });

    test('a shared file that was too big says so and adds nothing', () async {
      final fakes = FakeBillInputs(share: FakeShare(initialFiles: [SharedFile(Uint8List(0), 'pdf', tooBig: true)]));
      final wc = bw(inputs: fakes);
      final results = <BillImport>[];
      final sub = wc.sharedBillResults.listen(results.add);
      addTearDown(sub.cancel);
      await wc.startSharing();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(results.single.kind, BillImportKind.tooBig);
      expect(wc.billsAll(), isEmpty);
    });

    // ---- 5. PDF reading off the UI isolate ----
    test('a PDF is read through the isolate path on native, and through the swappable reader', () async {
      final wc = bw(inputs: FakeBillInputs(pictures: FakePictures(canRead: false), pdf: FakePdf(canRender: false)));
      wc.seams.pdfParser = parsePdf; // the real one: Isolate.run
      final before = pdfParsedOffUi;
      final r = await wc.importBillFile(smallPdf(['Datum racuna: 18.10.2026', 'Ukupno: 45,60 EUR']), 'pdf');
      expect(wc.bill(r.billId!)!.total, 4560);
      expect(pdfParsedOffUi, before + 1, reason: 'pdfText + billFromText ran in Isolate.run, not on the UI isolate');
      var calls = 0;
      wc.seams.pdfParser = (pdf) async {
        calls++;
        return (text: 'Ukupno: 10,00 EUR\n01.10.2026', bill: null);
      };
      await wc.importBillFile(smallPdf(['x']), 'pdf');
      expect(calls, 1);
    });

    test('a PDF the reader fails on is still kept, to be typed', () async {
      final wc = bw(inputs: FakeBillInputs(pictures: FakePictures(canRead: false), pdf: FakePdf(canRender: false)));
      wc.seams.pdfParser = (pdf) async => throw StateError('boom');
      final r = await wc.importBillFile(smallPdf(['Ukupno: 5,00 EUR']), 'pdf');
      expect(r.kind, BillImportKind.added);
      expect(wc.bill(r.billId!)!.total, isNull);
    });

    // ---- core merged: real suggestion, "Planned by", older relay ----
    /// A wallet with a confirmed expected bill for a made-up gym (three monthly card rows), next due 25 Oct.
    WalletController withGymBill() {
      final wc = bw();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (final d in const ['2026-07-25', '2026-08-25', '2026-09-25']) syntheticTx(d, -2999, 'POS plaćanje', 'POS SYNTHGYM ZAGREB'),
      ]));
      wc.reload();
      final cand = wc.recurringBills().singleWhere((r) => r.label.toLowerCase().contains('synthgym'));
      wc.confirmRecurring(cand.id);
      return wc;
    }

    test('the real core suggests the category of the expected bill with the same payee', () {
      final wc = withGymBill();
      final r = wc.recurringBills().singleWhere((r) => r.confirmed);
      final id = addBill(wc, syntheticBill('gym1', payee: 'SYNTHGYM ZAGREB', due: '2026-10-25'));
      expect(wc.suggestedBillCategory(wc.bill(id)!), r.category);
      expect(wc.suggestedBillCategory(wc.bill(addBill(wc, syntheticBill('x1', payee: 'Unknown Plumber')))!), isNull);
    });

    tw('the bill sheet says which expected bill already plans the slip, and says nothing for another payee', (tester) async {
      final wc = withGymBill();
      final label = wc.recurringBills().singleWhere((r) => r.confirmed).label;
      final id = addBill(wc, syntheticBill('gym2', payee: 'SYNTHGYM ZAGREB', due: '2026-10-25'));
      expect(wc.billPlannedBy(wc.bill(id)!)?.label, label);
      await openSheetFor(tester, wc, id, size: const Size(400, 1600));
      expect(find.text('Planned by $label'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      final other = addBill(wc, syntheticBill('gym3', payee: 'Unknown Plumber', due: '2026-10-25'));
      expect(wc.billPlannedBy(wc.bill(other)!), isNull);
      await openSheetFor(tester, wc, other, size: const Size(400, 1600));
      expect(key('plannedBy'), findsNothing);
    });

    tw('Plan › Sync tells that an older relay cannot keep bill photos', (tester) async {
      final wc = bw();
      wc.seams.syncRunner = (relay, k, r) async => const SyncReport(0, 0, 0, caughtUp: true, blobsWaiting: 2, blobsUnsupported: true);
      await tester.runAsync(() => wc.setRelay(Uri.parse('http://homeserver.local:8787')));
      await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: SyncPanel(wc: wc, onShowKey: () {}))), size: const Size(400, 1200));
      expect(find.textContaining("This relay can't keep bill photos yet. Update the relay on the home server.", findRichText: true),
          findsOneWidget);
      wc.seams.syncRunner = (relay, k, r) async => const SyncReport(0, 0, 0, caughtUp: true, blobsWaiting: 2);
      await tester.runAsync(wc.syncNow);
      await tester.pump();
      expect(key('blobsUnsupported'), findsNothing);
      expect(find.textContaining('2 bill files waiting to upload', findRichText: true), findsOneWidget);
    });

    // ---- 7. reminder days and waiting bill files ----
    tw('Plan › Bills saves the reminder days and refuses numbers out of range', (tester) async {
      final wc = bw();
      await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: BillsPanel(wc: wc))), size: const Size(400, 1600));
      expect(tester.widget<TextField>(key('returnReminderDays')).controller!.text, '3');
      expect(tester.widget<TextField>(key('warrantyReminderDays')).controller!.text, '14');
      await tester.enterText(key('returnReminderDays'), '31');
      await tester.ensureVisible(key('remindSave'));
      await tester.tap(key('remindSave'));
      await tester.pumpAndSettle();
      expect(key('remindError'), findsOneWidget);
      expect(wc.returnReminderDays, 3);
      await tester.enterText(key('returnReminderDays'), '7');
      await tester.enterText(key('warrantyReminderDays'), '91');
      await tester.tap(key('remindSave'));
      await tester.pumpAndSettle();
      expect(key('remindError'), findsOneWidget);
      expect(wc.warrantyReminderDays, 14);
      await tester.enterText(key('warrantyReminderDays'), '30');
      await tester.tap(key('remindSave'));
      await tester.pumpAndSettle();
      expect(key('remindError'), findsNothing);
      expect((wc.returnReminderDays, wc.warrantyReminderDays), (7, 30));
      expect(wc.settings.returnReminderDays, 7);
    });

    test('saveBillReminderDays checks both ranges (0 is on the day)', () {
      final wc = bw();
      expect(wc.saveBillReminderDays(returnDays: 0, warrantyDays: 0), isTrue);
      expect(wc.saveBillReminderDays(returnDays: 30, warrantyDays: 90), isTrue);
      expect(wc.saveBillReminderDays(returnDays: 31, warrantyDays: 5), isFalse);
      expect(wc.saveBillReminderDays(returnDays: 5, warrantyDays: -1), isFalse);
      expect((wc.returnReminderDays, wc.warrantyReminderDays), (30, 90));
    });

    tw('Plan › Sync says how many bill files wait to upload, only when some do', (tester) async {
      final wc = bw();
      wc.seams.syncRunner = (relay, k, r) async => const SyncReport(0, 0, 0, caughtUp: true, blobsWaiting: 2);
      await tester.runAsync(() => wc.setRelay(Uri.parse('http://homeserver.local:8787')));
      await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: SyncPanel(wc: wc, onShowKey: () {}))), size: const Size(400, 1200));
      expect(find.textContaining('2 bill files waiting to upload', findRichText: true), findsOneWidget);
      wc.seams.syncRunner = (relay, k, r) async => const SyncReport(0, 0, 0, caughtUp: true, blobsWaiting: 1);
      await tester.runAsync(wc.syncNow);
      await tester.pump();
      expect(find.textContaining('1 bill file waiting to upload', findRichText: true), findsOneWidget);
      wc.seams.syncRunner = (relay, k, r) async => const SyncReport(0, 0, 0, caughtUp: true);
      await tester.runAsync(wc.syncNow);
      await tester.pump();
      expect(key('blobsWaiting'), findsNothing);
    });
  });

  group('final fixes (B6)', () {
    /// A confirmed, unpaid bill due from today on with no category: confirmed while paid (no category needed then), then
    /// unlinked, as after a deleted payment. Bills confirmed before B5a look the same.
    String reopenedWithoutCategory(WalletController wc) {
      final (id, _) = wc.repo.importBill(syntheticBill('b6-open', due: '2026-10-25', payee: 'Synthetic Gas'));
      final tx = wc.repo.transactions().firstWhere((t) => t.description.contains('SYNTHSHOP'));
      wc.repo.linkBill(id, tx.id);
      wc.repo.confirmBill(id);
      wc.repo.unlinkBill(id);
      wc.reload();
      final b = wc.bill(id)!;
      expect((b.confirmed, b.paid, b.category), (true, false, null));
      return id;
    }

    test('B6 bug: updateBill/setBillDates threw on a reopened bill without a category; now small edits save, others return false', () {
      final wc = bw();
      final id = reopenedWithoutCategory(wc);
      expect(wc.updateBill(id, note: 'synthetic note'), isTrue);
      expect(wc.setBillDates(id, warrantyUntil: '2027-10-18'), isTrue);
      expect(wc.updateBill(id, total: 5000), isFalse, reason: 'a total change on a reserving bill needs the category');
      expect(wc.bill(id)!.total, 4560);
      expect(wc.updateBill(id, total: 5000, category: 'Bills & one-offs'), isTrue);
      expect((wc.bill(id)!.total, wc.bill(id)!.category), (5000, 'Bills & one-offs'));
    });

    test('its planned row is listed but not reserved until it has a category', () {
      final wc = bw();
      final id = reopenedWithoutCategory(wc);
      final p = wc.period();
      expect(p.duePlanned.where((x) => x.needsCategory).map((x) => x.id), [WalletRepo.billPlannedId(id)]);
      expect(p.reservedPlanned, 0);
      wc.updateBill(id, category: 'Bills & one-offs');
      expect(wc.period().reservedPlanned, 4560);
    });

    tw('B6 bug: Save on such a bill failed silently; now it says why and the sheet stays open', (tester) async {
      final wc = bw();
      final id = reopenedWithoutCategory(wc);
      await openSheetFor(tester, wc, id, size: const Size(400, 1600));
      expect(find.text('Category (needed)'), findsOneWidget);
      await tester.enterText(key('billTotal'), '50.00');
      await tester.ensureVisible(key('saveBill'));
      await tester.tap(key('saveBill'));
      await tester.pumpAndSettle();
      expect(key('billError'), findsOneWidget);
      expect(find.text("Pick the category so Budget Wallet doesn't count this bill twice."), findsWidgets);
      expect(key('saveBill'), findsOneWidget, reason: 'the sheet stays open');
      expect(wc.bill(id)!.total, 4560);
      // A note alone saves and closes the sheet.
      await tester.enterText(key('billTotal'), '45.60');
      await tester.enterText(key('billNote'), 'synthetic note');
      await tester.ensureVisible(key('saveBill'));
      await tester.tap(key('saveBill'));
      await tester.pumpAndSettle();
      expect(key('saveBill'), findsNothing);
      expect(wc.bill(id)!.note, 'synthetic note');
    });

    test('Paid in cash gives the bill the category, so deleting the expense reopens it categorized', () {
      final wc = bw();
      final id = addBill(wc, syntheticBill('b6-cash', due: '2026-10-25'));
      final txId = wc.repo.addExpenseFromBill(id, category: 'Bills & subscriptions');
      wc.repo.deleteTransaction(txId);
      wc.reload();
      final b = wc.bill(id)!;
      expect((b.paid, b.category), (false, 'Bills & subscriptions'));
      expect(wc.updateBill(id, note: 'synthetic note'), isTrue);
      expect(wc.period().reservedPlanned, 0, reason: 'a fixed category: covered by the plan');
    });

    /// 20 Oct 2026 (repo clock too), pay period 1 Oct .. 31 Oct. A confirmed recurring bill SYNTH POWER due 10-20, and four
    /// planned rows: a plain flex cost (reserved), the power slip that recurring bill holds, a water slip in a fixed category,
    /// and a gas slip with no category (confirmed while paid, then unlinked).
    ({WalletController wc, String plain, String power, String water, String gas}) mixedWallet() {
      final repo = WalletRepo.inMemory(now: () => budgetToday.millisecondsSinceEpoch);
      final wc = seamedController(repo, key: VaultKey.generate(), clock: () => budgetToday, billInputs: FakeBillInputs().inputs);
      repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (final d in ['2026-07-22', '2026-08-21', '2026-09-20']) syntheticTx(d, -3000, 'Trajni nalog', 'SYNTH POWER'),
        syntheticTx('2026-10-19', -2500, 'POS plaćanje', 'POS SYNTHSHOP ZAGREB'),
      ]));
      repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01', 'paydayDay': 1});
      final rec = repo.recurringBills().single;
      expect(rec.nextDue, '2026-10-20');
      repo.confirmRecurring(rec.id);
      final plain = repo.addPlanned(title: 'Synthetic dentist', date: '2026-10-24', amount: 8000, category: 'Health & care');
      String slip(String ext, String payee, String due, int total, String? category) {
        final (id, _) = repo.importBill(syntheticBill(ext, payee: payee, due: due, total: total));
        if (category != null) {
          repo.updateBill(id, category: category);
          repo.confirmBill(id);
        }
        return id;
      }

      final power = slip('b6-power', 'Synth Power', '2026-10-22', 3100, 'Bills & one-offs');
      final water = slip('b6-water', 'Synth Water', '2026-10-25', 4000, 'Bills & subscriptions');
      final gas = slip('b6-gas', 'Synth Gas', '2026-10-26', 2500, null);
      repo.linkBill(gas, repo.transactions().firstWhere((t) => t.description.contains('SYNTHSHOP')).id);
      repo.confirmBill(gas);
      repo.unlinkBill(gas);
      wc.snoozeKeyBackup();
      wc.reload();
      return (wc: wc, plain: plain, power: power, water: water, gas: gas);
    }

    test('Coming up and Set aside count exactly the planned rows the period reserves', () {
      final w = mixedWallet();
      final p = w.wc.period();
      expect(p.duePlanned, hasLength(4));
      expect(p.reservedPlannedRows.map((x) => x.id), [w.plain]);
      expect(p.reservedPlanned, 8000);
      expect(w.wc.comingUp(), (count: p.reservedPlannedRows.length, total: p.reservedPlanned));
      final range = w.wc.upcomingRange();
      final items = w.wc.upcomingItems(range.start, range.end);
      final counted = w.wc.countedIn(items);
      final bills = p.dueBills.where((b) => !b.coveredByPlan);
      expect(counted, (count: p.reservedPlannedRows.length + bills.length, total: p.reservedPlanned + p.reservedBills));
      // Each planned row in Upcoming is counted exactly when the period reserves it.
      final shownPlanned = [
        for (final i in items)
          if (i.planned != null) i
      ];
      expect(w.wc.countedIn(shownPlanned), (count: 1, total: 8000));
      expect(w.wc.plannedNeedingCategory().single.isBill, isTrue);
      expect(w.wc.plannedNeedingCategory().single.sourceRef, w.gas);
    });

    tw('"Needs a category" on Today and in Upcoming at 320 dp x 2.0; tapping opens the bill sheet', (tester) async {
      final w = mixedWallet();
      w.wc.saveHeadsUp(cents: 1000, days: 7);
      await pumpApp(tester, todayOf(w.wc), size: const Size(320, 4000), textScale: 2);
      final line = key('needsCategory:${WalletRepo.billPlannedId(w.gas)}');
      expect(line, findsOneWidget);
      expect(find.descendant(of: line, matching: find.text('Needs a category')), findsOneWidget);
      expect(find.text('Needs a category'), findsNWidgets(2), reason: 'its own tile and its heads-up tile');
      await tester.ensureVisible(line);
      await tester.tap(line);
      await tester.pumpAndSettle();
      expect(find.text('Category (needed)'), findsOneWidget, reason: 'the bill sheet of the gas slip');
      await tester.tap(key('sheetClose')); // the sheet is a route of the app: close it so the next page starts clean
      await tester.pumpAndSettle();
      expect(find.text('Category (needed)'), findsNothing);

      await pumpApp(tester, Scaffold(body: UpcomingScreen(view: UpcomingView(w.wc))), size: const Size(320, 4000), textScale: 2);
      final tag = key('needsCategory:p:${WalletRepo.billPlannedId(w.gas)}');
      expect(tag, findsOneWidget);
      expect(find.textContaining('Needs a category', findRichText: true), findsOneWidget);
      final row = key('up:p:${WalletRepo.billPlannedId(w.gas)}');
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('Category (needed)'), findsOneWidget);
    });
  });

  group('privacy', () {
    test('logs carry counts and enum words, never a payee, IBAN, reference, amount, item, JIR, note or file name', () async {
      final fakes = FakeBillInputs();
      fakes.pictures.textResult = 'Datum racuna 05.10.2026\nUkupno 77,31';
      final wc = bw(inputs: fakes);
      await wc.importScannedCode(const ScannedCode(CodeKind.qr, receiptQr));
      final slip = await wc.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip));
      wc.updateBill(slip.billId!, date: '2026-10-18'); // a slip has no date: the owner types it
      await wc.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip));
      await wc.importScannedCode(const ScannedCode(CodeKind.qr, 'https://example.org/secret-looking-code'));
      final x = await wc.importBillFile(bytesOfString(eInvoice), 'xml');
      await wc.importBillFile(tinyPng, 'png');
      await wc.importBillFile(smallPdf(['Ukupno: 31,41 EUR', '03.10.2026']), 'pdf', trigger: 'share');
      wc.updateBill(slip.billId!, payee: 'Zzyzx Plumbing', note: 'private note about the boiler', category: 'Bills & subscriptions');
      wc.setBillDates(slip.billId!, warrantyUntil: '2027-02-02', returnBy: '2026-11-11');
      wc.confirmBill(slip.billId!);
      final cand = wc.billCandidatesFor(wc.bill(slip.billId!)!).first;
      wc.linkBill(slip.billId!, cand.tx.id);
      wc.unlinkBill(slip.billId!);
      wc.addBillAsExpense(x.billId!, category: 'Groceries');
      wc.searchBills('zzyzx');
      await wc.billFile(wc.bill(slip.billId!)!);
      wc.deleteBill(slip.billId!);
      final text = lines.join('\n');
      for (final secret in [
        'Zzyzx',
        'Synthetic Water',
        'Synthetic Supplier',
        'SYN-2026',
        'HR1210010051863000160',
        '1234-5678',
        '00000000-0000-4000',
        'boiler',
        'porezna',
        'secret-looking',
        '77,31',
        '45,60',
        '4560',
        '12500',
        '3141',
      ]) {
        expect(text, isNot(contains(secret)), reason: 'the logs must not contain "$secret"');
      }
      expect(text, contains('bills.import'));
      expect(text, contains('bill.confirm'));
    });
  });

  group('plugins stay out of the shared code', () {
    test('only bill_inputs_io.dart imports the camera, OCR and share plugins; nothing on the web path imports dart:io', () {
      final plugins = RegExp(r"import 'package:(mobile_scanner|google_mlkit_\w+|receive_sharing_intent)/");
      final offenders = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        if (plugins.hasMatch(e.readAsStringSync()) && !e.path.endsWith('bill_inputs_io.dart')) offenders.add(e.path);
      }
      expect(offenders, isEmpty);
      for (final f in [
        'lib/src/bill_inputs.dart',
        'lib/src/bill_inputs_web.dart',
        'lib/src/bill_platform.dart',
        'lib/src/controller_bills.dart'
      ]) {
        expect(File(f).readAsStringSync(), isNot(contains("import 'dart:io'")), reason: f);
      }
      expect(File('lib/src/bill_platform.dart').readAsStringSync(), contains("if (dart.library.js_interop) 'bill_inputs_web.dart'"));
    });
  });

  group('layout', () {
    final sizes = [
      ('320 dp at text 2.0', const Size(320, 640), 2.0),
      ('360 dp', const Size(360, 800), 1.0),
      ('1280 wide', const Size(1280, 900), 1.0),
    ];
    for (final (name, size, scale) in sizes) {
      WalletController full() {
        final wc = bw();
        addBill(wc, syntheticBill('l1', payee: 'A very long synthetic payee name that has to wrap on a narrow screen', total: 123456789));
        final u = addBill(wc, syntheticBill('l2', payee: 'Unpaid', due: '2026-10-12'), confirm: true);
        wc.setBillDates(u, warrantyUntil: '2026-10-28', returnBy: '2026-10-24');
        final p = addBill(wc, syntheticBill('l3', payee: 'Paid'), confirm: true);
        wc.linkBill(p, wc.billCandidatesFor(wc.bill(p)!).first.tx.id);
        for (var i = 0; i < 8; i++) {
          addBill(wc, syntheticBill('p$i', payee: 'Paid $i'), confirm: true);
        }
        return wc;
      }

      tw('$name: Plan with the Bills panel', (tester) async {
        await withErrors((errors) async {
          await pumpApp(tester, Scaffold(body: PlanPage(wc: full())), size: size, textScale: scale);
          await scrollThrough(tester);
          errors.check();
        });
      });

      tw('$name: the bill sheet with items, unsure marks, paid state and the dates', (tester) async {
        await withErrors((errors) async {
          final wc = bw();
          final id = addBill(
              wc,
              NormalizedBill(
                  source: BillSource.pdf,
                  externalId: 'inv:long',
                  date: '2026-10-10',
                  dueDate: '2026-10-25',
                  total: 9999999,
                  payee: 'A very long synthetic payee name that has to wrap on a narrow screen',
                  iban: 'HR1210010051863000160',
                  reference: 'HR01 1234-5678-9012-3456',
                  description: 'A long synthetic description of what was bought, to see the wrapping at large text',
                  items: [
                    for (var i = 0; i < 4; i++)
                      BillItem(name: 'A synthetic item with a rather long name number $i', quantity: '2', amount: 12345)
                  ]));
          await openSheetFor(tester, wc, id, size: size, scale: scale);
          for (final k in ['confirmBill', 'deleteBill']) {
            await tester.ensureVisible(key(k));
            await tester.pump();
          }
          wc.updateBill(id, category: 'Bills & subscriptions');
          expect(wc.confirmBill(id), isTrue, reason: 'a bill due from today on needs a category to confirm');
          await tester.pump();
          await tester.ensureVisible(key('paidBy'));
          await tester.pump();
          errors.check();
        });
      });

      tw('$name: Today with the line, Upcoming with bill dates, the camera screen', (tester) async {
        await withErrors((errors) async {
          final wc = full();
          await pumpApp(tester, todayOf(wc), size: size, textScale: scale);
          await scrollThrough(tester);
          await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: size, textScale: scale);
          await scrollThrough(tester);
          await pumpApp(tester, ScanBillScreen(wc: wc), size: size, textScale: scale);
          errors.check();
        });
      });
    }
  });
}
