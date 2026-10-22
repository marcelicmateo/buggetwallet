// Fakes and SYNTHETIC bills for the bills tests (stage B4): the camera, picture reading, PDF pages and Share behind
// `bill_inputs.dart`, so no test touches a plugin. Payloads are made-up shapes (no real merchant, IBAN or person).
import 'dart:async';
import 'dart:typed_data';

import 'package:budget_wallet/src/bill_inputs.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'wallet.dart';

/// A made-up fiscal receipt QR (Croatian shape): a fixed JIR, 12.34 on 2026-10-18.
const receiptQr = 'https://porezna.gov.hr/rn?jir=00000000-0000-4000-8000-000000000001&datv=20261018_1000&izn=1234';

/// A made-up HUB-3 payment slip: 45.60 to "Synthetic Water" with a reference. The IBAN is made up with a valid checksum.
const hub3Slip = 'HRVHUB30\nEUR\n000000000004560\nPayer Name\nPayer Street 1\n10000 Zagreb\nSynthetic Water\nWater Street 2\n'
    '10000 Zagreb\nHR1210010051863000160\nHR01\n1234-5678\nCOST\nWater bill';

Uint8List bytesOfString(String s) => Uint8List.fromList(s.codeUnits);

/// A tiny PDF whose text layer holds [lines] (one `Tj` each), enough for the readers.
Uint8List smallPdf(List<String> lines) {
  final body = [for (final l in lines) '($l) Tj'].join('\n');
  return bytesOfString('%PDF-1.4\n1 0 obj << /Length ${body.length} >> stream\nBT\n$body\nET\nendstream endobj\n%%EOF');
}

/// The camera: a plain box; [emit] sends a code as if the camera saw it.
class FakeCamera implements BillCamera {
  final bool canShow;
  ValueChanged<ScannedCode>? _onCode;
  FakeCamera({this.canShow = true});
  @override
  bool get supported => canShow;
  @override
  Widget view({required ValueChanged<ScannedCode> onCode}) {
    _onCode = onCode;
    return const ColoredBox(key: ValueKey('fakeCamera'), color: Color(0xFF222222), child: Center(child: Text('camera')));
  }

  void emit(ScannedCode c) => _onCode!(c);
}

/// Codes and text "read" from pictures: the lists you set.
class FakePictures implements PictureReader {
  final bool canRead;
  List<ScannedCode> codeList = const [];
  String? textResult;
  int codeCalls = 0, textCalls = 0;
  FakePictures({this.canRead = true});
  @override
  bool get supported => canRead;
  @override
  Future<List<ScannedCode>> codes(Uint8List image) async {
    codeCalls++;
    return codeList;
  }

  @override
  Future<String?> text(Uint8List image) async {
    textCalls++;
    return textResult;
  }
}

/// PDF pages and JPEG sizing: every PDF "renders" to [pages], every picture comes back as [jpeg] (null = cannot be sized).
class FakePdf implements PdfPages {
  final bool canRender;
  List<Uint8List> pages;
  Uint8List? jpeg;
  int renders = 0;
  FakePdf({this.canRender = true, List<Uint8List>? pages, this.jpeg})
      : pages = pages ??
            [
              Uint8List.fromList([1])
            ];
  @override
  bool get supported => canRender;
  @override
  Future<List<Uint8List>> render(Uint8List pdf, {int dpi = 200, int maxPages = 5}) async {
    renders++;
    return pages.take(maxPages).toList();
  }

  @override
  Future<Uint8List?> toJpeg(Uint8List image, {int maxSide = 2560}) async => jpeg;
}

/// Share to app: [initialFiles] are there at start, [send] pushes one while the app runs.
class FakeShare implements ShareInbox {
  final bool canShare;
  List<SharedFile> initialFiles;
  final _ctl = StreamController<List<SharedFile>>.broadcast();
  FakeShare({this.canShare = true, this.initialFiles = const []});
  @override
  bool get supported => canShare;
  @override
  Future<List<SharedFile>> initial() async => initialFiles;
  @override
  Stream<List<SharedFile>> get files => _ctl.stream;
  void send(List<SharedFile> f) => _ctl.add(f);
}

/// The four fakes together.
class FakeBillInputs {
  final FakeCamera camera;
  final FakePictures pictures;
  final FakePdf pdf;
  final FakeShare share;
  FakeBillInputs({FakeCamera? camera, FakePictures? pictures, FakePdf? pdf, FakeShare? share})
      : camera = camera ?? FakeCamera(),
        pictures = pictures ?? FakePictures(),
        pdf = pdf ?? FakePdf(),
        share = share ?? FakeShare();
  BillInputs get inputs => BillInputs(camera: camera, reader: pictures, pdf: pdf, share: share);
}

/// A wallet on 20 Oct 2026 for the bills tests: two bank rows (one could have paid a slip), a salary period, and the fakes.
WalletController billsWallet({FakeBillInputs? inputs, FakeNudges? nudges}) {
  final wc = WalletController.forTest(WalletRepo.inMemory(),
      key: VaultKey.generate(), clock: () => budgetToday, nudges: nudges, billInputs: (inputs ?? FakeBillInputs()).inputs);
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    syntheticTx('2026-10-19', -4560, 'Trajni nalog', 'SYNTHETIC WATER HR01 1234-5678'),
    syntheticTx('2026-10-19', -1250, 'POS plaćanje', 'POS SYNTHSHOP ZAGREB'),
  ]));
  wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01'});
  wc.snoozeKeyBackup();
  wc.reload();
  return wc;
}

/// A bill the way a reader would give it, for lists and sheets: [total] cents on [date].
NormalizedBill syntheticBill(String id,
        {String? date = '2026-10-18',
        int? total = 4560,
        String payee = 'Synthetic Water',
        String? due,
        BillSource source = BillSource.hub3}) =>
    NormalizedBill(source: source, externalId: id, date: date, dueDate: due, total: total, payee: payee, description: 'Water bill');
