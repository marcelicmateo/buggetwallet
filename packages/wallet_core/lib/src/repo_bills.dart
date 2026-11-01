part of 'repo.dart';

/// Bills (receipts, slips, e-invoices; `docs/context/BILLS_API.md` §2): import, review, confirm, link to payments.
extension WalletRepoBills on WalletRepo {
  /// Live bills (deleted ones too with [includeDeleted]), newest first: by date (or due date), then id.
  /// A bill in a deleted custom category reads with its automatic one ([Categorizer.resolveStored] on its payee), or
  /// none; the stored row is unchanged ([bill] reads it as stored). Attachments (P16b, [attachments]) only with
  /// [includeAttachments].
  List<Bill> bills({bool includeDeleted = false, bool includeAttachments = false}) => _resolved([
        for (final r in db.select('SELECT * FROM bills WHERE ${includeDeleted ? '1' : 'deleted = 0'}'
            '${includeAttachments ? '' : " AND source != 'attachment'"} '
            "ORDER BY COALESCE(date, due_date, '') DESC, id"))
          r,
      ], (cz, r) => cz.resolveStored(r['category'] as String?, text: '${r['payee'] ?? ''}'), Bill.fromRow);

  /// One bill by id (deleted ones included), or null.
  Bill? bill(String id) {
    final rs = db.select('SELECT * FROM bills WHERE id = ?', [id]);
    return rs.isEmpty ? null : Bill.fromRow(rs.first);
  }

