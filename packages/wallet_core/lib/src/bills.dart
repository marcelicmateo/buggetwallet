// Bills database (stage B, docs/context/BILLS_API.md §2–§3): the synced `bill` entity, deterministic auto link,
// "Paid by this?" candidates and warranty / return-by reminders. Pure and web-safe.
import 'dart:convert';

import 'package:cryptography/dart.dart' show DartSha256;
import 'package:wallet_importer/wallet_importer.dart' show BillItem, BillSource;

import 'dates.dart';
import 'models.dart';
import 'planned.dart' show UpcomingKind;
import 'search.dart' show foldText;

/// review: read from a code, file or photo (or typed), every value a suggestion; confirmed: the owner checked it, so
/// it may reserve money (a planned row) and link to its payment automatically.
enum BillStatus { review, confirmed }

/// A file kept for a bill on the relay ([BlobStore]): [hash] = lowercase hex SHA-256 of the sealed bytes, [type]
/// one of [blobTypes], [bytes] the plain size.
class BlobRef {
  final String hash;
  final String type;
  final int bytes;
  const BlobRef({required this.hash, required this.type, required this.bytes});

  @override
  bool operator ==(Object other) => other is BlobRef && other.hash == hash && other.type == type && other.bytes == bytes;
  @override
  int get hashCode => Object.hash(hash, type, bytes);
}

/// File types a bill may keep.
const blobTypes = {'jpg', 'png', 'pdf', 'xml'};

/// Limits of a bill's item list (stored as JSON text in `bills.items`).
const maxBillItems = 500, maxBillItemName = 200;

/// A bill (receipt, payment slip, e-invoice, PDF or photo), synced entity `bill` (schema 7). Amounts are cents,
/// positive = what the bill asks. Bills are information: linking one never changes the paying row's category.
class Bill {
  /// `bill:<32 hex of SHA-256(externalId)>` when [externalId] is known (devices converge on one bill), else `b…`.
  final String id;
  final BillSource source;
  final BillStatus status;
  final String? externalId, date, dueDate, payee, iban, reference, description, category, note;
  final int? total;
  final String currency;
  final List<BillItem> items;

  /// Fields the reader guessed from free text (PDF text, OCR): the UI marks the bill as unsure while > 0.
  final int unsure;

  /// The payment: a bank row or a hand-added expense ([WalletRepo.linkBill], [WalletRepo.addExpenseFromBill]).
  final String? linkedTx;
  final String? warrantyUntil, returnBy;

  /// The bill's file on the relay ([BlobRef.hash]), its type and plain size.
  final String? blob, blobType;
  final int? blobBytes;
  final bool deleted;

  const Bill({
    required this.id,
    this.source = BillSource.manual,
    this.status = BillStatus.review,
    this.externalId,
    this.date,
    this.dueDate,
    this.payee,
    this.iban,
    this.reference,
    this.description,
    this.category,
    this.note,
    this.total,
    this.currency = 'EUR',
    this.items = const [],
    this.unsure = 0,
    this.linkedTx,
    this.warrantyUntil,
    this.returnBy,
    this.blob,
    this.blobType,
    this.blobBytes,
    this.deleted = false,
  });

  bool get paid => linkedTx != null;
  bool get confirmed => status == BillStatus.confirmed;

  /// The file as a [BlobRef], or null without one.
  BlobRef? get file => blob != null && blobType != null ? BlobRef(hash: blob!, type: blobType!, bytes: blobBytes ?? 0) : null;

  /// Payee, else `Bill`: the planned row's title.
  String get title => _nonEmpty(payee) ?? 'Bill';

  /// The id of the bill with [externalId], the same on every device.
  static String idFor(String externalId) => 'bill:${sha256Hex(utf8.encode(externalId)).substring(0, 32)}';

  /// Unknown `source`/`status` words (a newer build) read as manual/review; a damaged item list reads as empty.
  static Bill fromRow(Map<String, Object?> r) => Bill(
        id: r['id'] as String,
        source: BillSource.values.asNameMap()[r['source']] ?? BillSource.manual,
        status: BillStatus.values.asNameMap()[r['status']] ?? BillStatus.review,
        externalId: _s(r['external_id']),
        date: _s(r['date']),
        dueDate: _s(r['due_date']),
        payee: _s(r['payee']),
        iban: _s(r['iban']),
        reference: _s(r['reference']),
        description: _s(r['description']),
        category: _s(r['category']),
        note: _s(r['note']),
        total: _i(r['total']),
        currency: _s(r['currency']) ?? 'EUR',
        items: decodeBillItems(r['items']) ?? const [],
        unsure: _i(r['unsure']) ?? 0,
        linkedTx: _s(r['linked_tx']),
        warrantyUntil: _s(r['warranty_until']),
        returnBy: _s(r['return_by']),
        blob: _s(r['blob']),
        blobType: _s(r['blob_type']),
        blobBytes: _i(r['blob_bytes']),
        deleted: r['deleted'] == 1,
      );
}

