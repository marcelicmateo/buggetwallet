/// Why a bill reader found nothing ([ReadResult.reason]). The same words the readers log.
enum ReadFailure {
  /// Nothing to read: an empty payload.
  empty,

  /// Over the reader's size cap (`maxPdfBytes`, `maxEInvoiceChars`, a code's length limit).
  tooBig,

  /// Not the shape this reader knows: another URL, no `HRVHUB30` header, not a UBL `Invoice`, not a PDF.
  notRecognized,

  /// The right shape with a bad part: a non-date, a bad amount or currency, bad percent-encoding, malformed XML,
  /// a DOCTYPE or entity declaration.
  malformed,

  /// Read fine, but nothing worth a bill: text without a labelled field, an invoice with neither number nor total.
  nothingFound,

  /// An encrypted PDF.
  encrypted,

  /// A PDF whose operator budget ran out before any text came out.
  budget,

  /// A PDF with no text layer (scanned pages).
  noText,

  /// The reader threw: the file is unreadable.
  error,
}

/// A bill reader's outcome when asked why: the [value], or the [reason] there is none. The nullable readers
/// (`readFiscalQr`, `readHub3`, `readEInvoice`, `billFromText`, `pdfText`) are these `…Result` readers' values.
class ReadResult<T extends Object> {
  final T? value;
  final ReadFailure? reason;
  const ReadResult.ok(T this.value) : reason = null;
  const ReadResult.failed(ReadFailure this.reason) : value = null;

  bool get ok => value != null;

  @override
  String toString() => ok ? 'ReadResult.ok' : 'ReadResult.failed(${reason!.name})';
}
