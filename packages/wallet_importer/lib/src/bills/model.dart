/// Bills read from receipts, payment slips, e-invoices, PDFs and photos (stage B, `docs/context/BILLS_API.md`).
library;

/// Where a bill was read from.
enum BillSource { receiptQr, hub3, eInvoice, pdf, photo, manual }

/// One line of a bill (e-invoices only, for now).
class BillItem {
  final String name;

  /// As the bill writes it (`2`, `1,5`), or `null` when not given.
  final String? quantity;

  /// Line total in cents.
  final int amount;
  const BillItem({required this.name, this.quantity, required this.amount});

  Map<String, Object?> toJson() => {'name': name, if (quantity != null) 'quantity': quantity, 'amount': amount};
  @override
  bool operator ==(Object other) => other is BillItem && other.name == name && other.quantity == quantity && other.amount == amount;
  @override
  int get hashCode => Object.hash(name, quantity, amount);
}

/// A bill in Budget Wallet's own format: what every reader returns. The payer of a slip (the owner) is never read in.
/// Every field is a suggestion until the owner confirms the bill in the app.
class NormalizedBill {
  final BillSource source;

  /// Unique per bill, so the same bill read twice is one bill: `jir:<uuid>`, `zki:<hex>`,
  /// `inv:<supplier id or IBAN>:<invoice no>`, `hub3:<IBAN>:<model reference>:<amount>`; `null` when unknown.
  final String? externalId;

  /// `YYYY-MM-DD`.
  final String? date, dueDate;
  final String? payee, iban, description;

  /// Model + poziv na broj, normalized: `HR01 1234-5678`.
  final String? reference;

  /// Cents, `null` when not found.
  final int? total;
  final String currency;
  final List<BillItem> items;

  /// How many fields were guessed from free text (PDF text, OCR); the app marks them.
  final int unsure;
  const NormalizedBill({
    required this.source,
    this.externalId,
    this.date,
    this.dueDate,
    this.payee,
    this.iban,
    this.description,
    this.reference,
    this.total,
    this.currency = 'EUR',
    this.items = const [],
    this.unsure = 0,
  });
}
