// The bills database in the controller (API: docs/context/BILLS_API.md): bills from the camera, files, photos and Share to app, the lists in Plan ›
// Bills, the bill sheet's actions, the file on the relay, search and the reminders. A `part` of controller.dart so it can use
// the cache and `_changed`. The readers (QR, HUB-3, e-invoice, PDF text, text) are pure code in wallet_importer; the camera, OCR,
// PDF pages and Share are behind `BillInputs` (bill_inputs.dart) so tests never touch a plugin.
//
// Privacy: logs carry counts, sources and enum words only: never a payee, IBAN, reference, amount, item, file name or hash.
// Everything read from a code, file or photo is a suggestion: a bill stays "To review" until the owner confirms it.
part of 'controller.dart';

final _billLog = Logger('bw.bills');

/// How a try to attach a file to a payment ended.
enum AttachResult { ok, tooBig, badType, full, failed }

/// The plain words for a failed attach (null for [AttachResult.ok]).
String? attachMessage(AttachResult r) => switch (r) {
      AttachResult.ok => null,
      AttachResult.tooBig => 'This file is too big to attach (max 15 MB).',
      AttachResult.badType => 'Only photos and PDFs can be attached.',
      AttachResult.full => 'A payment holds 5 attachments at most.',
      AttachResult.failed => "Couldn't save that file. Try again.",
    };

/// How a try to add a bill ended.
enum BillImportKind { added, duplicate, unreadable, tooBig, failed, clockBehind }

class BillImport {
  final BillImportKind kind;

  /// The bill (added or already there).
  final String? billId;

  /// The original file was kept with the bill (so "Show photo" works).
  final bool fileKept;

  /// For a duplicate: the bill already there is paid or past its due date, so this is probably next month's slip.
  final bool existingDone;

  /// For a duplicate: adds the same slip once more as a new bill ("Add as new bill"); null when there is nothing to add again.
  final Future<BillImport> Function()? addAsNew;
  const BillImport(this.kind, {this.billId, this.fileKept = false, this.existingDone = false, this.addAsNew});

  bool get ok => kind == BillImportKind.added || kind == BillImportKind.duplicate;

  /// What the owner reads after the try.
  String get message => switch (kind) {
        BillImportKind.added => 'Bill added to review',
        BillImportKind.duplicate =>
          existingDone && addAsNew != null ? 'You already paid a bill like this. Add it as a new one?' : 'Already in your bills',
        BillImportKind.unreadable => "Couldn't read that bill. Try another file or photo.",
        BillImportKind.tooBig => billTooBigMessage,
        BillImportKind.failed => "Couldn't add that bill.",
        BillImportKind.clockBehind => clockBehindText,
      };
}

/// What "Show photo / PDF" gets.
enum BillFileState { ready, none, missing }

class BillFile {
  final BillFileState state;
  final Uint8List? bytes;

  /// `jpg`, `png`, `pdf` or `xml`.
  final String? type;
  const BillFile(this.state, {this.bytes, this.type});
}

/// Lists of Plan › Bills.
class BillLists {
  final List<Bill> review, unpaid, paid;
  const BillLists(this.review, this.unpaid, this.paid);
  bool get isEmpty => review.isEmpty && unpaid.isEmpty && paid.isEmpty;
}

/// A reader result with the gaps filled from [b].
NormalizedBill _fill(NormalizedBill a, NormalizedBill? b) => b == null
    ? a
    : NormalizedBill(
        source: a.source,
        externalId: a.externalId ?? b.externalId,
        date: a.date ?? b.date,
        dueDate: a.dueDate ?? b.dueDate,
        payee: a.payee ?? b.payee,
        iban: a.iban ?? b.iban,
        reference: a.reference ?? b.reference,
        description: a.description ?? b.description,
        total: a.total ?? b.total,
        currency: a.currency,
        items: a.items.isNotEmpty ? a.items : b.items,
        unsure: a.unsure + (b.unsure > 0 ? 1 : 0),
      );

