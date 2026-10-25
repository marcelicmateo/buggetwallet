part of 'repo.dart';

/// Bills (receipts, slips, e-invoices; `docs/context/BILLS_API.md` §2): import, review, confirm, link to payments.
extension WalletRepoBills on WalletRepo {
  /// Live bills (deleted ones too with [includeDeleted]), newest first: by date (or due date), then id.
  /// A bill in a deleted custom category reads with its automatic one ([Categorizer.resolveStored] on its payee), or
  /// none; the stored row is unchanged ([bill] reads it as stored).
  List<Bill> bills({bool includeDeleted = false}) => _resolved([
        for (final r in db.select('SELECT * FROM bills ${includeDeleted ? '' : 'WHERE deleted = 0'} '
            "ORDER BY COALESCE(date, due_date, '') DESC, id"))
          r,
      ], (cz, r) => cz.resolveStored(r['category'] as String?, text: '${r['payee'] ?? ''}'), Bill.fromRow);

  /// One bill by id (deleted ones included), or null.
  Bill? bill(String id) {
    final rs = db.select('SELECT * FROM bills WHERE id = ?', [id]);
    return rs.isEmpty ? null : Bill.fromRow(rs.first);
  }

  Bill _liveBill(String id) {
    final b = bill(id);
    if (b == null || b.deleted) throw ArgumentError('No such bill.');
    return b;
  }

  static bool _okDate(String? d) => d != null && isIsoDate(d);
  static bool _okTotal(int? t) => t != null && t > 0 && t <= WalletSettings.maxAmount;

  /// Adds a bill read from a code, file or photo as status review and returns (id, isNew). With an external id the id
  /// is [Bill.idFor] it, so the same bill read on two devices is one row. A bill already here (same external id) keeps
  /// what it has: a bill in review gets only its empty fields filled, a confirmed one only its file (when it had none)
  /// and its items (when empty); its money fields never change. A deleted one is brought back as a new review bill
  /// with the values read now (isNew true). Values a reader got wrong are left out, never thrown: a date that is not a
  /// real `YYYY-MM-DD`, a total ≤ 0, items past the limits (cut to [maxBillItems], names to [maxBillItemName]). A
  /// [file] the bill does not take is dropped again (never uploaded, or deleted on the relay). A [file] type outside
  /// [blobTypes]: [ArgumentError].
  ///
  /// [asNew] (the owner said "this is a new bill", e.g. next month's slip that reads exactly like this one): stored as
  /// a separate bill even though a live bill has the same external id: id [Bill.idFor] of `<externalId>#<n>` with the
  /// first n >= 1 not used by a live bill (a deleted copy is revived), external id unchanged. Two devices adding a copy
  /// before they sync pick the same n, so their copies become one bill (the later import's read fields win).
  (String, bool) importBill(NormalizedBill b, {BlobRef? file, bool asNew = false}) {
    if (file != null && !blobTypes.contains(file.type)) throw ArgumentError('Unknown file type.');
    String? text(String? s) => s == null || s.trim().isEmpty ? null : s.trim();
    final items = [
      for (final i in b.items.take(maxBillItems))
        BillItem(
            name: i.name.length > maxBillItemName ? i.name.substring(0, maxBillItemName) : i.name, quantity: i.quantity, amount: i.amount)
    ];
    final read = <String, Object?>{
      'source': b.source.name,
      'external_id': text(b.externalId),
      'date': _okDate(b.date) ? b.date : null,
      'due_date': _okDate(b.dueDate) ? b.dueDate : null,
      'payee': text(b.payee),
      'iban': text(b.iban),
      'reference': text(b.reference),
      'description': text(b.description),
      'total': _okTotal(b.total) ? b.total : null,
      'currency': RegExp(r'^[A-Z]{3}$').hasMatch(b.currency) ? b.currency : 'EUR',
      'items': encodeBillItems(items),
      'unsure': b.unsure < 0 ? 0 : b.unsure,
      if (file != null) ...{'blob': file.hash, 'blob_type': file.type, 'blob_bytes': file.bytes},
    };
    final ext = read['external_id'] as String?;
    var id = ext != null ? Bill.idFor(ext) : _newId('b');
    var old = ext != null ? bill(id) : null;
    if (asNew && old != null && !old.deleted) {
      for (var n = 1; old != null && !old.deleted; n++) {
        id = Bill.idFor('$ext#$n');
        old = bill(id);
      }
    }
    final String event;
    var isNew = true, fileUsed = file != null;
    if (old == null) {
      // No status or deleted here: a late import on another device must never undo a confirm or delete made elsewhere
      // (the column defaults are review and live).
      _write([
        (
          'bill',
          id,
          {
            for (final e in read.entries)
              if (e.value != null) e.key: e.value
          }
        )
      ]);
      event = 'bills.import';
    } else if (old.deleted) {
      _write([
        (
          'bill',
          id,
          {
            for (final c in entitySchema['bill']!.columns) c.name: null,
            ...read,
            'items': read['items'] ?? '[]',
            'status': BillStatus.review.name,
            'deleted': 0,
          }
        )
      ]);
      event = 'bills.revive';
    } else {
      isNew = false;
      final row = db.select('SELECT * FROM bills WHERE id = ?', [id]).first;
      bool empty(String k) => row[k] == null || row[k] == '' || (k == 'items' && (decodeBillItems(row[k]) ?? const []).isEmpty);
      const never = {'source', 'currency', 'unsure', 'external_id'};
      final allowed = old.confirmed ? const {'items', 'blob', 'blob_type', 'blob_bytes'} : read.keys.toSet();
      final fill = <String, Object?>{
        for (final e in read.entries)
          if (allowed.contains(e.key) && !never.contains(e.key) && e.value != null && empty(e.key)) e.key: e.value,
      };
      if (row['blob'] != null) fill.removeWhere((k, _) => k.startsWith('blob'));
      fileUsed = fill.containsKey('blob');
      _write([if (fill.isNotEmpty) ('bill', id, fill)]);
      event = 'bills.reimport';
    }
    if (file != null && !fileUsed) _forgetUnusedBlob(file.hash);
    logEvent(_log, Level.INFO, event, {'source': b.source.name, 'file': fileUsed, 'items': items.length, if (asNew) 'asNew': true});
    return (id, isNew);
  }

