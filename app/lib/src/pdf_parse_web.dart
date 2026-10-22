// Web: no isolates, the same reading runs inline (see pdf_parse.dart).
import 'dart:typed_data';

import 'package:wallet_importer/wallet_importer.dart';

import 'pdf_parse.dart' show PdfParse;

/// Always 0 in the browser.
int pdfParsedOffUi = 0;

Future<PdfParse> parsePdf(Uint8List pdf) async {
  final text = pdfText(pdf);
  return (text: text, bill: text == null ? null : billFromText(text, source: BillSource.pdf));
}
