// Bills database (stage B, docs/context/BILLS_API.md §2–§3): the synced `bill` entity, deterministic auto link,
// "Paid by this?" candidates and warranty / return-by reminders. Pure and web-safe.
import 'dart:convert';

import 'package:cryptography/dart.dart' show DartSha256;
import 'package:wallet_importer/wallet_importer.dart' show BillItem, BillSource;

import 'categories.dart' show BudgetKind, CategoryTable, merchantKey;
import 'cols.dart';
import 'dates.dart';
import 'models.dart';
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

/// Whether [s] is a blob hash: 64 lowercase hex characters.
bool isBlobHash(String s) => RegExp(r'^[0-9a-f]{64}$').hasMatch(s);

/// File types an attachment (P16b) may have: photos and PDFs (an e-invoice `xml` belongs to a bill).
const attachmentTypes = {'jpg', 'png', 'pdf'};

/// At most this many live attachments ([BillSource.attachment], P16b) per payment.
const maxAttachmentsPerTx = 5;

/// Limits of a bill's item list (stored as JSON text in `bills.items`).
const maxBillItems = 500, maxBillItemName = 200;

/// The columns of the synced entity `bill` (table `bills`), in table order: one line per column gives its DDL, sync
/// type check, snapshot, search, `WalletRepo.patch` validation and its label ([Col]).
abstract final class BillCols {
  static const entity = 'bill';
  static const source = EnumCol(entity, 'source', label: 'Source', values: BillSource.values, defaultValue: BillSource.manual);
  static const status = EnumCol(entity, 'status', label: 'Status', values: BillStatus.values, defaultValue: BillStatus.review);
  static const externalId = TextCol(entity, 'external_id', label: 'Code', nullable: true);
  static const date = DateCol(entity, 'date', label: 'Date', nullable: true);
  static const dueDate = DateCol(entity, 'due_date', label: 'Due date', nullable: true);
  static const payee = TextCol(entity, 'payee', label: 'Payee', nullable: true, searchable: true);
  static const iban = TextCol(entity, 'iban', label: 'IBAN', nullable: true);
  static const reference = TextCol(entity, 'reference', label: 'Reference', nullable: true);
  static const description = TextCol(entity, 'description', label: 'Description', nullable: true, searchable: true);
  static const category = TextCol(entity, 'category', label: 'Category', nullable: true);
  static const note = TextCol(entity, 'note', label: 'Note', nullable: true);
  static const total = MoneyCol(entity, 'total', label: 'Total', nullable: true, searchable: true, positive: true);
  static const currency = TextCol(entity, 'currency', label: 'Currency', defaultValue: 'EUR');
  static const items = JsonCol(entity, 'items', label: 'Items', defaultValue: '[]', check: billItemsProblem);
  static const unsure = IntCol(entity, 'unsure', label: 'Unsure fields', defaultValue: 0);
  static const linkedTx = RefCol(entity, 'linked_tx', label: 'Payment', target: 'tx', nullable: true);
  static const warrantyUntil = DateCol(entity, 'warranty_until', label: 'Warranty until', nullable: true);
  static const returnBy = DateCol(entity, 'return_by', label: 'Return by', nullable: true);
  static const blob = TextCol(entity, 'blob', label: 'File', nullable: true);
  static const blobType = TextCol(entity, 'blob_type', label: 'File type', nullable: true);
  static const blobBytes = IntCol(entity, 'blob_bytes', label: 'File size', nullable: true);
  static const deleted = FlagCol(entity, 'deleted', label: 'Deleted');
  // v16 (P16b): the payment an attachment belongs to; `linked_tx` stays null for attachments, so builds before P16b
  // never take one for the bill that paid a row. No index: the DDL (with its indexes) runs before the column migration
  // adds this column to an existing table.
  static const attachedTx = RefCol(entity, 'attached_tx', label: 'Attached to', target: 'tx', nullable: true);
  // v20 (UX-A): this bill's own reminder days before its return-by / warranty date; null = the wallet setting.
  static const returnReminderDays = IntCol(entity, 'return_reminder_days',
      label: 'Return reminder', nullable: true, min: 0, max: WalletSettings.maxReturnReminderDays, unit: 'days before');
  static const warrantyReminderDays = IntCol(entity, 'warranty_reminder_days',
      label: 'Warranty reminder', nullable: true, min: 0, max: WalletSettings.maxWarrantyReminderDays, unit: 'days before');