String? _s(Object? v) => v is String ? v : null;
int? _i(Object? v) => v is int ? v : null;
String? _nonEmpty(String? s) => s == null || s.trim().isEmpty ? null : s;

/// Lowercase hex SHA-256 of [bytes] (synchronous, pure Dart).
String sha256Hex(List<int> bytes) => hexOf(const DartSha256().hashSync(bytes).bytes);

String hexOf(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// [items] as stored, or null when invalid (more than [maxBillItems], a name over [maxBillItemName] characters).
String? encodeBillItems(List<BillItem> items) {
  if (items.length > maxBillItems || items.any((i) => i.name.length > maxBillItemName)) return null;
  return jsonEncode([for (final i in items) i.toJson()]);
}

/// The stored item list, or null when it is not valid JSON of the right shape (int amounts, limits as [encodeBillItems]).
List<BillItem>? decodeBillItems(Object? raw) {
  if (raw is! String) return null;
  final Object? j;
  try {
    j = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (j is! List || j.length > maxBillItems) return null;
  final out = <BillItem>[];
  for (final e in j) {
    if (e is! Map) return null;
    final (name, qty, amount) = (e['name'], e['quantity'], e['amount']);
    if (name is! String || name.length > maxBillItemName || amount is! int || (qty != null && qty is! String)) return null;
    out.add(BillItem(name: name, quantity: qty as String?, amount: amount));
  }
  return out;
}

// ---------- auto link ----------

/// Days before the bill's date and after its due date (or date) in which a bank row may be its payment ([planBillLinks]).
const billLinkDaysBefore = 3, billLinkDaysAfter = 60;

/// Days after the due date (or date) that [billCandidates] looks at.
const billCandidateDaysAfter = 30;

/// Upper case, letters A–Z and digits only (accents folded first): how references, JIRs and invoice numbers are
/// compared with a bank row's description.
String normalizeForLink(String s) => foldText(s).toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

/// What may identify [b]'s payment in a bank description, normalized ([normalizeForLink]): its reference (model + poziv
/// na broj, and the poziv na broj alone) when it has at least 6 digits, its JIR (`jir:` external id), its invoice number
/// (`inv:` external id) when at least 4 characters.
List<String> billLinkTokens(Bill b) {
  final out = <String>[];
  if (b.reference case final ref?) {
    final m = RegExp(r'^\s*(HR\d\d)\s*(.*)$', caseSensitive: false).firstMatch(ref);
    final number = (m?.group(2) ?? ref).replaceAll(RegExp(r'\D'), '');
    if (number.length >= 6) {
      if (m != null) out.add(normalizeForLink('${m.group(1)}$number'));
      out.add(number);
    }
  }
  final ext = b.externalId ?? '';
  if (ext.startsWith('jir:')) {
    final jir = normalizeForLink(ext.substring(4));
    if (jir.length >= 6) out.add(jir);
  } else if (ext.startsWith('inv:')) {
    final rest = ext.substring(4);
    final cut = rest.indexOf(':');
    final no = normalizeForLink(cut < 0 ? '' : rest.substring(cut + 1));
    if (no.length >= 4) out.add(no);
  }
  return out;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// Whether [token] occurs in the normalized [description] without running into more digits on a side where the
/// token itself starts or ends with a digit (`12345678` is not found in `9123456789`).
bool descriptionHasToken(String description, String token) {
  if (token.isEmpty) return false;
  final d = normalizeForLink(description);
  final first = _isDigit(token.codeUnitAt(0)), last = _isDigit(token.codeUnitAt(token.length - 1));
  for (var i = d.indexOf(token); i >= 0; i = d.indexOf(token, i + 1)) {
    final end = i + token.length;
    if (first && i > 0 && _isDigit(d.codeUnitAt(i - 1))) continue;
    if (last && end < d.length && _isDigit(d.codeUnitAt(end))) continue;
    return true;
  }
  return false;
}

bool _validDate(String? s) => s != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s) && isoDate(parseIso(s)) == s;

/// The dates a payment of [b] may carry for the auto link: (bill date − 3, (due date ?? date) + 60); null without a date.
(String, String)? billLinkWindow(Bill b, {int after = billLinkDaysAfter}) {
  final start = _validDate(b.date) ? b.date! : (_validDate(b.dueDate) ? b.dueDate! : null);
  final end = _validDate(b.dueDate) ? b.dueDate! : start;
  if (start == null || end == null) return null;
  return (addDays(start, -billLinkDaysBefore), addDays(end, after));
}

/// The deterministic auto link (bill id → tx id): a confirmed, unpaid, live bill with a total links to the one live
/// bank expense (not hand-added, not an own transfer, same currency) whose description holds one of its
/// [billLinkTokens] **and** whose −amount equals the total exactly, dated in [billLinkWindow]. Rows already linked to
/// another bill in [bills] never count. A bill with several such rows, or a row that would serve several bills, links
/// nothing (left for the owner). Never by amount alone: a bill without tokens never links.
Map<String, String> planBillLinks(List<Bill> bills, List<Tx> rows) {
  final taken = {
    for (final b in bills)
      if (!b.deleted && b.linkedTx != null) b.linkedTx!
  };
  final proposals = <String, String>{};
  final byTx = <String, int>{};
  for (final b in bills) {
    if (b.deleted || !b.confirmed || b.paid || b.total == null || b.total! <= 0) continue;
    final tokens = billLinkTokens(b);
    final window = billLinkWindow(b);
    if (tokens.isEmpty || window == null) continue;
    final found = [
      for (final t in rows)
        if (!t.manual &&
            !t.deleted &&
            t.transferTo == null &&
            t.amount == -b.total! &&
            t.currency == b.currency &&
            !taken.contains(t.id) &&
            t.date.compareTo(window.$1) >= 0 &&
            t.date.compareTo(window.$2) <= 0 &&
            tokens.any((k) => descriptionHasToken(t.description, k)))
          t.id
    ];
    if (found.length != 1) continue;
    proposals[b.id] = found.single;
    byTx[found.single] = (byTx[found.single] ?? 0) + 1;
  }
  proposals.removeWhere((_, tx) => byTx[tx]! > 1);
  return proposals;
}

/// "Paid by this?" candidates for [b]: live expenses dated from (date − 3) to (due date ?? date) + 30 that are not
/// linked to another bill in [all]; rows whose description holds a word of the payee (3+ letters, folded) first, then
/// the closest to the bill's date or due date, then the amount closest to the total, then date, then id. Never filtered
/// by amount. A bill without a date has none.
List<CategorizedTx> billCandidates(Bill b, List<CategorizedTx> txs, List<Bill> all) {
  final window = billLinkWindow(b, after: billCandidateDaysAfter);
  if (window == null) return const [];
  final taken = {
    for (final o in all)
      if (o.id != b.id && !o.deleted && o.linkedTx != null) o.linkedTx!
  };
  final words = [
    for (final w in foldText(b.payee ?? '').split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)))
      if (w.length >= 3) w
  ];
  final out = [
    for (final t in txs)
      if (t.tx.live && t.amount < 0 && !taken.contains(t.tx.id) && t.date.compareTo(window.$1) >= 0 && t.date.compareTo(window.$2) <= 0) t
  ];
  bool named(CategorizedTx t) {
    final d = foldText(t.tx.description);
    return words.any(d.contains);
  }

  int dist(CategorizedTx t) => [
        for (final d in [b.date, b.dueDate])
          if (_validDate(d)) daysBetween(d!, t.date).abs()
      ].reduce((x, y) => x < y ? x : y);
  int off(CategorizedTx t) => b.total == null ? 0 : (-t.amount - b.total!).abs();
  final isNamed = {for (final t in out) t.tx.id: named(t)};
  out.sort((x, y) {
    var c = (isNamed[x.tx.id]! ? 0 : 1).compareTo(isNamed[y.tx.id]! ? 0 : 1);
    if (c == 0) c = dist(x).compareTo(dist(y));
    if (c == 0) c = off(x).compareTo(off(y));
    if (c == 0) c = x.date.compareTo(y.date);
    return c != 0 ? c : x.tx.id.compareTo(y.tx.id);
  });
  return out;
}

