// TEMPORARY STAND-INS for two wallet_core APIs a core-builder is adding in parallel (stage B5): remove this file, and the
// two calls to it in controller_bills.dart, once core is merged (the lead says when).
//   String? suggestBillCategory(Bill b, {required List<RecurringBill> recurring, required List<CategorizedTx> txs})
//   WalletRepo.importBill(b, {file, bool asNew = false})
import 'package:wallet_core/wallet_core.dart';

/// Stand-in: the category of a confirmed expected bill whose label and the bill's payee contain one another.
String? standInSuggestBillCategory(Bill b, {required List<RecurringBill> recurring, required List<CategorizedTx> txs}) {
  final payee = (b.payee ?? '').toLowerCase();
  if (payee.isEmpty) return null;
  for (final r in recurring) {
    if (r.status != 'confirmed') continue;
    final label = r.label.toLowerCase();
    if (label.isNotEmpty && (payee.contains(label) || label.contains(payee))) return r.category;
  }
  return null;
}

/// Stand-in for `importBill(..., asNew: true)`: the same slip as a new bill under a different external id.
(String, bool) standInImportBill(WalletRepo repo, NormalizedBill b, {BlobRef? file, bool asNew = false}) {
  if (!asNew) return repo.importBill(b, file: file);
  final n = NormalizedBill(
    source: b.source,
    externalId: '${b.externalId ?? 'file'}#${DateTime.now().microsecondsSinceEpoch}',
    date: b.date,
    dueDate: b.dueDate,
    payee: b.payee,
    iban: b.iban,
    reference: b.reference,
    description: b.description,
    total: b.total,
    currency: b.currency,
    items: b.items,
    unsure: b.unsure,
  );
  return repo.importBill(n, file: file);
}
