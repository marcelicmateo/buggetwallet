/// Bank file importer for Budget Wallet.
///
/// This is the only place that knows about bank export formats: one [BankProfile] per bank, tried in the order of
/// [bankProfiles]. It outputs [NormalizedTransaction]s; the app and database never see bank files.
library;

export 'src/bills/codes.dart' show readFiscalQr, readFiscalQrResult, readHub3, readHub3Result;
export 'src/bills/common.dart' show validIban;
export 'src/bills/einvoice.dart' show readEInvoice, readEInvoiceResult, maxEInvoiceChars;
export 'src/bills/model.dart';
export 'src/bills/pdf_text.dart' show pdfText, pdfTextResult, maxPdfBytes, pdfOpBudget;
export 'src/bills/read_result.dart' show ReadFailure, ReadResult;
export 'src/bills/text_bill.dart' show billFromText, billFromTextResult, maxBillTextChars;
export 'src/csv_generic.dart'
    show
        CsvLayoutMatch,
        CsvShape,
        CsvPreviewRow,
        NeedsMapping,
        csvColumnNames,
        csvLayoutId,
        csvNoHeader,
        csvNoHeaderId,
        csvShape,
        csvShapeId,
        csvSampleRows,
        csvSourcePrefix,
        guessMapping,
        layoutMismatchMessage,
        mappingProblems,
        matchCsvLayout,
        matchCsvMapping,
        needsMappingMessage,
        parseCsvCents,
        parseCsvDate,
        parseMappedCsv,
        previewMapping,
        sourceLogKey,
        tooManyColumnsMessage;
export 'src/csv_mapping.dart' show CsvMapping, CsvDateFormat, CsvDecimal, maxCsvColumns, maxCsvHeaderChars;
export 'src/ids.dart' show transactionId, sourceTransactionId;
export 'src/importer.dart' show importBankFile, parseRows, ImportException, unknownLayoutMessage;
export 'src/limits.dart' show maxImportBytes, maxXlsxUnpackedBytes, passwordProtectedMessage, tooLargeMessage;
export 'src/model.dart';
export 'src/profiles/profile.dart' show BankProfile, ImportContext, RowResult, RowOutcome, headRows;
export 'src/profiles/registry.dart' show bankProfiles;
