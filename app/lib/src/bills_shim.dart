// TEMPORARY SHIM (stage B4) — delete this file when B1a (readers) and B1b (core) are merged.
//
// Everything the bills database will get from `wallet_core` / `wallet_importer`, under the names fixed in
// docs/context/BILLS_API.md, so the app half could be built and tested before the real code exists. The in-memory store
// lives in an Expando keyed by the repo, so nothing here touches the database. The readers understand only the simple
// synthetic shapes the app tests use. The swap is mechanical: remove this file and its imports (`bills_shim.dart`) and the
// `// SHIM:` lines in controller_bills.dart; the names stay the same.
import 'dart:convert';
import 'dart:typed_data';

import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show BillItem, BillSource, NormalizedBill, fnv1a36;

export 'package:wallet_importer/wallet_importer.dart' show BillItem, BillSource, NormalizedBill; // the core will re-export these

enum BillStatus { review, confirmed }

class Bill {
  final String id;
  final BillSource source;
  final BillStatus status;
  final String? externalId, date, dueDate, payee, iban, reference, description, category, note;
  final int? total;
  final String currency;
  final List<BillItem> items;
  final String? linkedTx, warrantyUntil, returnBy, blob, blobType;
  final int? blobBytes;
  final bool deleted;
  const Bill({
    required this.id,
    required this.source,
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
    this.linkedTx,
    this.warrantyUntil,
    this.returnBy,
    this.blob,
    this.blobType,
    this.blobBytes,
    this.deleted = false,
  });
  bool get paid => linkedTx != null;

  Bill _with({
    BillStatus? status,
    Object? date = _keep,
    Object? dueDate = _keep,
    Object? total = _keep,
    Object? payee = _keep,
    Object? iban = _keep,
    Object? reference = _keep,
    Object? description = _keep,
    Object? category = _keep,
    Object? note = _keep,
    List<BillItem>? items,
    Object? linkedTx = _keep,
    Object? warrantyUntil = _keep,
    Object? returnBy = _keep,
    bool? deleted,
  }) =>
      Bill(
        id: id,
        source: source,
        status: status ?? this.status,
        externalId: externalId,
        date: identical(date, _keep) ? this.date : date as String?,
        dueDate: identical(dueDate, _keep) ? this.dueDate : dueDate as String?,
        payee: identical(payee, _keep) ? this.payee : payee as String?,
        iban: identical(iban, _keep) ? this.iban : iban as String?,
        reference: identical(reference, _keep) ? this.reference : reference as String?,
        description: identical(description, _keep) ? this.description : description as String?,
        category: identical(category, _keep) ? this.category : category as String?,
        note: identical(note, _keep) ? this.note : note as String?,
        total: identical(total, _keep) ? this.total : total as int?,
        currency: currency,
        items: items ?? this.items,
        linkedTx: identical(linkedTx, _keep) ? this.linkedTx : linkedTx as String?,
        warrantyUntil: identical(warrantyUntil, _keep) ? this.warrantyUntil : warrantyUntil as String?,
        returnBy: identical(returnBy, _keep) ? this.returnBy : returnBy as String?,
        blob: blob,
        blobType: blobType,
        blobBytes: blobBytes,
        deleted: deleted ?? this.deleted,
      );
}

const Object _keep = Object();

class BlobRef {
  final String hash;
  final String type;
  final int bytes;
  const BlobRef(this.hash, this.type, this.bytes);
}

final Map<String, Uint8List> _blobs = {};

class BlobStore {
  BlobStore(WalletRepo repo, VaultKey key);
  Future<BlobRef> add(Uint8List plain, String type) async {
    if (plain.length > 15 * 1024 * 1024) throw ArgumentError('too big');
    final hash = '${fnv1a36(base64.encode(plain.take(2000).toList()))}${plain.length.toRadixString(16)}';
    _blobs[hash] = plain;
    return BlobRef(hash, type, plain.length);
  }

  Future<Uint8List?> read(String hash, {SyncTransport? transport}) async => _blobs[hash];
}

class _Store {
  final List<Bill> bills = [];
  int n = 0;
}

final Expando<_Store> _stores = Expando('bills');

extension BillsShim on WalletRepo {
  _Store get _s => _stores[this] ??= _Store();

  List<Bill> bills({bool includeDeleted = false}) => [
        for (final b in _s.bills)
          if (includeDeleted || !b.deleted) b
      ];