NormalizedBill? _fromCode(ScannedCode c) {
  switch (c.kind) {
    case CodeKind.qr:
      return readFiscalQr(c.raw) ?? readHub3(c.raw);
    case CodeKind.pdf417:
      return readHub3(c.raw) ?? readFiscalQr(c.raw);
    case CodeKind.other:
      return readHub3(c.raw) ?? readFiscalQr(c.raw);
  }
}

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// A confirmed recurring bill's month-by-month history (Plan › Expected bills › History): the core months and, for each
/// payment, the categorized row the transaction sheet needs.
class BillHistoryView {
  final RecurringBill bill;
  final List<BillMonth> months;
  final Map<String, CategorizedTx> rows;
  const BillHistoryView(this.bill, this.months, this.rows);
}

extension BillsDb on WalletController {
  /// The history of the confirmed recurring bill [billId] (12 months, home currency), or null when it is not a confirmed
  /// bill (any more). Computed once per data version and day, and only for a bill whose History is open (never per list row).
  BillHistoryView? billHistoryFor(String billId) => _cached<BillHistoryView?>(MemoKey('billHistory', billId), () {
        RecurringBill? found;
        for (final b in recurringBills()) {
          // An income has its own cycles, not a bill's history (P9): `found` stays null for it.
          if (!b.isIncome && b.id == billId && b.status == 'confirmed') found = b;
        }
        final bill = found;
        if (bill == null) return null;
        final months = timed(
            'wc.billHistory',
            () => billHistory(
                bill,
                [
                  for (final c in wholeTxs)
                    if (c.kind != BudgetKind.transfer) c.tx
                ],
                billsAll(),
                today: today(),
                currency: currency,
                table: categoryTable,
                payeeAliases: payeeAliases()));
        final byId = {for (final c in wholeTxs) c.tx.id: c};
        return BillHistoryView(bill, months, {
          for (final m in months)
            for (final p in m.payments)
              if (byId[p.id] != null) p.id: byId[p.id]!,
        });
      });

  // ---------- lists ----------

  /// Every live bill (cached per data version).
  List<Bill> billsAll() => _cached(const MemoKey('billsDb'), () => repo.bills());

