// P16b: photos and PDFs attached to a payment (the payment sheet's "Attach photo or PDF"). All data is SYNTHETIC
// (billsWallet: Tuesday 20 Oct 2026, two bank rows). The camera, PDF sizing and the file dialog are fakes.
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/bill_inputs.dart';
import 'package:budget_wallet/src/clock_notice.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/screens/bills_panel.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show ImportBatch;

import 'support/bills.dart';
import 'support/wallet.dart';

Finder key(String k) => find.byKey(ValueKey(k));
Finder snack(String text) => find.byWidgetPredicate((w) => w.key == const ValueKey('attachNote') && w is Text && w.data == text);

void tw(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 65)); // the sync debounce
    }, timeout: const Timeout(Duration(seconds: 60)));

/// A picked file whose size and bytes the test sets (a huge file is only a number: it is never read).
base class FakePicked extends PlatformFile {
  @override
  final String name;
  final Uint8List data;
  final int? fakeSize;
  FakePicked(this.name, this.data, {this.fakeSize});
  @override
  Uri get uri => Uri(path: name);
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => fakeSize ?? data.length;
  @override
  Future<int?> length() async => fakeSize ?? data.length;
  @override
  Future<Uint8List> readAsBytes() async => data;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(data);
}

class FakeAttachChooser extends FileChooser {
  List<PlatformFile> picks = [];
  final savedNames = <String>[];
  int calls = 0;
  Object? error;
  @override
  Future<Uri?> saveBillFile({required String fileName, required Uint8List bytes, required String title}) async {
    savedNames.add(fileName);
    return Uri(path: fileName);
  }

  @override
  Future<List<PlatformFile>> pickAttachmentFiles() async {
    calls++;
    if (error != null) Error.throwWithStackTrace(error!, StackTrace.current);
    return picks;
  }
}

final tinyPng = base64.decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');
final photoBytes = Uint8List.fromList([1, 2, 3, 4]);

/// Lets the sealing (real async crypto) finish: widget tests run in fake time.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

CategorizedTx payment(WalletController wc) => wc.wholeTxs.firstWhere((c) => c.tx.amount == -1250);

Future<void> openTx(WidgetTester tester, WalletController wc,
    {FakeAttachChooser? chooser, Size size = const Size(400, 900), double scale = 1}) async {
  final t = payment(wc);
  await pumpApp(
      tester,
      Scaffold(
          body: Builder(
              builder: (c) => Center(
                  child: TextButton(
                      onPressed: () => showSheet<String>(c, TxSheet(wc: wc, t: t, chooser: chooser ?? FakeAttachChooser())),
                      child: const Text('open'))))),
      size: size,
      textScale: scale);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await tester.pump();
}

/// [n] attachments added through the controller.
Future<void> addMany(WidgetTester tester, WalletController wc, int n) async {
  final tx = payment(wc).tx.id;
  for (var i = 0; i < n; i++) {
    final r = await tester.runAsync(() => wc.attachFile(tx, Uint8List.fromList([i, 9, 9]), i.isEven ? 'jpg' : 'pdf'));
    expect(r, AttachResult.ok);
  }
}

/// Fakes where the phone can size pictures ([FakePdf.supported]) and sizes every one to the tiny PNG, unless [pdf] says otherwise.
FakeBillInputs inputsOf(FakeCamera camera, {FakePdf? pdf}) => FakeBillInputs(camera: camera, pdf: pdf ?? FakePdf(jpeg: tinyPng));

WalletController wallet({FakeBillInputs? inputs}) {
  final wc = billsWallet(inputs: inputs ?? inputsOf(FakeCamera()));
  addTearDown(wc.dispose);
  return wc;
}