  static const all = <Col>[
    source, status, externalId, date, dueDate, payee, iban, reference, description, category, note, total, currency, //
    items, unsure, linkedTx, warrantyUntil, returnBy, blob, blobType, blobBytes, deleted, attachedTx, //
    returnReminderDays, warrantyReminderDays,
  ];
}

/// Why a stored item list ([BillCols.items]) is refused: null when [text] is a list within the limits.
String? billItemsProblem(String text) {
  final items = decodeBillItems(text);
  return items == null || encodeBillItems(items) == null ? 'Too many items or a name too long.' : null;
}

/// A bill (receipt, payment slip, e-invoice, PDF or photo), synced entity `bill` (schema 7). Amounts are cents,
/// positive = what the bill asks. Bills are information: linking one never changes the paying row's category.
/// Backed by its stored row: the getters read through [BillCols] ([Col.read]: an unknown `source`/`status` word reads
/// as manual/review, a damaged item list as empty, a bad date or reminder count as none); `bill[col]` reads any column.
class Bill extends RowModel {
  Bill._(super.row);

  /// A bill from its values (tests, previews); stored rows come through [fromRow].
  factory Bill({
    required String id,
    BillSource source = BillSource.manual,
    BillStatus status = BillStatus.review,
    String? externalId,
    String? date,
    String? dueDate,
    String? payee,
    String? iban,
    String? reference,
    String? description,
    String? category,
    String? note,
    int? total,
    String currency = 'EUR',
    List<BillItem> items = const [],
    int unsure = 0,
    String? linkedTx,
    String? attachedTx,
    String? warrantyUntil,
    String? returnBy,
    int? returnReminderDays,
    int? warrantyReminderDays,
    String? blob,
    String? blobType,
    int? blobBytes,
    bool deleted = false,
  }) =>
      Bill._({
        'id': id,
        'source': source.name,
        'status': status.name,
        'external_id': externalId,
        'date': date,
        'due_date': dueDate,
        'payee': payee,
        'iban': iban,
        'reference': reference,
        'description': description,
        'category': category,
        'note': note,
        'total': total,
        'currency': currency,
        'items': encodeBillItems(items) ?? items, // a list past the limits stays a list (read back as given)
        'unsure': unsure,
        'linked_tx': linkedTx,
        'attached_tx': attachedTx,
        'warranty_until': warrantyUntil,
        'return_by': returnBy,
        'return_reminder_days': returnReminderDays,
        'warranty_reminder_days': warrantyReminderDays,
        'blob': blob,
        'blob_type': blobType,
        'blob_bytes': blobBytes,
        'deleted': deleted ? 1 : 0,
      });

  /// A stored row (a map as `SELECT *` gives it); the map is copied.
  static Bill fromRow(Map<String, Object?> r) => Bill._(Map.of(r));

  /// `bill:<32 hex of SHA-256(externalId)>` when [externalId] is known (devices converge on one bill), else `b…`.
  String get id => row['id'] as String;
  BillSource get source => BillCols.source.read(row)!;
  BillStatus get status => BillCols.status.read(row)!;
  String? get externalId => BillCols.externalId.read(row);
  String? get date => BillCols.date.read(row);
  String? get dueDate => BillCols.dueDate.read(row);
  String? get payee => BillCols.payee.read(row);
  String? get iban => BillCols.iban.read(row);
  String? get reference => BillCols.reference.read(row);
  String? get description => BillCols.description.read(row);
  String? get category => BillCols.category.read(row);
  String? get note => BillCols.note.read(row);
  int? get total => BillCols.total.read(row);
  String get currency => BillCols.currency.read(row)!;

  /// The item list; a damaged one reads as empty. A bill made with [Bill.new] holds its list as given.
  List<BillItem> get items => switch (row['items']) { final List<BillItem> l => l, final v => decodeBillItems(v) ?? const [] };

  /// Fields the reader guessed from free text (PDF text, OCR): the UI marks the bill as unsure while > 0.
  int get unsure => BillCols.unsure.read(row)!;

  /// The payment: a bank row or a hand-added expense ([WalletRepo.linkBill], [WalletRepo.addExpenseFromBill]). Null
  /// for an attachment (its payment is [attachedTx]).
  String? get linkedTx => BillCols.linkedTx.read(row);