// ---------- reminders ----------

/// A warranty or return window of a bill that ends soon ([billReminders]).
class BillReminder {
  final Bill bill;

  /// [UpcomingKind.warranty] or [UpcomingKind.returnBy].
  final UpcomingKind kind;

  /// The last day (the bill's `warrantyUntil` / `returnBy`).
  final String date;

  /// Days from today to [date] (0 = today).
  final int daysLeft;
  const BillReminder({required this.bill, required this.kind, required this.date, required this.daysLeft});
}

/// Return windows ending from [today] to [today] + [returnDays] and warranties ending from [today] to [today] +
/// [warrantyDays] (inclusive), of confirmed, live bills. Sorted by date, then kind (return first), then bill id. The app
/// passes the settings `returnReminderDays` / `warrantyReminderDays` for Today, or a longer horizon to schedule
/// notifications (09:00 on date − days).
List<BillReminder> billReminders(List<Bill> bills, String today, {required int returnDays, required int warrantyDays}) {
  if (!_validDate(today)) return const [];
  final out = <BillReminder>[];
  void add(Bill b, UpcomingKind kind, String? date, int days) {
    if (days < 0 || !_validDate(date)) return;
    final left = daysBetween(today, date!);
    if (left >= 0 && left <= days) out.add(BillReminder(bill: b, kind: kind, date: date, daysLeft: left));
  }

  for (final b in bills) {
    if (b.deleted || !b.confirmed) continue;
    add(b, UpcomingKind.returnBy, b.returnBy, returnDays);
    add(b, UpcomingKind.warranty, b.warrantyUntil, warrantyDays);
  }
  int rank(UpcomingKind k) => k == UpcomingKind.returnBy ? 0 : 1;
  out.sort((a, b) {
    var c = a.date.compareTo(b.date);
    if (c == 0) c = rank(a.kind).compareTo(rank(b.kind));
    return c != 0 ? c : a.bill.id.compareTo(b.bill.id);
  });
  return out;
}