  Bill? bill(String id) {
    for (final b in billsAll()) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// To review / Unpaid (confirmed, not linked) / Paid (linked), newest first.
  BillLists billLists() => _cached(const MemoKey('billLists'), () {
        int newest(Bill a, Bill b) => (b.date ?? '').compareTo(a.date ?? '');
        final all = billsAll();
        final review = all.where((b) => b.status == BillStatus.review).toList()..sort(newest);
        final unpaid = all.where((b) => b.status == BillStatus.confirmed && !b.paid).toList()
          ..sort((a, b) => (a.dueDate ?? a.date ?? '').compareTo(b.dueDate ?? b.date ?? ''));
        final paid = all.where((b) => b.status == BillStatus.confirmed && b.paid).toList()..sort(newest);
        return BillLists(review, unpaid, paid);
      });

  int billsToReview() => billLists().review.length;

  /// The bill paid by this transaction, or null (cached map).
  Bill? billForTx(String txId) => _cached<Map<String, Bill>>(
      const MemoKey('billByTx'),
      () => {
            for (final b in billsAll())
              if (b.linkedTx != null) b.linkedTx!: b
          })[txId];

  /// "Paid by this?" candidates for [b]: payee-word matches first.
  List<CategorizedTx> billCandidatesFor(Bill b) => billCandidates(b, wholeTxs, billsAll());

  /// Bills matching [query] (payee, description, item names, exact total); the bills part of [search].
  List<Bill> searchBills(String query) => search(query).billsDb;

  // ---------- adding ----------

  /// Adds the bill read from [raw] bytes of a file the owner picked, shared or scanned: a PDF (text layer, and on Android the pages
  /// scanned for a code and, without a text layer, read as text), an e-invoice XML, or a picture (Android: codes first, then text;
  /// elsewhere kept unread). The original goes to the blob store (pictures sized down first). [trigger]: `file`, `share`, `scan`.
  Future<BillImport> importBillFile(Uint8List raw, String ext, {String trigger = 'file'}) async {
    try {
      final e = ext.toLowerCase().replaceFirst('.', '');
      if (raw.length > maxBillFileBytes(e)) {
        logEvent(_billLog, Level.INFO, 'bills.import', {'trigger': trigger, 'result': 'tooBig', 'where': 'raw'});
        return const BillImport(BillImportKind.tooBig);
      }
      NormalizedBill? bill;
      var keep = raw, type = e;
      if (e == 'pdf') {
        bill = await _readPdf(raw);
      } else if (e == 'xml') {
        try {
          bill = readEInvoice(utf8.decode(raw, allowMalformed: true));
        } catch (_) {
          bill = null;
        }
        if (bill == null) {
          logEvent(_billLog, Level.INFO, 'bills.import', {'trigger': trigger, 'result': 'unreadable', 'type': 'xml'});
          return const BillImport(BillImportKind.unreadable);
        }
      } else if (e == 'jpg' || e == 'jpeg' || e == 'png') {
        final jpeg = await billInputs.pdf.toJpeg(raw);
        if (jpeg != null) {
          keep = jpeg;
          type = 'jpg';
        } else {
          type = e == 'png' ? 'png' : 'jpg';
        }
        bill = await _readPicture(keep);
      } else {
        logEvent(_billLog, Level.INFO, 'bills.import', {'trigger': trigger, 'result': 'unsupported', 'type': 'other'});
        return const BillImport(BillImportKind.unreadable);
      }
      return await _storeBill(bill, keep, type, trigger: trigger);
    } on ClockBehindException catch (e) {
      noticeClockBehind(e);
      return const BillImport(BillImportKind.clockBehind);
    } catch (err, st) {
      logError(_billLog, 'bills.importFailed', err, st, fields: {'trigger': trigger, 'type': err.runtimeType.toString()});
      return const BillImport(BillImportKind.failed);
    }
  }

  /// A code seen by the camera (QR → receipt, PDF417 → payment slip). No file is kept. Null-safe: unreadable codes answer
  /// [BillImportKind.unreadable] and the camera goes on looking.
  Future<BillImport> importScannedCode(ScannedCode code) async {
    try {
      final b = _fromCode(code);
      if (b == null) {
        logEvent(_billLog, Level.INFO, 'bills.import', {'trigger': 'scan', 'result': 'unreadable', 'code': code.kind.name});
        return const BillImport(BillImportKind.unreadable);
      }
      return await _storeBill(b, null, null, trigger: 'scan');
    } on ClockBehindException catch (e) {
      noticeClockBehind(e);
      return const BillImport(BillImportKind.clockBehind);
    } catch (err, st) {
      logError(_billLog, 'bills.importFailed', err, st, fields: {'trigger': 'scan', 'type': err.runtimeType.toString()});
      return const BillImport(BillImportKind.failed);
    }
  }

  /// "Take photo": the kept camera frame (any image bytes). Codes first, then text; the frame is kept with the bill.
  Future<BillImport> importPhoto(Uint8List frame) => importBillFile(frame, 'jpg', trigger: 'photo');

  Future<NormalizedBill?> _readPdf(Uint8List pdf) async {
    NormalizedBill? fromText;
    String? text;
    try {
      // Off the UI isolate on native: a big PDF must not stall the screen.
      final parsed = await deps.pdfParser(pdf);
      text = parsed.text;
      fromText = parsed.bill;
    } catch (e, st) {
      logError(_billLog, 'bills.pdfTextFailed', e, st, fields: {'type': e.runtimeType.toString()});
    }
    NormalizedBill? fromCode;
    if (billInputs.pdf.supported && billInputs.reader.supported) {
      final pages = await billInputs.pdf.render(pdf);
      for (final page in pages) {
        for (final c in await billInputs.reader.codes(page)) {
          fromCode = _fromCode(c);
          if (fromCode != null) break;
        }
        if (fromCode != null) break;
      }
      if (text == null && fromCode == null && pages.isNotEmpty) {
        // A scanned PDF has no text layer: read the first page like a photo.
        final t = await billInputs.reader.text(pages.first);
        if (t != null) fromText = billFromText(t, source: BillSource.pdf);
      }
    }
    if (fromCode != null) {
      // The code is exact, the text only fills the gaps (the source stays the code's).
      return _fill(fromCode, fromText);
    }
    return fromText;
  }

  Future<NormalizedBill?> _readPicture(Uint8List jpeg) async {
    if (!billInputs.reader.supported) return null; // Linux / web: kept unread, the owner types the fields
    for (final c in await billInputs.reader.codes(jpeg)) {
      final b = _fromCode(c);
      if (b != null) return b;
    }
    final t = await billInputs.reader.text(jpeg);
    return t == null ? null : billFromText(t, source: BillSource.photo);
  }

  Future<BillImport> _storeBill(NormalizedBill? read, Uint8List? keep, String? type, {required String trigger, bool asNew = false}) async {
    var bill = read ?? NormalizedBill(source: type == 'pdf' ? BillSource.pdf : BillSource.photo);
    final found = read != null;
    if (keep != null && bill.externalId == null) {
      // Nothing in the file names the bill: the same file is the same bill (a hash of the file, never logged).
      final fileId = 'file:${_hex((await Sha256().hash(keep)).bytes).substring(0, 32)}';
      bill = NormalizedBill(
        source: bill.source,
        externalId: fileId,
        date: bill.date,
        dueDate: bill.dueDate,
        payee: bill.payee,
        iban: bill.iban,
        reference: bill.reference,
        description: bill.description,
        total: bill.total,
        currency: bill.currency,
        items: bill.items,
        unsure: bill.unsure,
      );
    }
    final existing = bill.externalId == null || asNew ? null : billsAll().where((b) => b.externalId == bill.externalId).firstOrNull;
    if (existing != null) {
      final done = existing.paid || (existing.dueDate != null && existing.dueDate!.compareTo(today()) < 0);
      logEvent(_billLog, Level.INFO, 'bills.import', {'trigger': trigger, 'source': bill.source.name, 'isNew': false, 'paidOrLate': done});
      // Next month's slip can look the same (same reference): the owner may add it once more as a new bill.
      return BillImport(BillImportKind.duplicate,
          billId: existing.id, existingDone: done, addAsNew: () => _storeBill(read, keep, type, trigger: trigger, asNew: true));
    }
    BlobRef? ref;
    if (keep != null && key != null) {
      if (keep.length > maxBlobPlainBytes) {
        logEvent(_billLog, Level.INFO, 'bills.import', {'trigger': trigger, 'result': 'tooBig'});
        return const BillImport(BillImportKind.tooBig);
      }
      ref = await _blobStore().add(keep, type ?? 'jpg');
    }
    final (id, isNew) = repo.importBill(bill, file: ref, asNew: asNew);
    logEvent(_billLog, Level.INFO, 'bills.import', {
      'trigger': trigger,
      'source': bill.source.name,
      'isNew': isNew,
      'read': found,
      'unsure': bill.unsure,
      'items': bill.items.length,
      'kept': ref != null,
      'asNew': asNew
    });
    _changed();
    return BillImport(isNew ? BillImportKind.added : BillImportKind.duplicate, billId: id, fileKept: ref != null);
  }

  // ---------- share to app ----------

  /// Results of files shared to the app (HomeShell shows the message as a SnackBar).
  Stream<BillImport> get sharedBillResults => _shareResults.stream;

  /// Starts listening for PDFs and pictures shared to the app (Android). Reads what was shared before the app opened, then
  /// everything shared while it runs. Safe to call twice.
  Future<void> startSharing() async {
    if (_shareSub != null || !billInputs.share.supported) return;
    _shareSub = billInputs.share.files.listen(_gotShared, onError: (Object e, StackTrace st) {
      logError(_billLog, 'share.streamFailed', e, st, fields: {'type': e.runtimeType.toString()});
    });
    try {
      await _gotShared(await billInputs.share.initial());
    } catch (e, st) {
      logError(_billLog, 'share.initialFailed', e, st, fields: {'type': e.runtimeType.toString()});
    }
  }

  Future<void> _gotShared(List<SharedFile> files) async {
    if (files.isEmpty || !hasWallet) return;
    logEvent(_billLog, Level.INFO, 'share.received', {'files': files.length});
    for (final f in files) {
      final r = f.tooBig ? const BillImport(BillImportKind.tooBig) : await importBillFile(f.bytes, f.ext, trigger: 'share');
      if (!_shareResults.isClosed) _shareResults.add(r);
    }
  }

  // ---------- the bill sheet ----------

  /// Saves edited fields; an empty text clears none of them (the sheet passes only fields the owner changed). Returns
  /// false (nothing saved) when core refuses the edit: a due date, total or category change that would leave an unpaid
  /// bill due from today on without a category (the sheet asks for one).
  bool updateBill(String id,
      {String? date,
      String? dueDate,
      int? total,
      String? payee,
      String? iban,
      String? reference,
      String? description,
      String? category,
      String? note,
      bool clearDueDate = false,
      bool clearCategory = false}) {
    try {
      repo.updateBill(id,
          date: date,
          dueDate: dueDate,
          total: total,
          payee: payee,
          iban: iban,
          reference: reference,
          description: description,
          category: category,
          note: note,
          clearDueDate: clearDueDate,
          clearCategory: clearCategory);
    } on ArgumentError {
      // Refused by core (a reserving bill without a category; the sheet's own checks catch the rest first).
      logEvent(_billLog, Level.INFO, 'bill.edit', {'ok': false});
      return false;
    }
    logEvent(_billLog, Level.INFO, 'bill.edit', {'category': category != null});
    _changed();
    return true;
  }

  /// Warranty and return-by dates; a null date with the clear flag removes it. Returns false (nothing saved) when core
  /// refuses it.
  bool setBillDates(String id, {String? warrantyUntil, String? returnBy, bool clearWarranty = false, bool clearReturnBy = false}) {
    try {
      repo.updateBill(id, warrantyUntil: warrantyUntil, returnBy: returnBy, clearWarranty: clearWarranty, clearReturnBy: clearReturnBy);
    } on ArgumentError {
      // Refused by core (a reserving bill without a category; the sheet's own checks catch the rest first).
      logEvent(_billLog, Level.INFO, 'bill.dates', {'ok': false});
      return false;
    }
    logEvent(_billLog, Level.INFO, 'bill.dates',
        {'warranty': warrantyUntil != null, 'returnBy': returnBy != null, 'cleared': clearWarranty || clearReturnBy});
    _changed();
    return true;
  }

  /// To review → confirmed. Needs a date and a total; returns false (nothing changed) when one is missing.
  bool confirmBill(String id) {
    final b = bill(id);
    if (b == null || b.date == null || (b.total ?? 0) <= 0) return false;
    // A slip that is still to be paid reserves money; without a category it would count on top of the fixed plan.
    if (billNeedsCategory(b)) return false;
    try {
      repo.confirmBill(id);
    } on ArgumentError {
      logEvent(_billLog, Level.INFO, 'bill.confirm', {'ok': false});
      return false;
    }
    logEvent(_billLog, Level.INFO, 'bill.confirm', {'source': b.source.name, 'items': b.items.length, 'due': b.dueDate != null});
    _changed();
    return true;
  }

  /// A bill with a due date today or later needs a category before it is confirmed.
  bool billNeedsCategory(Bill b) => b.category == null && b.dueDate != null && b.dueDate!.compareTo(today()) >= 0;

  /// The category worth suggesting for [b] (earlier bills and payments of the same payee); null when nothing fits.
  String? suggestedBillCategory(Bill b) =>
      deps.billCategorySuggester(b, () => suggestBillCategory(b, recurring: expectedBills(), txs: wholeTxs, table: categoryTable, payeeAliases: payeeAliases()));

  /// The confirmed expected bill that already plans this slip (same payee, due about one cycle), or null. Such a bill's planned row is
  /// listed but not reserved (decided by core when read).
  RecurringBill? billPlannedBy(Bill b) => billCoveredBy(b, expectedBills(), payeeAliases: payeeAliases());

  /// KL-A "Belongs to bill…": the confirmed expected bills slip [b] could belong to, when no expected bill covers it yet. Bills whose payee
  /// already is the slip's payee are left out (nothing to link). Empty for an attachment or a slip without a payee.
  List<RecurringBill> billsForSlip(Bill b) {
    final key = billPayeeKey(b);
    if (key == null || b.isAttachment || billPlannedBy(b) != null) return const [];
    return [
      for (final r in expectedBills())
        if (r.confirmed && r.payee.isNotEmpty && r.payee != key) r
    ];
  }

  /// The slip's spelling of its payee becomes an alias of expected bill [r]'s payee (exact, on every device). Returns core's text when it
  /// refuses (the chain rules), else null. Undo = [unlinkSlip].
  String? linkSlipToBill(Bill b, RecurringBill r) {
    try {
      repo.linkSlipToBill(b.id, r.id);
    } on ArgumentError catch (e) {
      logEvent(_billLog, Level.INFO, 'bill.belongsTo', {'ok': false});
      return '${e.message}';
    }
    logEvent(_billLog, Level.INFO, 'bill.belongsTo', {'ok': true});
    _changed();
    return null;
  }

  /// The Undo of [linkSlipToBill]: the alias of [b]'s payee spelling is forgotten again.
  void unlinkSlip(Bill b) {
    final key = billPayeeKey(b);
    if (key == null) return;
    repo.removePayeeAlias(key);
    logEvent(_billLog, Level.INFO, 'bill.belongsTo.undo', {});
    _changed();
  }

  /// "Paid by…": the owner picked the payment. Returns false when that payment already belongs to another bill.
  bool linkBill(String id, String txId) {
    try {
      repo.linkBill(id, txId);
    } on ArgumentError {
      logEvent(_billLog, Level.INFO, 'bill.link', {'ok': false});
      return false;
    }
    logEvent(_billLog, Level.INFO, 'bill.link', {'ok': true});
    _changed();
    return true;
  }

  void unlinkBill(String id) {
    repo.unlinkBill(id);
    logEvent(_billLog, Level.INFO, 'bill.unlink');
    _changed();
  }

  void deleteBill(String id) {
    repo.deleteBill(id);
    logEvent(_billLog, Level.INFO, 'bill.delete');
    _changed();
  }

  /// "Paid in cash": a hand-added expense for the bill's total and date, linked to it.
  void addBillAsExpense(String id, {required String category}) {
    repo.addExpenseFromBill(id, category: category);
    logEvent(_billLog, Level.INFO, 'bill.cashExpense', {'category': _logCategory(category)});
    _changed();
  }

  // ---------- attachments (P16b) ----------

  /// The files attached to a payment (photos and PDFs of a receipt, a warranty, a slip), oldest first. Never in the bill lists.
  List<Bill> attachments(String txId) => _cached(MemoKey('attach', txId), () => repo.attachments(txId));

  /// Attaches [raw] (a photo or PDF, [ext] with or without the dot) to the payment [txId]. Pictures are sized down like a bill's.
  Future<AttachResult> attachFile(String txId, Uint8List raw, String ext) async {
    try {
      final e = ext.toLowerCase().replaceFirst('.', '');
      if (e != 'pdf' && e != 'jpg' && e != 'jpeg' && e != 'png') {
        logEvent(_billLog, Level.INFO, 'attach', {'result': 'badType'});
        return AttachResult.badType;
      }
      if (raw.length > maxBillFileBytes(e)) {
        logEvent(_billLog, Level.INFO, 'attach', {'result': 'tooBig', 'where': 'raw'});
        return AttachResult.tooBig;
      }
      if (key == null) return AttachResult.failed;
      if (attachments(txId).length >= maxAttachmentsPerTx) {
        logEvent(_billLog, Level.INFO, 'attach', {'result': 'full'});
        return AttachResult.full;
      }
      var keep = raw, type = e == 'jpeg' ? 'jpg' : e;
      if (type != 'pdf') {
        final jpeg = await billInputs.pdf.toJpeg(raw);
        if (jpeg != null) {
          keep = jpeg;
          type = 'jpg';
        } else if (billInputs.pdf.supported) {
          // The phone can size pictures and could not read this one: do not keep something that may not open.
          logEvent(_billLog, Level.INFO, 'attach', {'result': 'badType', 'where': 'unreadable'});
          return AttachResult.badType;
        }
      }
      if (keep.length > maxBlobPlainBytes) {
        logEvent(_billLog, Level.INFO, 'attach', {'result': 'tooBig', 'where': 'kept'});
        return AttachResult.tooBig;
      }
      // The sizing above took time: sync may have deleted the payment or filled it meanwhile. Check again before a file is sealed
      // and queued for upload that nothing would reference.
      final tx = repo.transaction(txId);
      if (tx == null || tx.deleted) return AttachResult.failed;
      if (repo.attachments(txId).length >= maxAttachmentsPerTx) {
        logEvent(_billLog, Level.INFO, 'attach', {'result': 'full', 'where': 'late'});
        return AttachResult.full;
      }
      final ref = await _blobStore().add(keep, type);
      try {
        repo.addAttachment(txId, ref);
      } on StateError {
        logEvent(_billLog, Level.INFO, 'attach', {'result': 'full', 'where': 'write'});
        return AttachResult.full;
      }
      logEvent(_billLog, Level.INFO, 'attach', {'result': 'ok', 'type': type, 'bytes': keep.length});
      _changed();
      return AttachResult.ok;
    } on ClockBehindException catch (e) {
      noticeClockBehind(e);
      return AttachResult.failed;
    } catch (err, st) {
      logError(_billLog, 'attach.failed', err, st, fields: {'type': err.runtimeType.toString()});
      return AttachResult.failed;
    }
  }

  /// Removes an attachment from its payment (Undo: [restoreAttachment]).
  void removeAttachment(String id) {
    repo.removeAttachment(id);
    logEvent(_billLog, Level.INFO, 'attach.remove');
    _changed();
  }

  /// Undo of [removeAttachment]; false when the payment already holds the most ([maxAttachmentsPerTx]).
  bool restoreAttachment(String id) {
    try {
      repo.restoreAttachment(id);
    } on StateError {
      logEvent(_billLog, Level.INFO, 'attach.restore', {'result': 'full'});
      return false;
    }
    logEvent(_billLog, Level.INFO, 'attach.restore', {'result': 'ok'});
    _changed();
    return true;
  }

  BlobStore _blobStore() => BlobStore(repo, key!, maxCacheBytes: isWeb ? blobCacheBytesWeb : blobCacheBytesNative);

  /// The original file: from this device, else from the relay. [BillFileState.missing] = it is not here and could not be fetched
  /// (no address, offline, not on the relay yet).
  Future<BillFile> billFile(Bill b) async {
    if (b.blob == null || key == null) return const BillFile(BillFileState.none);
    SyncTransport? transport;
    RelayTransport? own;
    DeviceRelay? device;
    try {
      final url = relayUrl;
      if (url != null) {
        // Signed like every other request of this install (device key, id, api floor): a wallet that requires approval refuses the
        // wallet key alone. The device relay seam gives that transport; without it the plain one (no device features).
        final open = deps.deviceRelayOpener;
        if (open != null) {
          device = await open(url, key!, repo);
          transport = device.transport;
        } else {
          transport = own = WalletController.relayTransport(url, key!, repo);
        }
      }
      final bytes = await _blobStore().read(b.blob!, transport: transport);
      logEvent(_billLog, Level.INFO, 'bill.file', {'found': bytes != null, 'type': b.blobType});
      return bytes == null ? const BillFile(BillFileState.missing) : BillFile(BillFileState.ready, bytes: bytes, type: b.blobType);
    } catch (e, st) {
      logError(_billLog, 'bill.fileFailed', e, st, fields: {'type': e.runtimeType.toString()});
      return const BillFile(BillFileState.missing);
    } finally {
      own?.close();
      device?.close();
    }
  }

  // ---------- reminders ----------

  /// Days before the end of a return window / a warranty that the reminder comes (synced settings; 0 = on the day).
  int get returnReminderDays => settings.returnReminderDays;
  int get warrantyReminderDays => settings.warrantyReminderDays;

  /// Saves both reminder spans; false (nothing saved) when one is outside 0..30 (return) or 0..90 (warranty).
  bool saveBillReminderDays({required int returnDays, required int warrantyDays}) {
    if (returnDays < 0 ||
        returnDays > WalletSettings.maxReturnReminderDays ||
        warrantyDays < 0 ||
        warrantyDays > WalletSettings.maxWarrantyReminderDays) {
      return false;
    }
    updateSettings({'returnReminderDays': returnDays, 'warrantyReminderDays': warrantyDays});
    return true;
  }

  /// Return-window and warranty reminders: 09:00 on (end date − days) for every confirmed bill with such a date still ahead.
  /// The text has no payee, amount or item. Runs inside [rescheduleHeadsUps]'s chain, so it never overlaps another run.
  Future<void> _rescheduleBillRemindersNow() async {
    try {
      if (!headsUpNotify) {
        await nudges.cancelBillReminders();
        return;
      }
      final t = today();
      final items = <(String, bool, int)>[];
      for (final b in billsAll()) {
        if (!b.confirmed) continue;
        if (b.returnBy != null && b.returnBy!.compareTo(t) >= 0) items.add((b.returnBy!, false, settings.returnReminderDays));
        if (b.warrantyUntil != null && b.warrantyUntil!.compareTo(t) >= 0) {
          items.add((b.warrantyUntil!, true, settings.warrantyReminderDays));
        }
      }
      final n = await nudges.scheduleBillReminders(billReminderSlots(_clock(), items));
      logEvent(_billLog, Level.INFO, 'bills.remindersScheduled', {'count': n});
    } catch (e, st) {
      logError(_billLog, 'bills.reminderFailed', e, st);
    }
  }
}
