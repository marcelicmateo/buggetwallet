// Reading a PDF's text layer and the bill in it can take a while on a big file, so on phones and desktops it runs in another isolate
// (pdf_parse_io.dart) and the screen never stalls; the browser has no isolates and runs it inline (pdf_parse_web.dart). Same pairing as
// bill_platform.dart. Pure Dart readers only: nothing here knows a plugin.
import 'dart:typed_data';

import 'package:wallet_importer/wallet_importer.dart' show NormalizedBill;

export 'pdf_parse_io.dart' if (dart.library.js_interop) 'pdf_parse_web.dart' show parsePdf, pdfParsedOffUi;

/// What the PDF's text layer gave: the text (null = none) and the bill read from it (null = nothing readable).
typedef PdfParse = ({String? text, NormalizedBill? bill});

/// The reader the controller uses; tests swap it.
typedef PdfParser = Future<PdfParse> Function(Uint8List pdf);
