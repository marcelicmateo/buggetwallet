// Minimal PDF text-layer extractor for bills: enough of PDF to read the text a bill generator writes.
//
// Supported: objects found by scanning for `N G obj` (xref tables and xref streams are not read, so broken xrefs and
// incremental updates are fine: the last definition of an object wins), compressed object streams (/ObjStm),
// stream data by /Length (direct or indirect) with a fallback scan for `endstream`, filters FlateDecode (zlib or raw
// deflate), ASCIIHexDecode and ASCII85Decode, the page tree in order (inherited /Resources), Form XObjects (`Do`),
// text operators Tj, TJ (large negative offsets become a space), ', ", T*, Td, TD, Tm, inline images skipped,
// literal and hex strings with escapes, ToUnicode CMaps (codespace ranges, bfchar, bfrange incl. the array form,
// 1- to 4-byte codes) and, for simple fonts without a CMap, WinAnsi plus /Differences glyph names.
//
// Not supported (text from these is missing or wrong, never an exception): encrypted files (→ null), PNG/TIFF
// predictors (/DecodeParms /Predictor, only used by some object streams), LZW and RunLength filters, predefined CJK
// CMaps and Type0 fonts without a ToUnicode CMap, MacRoman/Standard encodings (read as WinAnsi), text in annotations
// or form fields, text drawn as images (scans need OCR), reading order beyond "content stream order, new line when the
// baseline moves".
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:logging/logging.dart';

import '../log.dart';
import 'common.dart';
import 'read_result.dart';

part 'pdf/bytes.dart';
part 'pdf/cmap.dart';
part 'pdf/content.dart';
part 'pdf/encodings.dart';
part 'pdf/filters.dart';
part 'pdf/fonts.dart';
part 'pdf/lexer.dart';
part 'pdf/objects.dart';

/// Largest PDF read; bigger → `null`.
const maxPdfBytes = 20 * 1024 * 1024;

/// Work budget for one file (tokens, glyphs, inflated KB): past it, the text read so far is returned (or `null`).
const pdfOpBudget = 5000000;

/// Most bytes inflated from one file (all streams together): a compression bomb stops here.
const _maxInflated = 64 * 1024 * 1024;

/// Most characters of text returned.
const _maxChars = 2000000;

/// The text layer of [pdf], pages in order, lines separated by `\n`; `null` when the file is not a PDF, is encrypted,
/// is over [maxPdfBytes], has no text, or is unreadable. Never throws.
String? pdfText(Uint8List pdf) => pdfTextResult(pdf).value;

/// [pdfText] with the reason when there is no text ([ReadFailure.tooBig], [ReadFailure.notRecognized],
/// [ReadFailure.encrypted], [ReadFailure.budget], [ReadFailure.noText], [ReadFailure.error]).
ReadResult<String> pdfTextResult(Uint8List pdf) {
  final sw = Stopwatch()..start();
  var reason = 'ok';
  String? text;
  var pages = 0, objects = 0;
  try {
    if (pdf.length > maxPdfBytes) {
      reason = 'tooBig';
    } else if (_indexOf(pdf, _pdfHeader, 0, 1024) < 0) {
      reason = 'notPdf';
    } else if (_hasEncrypt(pdf)) {
      reason = 'encrypted';
    } else {
      final doc = _Pdf(pdf);
      final out = _Out();
      try {
        doc.scan();
        objects = doc.offsets.length;
        final list = doc.pages();
        pages = list.length;
        for (final p in list) {
          out.page();
          try {
            doc.pageText(p.$1, p.$2, out);
          } on _OutOfBudget {
            rethrow;
          } catch (_) {
            // a broken page: keep what the others give
          }
        }
      } on _OutOfBudget {
        reason = 'budget';
      }
      text = out.result();
      if (text == null && reason == 'ok') reason = 'noText';
    }
  } catch (_) {
    reason = 'error';
    text = null;
  }
  if (reason == 'error') {
    logImporter(billsLog, Level.WARNING, 'bills.pdf', {'reason': reason});
  } else {
    logImporter(billsLog, text == null ? Level.INFO : Level.FINE, 'bills.pdf', {
      'reason': reason,
      'bytes': pdf.length,
      'objects': objects,
      'pages': pages,
      'chars': text?.length ?? 0,
      'ms': sw.elapsedMilliseconds,
    });
  }
  if (text != null) return ReadResult.ok(text);
  return ReadResult.failed(switch (reason) {
    'tooBig' => ReadFailure.tooBig,
    'notPdf' => ReadFailure.notRecognized,
    'encrypted' => ReadFailure.encrypted,
    'budget' => ReadFailure.budget,
    'noText' => ReadFailure.noText,
    _ => ReadFailure.error,
  });
}
