// Native: pdfText + billFromText in a separate isolate (see pdf_parse.dart).
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:wallet_importer/wallet_importer.dart';

import 'pdf_parse.dart' show PdfParse;

/// How many PDFs were read off the UI isolate (tests check the isolate path was taken).
@visibleForTesting
int pdfParsedOffUi = 0;

PdfParse _parse(Uint8List pdf) {
  final text = pdfText(pdf);
  return (text: text, bill: text == null ? null : billFromText(text, source: BillSource.pdf));
}

/// Reads the PDF in another isolate; a failure inside is thrown here (the controller logs the type and goes on without text).
Future<PdfParse> parsePdf(Uint8List pdf) {
  pdfParsedOffUi++;
  return Isolate.run(() => _parse(pdf));
}