  /// The payment an attachment (P16b, [isAttachment]) belongs to; null for every other bill.
  String? get attachedTx => BillCols.attachedTx.read(row);
  String? get warrantyUntil => BillCols.warrantyUntil.read(row);
  String? get returnBy => BillCols.returnBy.read(row);

  /// This bill's own reminder days before [returnBy] / [warrantyUntil] (UX-A, 0..[WalletSettings.maxReturnReminderDays] /
  /// 0..[WalletSettings.maxWarrantyReminderDays]); null = the wallet setting ([effectiveReturnReminderDays]).
  int? get returnReminderDays => BillCols.returnReminderDays.read(row);
  int? get warrantyReminderDays => BillCols.warrantyReminderDays.read(row);

  /// The bill's file on the relay ([BlobRef.hash]), its type and plain size.
  String? get blob => BillCols.blob.read(row);
  String? get blobType => BillCols.blobType.read(row);
  int? get blobBytes => BillCols.blobBytes.read(row);
  bool get deleted => BillCols.deleted.read(row)!;

  /// Linked to its payment; an attachment always (it is a record of its payment, [attachedTx]).
  bool get paid => linkedTx != null || isAttachment;
  bool get confirmed => status == BillStatus.confirmed;

  /// A file attached to its payment ([linkedTx]; P16b): never a bill to review, pay, reserve, match or remind of.
  bool get isAttachment => source == BillSource.attachment;

  /// The file as a [BlobRef], or null without one.
  BlobRef? get file => blob != null && blobType != null ? BlobRef(hash: blob!, type: blobType!, bytes: blobBytes ?? 0) : null;

  /// Payee, else `Bill`: the planned row's title.
  String get title => _nonEmpty(payee) ?? 'Bill';

  /// The id of the bill with [externalId], the same on every device.
  static String idFor(String externalId) => 'bill:${sha256Hex(utf8.encode(externalId)).substring(0, 32)}';
}

/// The days before [b]'s return-by date its reminder comes (UX-A): the bill's own [Bill.returnReminderDays], else the
/// wallet setting [WalletSettings.returnReminderDays].
int effectiveReturnReminderDays(Bill b, WalletSettings s) => b.returnReminderDays ?? s.returnReminderDays;

/// The days before [b]'s warranty end its reminder comes: [Bill.warrantyReminderDays], else the wallet setting.
int effectiveWarrantyReminderDays(Bill b, WalletSettings s) => b.warrantyReminderDays ?? s.warrantyReminderDays;
String? _nonEmpty(String? s) => s == null || s.trim().isEmpty ? null : s;

/// Lowercase hex SHA-256 of [bytes] (synchronous, pure Dart).
String sha256Hex(List<int> bytes) => _hexOf(const DartSha256().hashSync(bytes).bytes);