  (String, bool) importBill(NormalizedBill b, {BlobRef? file}) {
    final s = _s;
    if (b.externalId != null) {
      final i = s.bills.indexWhere((x) => x.externalId == b.externalId && !x.deleted);
      if (i >= 0) return (s.bills[i].id, false);
    }
    final id = b.externalId != null ? 'bill:${fnv1a36(b.externalId!)}' : 'b${++s.n}';
    s.bills.add(Bill(
      id: id,
      source: b.source,
      externalId: b.externalId,
      date: b.date,
      dueDate: b.dueDate,
      payee: b.payee,
      iban: b.iban,
      reference: b.reference,
      description: b.description,
      total: b.total,
      currency: b.currency,
      items: b.items,
      blob: file?.hash,
      blobType: file?.type,
      blobBytes: file?.bytes,
    ));
    return (id, true);
  }

  void _put(String id, Bill Function(Bill) f) {
    final s = _s;
    final i = s.bills.indexWhere((x) => x.id == id);
    if (i < 0) throw ArgumentError('no such bill');
    s.bills[i] = f(s.bills[i]);
  }

  void updateBill(String id,
      {String? date,
      String? dueDate,
      int? total,
      String? payee,
      String? iban,
      String? reference,
      String? description,
      String? category,
      String? note,
      List<BillItem>? items,
      String? warrantyUntil,
      String? returnBy,
      bool clearDueDate = false,
      bool clearWarranty = false,
      bool clearReturnBy = false,
      bool clearCategory = false}) {
    _put(
        id,
        (b) => b._with(
              date: date ?? _keep,
              dueDate: clearDueDate ? null : (dueDate ?? _keep),
              total: total ?? _keep,
              payee: payee ?? _keep,
              iban: iban ?? _keep,
              reference: reference ?? _keep,
              description: description ?? _keep,
              category: clearCategory ? null : (category ?? _keep),
              note: note ?? _keep,
              items: items,
              warrantyUntil: clearWarranty ? null : (warrantyUntil ?? _keep),
              returnBy: clearReturnBy ? null : (returnBy ?? _keep),
            ));
  }

  void confirmBill(String id) {
    _put(id, (b) {
      if (b.date == null || (b.total ?? 0) <= 0) throw ArgumentError('needs date and total');
      return b._with(status: BillStatus.confirmed);
    });
  }

  void linkBill(String id, String txId) {
    if (_s.bills.any((b) => b.id != id && b.linkedTx == txId && !b.deleted)) throw ArgumentError('payment already linked');
    _put(id, (b) => b._with(linkedTx: txId));
  }

  void unlinkBill(String id) => _put(id, (b) => b._with(linkedTx: null));
  void deleteBill(String id) => _put(id, (b) => b._with(deleted: true));

  String addExpenseFromBill(String id, {required String category}) {
    final b = _s.bills.firstWhere((x) => x.id == id);
    final tx = addManual(
        date: b.date ?? '1970-01-01',
        amount: b.total ?? 0,
        category: category,
        note: b.payee ?? b.description ?? 'Bill',
        currency: b.currency);
    _put(id, (x) => x._with(linkedTx: tx, status: BillStatus.confirmed));
    return tx;
  }
}

/// Live expenses dated date − 3 .. (dueDate ?? date) + 30, not linked to another bill; payee words first, then date distance.
List<CategorizedTx> billCandidates(Bill b, List<CategorizedTx> txs, List<Bill> all) {
  final d = b.date;
  if (d == null) return const [];
  final from = addDays(d, -3), to = addDays(b.dueDate ?? d, 30);
  final used = {
    for (final x in all)
      if (x.id != b.id && !x.deleted && x.linkedTx != null) x.linkedTx!
  };
  final words = (b.payee ?? '').toLowerCase().split(RegExp(r'\W+')).where((w) => w.length >= 3).toList();
  final out = [
    for (final t in txs)
      if (t.tx.live && t.amount < 0 && t.date.compareTo(from) >= 0 && t.date.compareTo(to) <= 0 && !used.contains(t.tx.id)) t
  ];
  bool hit(CategorizedTx t) => words.any((w) => t.tx.description.toLowerCase().contains(w));
  out.sort((a, c) {
    final h = (hit(c) ? 1 : 0) - (hit(a) ? 1 : 0);
    if (h != 0) return h;
    return daysBetween(d, a.date).abs() - daysBetween(d, c.date).abs();
  });
  return out;
}

/// The Upcoming kinds the core will add: the shim shows them as planned-kind items with a `w:` / `r:` key.
class BillReminder {
  final Bill bill;
  final String kind; // 'warranty' | 'returnBy'
  final String date;
  final int daysLeft;
  const BillReminder(this.bill, this.kind, this.date, this.daysLeft);
}

