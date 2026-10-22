// Fakes and SYNTHETIC bills for the bills tests (stage B4): the camera, picture reading, PDF pages and Share behind
// `bill_inputs.dart`, so no test touches a plugin. Payloads are made-up shapes (no real merchant, IBAN or person).
import 'dart:async';
import 'dart:typed_data';

import 'package:budget_wallet/src/bill_inputs.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/pdf_parse.dart';
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

/// A one-page PDF with a proper xref whose text layer holds [lines] (Helvetica, one `Tj` per line), enough for the real readers.
Uint8List smallPdf(List<String> lines) {
  final content = 'BT /F1 12 Tf 72 700 Td 14 TL ${[for (final l in lines) '($l) Tj T*'].join(' ')} ET';
  final objs = [
    '<</Type/Catalog/Pages 2 0 R>>',
    '<</Type/Pages/Kids[3 0 R]/Count 1>>',
    '<</Type/Page/Parent 2 0 R/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>',
    '<</Length ${content.length}>>\nstream\n$content\nendstream',
    '<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>',
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objs.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<</Size ${objs.length + 1}/Root 1 0 R>>\nstartxref\n$xref\n%%EOF\n');
  return bytesOfString(out.toString());
}

/// The camera: a plain box; [emit] sends a code as if the camera saw it.
class FakeCamera implements BillCamera {
  final bool canShow;
  ValueChanged<ScannedCode>? _onCode;

  /// What the system camera "takes" (null = the owner cancelled); [photoError] makes it throw a [BillPhotoException] with that code.
  Uint8List? photo;
  String? photoError;
  int photoCalls = 0;
  FakeCamera({this.canShow = true, this.photo});

  @override
  Future<Uint8List?> takePhoto() async {
    photoCalls++;
    if (photoError != null) throw BillPhotoException(photoError!);
    return photo;
  }

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

/// The PDF reader without an isolate (what the browser does).
Future<PdfParse> inlinePdfParser(Uint8List pdf) async {
  final text = pdfText(pdf);
  return (text: text, bill: text == null ? null : billFromText(text, source: BillSource.pdf));
}

/// A wallet on 20 Oct 2026 for the bills tests: two bank rows (one could have paid a slip), a salary period, and the fakes.
WalletController billsWallet({FakeBillInputs? inputs, FakeNudges? nudges}) {
  final wc = WalletController.forTest(WalletRepo.inMemory(),
      key: VaultKey.generate(), clock: () => budgetToday, nudges: nudges, billInputs: (inputs ?? FakeBillInputs()).inputs);
  // Widget tests run in fake time, where a real isolate never answers: PDFs are read inline unless a test asks for the isolate path.
  wc.pdfParser = inlinePdfParser;
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
    NormalizedBill(
        source: source,
        externalId: id,
        date: date,
        dueDate: due,
        total: total,
        payee: payee,
        description: 'Water bill',
        unsure: source == BillSource.pdf || source == BillSource.photo ? 3 : 0);