  /// Changes the given fields only (null = unchanged); the clear flags set those to none. A bad date, a total ≤ 0 or
  /// items past the limits: [ArgumentError]. A confirmed bill's planned row follows ([_billWrites]). An update of the
  /// due date, total or category that leaves a confirmed, unpaid bill with a total and a due date from today on
  /// without a category: [ArgumentError] (its planned row would reserve money, and only the category tells whether the
  /// payday plan already holds it). Other edits (note, payee, dates of warranty or return …) never throw for it (BILLS_API.md §3).
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
    for (final d in [date, dueDate, warrantyUntil, returnBy]) {
      if (d != null && !_okDate(d)) throw ArgumentError('Bad date.');
    }
    if (total != null && !_okTotal(total)) throw ArgumentError('Bad amount.');
    final itemsText = items == null ? null : encodeBillItems(items);
    if (items != null && itemsText == null) throw ArgumentError('Too many items or a name too long.');
    final b = _liveBill(id);
    final fields = <String, Object?>{
      if (date != null) 'date': date,
      if (clearDueDate) 'due_date': null else if (dueDate != null) 'due_date': dueDate,
      if (total != null) 'total': total,
      if (payee != null) 'payee': payee,
      if (iban != null) 'iban': iban,
      if (reference != null) 'reference': reference,
      if (description != null) 'description': description,
      if (clearCategory) 'category': null else if (category != null) 'category': category,
      if (note != null) 'note': note,
      if (itemsText != null) 'items': itemsText,
      if (clearWarranty) 'warranty_until': null else if (warrantyUntil != null) 'warranty_until': warrantyUntil,
      if (clearReturnBy) 'return_by': null else if (returnBy != null) 'return_by': returnBy,
    };
    if (fields.isEmpty) return;
    // Only an edit that changes the reserve (due date, total, category) is held to the category rule; a note,
    // payee or warranty edit on a bill without one (confirmed before categories were asked for, or reopened) still saves: such a bill's
    // planned row is listed, not reserved ([PlannedCost.needsCategory]), so nothing counts twice either way.
    _write(_billWrites(b, fields, _today(), needCategory: fields.keys.any(_billReserveFields.contains)));
    logEvent(_log, Level.INFO, 'bills.update', {'fields': fields.length});
  }

  /// The owner checked the bill: review → confirmed. Needs a date and a total > 0, else [ArgumentError]. A due date
  /// from today on gives it a planned row (reserved until paid), so an unpaid bill due from today on also needs a
  /// category (set it with [updateBill] first; [suggestBillCategory] offers one), else [ArgumentError]: a slip in a
  /// fixed category (Bills & subscriptions …) is already in the payday plan and must not be reserved again
  /// ([PlannedCost.coveredByPlan]); one a confirmed recurring bill already plans is not reserved either
  /// ([plannedCoveredBy], read time). A matching bank row may now link it ([planBillLinks]): at once while [syncCaughtUp], else at the next
  /// caught-up sync.
  void confirmBill(String id) {
    final b = _liveBill(id);
    if (!_okDate(b.date)) throw ArgumentError('The bill needs a date.');
    if (!_okTotal(b.total)) throw ArgumentError('The bill needs a total.');
    _write(_billWrites(b, {if (!b.confirmed) 'status': BillStatus.confirmed.name}, _today(), needCategory: true));
    logEvent(_log, Level.INFO, 'bills.confirm', {'source': b.source.name});
    if (syncCaughtUp) {
      _autoLinkBills();
    } else {
      _setMeta('match_pending', '1');
    }
  }

  /// The owner picked [txId] as the bill's payment. A transaction already linked to another bill, an unknown or
  /// deleted transaction or bill: [ArgumentError]. The paying row's category never changes.
  void linkBill(String id, String txId) {
    final b = _liveBill(id);
    final t = transaction(txId);
    if (t == null || t.deleted) throw ArgumentError('No such transaction.');
    if (db.select('SELECT 1 FROM bills WHERE deleted = 0 AND linked_tx = ? AND id != ?', [txId, id]).isNotEmpty) {
      throw ArgumentError('That payment belongs to another bill.');
    }
    _write(_billWrites(b, {'linked_tx': txId}, _today()));
    logEvent(_log, Level.INFO, 'bills.link', {'auto': false});
  }

  /// Not paid by that transaction after all: unpaid again (its planned row reopens). Unknown bill: [ArgumentError].
  void unlinkBill(String id) {
    final b = _liveBill(id);
    if (!b.paid) return;
    _write(_billWrites(b, {'linked_tx': null}, _today()));
    logEvent(_log, Level.INFO, 'bills.unlink');
  }

  /// Deletes the bill (the row stays, deleted; the same code read again brings it back as new) and its planned row;
  /// its file stays in this device's cache until evicted and is never deleted on the relay (P14: the relay's GC drops
  /// it once no kept snapshot declares it), so an undelete finds it again. Unknown bill: [ArgumentError].
  void deleteBill(String id) {
    final b = _liveBill(id);
    _write(_billWrites(b, {'deleted': 1}, _today()));
    logEvent(_log, Level.INFO, 'bills.delete', {'file': b.blob != null});
  }

  /// A cash receipt: one write holds the hand-added expense (−total on the bill's date, [category], payee as
  /// description, `seen_bank` like [addTransaction]), the link, the confirm when the bill was in review (adding it as
  /// money is the owner's check) and [category] on the bill when it has none (BILLS_API.md §3). No date or total, or already paid: [ArgumentError]. Returns the expense's id.
  String addExpenseFromBill(String id, {required String category}) {
    final b = _liveBill(id);
    if (!_okDate(b.date)) throw ArgumentError('The bill needs a date.');
    if (!_okTotal(b.total)) throw ArgumentError('The bill needs a total.');
    if (b.paid) throw ArgumentError('The bill is already paid.');
    final txId = _newId('m');
    _write([
      (
        'tx',
        txId,
        {
          'source': 'manual',
          'date': b.date,
          'amount': -b.total!,
          'currency': b.currency,
          'description': b.payee ?? '',
          'category': category,
          'note': '',
          'manual': 1,
          'deleted': 0,
          'seen_bank': _seenBank(),
        }
      ),
      // The bill takes the expense's category when it has none, so a later delete of the expense reopens a
      // categorized row (reserved, or covered by the plan) instead of one that reserves with no category.
      ..._billWrites(
          b,
          {
            'linked_tx': txId,
            if (!b.confirmed) 'status': BillStatus.confirmed.name,
            if (b.category == null || b.category!.trim().isEmpty) 'category': category,
          },
          _today()),
    ]);
    logEvent(_log, Level.INFO, 'bills.cashExpense');
    return txId;
  }

  /// The bill fields that change what its planned row reserves; an [updateBill] touching one is held to the category rule.
  static const _billReserveFields = {'due_date', 'total', 'category'};

  /// The writes for [fields] on bill [b], plus what keeps its planned row in step: a confirmed, unpaid, live bill with
  /// a total and a due date has one open row (created only while the due date is today or later; an existing row
  /// follows edits); a paid bill's row is marked paid with the payment; a deleted bill's row, or one whose due date or
  /// total is gone, is deleted. Nothing is written for a row already as it should be. With [needCategory] (owner
  /// edits): a bill that would reserve (confirmed, unpaid, total, due date from [today] on) without a category is an
  /// [ArgumentError].
  List<(String, String, Map<String, Object?>)> _billWrites(Bill b, Map<String, Object?> fields, String today, {bool needCategory = false}) {
    final n = Bill.fromRow({
      ...db.select('SELECT * FROM bills WHERE id = ?', [b.id]).first,
      ...fields
    });
    final reserves = !n.deleted && n.confirmed && !n.paid && _okTotal(n.total) && _okDate(n.dueDate);
    if (needCategory && reserves && n.dueDate!.compareTo(today) >= 0 && (n.category == null || n.category!.trim().isEmpty)) {
      throw ArgumentError('The bill needs a category.');
    }
    final pid = WalletRepo.billPlannedId(b.id);
    final rs = db.select('SELECT * FROM planned WHERE id = ?', [pid]);
    final p = rs.isEmpty ? null : PlannedCost.fromRow(rs.first);
    Map<String, Object?> want;
    if (n.deleted || !n.confirmed || !_okTotal(n.total) || !_okDate(n.dueDate)) {
      want = p == null || p.deleted ? const {} : {'deleted': 1};
    } else if (n.paid) {
      want = p == null || p.deleted ? const {} : {'status': PlannedStatus.paid.name, 'paid_tx': n.linkedTx};
    } else if ((p == null || p.deleted) && n.dueDate!.compareTo(today) < 0) {
      want = const {};
    } else {
      want = {
        'title': n.title,
        'date': n.dueDate,
        'amount': n.total,
        'category': n.category,
        'source': PlannedSource.bill.name,
        'source_ref': n.id,
        'status': PlannedStatus.open.name,
        'paid_tx': null,
        'deleted': 0,
      };
    }
    if (rs.isNotEmpty && want.isNotEmpty) {
      final cur = rs.first;
      // `status` and `paid_tx` mean something only together (H9): when one changes both are written, so another
      // device's edit of one of them cannot leave a paid row without its payment or an open row with one.
      final pair = cur['status'] != want['status'] || cur['paid_tx'] != want['paid_tx'];
      want = {
        for (final e in want.entries)
          if (cur[e.key] != e.value || (pair && (e.key == 'status' || e.key == 'paid_tx'))) e.key: e.value
      };
    }
    return [
      if (fields.isNotEmpty) ('bill', b.id, fields),
      if (want.isNotEmpty) ('planned', pid, want),
    ];
  }

  /// H9: fields that only mean something together, which per-field last-writer-wins can split when two devices edit
  /// them apart (a Paid on one, a Skip on the other): a live planned cost keeps `paid_tx` only while `status` is paid,
  /// a payment row pays at most one live bill (the link made first by its `linked_tx` clock stays, then the smallest id;
  /// the others are unlinked through [_billWrites], so their planned rows reopen and [_autoLinkBills] may link them to
  /// another row), and a bill's planned row `bill:<id>` is as [_billWrites] wants it for the bill as it is now (paid
  /// with its payment, open, or deleted). Deterministic, so caught-up devices write the same values. Runs in
  /// [_reconcile].
  void _repairFieldPairs() {
    final stalePaid = [
      for (final r
          in db.select("SELECT id FROM planned WHERE deleted = 0 AND paid_tx IS NOT NULL AND (status IS NULL OR status != 'paid')"))
        r['id'] as String
    ];
    final dupes = db.select('''
      SELECT b.*, c.hlc AS link_clock FROM bills b LEFT JOIN clocks c ON c.entity = 'bill' AND c.id = b.id AND c.field = 'linked_tx'
      WHERE b.deleted = 0 AND b.linked_tx IN (SELECT linked_tx FROM bills WHERE deleted = 0 AND linked_tx IS NOT NULL
        GROUP BY linked_tx HAVING COUNT(*) > 1)''');
    final byTx = <String, List<(String, Bill)>>{};
    for (final r in dupes) {
      final b = Bill.fromRow(r);
      (byTx[b.linkedTx!] ??= []).add((r['link_clock'] as String? ?? '', b));
    }
    final unlink = <Bill>[];
    for (final list in byTx.values) {
      list.sort((x, y) {
        final c = x.$1.isEmpty || y.$1.isEmpty ? x.$1.compareTo(y.$1) : Hlc.compareStrings(x.$1, y.$1);
        return c != 0 ? c : x.$2.id.compareTo(y.$2.id);
      });
      unlink.addAll([for (final (_, b) in list.skip(1)) b]);
    }
    final today = _today();
    final unlinked = {for (final b in unlink) b.id};
    final follow = [
      for (final r in db.select('SELECT * FROM bills ORDER BY id'))
        if (!unlinked.contains(r['id'])) ..._billWrites(Bill.fromRow(r), const {}, today),
    ];
    final stale = {for (final (_, id, _) in follow) id};
    final writes = [
      for (final id in stalePaid)
        if (!stale.contains(id)) ('planned', id, <String, Object?>{'paid_tx': null}),
      ...follow,
      for (final b in unlink) ..._billWrites(b, {'linked_tx': null}, today),
    ];
    if (writes.isEmpty) return;
    _write(writes);
    logEvent(
        _log, Level.INFO, 'repo.repairPairs', {'plannedPaidTx': stalePaid.length, 'billLinks': unlink.length, 'billRows': follow.length});
  }

  /// Links confirmed bills to their payments ([planBillLinks]) and closes their planned rows. Runs in [_reconcile]
  /// (only while caught up) and after a confirm. Logged as `bills.autoLink` on `bw.perf` with counts.
  void _autoLinkBills() {
    // A payment deleted on any device: its bill is unpaid again here too (planned row reopened if still due). The
    // deleting device did it at once (deleteTransaction); every other device does it on its next caught-up run.
    final gone = [
      for (final r in db.select('SELECT b.* FROM bills b JOIN tx t ON t.id = b.linked_tx WHERE b.deleted = 0 AND t.deleted = 1'))
        Bill.fromRow(r)
    ];
    if (gone.isNotEmpty) {
      final today = _today();
      _write([
        for (final b in gone) ..._billWrites(b, {'linked_tx': null}, today)
      ]);
      logEvent(_log, Level.INFO, 'bills.unlinkDeleted', {'bills': gone.length});
    }
    final open = [
      for (final r in db.select("SELECT * FROM bills WHERE deleted = 0 AND status = 'confirmed' AND linked_tx IS NULL AND total > 0"))
        Bill.fromRow(r)
    ];
    if (open.isEmpty) return;
    final t = PerfTimer('bills.autoLink');
    final totals = {for (final b in open) -b.total!}.toList();
    final rows = [
      for (final r in db.select(
          'SELECT * FROM tx WHERE manual = 0 AND deleted = 0 AND amount IN (${List.filled(totals.length, '?').join(',')})', totals))
        Tx.fromRow(r)
    ];
    final linked = [
      for (final r in db.select('SELECT * FROM bills WHERE deleted = 0 AND linked_tx IS NOT NULL')) Bill.fromRow(r),
    ];
    final plan = planBillLinks([...open, ...linked], rows);
    final today = _today();
    final byId = {for (final b in open) b.id: b};
    _write([
      for (final e in plan.entries) ..._billWrites(byId[e.key]!, {'linked_tx': e.value}, today),
    ]);
    t.done({'bills': open.length, 'rows': rows.length, 'linked': plan.length});
  }
}