void main() {
  group('attaching', () {
    tw('from the camera: a chooser first, then the photo is listed and opens', (tester) async {
      final inputs = inputsOf(FakeCamera(photo: tinyPng));
      final wc = wallet(inputs: inputs);
      await openTx(tester, wc);
      expect(key('attachAdd'), findsOneWidget);
      expect(find.text('Attach photo or PDF'), findsOneWidget);
      await tapVisible(tester, key('attachAdd'));
      await tester.pumpAndSettle();
      expect(key('attachCamera'), findsOneWidget);
      expect(key('attachPick'), findsOneWidget);
      await tester.tap(key('attachCamera'));
      await tester.pump();
      await settle(tester);
      expect(inputs.camera.photoCalls, 1);
      final list = wc.attachments(payment(wc).tx.id);
      expect(list, hasLength(1));
      expect(list.single.source, BillSource.attachment);
      expect(list.single.blobType, 'jpg');
      expect(key('attachRow:${list.single.id}'), findsOneWidget);
      expect(find.textContaining('Photo 1'), findsOneWidget);
      // The row opens the picture.
      await tapVisible(tester, key('attachRow:${list.single.id}'));
      await tester.pumpAndSettle();
      expect(key('billImage'), findsOneWidget);
    });

    tw('from a file where there is no camera: straight to the file dialog; a PDF is kept as a PDF', (tester) async {
      final wc = wallet(inputs: inputsOf(FakeCamera(canShow: false)));
      final chooser = FakeAttachChooser()
        ..picks = [
          FakePicked('receipt.PDF', smallPdf(['Warranty']))
        ];
      await openTx(tester, wc, chooser: chooser);
      await tapVisible(tester, key('attachAdd'));
      await tester.pump();
      expect(key('attachCamera'), findsNothing);
      await settle(tester);
      expect(chooser.calls, 1);
      final list = wc.attachments(payment(wc).tx.id);
      expect(list, hasLength(1));
      expect(list.single.blobType, 'pdf');
      expect(find.textContaining('PDF 1'), findsOneWidget);
    });

    tw('on Android "Pick a file" in the chooser opens the file dialog', (tester) async {
      final wc = wallet();
      final chooser = FakeAttachChooser()..picks = [FakePicked('a.png', photoBytes)];
      await openTx(tester, wc, chooser: chooser);
      await tapVisible(tester, key('attachAdd'));
      await tester.pumpAndSettle();
      await tester.tap(key('attachPick'));
      await tester.pump();
      await settle(tester);
      expect(chooser.calls, 1);
      expect(wc.attachments(payment(wc).tx.id), hasLength(1));
    });

    tw('a cancelled photo or file dialog changes nothing and says nothing', (tester) async {
      final inputs = inputsOf(FakeCamera()); // photo null = cancelled
      final wc = wallet(inputs: inputs);
      final chooser = FakeAttachChooser(); // picks empty = cancelled
      await openTx(tester, wc, chooser: chooser);
      await tapVisible(tester, key('attachAdd'));
      await tester.pumpAndSettle();
      await tester.tap(key('attachCamera'));
      await tester.pump();
      await settle(tester);
      await tapVisible(tester, key('attachAdd'));
      await tester.pumpAndSettle();
      await tester.tap(key('attachPick'));
      await tester.pump();
      await settle(tester);
      expect(wc.attachments(payment(wc).tx.id), isEmpty);
      expect(key('attachNote'), findsNothing);
    });

    tw('a file that is too big is refused with plain words, before it is read', (tester) async {
      final wc = wallet(inputs: inputsOf(FakeCamera(canShow: false)));
      final chooser = FakeAttachChooser()..picks = [FakePicked('big.pdf', photoBytes, fakeSize: maxBlobPlainBytes + 1)];
      await openTx(tester, wc, chooser: chooser);
      await tapVisible(tester, key('attachAdd'));
      await settle(tester);
      expect(snack('This file is too big to attach (max 15 MB).'), findsOneWidget);
      expect(wc.attachments(payment(wc).tx.id), isEmpty);
      // A picture may be bigger before it is sized down, but not past 40 MB.
      expect(maxBillFileBytes('png'), greaterThan(maxBlobPlainBytes));
    });

    tw('controller: size, type and result words', (tester) async {
      final wc = wallet();
      final tx = payment(wc).tx.id;
      Future<AttachResult> go(Uint8List b, String ext) async => (await tester.runAsync(() => wc.attachFile(tx, b, ext)))!;
      expect(await go(Uint8List(maxBlobPlainBytes + 1), 'pdf'), AttachResult.tooBig);
      expect(await go(Uint8List(maxBillImageBytes + 1), 'jpg'), AttachResult.tooBig);
      expect(await go(photoBytes, 'xml'), AttachResult.badType);
      expect(await go(photoBytes, 'exe'), AttachResult.badType);
      expect(await go(photoBytes, ''), AttachResult.badType);
      expect(wc.attachments(tx), isEmpty);
      expect(await go(photoBytes, '.JPEG'), AttachResult.ok);
      expect(wc.attachments(tx).single.blobType, 'jpg');
      expect(attachMessage(AttachResult.ok), isNull);
      expect(attachMessage(AttachResult.badType), 'Only photos and PDFs can be attached.');
      expect(attachMessage(AttachResult.full), 'A payment holds 5 attachments at most.');
      expect(attachMessage(AttachResult.failed), "Couldn't save that file. Try again.");
    });

    tw('a 20 MB picture is sized down by the phone and kept as a small JPEG', (tester) async {
      final wc = wallet();
      final tx = payment(wc).tx.id;
      expect(await tester.runAsync(() => wc.attachFile(tx, Uint8List(20 << 20), 'png')), AttachResult.ok);
      final a = wc.attachments(tx).single;
      expect(a.blobType, 'jpg');
      expect(a.blobBytes, tinyPng.length);
    });

    tw('where pictures cannot be sized, a 20 MB picture is too big and nothing is cached or queued', (tester) async {
      final wc = wallet(inputs: inputsOf(FakeCamera(), pdf: FakePdf(canRender: false)));
      final tx = payment(wc).tx.id;
      expect(await tester.runAsync(() => wc.attachFile(tx, Uint8List(20 << 20), 'png')), AttachResult.tooBig);
      expect(wc.attachments(tx), isEmpty);
      expect(wc.repo.queuedBlobs(), isEmpty);
    });

    tw('where pictures can be sized, one the phone cannot read is refused and nothing is queued', (tester) async {
      final wc = wallet(inputs: inputsOf(FakeCamera(), pdf: FakePdf()));
      final tx = payment(wc).tx.id;
      expect(await tester.runAsync(() => wc.attachFile(tx, photoBytes, 'jpg')), AttachResult.badType);
      expect(wc.attachments(tx), isEmpty);
      expect(wc.repo.queuedBlobs(), isEmpty);
    });

    tw('a payment that is gone is refused before any file is sealed', (tester) async {
      final wc = wallet();
      expect(await tester.runAsync(() => wc.attachFile('no-such-payment', photoBytes, 'jpg')), AttachResult.failed);
      expect(wc.repo.queuedBlobs(), isEmpty);
    });

    tw('a clock that is behind raises the notice and fails the attach', (tester) async {
      var t = budgetToday.millisecondsSinceEpoch;
      final repo = WalletRepo.inMemory(now: () => t);
      repo.importBatch(
          ImportBatch(source: 'pbz', transactions: [syntheticTx('2026-10-19', -1250, 'POS plaćanje', 'POS SYNTHSHOP ZAGREB')]));
      repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01'});
      final wc =
          WalletController.forTest(repo, key: VaultKey.generate(), clock: () => budgetToday, billInputs: inputsOf(FakeCamera()).inputs);
      addTearDown(wc.dispose);
      wc.reload();
      t -= const Duration(hours: 3).inMilliseconds; // the clock was set back
      final before = clockBehindNotice.value;
      expect(await tester.runAsync(() => wc.attachFile(payment(wc).tx.id, photoBytes, 'jpg')), AttachResult.failed);
      expect(clockBehindNotice.value, before + 1);
      expect(wc.attachments(payment(wc).tx.id), isEmpty);
    });

    tw('a file that is not a photo or PDF is refused', (tester) async {
      final wc = wallet(inputs: inputsOf(FakeCamera(canShow: false)));
      final chooser = FakeAttachChooser()..picks = [FakePicked('invoice.xml', photoBytes)];
      await openTx(tester, wc, chooser: chooser);
      await tapVisible(tester, key('attachAdd'));
      await settle(tester);
      expect(snack('Only photos and PDFs can be attached.'), findsOneWidget);
      expect(wc.attachments(payment(wc).tx.id), isEmpty);
    });

    tw('a refused camera permission says so in plain words; any other failure says it could not take the photo', (tester) async {
      final camera = FakeCamera()..photoError = 'permission';
      final wc = wallet(inputs: inputsOf(camera));
      await openTx(tester, wc);
      await tapVisible(tester, key('attachAdd'));
      await tester.pumpAndSettle();
      await tester.tap(key('attachCamera'));
      await tester.pump();
      await settle(tester);
      expect(snack(cameraOffMessage), findsOneWidget);
      expect(wc.attachments(payment(wc).tx.id), isEmpty);
      camera
        ..photoError = null
        ..crash = true;
      await tapVisible(tester, key('attachAdd'));
      await tester.pumpAndSettle();
      await tester.tap(key('attachCamera'));
      await tester.pump();
      await settle(tester);
      expect(snack(photoFailedMessage), findsOneWidget);
      expect(wc.attachments(payment(wc).tx.id), isEmpty);
    });

    tw('a file dialog that fails says so', (tester) async {
      final wc = wallet(inputs: inputsOf(FakeCamera(canShow: false)));
      final chooser = FakeAttachChooser()..error = StateError('no portal');
      await openTx(tester, wc, chooser: chooser);
      await tapVisible(tester, key('attachAdd'));
      await settle(tester);
      expect(snack(chooserFailedMessage), findsOneWidget);
    });
  });

  group('limit, remove and Undo', () {
    tw('at 5 the button is hidden and the sheet says why; a sixth is refused by the controller', (tester) async {
      final wc = wallet();
      await addMany(tester, wc, 4);
      await openTx(tester, wc);
      expect(key('attachAdd'), findsOneWidget);
      Navigator.of(tester.element(key('attachAdd'))).pop();
      await tester.pumpAndSettle();
      await addMany(tester, wc, 1);
      await openTx(tester, wc);
      expect(key('attachAdd'), findsNothing);
      await tester.ensureVisible(key('attachFull'));
      expect(find.text('5 attachments, the most a payment can hold'), findsOneWidget);
      final tx = payment(wc).tx.id;
      expect(await tester.runAsync(() => wc.attachFile(tx, photoBytes, 'jpg')), AttachResult.full);
      expect(wc.attachments(tx), hasLength(5));
    });

    tw('Remove takes the row away with a toast; Undo brings it back; the button returns after a remove from 5', (tester) async {
      final wc = wallet();
      await addMany(tester, wc, 5);
      await openTx(tester, wc);
      final id = wc.attachments(payment(wc).tx.id).first.id;
      await tapVisible(tester, key('attachRemove:$id'));
      await tester.pump();
      expect(key('attachRow:$id'), findsNothing);
      expect(key('attachAdd'), findsOneWidget);
      expect(snack('Attachment removed'), findsOneWidget);
      expect(wc.attachments(payment(wc).tx.id), hasLength(4));
      await tester.tap(key('attachUndo'));
      await tester.pump();
      expect(key('attachRow:$id'), findsOneWidget);
      expect(key('attachAdd'), findsNothing);
      expect(wc.attachments(payment(wc).tx.id).map((b) => b.id), contains(id));
    });

    tw('Undo stays after a cancelled Attach, and a new file replaces the note', (tester) async {
      final wc = wallet(inputs: inputsOf(FakeCamera(canShow: false)));
      await addMany(tester, wc, 1);
      final chooser = FakeAttachChooser(); // cancels
      await openTx(tester, wc, chooser: chooser);
      final id = wc.attachments(payment(wc).tx.id).single.id;
      await tapVisible(tester, key('attachRemove:$id'));
      await tester.pump();
      await tapVisible(tester, key('attachAdd'));
      await settle(tester);
      expect(chooser.calls, 1);
      expect(key('attachUndo'), findsOneWidget);
      expect(snack('Attachment removed'), findsOneWidget);
      chooser.picks = [FakePicked('a.png', photoBytes)];
      await tapVisible(tester, key('attachAdd'));
      await settle(tester);
      expect(key('attachUndo'), findsNothing);
      expect(key('attachNote'), findsNothing);
      expect(wc.attachments(payment(wc).tx.id), hasLength(1));
    });

    tw('an attachment saves as attachment-<payment date>.pdf', (tester) async {
      final wc = wallet(inputs: inputsOf(FakeCamera(), pdf: FakePdf(canRender: false)));
      final tx = payment(wc).tx.id;
      expect(await tester.runAsync(() => wc.attachFile(tx, smallPdf(['x']), 'pdf')), AttachResult.ok);
      final chooser = FakeAttachChooser();
      await openTx(tester, wc, chooser: chooser);
      await tapVisible(tester, key('attachRow:${wc.attachments(tx).single.id}'));
      await settle(tester);
      await tester.tap(key('saveBillFile'));
      await tester.pump();
      expect(chooser.savedNames.single, 'attachment-${payment(wc).tx.date}.pdf');
    });

    tw('Undo with the payment full again says so and keeps the count at 5', (tester) async {
      final wc = wallet();
      await addMany(tester, wc, 5);
      await openTx(tester, wc);
      final tx = payment(wc).tx.id;
      final id = wc.attachments(tx).first.id;
      await tapVisible(tester, key('attachRemove:$id'));
      await tester.pump();
      await tester.runAsync(() => wc.attachFile(tx, photoBytes, 'jpg')); // fills the free place
      await tester.tap(key('attachUndo'));
      await tester.pump();
      expect(snack('A payment holds 5 attachments at most.'), findsOneWidget);
      expect(wc.attachments(tx), hasLength(5));
      expect(wc.attachments(tx).map((b) => b.id), isNot(contains(id)));
    });
  });

  group('never a bill', () {
    tw('an attachment is in no bill list, no match, no Upcoming and reserves nothing', (tester) async {
      final wc = wallet();
      await addMany(tester, wc, 2);
      final tx = payment(wc).tx.id;
      expect(wc.attachments(tx), hasLength(2));
      expect(wc.billsAll(), isEmpty);
      final l = wc.billLists();
      expect([l.review, l.unpaid, l.paid].expand((x) => x), isEmpty);
      expect(wc.billsToReview(), 0);
      expect(wc.billForTx(tx), isNull);
      expect(wc.searchBills('').length, 0);
      final r = wc.upcomingRange();
      expect(wc.upcomingItems(r.start, r.end).where((i) => i.billDb != null), isEmpty);
      final p = wc.period();
      expect(p.reservedBills, 0);
      expect(p.dueBills, isEmpty);
      // Plan › Bills shows none.
      await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: BillsPanel(wc: wc))), size: const Size(400, 1400));
      expect(
          find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('bill:')), findsNothing);
    });

    tw('a payment with a real linked bill shows Open bill and its attachments', (tester) async {
      final wc = wallet();
      final slip = (await tester.runAsync(() => wc.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip))))!;
      wc.repo.updateBill(slip.billId!, date: '2026-10-19', total: 1250);
      wc.reload();
      expect(wc.confirmBill(slip.billId!), isTrue);
      final tx = payment(wc).tx.id;
      expect(wc.linkBill(slip.billId!, tx), isTrue);
      await addMany(tester, wc, 2);
      expect(wc.billForTx(tx)?.id, slip.billId);
      expect(wc.billForTx(tx)!.source, isNot(BillSource.attachment));
      await openTx(tester, wc);
      expect(key('openBill'), findsOneWidget);
      for (final a in wc.attachments(tx)) {
        expect(key('attachRow:${a.id}'), findsOneWidget);
      }
      expect(wc.billsAll().map((b) => b.id), [slip.billId]);
    });
  });

  group('layout', () {
    tw('five attachments and the chooser fit 320 dp at text scale 2.0', (tester) async {
      final wc = wallet();
      await addMany(tester, wc, 5);
      await openTx(tester, wc, size: const Size(320, 640), scale: 2);
      await tester.ensureVisible(key('attachFull'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final a in wc.attachments(payment(wc).tx.id)) {
        await tester.ensureVisible(key('attachRow:${a.id}'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(tester.getRect(key('attachRemove:${a.id}')).right, lessThanOrEqualTo(320));
      }
    });

    tw('the add button and the chooser fit 320 dp at text scale 2.0', (tester) async {
      final wc = wallet();
      await openTx(tester, wc, size: const Size(320, 640), scale: 2);
      await tester.ensureVisible(key('attachAdd'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(key('attachAdd')).right, lessThanOrEqualTo(320));
      await tester.tap(key('attachAdd'));
      await tester.pumpAndSettle();
      expect(key('attachCamera'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    tw('a wide window shows the same rows', (tester) async {
      final wc = wallet();
      await addMany(tester, wc, 2);
      await openTx(tester, wc, size: const Size(1280, 800));
      expect(find.textContaining('Photo 1'), findsOneWidget);
      expect(find.textContaining('PDF 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
