/// Bank file importer for Budget Wallet.
///
/// This is the only place that knows about bank export formats: one [BankProfile] per bank, tried in the order of
/// [bankProfiles]. It outputs [NormalizedTransaction]s; the app and database never see bank files.
library;

export 'src/bills/model.dart';
export 'src/ids.dart' show transactionId, sourceTransactionId, fnv1a36, formatCents;
export 'src/importer.dart' show importBankFile, parseRows, ImportException, unknownLayoutMessage;
export 'src/model.dart';
export 'src/profiles/profile.dart' show BankProfile, ImportContext, RowResult, RowOutcome, headRows;
export 'src/profiles/registry.dart' show bankProfiles;