  /// A live bill that is not an attachment (those have their own calls: [addAttachment] …), else [ArgumentError].
  Bill _liveBill(String id) {
    final b = bill(id);
    if (b == null || b.deleted || b.isAttachment) throw ArgumentError('No such bill.');
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
  /// first n >= 1 not used by a live bill (a deleted copy is revived), external id unchanged. KL-A: the copy id holds
  /// this device's id (`<externalId>#<deviceId>-<n>`; never logged), so two devices adding a copy before they sync
  /// make two bills; copies made before KL-A (`<externalId>#<n>`) keep their ids.
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
        id = Bill.idFor('$ext#$deviceId-$n');
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

  /// Changes the given fields only (null = unchanged); the clear flags set those to none: a thin wrapper over [patch]
  /// (F1; the flags go in F2). A bad date, a total ≤ 0 or items past the limits: `ArgumentError('<label>: <reason>')`. A confirmed bill's planned row follows ([_billWrites]). An update of the
  /// due date, total or category that leaves a confirmed, unpaid bill with a total and a due date from today on
  /// without a category: [ArgumentError] (its planned row would reserve money, and only the category tells whether the
  /// payday plan already holds it). Other edits (note, payee, dates of warranty or return …) never throw for it (BILLS_API.md §3).
  /// UX-A: [returnReminderDays] / [warrantyReminderDays] are this bill's own reminder days (0..30 / 0..90, else
  /// [ArgumentError]; the clear flags go back to the wallet setting, [effectiveReturnReminderDays]).
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
      bool clearCategory = false,
      int? returnReminderDays,
      int? warrantyReminderDays,
      bool clearReturnReminderDays = false,
      bool clearWarrantyReminderDays = false}) {
    patch(BillCols.entity, id, {
      if (date != null) BillCols.date: date,
      if (clearDueDate) BillCols.dueDate: clearValue else if (dueDate != null) BillCols.dueDate: dueDate,
      if (total != null) BillCols.total: total,
      if (payee != null) BillCols.payee: payee,
      if (iban != null) BillCols.iban: iban,
      if (reference != null) BillCols.reference: reference,
      if (description != null) BillCols.description: description,
      if (clearCategory) BillCols.category: clearValue else if (category != null) BillCols.category: category,
      if (note != null) BillCols.note: note,
      if (items != null)
        BillCols.items: encodeBillItems(items) ?? (throw ArgumentError('${BillCols.items.label}: Too many items or a name too long.')),
      if (clearWarranty) BillCols.warrantyUntil: clearValue else if (warrantyUntil != null) BillCols.warrantyUntil: warrantyUntil,
      if (clearReturnBy) BillCols.returnBy: clearValue else if (returnBy != null) BillCols.returnBy: returnBy,
      if (clearReturnReminderDays)
        BillCols.returnReminderDays: clearValue
      else if (returnReminderDays != null)
        BillCols.returnReminderDays: returnReminderDays,
      if (clearWarrantyReminderDays)
        BillCols.warrantyReminderDays: clearValue
      else if (warrantyReminderDays != null)
        BillCols.warrantyReminderDays: warrantyReminderDays,
    });
  }

  /// P16b: attaches [file] (a photo or PDF, one of [attachmentTypes]) to payment [txId] and returns the new attachment's id.
  /// An attachment is a bill row with source [BillSource.attachment], `attached_tx` = the payment (`linked_tx` stays
  /// null, so builds before P16b never take it for the bill that paid the row), `total` = |amount|, the payment's date
  /// and currency, confirmed ([Bill.paid] is true for it), in one [_write] (its file is uploaded before the op like a bill's,
  /// declared by snapshots and carried by backups). It is listed only by [attachments]: never by [bills], matching,
  /// candidates, planned rows, search or reminders. An unknown or deleted payment, or a file type outside [attachmentTypes]:
  /// [ArgumentError]; a payment that already holds [maxAttachmentsPerTx] live attachments: [StateError].
  String addAttachment(String txId, BlobRef file) {
    if (!attachmentTypes.contains(file.type) || !isBlobHash(file.hash)) throw ArgumentError('Unknown file type.');
    final t = transaction(txId);
    if (t == null || t.deleted) throw ArgumentError('No such transaction.');
    if (_attachmentCount(txId) >= maxAttachmentsPerTx) throw StateError('A payment holds at most $maxAttachmentsPerTx attachments.');
    final id = _newId('b');
    _write([
      (
        'bill',
        id,
        {
          'source': BillSource.attachment.name,
          'status': BillStatus.confirmed.name,
          'date': t.date,
          'total': t.amount.abs(),
          'currency': t.currency,
          'attached_tx': txId,
          'blob': file.hash,
          'blob_type': file.type,
          'blob_bytes': file.bytes,
          'deleted': 0,
        }
      )
    ]);
    logEvent(_log, Level.INFO, 'bills.attach', {'type': file.type});
    return id;
  }

  /// The live attachments of payment [txId], oldest first (by the clock that created them, then id: the same order
  /// on every device; a restore keeps the place).
  List<Bill> attachments(String txId) {
    final rs = db.select('''
      SELECT b.*, c.hlc AS made_clock FROM bills b LEFT JOIN clocks c ON c.entity = 'bill' AND c.id = b.id AND c.field = 'source'
      WHERE b.deleted = 0 AND b.source = 'attachment' AND b.attached_tx = ?''', [txId]);
    final list = [for (final r in rs) (r['made_clock'] as String? ?? '', Bill.fromRow(r))];
    list.sort((x, y) {
      final c = x.$1.isEmpty || y.$1.isEmpty ? x.$1.compareTo(y.$1) : Hlc.compareStrings(x.$1, y.$1);
      return c != 0 ? c : x.$2.id.compareTo(y.$2.id);
    });
    return [for (final (_, b) in list) b];
  }

  /// P16b: a hand-added entry that matching replaced with its bank row ([planMatches]: `matched_to` = a live bank row
  /// here, not an own transfer) hands its live attachments to that row (`attached_tx` through [_write]; the cap is not
  /// checked: nothing is ever dropped). Rule: they stay on the bank row from then on; a reopened match (bank row
  /// deleted or paired) does not move them back, and an undelete of the row shows them there again. The same rows give
  /// the same writes on every device. Runs in [_reconcile] after matching (caught up only).
  void _moveMatchedAttachments() {
    final moves = [
      for (final r in db.select('''
        SELECT b.id AS id, e.matched_to AS bank FROM bills b JOIN tx e ON e.id = b.attached_tx JOIN tx k ON k.id = e.matched_to
        WHERE b.deleted = 0 AND b.source = 'attachment' AND e.manual = 1 AND e.deleted = 0
          AND k.manual = 0 AND k.deleted = 0 AND k.transfer_to IS NULL ORDER BY b.id'''))
        ('bill', r['id'] as String, <String, Object?>{'attached_tx': r['bank']}),
    ];
    if (moves.isEmpty) return;
    _write(moves);
    logEvent(_log, Level.INFO, 'bills.attachMoved', {'attachments': moves.length});
  }

  /// Q7: the ids of the payments that hold a live attachment (`attached_tx` of live `source: attachment` bills), for
  /// `searchAll(attachedTx:)`. Read-only.
  Set<String> attachedTxIds() => {
        for (final r in db
            .select("SELECT DISTINCT attached_tx AS t FROM bills WHERE deleted = 0 AND source = 'attachment' AND attached_tx IS NOT NULL"))
          r['t'] as String,
      };

  int _attachmentCount(String txId) =>
      db.select("SELECT COUNT(*) AS n FROM bills WHERE deleted = 0 AND source = 'attachment' AND attached_tx = ?", [txId]).first['n']
          as int;

  Bill _attachment(String id) {
    final b = bill(id);
    if (b == null || !b.isAttachment) throw ArgumentError('No such attachment.');
    return b;
  }

  /// Removes attachment [id] (soft delete, so [restoreAttachment] can undo it; the file stays cached and on the relay
  /// like a deleted bill's, P14). Unknown id or not an attachment: [ArgumentError]; already removed: nothing written.
  void removeAttachment(String id) {
    if (_attachment(id).deleted) return;
    _write([
      ('bill', id, {'deleted': 1})
    ]);
    logEvent(_log, Level.INFO, 'bills.detach');
  }

  /// Brings removed attachment [id] back on its payment (Undo). Unknown id or not an attachment: [ArgumentError];
  /// live already: nothing written; its payment already holds [maxAttachmentsPerTx] live attachments: [StateError].
  void restoreAttachment(String id) {
    final b = _attachment(id);
    if (!b.deleted) return;
    if (b.attachedTx != null && _attachmentCount(b.attachedTx!) >= maxAttachmentsPerTx) {
      throw StateError('A payment holds at most $maxAttachmentsPerTx attachments.');
    }
    _write([
      ('bill', id, {'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'bills.reattach');
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
    if (db
        .select("SELECT 1 FROM bills WHERE deleted = 0 AND source != 'attachment' AND linked_tx = ? AND id != ?", [txId, id]).isNotEmpty) {
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
    final reserves = !n.deleted && !n.isAttachment && n.confirmed && !n.paid && _okTotal(n.total) && _okDate(n.dueDate);
    if (needCategory && reserves && n.dueDate!.compareTo(today) >= 0 && (n.category == null || n.category!.trim().isEmpty)) {
      throw ArgumentError('The bill needs a category.');
    }
    final pid = WalletRepo.billPlannedId(b.id);
    final rs = db.select('SELECT * FROM planned WHERE id = ?', [pid]);
    final p = rs.isEmpty ? null : PlannedCost.fromRow(rs.first);
    Map<String, Object?> want;
    if (n.deleted || n.isAttachment || !n.confirmed || !_okTotal(n.total) || !_okDate(n.dueDate)) {
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
      WHERE b.deleted = 0 AND b.source != 'attachment' AND b.linked_tx IN (SELECT linked_tx FROM bills
        WHERE deleted = 0 AND source != 'attachment' AND linked_tx IS NOT NULL GROUP BY linked_tx HAVING COUNT(*) > 1)''');
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
    // Attachments stay on their payment (an undelete of the row shows them again).
    final gone = [
      for (final r in db.select(
          "SELECT b.* FROM bills b JOIN tx t ON t.id = b.linked_tx WHERE b.deleted = 0 AND b.source != 'attachment' AND t.deleted = 1"))
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
      for (final r in db.select(
          "SELECT * FROM bills WHERE deleted = 0 AND source != 'attachment' AND status = 'confirmed' AND linked_tx IS NULL AND total > 0"))
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
      for (final r in db.select("SELECT * FROM bills WHERE deleted = 0 AND source != 'attachment' AND linked_tx IS NOT NULL"))
        Bill.fromRow(r),
    ];
    final plan = planBillLinks([...open, ...linked], rows);
    final today = _today();
    final byId = {for (final b in open) b.id: b};
    _write([
      for (final e in plan.entries) ..._billWrites(byId[e.key]!, {'linked_tx': e.value}, today),
    ]);
    t.done({'bills': open.length, 'rows': rows.length, 'linked': plan.length});
  }

  // ---------- payee aliases (KL-A) ----------

  /// The live payee aliases: a slip's payee key ([billPayeeKey] without aliases) → the recurring bill payee key it
  /// stands for. Pass it as `payeeAliases` to [billPayeeKey], [billCoveredBy], [plannedCoverage], `computePeriod`,
  /// `periodDays`, `upcoming`, `plannedIcs`, `billHistory`, `suggestBillCategory` and `forecastToPayday`. Rows that
  /// would map a key to itself or to '' are left out; a chain two devices made at once is read one step only.
  Map<String, String> payeeAliases() => {
        for (final r in db.select("SELECT alias, payee FROM payee_aliases WHERE deleted = 0 AND alias != '' AND payee != ''"))
          if (r['alias'] case final String a when a != r['payee']) a: r['payee'] as String,
      };

  /// Reads slip payee key [aliasKey] as recurring bill payee key [payeeKey] from now on (exactly; no similar-name
  /// guessing), on every device (synced row [payeeAliasId]). [ArgumentError]: an empty key, the two equal, or a chain
  /// (one step only: [payeeKey] is itself an alias, or [aliasKey] is already what another alias maps to).
  void setPayeeAlias(String aliasKey, String payeeKey) {
    final a = aliasKey.trim(), p = payeeKey.trim();
    if (a.isEmpty || p.isEmpty) throw ArgumentError('Empty payee key.');
    if (a == p) throw ArgumentError('An alias cannot map a payee to itself.');
    final have = payeeAliases();
    if (have.containsKey(p) || have.values.contains(a)) throw ArgumentError('Payee aliases are one step only.');
    if (have[a] == p) return;
    _write([
      ('payee_alias', payeeAliasId(a), {'alias': a, 'payee': p, 'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'bills.alias.set', {'replaced': have.containsKey(a)});
  }

  /// Forgets the alias of [aliasKey] (the row stays, deleted). No alias: nothing happens.
  void removePayeeAlias(String aliasKey) {
    final a = aliasKey.trim();
    if (a.isEmpty || !payeeAliases().containsKey(a)) return;
    _write([
      ('payee_alias', payeeAliasId(a), {'deleted': 1})
    ]);
    logEvent(_log, Level.INFO, 'bills.alias.remove');
  }

  /// "Belongs to bill…" on a slip: the slip's payee key ([billPayeeKey] of bill [billId], without aliases) becomes an
  /// alias of recurring bill [recurringId]'s payee ([setPayeeAlias]), so its coverage, history and category follow that
  /// bill; then bills are linked to payments again ([planBillLinks]: at once while [syncCaughtUp], else at the next
  /// caught-up sync). A slip whose key already is that payee only loses an alias it had. [ArgumentError]: an unknown or
  /// deleted bill, an attachment, a bill without a payee key, an unknown recurring bill, an income or one without a
  /// payee, and the chain rules of [setPayeeAlias].
  void linkSlipToBill(String billId, String recurringId) {
    final b = _liveBill(billId);
    if (b.isAttachment) throw ArgumentError('An attachment belongs to its payment.');
    final key = billPayeeKey(b);
    if (key == null) throw ArgumentError('The bill has no payee.');
    final r = recurringBills(includeDismissed: true).where((x) => x.id == recurringId).firstOrNull;
    if (r == null || r.isIncome || r.payee.isEmpty) throw ArgumentError('No such recurring bill.');
    if (key == r.payee) {
      removePayeeAlias(key);
    } else {
      setPayeeAlias(key, r.payee);
    }
    if (syncCaughtUp) {
      _autoLinkBills();
    } else {
      _setMeta('match_pending', '1');
    }
    logEvent(_log, Level.INFO, 'bills.linkSlip', {'alias': key != r.payee});
  }
}