String _hexOf(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

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
const _billLinkDaysBefore = 3, billLinkDaysAfter = 60;

/// Days after the due date (or date) that [billCandidates] looks at.
const _billCandidateDaysAfter = 30;

/// Upper case, letters A–Z and digits only (accents folded first): how references, JIRs and invoice numbers are
/// compared with a bank row's description.
String _normalizeForLink(String s) => foldText(s).toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

/// What may identify [b]'s payment in a bank description, normalized ([_normalizeForLink]): its reference (model + poziv
/// na broj, and the poziv na broj alone) when it has at least 6 digits, its JIR (`jir:` external id), its invoice number
/// (`inv:` external id): digits only when at least 6 digits (like a reference, so `1234` or `2026` never match a card
/// mask or a year), mixed when at least 4 characters with a letter and a digit; letters alone never.
List<String> billLinkTokens(Bill b) {
  final out = <String>[];
  if (b.reference case final ref?) {
    final m = RegExp(r'^\s*(HR\d\d)\s*(.*)$', caseSensitive: false).firstMatch(ref);
    final number = (m?.group(2) ?? ref).replaceAll(RegExp(r'\D'), '');
    if (number.length >= 6) {
      if (m != null) out.add(_normalizeForLink('${m.group(1)}$number'));
      out.add(number);
    }
  }
  final ext = b.externalId ?? '';
  if (ext.startsWith('jir:')) {
    final jir = _normalizeForLink(ext.substring(4));
    if (jir.length >= 6) out.add(jir);
  } else if (ext.startsWith('inv:')) {
    final rest = ext.substring(4);
    final cut = rest.indexOf(':');
    final no = _normalizeForLink(cut < 0 ? '' : rest.substring(cut + 1));
    final digits = no.replaceAll(RegExp('[^0-9]'), '').length;
    if (digits == no.length ? digits >= 6 : no.length >= 4 && digits > 0) out.add(no);
  }
  return out;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// Whether [token] occurs in the normalized [description] without running into more digits on a side where the
/// token itself starts or ends with a digit (`12345678` is not found in `9123456789`).
bool descriptionHasToken(String description, String token) {
  if (token.isEmpty) return false;
  final d = _normalizeForLink(description);
  final first = _isDigit(token.codeUnitAt(0)), last = _isDigit(token.codeUnitAt(token.length - 1));
  for (var i = d.indexOf(token); i >= 0; i = d.indexOf(token, i + 1)) {
    final end = i + token.length;
    if (first && i > 0 && _isDigit(d.codeUnitAt(i - 1))) continue;
    if (last && end < d.length && _isDigit(d.codeUnitAt(end))) continue;
    return true;
  }
  return false;
}

bool _validDate(String? s) => s != null && isIsoDate(s);

/// The dates a payment of [b] may carry for the auto link: (bill date − 3, (due date ?? date) + 60); null without a date.
(String, String)? _billLinkWindow(Bill b, {int after = billLinkDaysAfter}) {
  final start = _validDate(b.date) ? b.date! : (_validDate(b.dueDate) ? b.dueDate! : null);
  final end = _validDate(b.dueDate) ? b.dueDate! : start;
  if (start == null || end == null) return null;
  return (addDays(start, -_billLinkDaysBefore), addDays(end, after));
}

/// The deterministic auto link (bill id → tx id): a confirmed, unpaid, live bill with a total links to the one live
/// bank expense (not hand-added, not an own transfer, same currency) whose description holds one of its
/// [billLinkTokens] **and** whose −amount equals the total exactly, dated in [_billLinkWindow]. Rows already linked to
/// another bill in [bills] never count. A bill with several such rows, or a row that would serve several bills, links
/// nothing (left for the owner). Never by amount alone: a bill without tokens never links. Attachments
/// ([Bill.isAttachment]) neither link nor take a row.
Map<String, String> planBillLinks(List<Bill> bills, List<Tx> rows) {
  final taken = {
    for (final b in bills)
      if (!b.deleted && !b.isAttachment && b.linkedTx != null) b.linkedTx!
  };
  final proposals = <String, String>{};
  final byTx = <String, int>{};
  for (final b in bills) {
    if (b.deleted || b.isAttachment || !b.confirmed || b.paid || b.total == null || b.total! <= 0) continue;
    final tokens = billLinkTokens(b);
    final window = _billLinkWindow(b);
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

/// The payee's words (3+ letters or digits, folded) that [billCandidates] and [suggestBillCategory] look for in a
/// bank row's description.
List<String> _billPayeeWords(Bill b) => [
      for (final w in foldText(b.payee ?? '').split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)))
        if (w.length >= 3) w
    ];

bool _named(List<String> words, CategorizedTx t) {
  final d = foldText(t.tx.description);
  return words.any(d.contains);
}

/// "Paid by this?" candidates for [b]: live expenses dated from (date − 3) to (due date ?? date) + 30 that are not
/// linked to another bill in [all] and are not an own transfer (`transferTo` set, or a transfer category); rows whose
/// description holds a word of the payee ([_billPayeeWords]) first, then
/// the closest to the bill's date or due date, then the amount closest to the total, then date, then id. Never filtered
/// by amount. A bill without a date has none.
/// P6: expects whole payments (`Categorizer.categorize`, one row per payment), never the expanded list (`Categorizer.expand`).
/// An attachment ([Bill.isAttachment]) has none and never takes a row.
List<CategorizedTx> billCandidates(Bill b, List<CategorizedTx> txs, List<Bill> all) {
  final window = b.isAttachment ? null : _billLinkWindow(b, after: _billCandidateDaysAfter);
  if (window == null) return const [];
  final taken = {
    for (final o in all)
      if (o.id != b.id && !o.deleted && !o.isAttachment && o.linkedTx != null) o.linkedTx!
  };
  final words = _billPayeeWords(b);
  final out = [
    for (final t in txs)
      if (t.tx.live &&
          t.amount < 0 &&
          t.tx.transferTo == null &&
          t.kind != BudgetKind.transfer &&
          !taken.contains(t.tx.id) &&
          t.date.compareTo(window.$1) >= 0 &&
          t.date.compareTo(window.$2) <= 0)
        t
  ];
  bool named(CategorizedTx t) => _named(words, t);

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

// ---------- categories and recurring bills (docs/context/BILLS_API.md §2) ----------

/// The bill's payee as a recurring-bill payee key ([merchantKey] of a bank row described by the payee, the rule
/// [RecurringBill.payee] uses), or null without a payee (or one without letters). KL-A: a key in [payeeAliases]
/// (`WalletRepoBills.payeeAliases`: a slip's spelling → the recurring bill's payee key) reads as its payee, one step
/// ([resolvePayeeAlias]).
String? billPayeeKey(Bill b, {Map<String, String> payeeAliases = const {}}) => resolvePayeeAlias(_payeeKey(b.payee), payeeAliases);

/// KL-A: [key] through [payeeAliases] (alias key → payee key), exactly and one step only: an alias that maps to
/// another alias is never followed further (no chains). null stays null.
String? resolvePayeeAlias(String? key, Map<String, String> payeeAliases) => key == null ? null : payeeAliases[key] ?? key;

/// KL-A: the synced row id of payee alias [aliasKey]: `pa:` + the first 16 hex characters of the SHA-256 of its UTF-8
/// bytes (the same alias set on two devices is one row; the id does not show the payee). Not safe in a log.
String payeeAliasId(String aliasKey) => 'pa:${sha256Hex(utf8.encode(aliasKey)).substring(0, 16)}';

String? _payeeKey(String? payee) {
  final p = _nonEmpty(payee);
  if (p == null) return null;
  final k = merchantKey(Tx(id: '', source: 'bill', date: '', amount: 0, description: p.trim()));
  return k == 'x' ? null : k;
}

/// The confirmed recurring bill that already plans [b]'s payment, or null: same payee key ([billPayeeKey] ==
/// [RecurringBill.payee], exactly) and [b]'s due date within ± the bill's [RecurringBill.tolerance] (3 days for a
/// monthly one) of one of its cycles: `nextDue` + k × `intervalDays` for k ≥ −1 (k = −1 is the cycle just paid, or skipped, before `nextDue`). Never by amount. Such a
/// bill's planned row is not reserved where the recurring bill's occurrence already is ([plannedCoverage], decided when
/// read, so the order of confirming the two never matters and nothing is written): the recurring bill reserves that
/// payment, or the fixed plan holds it. The bill
/// itself is listed as before (Plan › Bills, linking, reminders).
RecurringBill? billCoveredBy(Bill b, List<RecurringBill> recurring, {Map<String, String> payeeAliases = const {}}) =>
    _coverage(billPayeeKey(b, payeeAliases: payeeAliases), b.dueDate, recurring)?.bill;

/// [billCoveredBy] for a bill's planned row (`source` bill: payee = its title, due date = its date); null for any
/// other planned cost. Whether that keeps the row out of a total depends on where the covering occurrence falls
/// ([plannedCoverage]): `computePeriod`, `upcoming` and `plannedIcs` decide per period or range (BILLS_API.md §3).
RecurringBill? plannedCoveredBy(PlannedCost p, List<RecurringBill> recurring, {Map<String, String> payeeAliases = const {}}) =>
    plannedCoverage(p, recurring, payeeAliases: payeeAliases)?.bill;

/// Which recurring bill covers a bill's planned row [p] ([plannedCoveredBy]) and through which cycle: `occurrence` =
/// the covering cycle's date `nextDue + k × intervalDays` (k ≥ 0), or null for k = −1 (the cycle just paid or skipped
/// before `nextDue`: that payment is already in spending, or the owner skipped it). A row is left out of a total only
/// when that occurrence is itself in it (BILLS_API.md §3): `computePeriod` reserves the row unless the recurring bill is
/// `coveredByPlan`, the cycle is k = −1, or the occurrence is the `nextDue` that this period's `dueBills` lists;
/// `upcoming` / `plannedIcs` list the row unless the cycle is k = −1 or the occurrence is in their range. So a slip due
/// before payday whose recurring cycle falls just after it is reserved in this period, not dropped from both.
/// [payeeAliases]: as in [billPayeeKey] (the row's title is the slip's payee).
({RecurringBill bill, String? occurrence})? plannedCoverage(PlannedCost p, List<RecurringBill> recurring,
        {Map<String, String> payeeAliases = const {}}) =>
    p.source != PlannedSource.bill || p.title == 'Bill'
        ? null
        : _coverage(resolvePayeeAlias(_payeeKey(p.title), payeeAliases), p.date, recurring);

/// The key of one recurring bill occurrence in the set [plannedReserves] takes: `<bill id>@<YYYY-MM-DD>`.
String occurrenceKey(String recurringId, String date) => '$recurringId@$date';

/// The one rule (BILLS_API.md §3) for whether planned cost [p] adds its amount to what is set aside, given [counted]: the recurring
/// bill occurrences ([occurrenceKey]) the same total already holds. `computePeriod` passes this period's `dueBills`
/// (their `nextDue`) and sums the rows it accepts into `reservedPlanned` (`reservedPlannedRows`); the app's Upcoming
/// "Set aside" passes the bill occurrences it counts in its range, so both use the same rule. A row reserves when it is
/// open with an amount > 0, not in a fixed category ([PlannedCost.coveredByPlan]), not a bill row without a category
/// ([PlannedCost.needsCategory]), and not a slip a confirmed recurring bill already holds ([plannedCoverage]: that bill
/// is `coveredByPlan`, the cycle is the one just paid or skipped, or the covering occurrence is in [counted]). Dates are
/// the caller's to check (today .. payday for a period).
/// [table] decides which categories are fixed ([PlannedCost.coveredByPlanIn], [RecurringBill.coveredByPlanIn]).
/// [payeeAliases]: as in [billPayeeKey].
bool plannedReserves(PlannedCost p, List<RecurringBill> recurring, Set<String> counted,
    {required CategoryTable table, Map<String, String> payeeAliases = const {}}) {
  if (!p.isOpen || (p.amount ?? 0) <= 0 || p.coveredByPlanIn(table) || p.needsCategory) return false;
  final c = plannedCoverage(p, recurring, payeeAliases: payeeAliases);
  if (c == null) return true;
  return !(c.bill.coveredByPlanIn(table) || c.occurrence == null || counted.contains(occurrenceKey(c.bill.id, c.occurrence!)));
}

({RecurringBill bill, String? occurrence})? _coverage(String? key, String? due, List<RecurringBill> recurring) {
  if (key == null || !_validDate(due)) return null;
  for (final r in recurring) {
    if (!r.confirmed || r.isIncome || r.payee != key || !_validDate(r.nextDue)) continue; // an income (P9) plans no bill
    final d = daysBetween(r.nextDue, due!);
    final i = r.intervalDays;
    if (i < 1) {
      if (d.abs() <= r.tolerance) return (bill: r, occurrence: r.nextDue);
      continue;
    }
    final k = (d / i).round();
    for (final c in [k - 1, k, k + 1]) {
      if (c >= -1 && (d - c * i).abs() <= r.tolerance) return (bill: r, occurrence: c < 0 ? null : addDays(r.nextDue, c * i));
    }
  }
  return null;
}

/// A category to offer for [b] before it is confirmed ([WalletRepo.confirmBill] needs one for a bill it would
/// reserve): the category of the confirmed recurring bill with the same payee key ([billPayeeKey]); else the category
/// of the latest live bank expense (not hand-added, not an own transfer) whose description holds a payee word
/// ([_billPayeeWords], like [billCandidates]); else null. Never by amount.
/// P6: expects whole payments (`Categorizer.categorize`, one row per payment), never the expanded list (`Categorizer.expand`).
/// [payeeAliases]: as in [billPayeeKey].
String? suggestBillCategory(Bill b,
    {required List<RecurringBill> recurring,
    required List<CategorizedTx> txs,
    CategoryTable? table,
    Map<String, String> payeeAliases = const {}}) {
  final cats = table ?? CategoryTable.builtIn;
  final key = billPayeeKey(b, payeeAliases: payeeAliases);
  if (key != null) {
    for (final r in recurring) {
      if (r.confirmed && !r.isIncome && r.payee == key && r.category.isNotEmpty && cats.isLive(r.category)) return r.category;
    }
  }
  final words = _billPayeeWords(b);
  if (words.isEmpty) return null;
  CategorizedTx? best;
  for (final t in txs) {
    if (!t.tx.live || t.tx.manual || t.amount >= 0 || t.tx.transferTo != null || t.kind == BudgetKind.transfer) continue;
    if (!_named(words, t)) continue;
    if (best == null || t.date.compareTo(best.date) > 0 || (t.date == best.date && t.tx.id.compareTo(best.tx.id) > 0)) best = t;
  }
  return best?.category;
}
