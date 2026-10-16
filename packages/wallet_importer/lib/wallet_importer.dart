/// Bank file importer for Budget Wallet.
///
/// This is the only place that knows about bank export formats. It outputs
/// [NormalizedTransaction]s; the app and database never see bank files.
library;

export 'src/model.dart';
export 'src/importer.dart' show importBankFile, parseRows, ImportException;
export 'src/ids.dart' show transactionId, fnv1a36, formatCents;