List<BillReminder> billReminders(List<Bill> bills, String today, {required int returnDays, required int warrantyDays}) {
  final out = <BillReminder>[];
  for (final b in bills) {
    if (b.deleted || b.status != BillStatus.confirmed) continue;
    void one(String? date, String kind, int days) {
      if (date == null) return;
      final left = daysBetween(today, date);
      if (left < 0) return;
      if (left <= days) out.add(BillReminder(b, kind, date, left));
    }

    one(b.returnBy, 'returnBy', returnDays);
    one(b.warrantyUntil, 'warranty', warrantyDays);
  }
  out.sort((a, b) => a.date.compareTo(b.date));
  return out;
}

// ---- readers: only the simple shapes (see BILLS_API §1) ----

int? _cents(String s) {
  final t = s.trim().replaceAll(' ', '');
  if (RegExp(r'^\d+$').hasMatch(t)) return int.parse(t);
  final m = RegExp(r'^(\d+)[.,](\d{1,2})$').firstMatch(t);
  return m == null ? null : int.parse(m.group(1)!) * 100 + int.parse(m.group(2)!.padRight(2, '0'));
}

NormalizedBill? readFiscalQr(String payload) {
  final u = Uri.tryParse(payload.trim());
  if (u == null || u.host != 'porezna.gov.hr') return null;
  final jir = u.queryParameters['jir'], zki = u.queryParameters['zki'];
  final total = _cents(u.queryParameters['izn'] ?? '');
  final datv = u.queryParameters['datv'] ?? '';
  if ((jir == null && zki == null) || total == null) return null;
  final date = datv.length >= 8 ? '${datv.substring(0, 4)}-${datv.substring(4, 6)}-${datv.substring(6, 8)}' : null;
  return NormalizedBill(
      source: BillSource.receiptQr, externalId: jir != null ? 'jir:$jir' : 'zki:$zki', date: date, total: total, description: 'Receipt');
}

NormalizedBill? readHub3(String payload) {
  final l = payload.split(RegExp(r'\r?\n'));
  if (l.length < 14 || l[0].trim() != 'HRVHUB30') return null;
  final total = _cents(l[2]);
  if (total == null) return null;
  final iban = l[9].trim(), model = l[10].trim(), ref = l[11].trim();
  return NormalizedBill(
      source: BillSource.hub3,
      externalId: 'hub3:$iban:$model $ref:$total',
      payee: l[6].trim(),
      iban: iban,
      reference: '$model $ref',
      total: total,
      description: l.length > 13 ? l[13].trim() : null,
      currency: l[1].trim().isEmpty ? 'EUR' : l[1].trim());
}

NormalizedBill? readEInvoice(String xml) {
  String? tag(String t) => RegExp('<(?:cbc:)?$t[^>]*>([^<]+)<').firstMatch(xml)?.group(1)?.trim();
  final total = _cents(tag('PayableAmount') ?? '');
  final id = tag('ID');
  if (id == null || total == null) return null;
  return NormalizedBill(
      source: BillSource.eInvoice,
      externalId: 'inv:$id',
      date: tag('IssueDate'),
      dueDate: tag('DueDate'),
      total: total,
      description: 'Invoice $id');
}

String? pdfText(Uint8List pdf) {
  final s = latin1.decode(pdf, allowInvalid: true);
  final parts = [for (final m in RegExp(r'\(([^)]*)\)\s*Tj').allMatches(s)) m.group(1)!];
  return parts.isEmpty ? null : parts.join('\n');
}

NormalizedBill? billFromText(String text, {required BillSource source}) {
  final m = RegExp(r'(?:Ukupno|Total|Za platiti)[^\d]{0,12}(\d+[.,]\d{2})', caseSensitive: false).firstMatch(text);
  final d = RegExp(r'(\d{1,2})\.(\d{1,2})\.(\d{4})').firstMatch(text);
  final iso = RegExp(r'(\d{4})-(\d{2})-(\d{2})').firstMatch(text);
  String? date;
  if (d != null) date = '${d.group(3)}-${d.group(2)!.padLeft(2, '0')}-${d.group(1)!.padLeft(2, '0')}';
  if (iso != null) date = iso.group(0);
  if (m == null && date == null) return null;
  return NormalizedBill(
      source: source, total: m == null ? null : _cents(m.group(1)!), date: date, unsure: (m == null ? 0 : 1) + (date == null ? 0 : 1));
}
