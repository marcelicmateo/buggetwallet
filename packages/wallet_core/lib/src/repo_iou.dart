part of 'repo.dart';

/// IOUs (Q8, schema 17; see [Iou], [IouPart], [IouView]): money lent to or borrowed from a person and its
/// repayments. Every rule is an [ArgumentError] with an owner-readable message, checked on local writes only (sync
/// never refuses an op; two devices' repayments may overpay, [IouView.outstanding] then shows 0). A payment linked
/// to a live IOU or to a live repayment of one ([iouLinkedTx]) counts as neither spending nor income
/// (`Categorizer.iouTx`). Logs carry counts and enum words only (never the person, note or amounts).
extension WalletRepoIou on WalletRepo {
  static final _currency = RegExp(r'^[A-Z]{3}$');

  static String _checkPerson(String person) {
    final p = person.trim();
    if (p.isEmpty) throw ArgumentError('Say who the money is with.');
    if (p.runes.length > Iou.maxPerson) throw ArgumentError('The name is limited to ${Iou.maxPerson} characters.');
    return p;
  }

  static String? _checkNote(String? note) {
    final n = note?.trim() ?? '';
    if (n.runes.length > Iou.maxNote) throw ArgumentError('The note is limited to ${Iou.maxNote} characters.');
    return n.isEmpty ? null : n;
  }

  static void _checkIouAmount(int cents) {
    if (cents <= 0) throw ArgumentError('Enter an amount above zero.');
    if (cents > WalletSettings.maxAmount) throw ArgumentError('The amount is over the allowed amount.');
  }

  static void _checkIouDate(String date) {
    if (!isIsoDate(date)) throw ArgumentError('Bad date.');
  }

  /// The stored IOU [id] (deleted ones too), or an [ArgumentError].
  Iou _iou(String id) {
    final rs = db.select('SELECT * FROM ious WHERE id = ?', [id]);
    if (rs.isEmpty) throw ArgumentError('No such IOU.');
    return Iou.fromRow(rs.first);
  }

  IouPart _iouPart(String id) {
    final rs = db.select('SELECT * FROM iou_parts WHERE id = ?', [id]);
    if (rs.isEmpty) throw ArgumentError('No such repayment.');
    return IouPart.fromRow(rs.first);
  }

  /// The live repayments of IOU [iouId], oldest first.
  List<IouPart> _liveParts(String iouId) => [
        for (final r in db.select('SELECT * FROM iou_parts WHERE iou_id = ? AND deleted = 0 ORDER BY date, id', [iouId])) IouPart.fromRow(r)
      ];

  /// The payment a link to [txId] stands for, and the ids the link holds: [txId] itself and, for a hand-added entry,
  /// the bank row that replaced it (`matched_to`), which inherits the link ([iouLinkedTx]). The payment is that bank row
  /// once the entry is replaced, else the row itself (null when neither is here).
  (Tx?, Set<String>) _linkRows(String txId) {
    final t = transaction(txId);
    final m = t?.matchedTo;
    final ids = {txId, if (m != null) m};
    if (t != null && m != null && !t.live) return (transaction(m), ids);
    return (t, ids);
  }

  /// Checks that payment [txId] may be linked as [amount] in [currency]: it (or the bank row that replaced it,
  /// [_linkRows]) exists and is live, is no own transfer and has no split, is in [currency], is money out when
  /// [outflow] (else money in) of exactly [amount], and no other live link holds it, directly or through `matched_to`
  /// (the IOU [exceptIou]'s own link / repayment [exceptPart] being edited aside).
  void _checkLink(String txId,
      {required int amount, required String currency, required bool outflow, String? exceptIou, String? exceptPart}) {
    final (t, ids) = _linkRows(txId);
    if (t == null || !t.live) throw ArgumentError('No such payment.');
    final cz = categorizer(withTags: false);
    if (t.transferTo != null || cz.table.kindOf(cz.categoryOf(t)) == BudgetKind.transfer) {
      throw ArgumentError('An own transfer cannot be linked to an IOU.');
    }
    if (splits().containsKey(t.id)) throw ArgumentError('A split payment cannot be linked to an IOU.');
    if (t.currency != currency) throw ArgumentError('The payment is in ${t.currency}, the IOU in $currency.');
    if (outflow && t.amount >= 0) throw ArgumentError('Link a payment that went out.');
    if (!outflow && t.amount <= 0) throw ArgumentError('Link a payment that came in.');
    if (t.amount.abs() != amount) {
      throw ArgumentError('The payment must be exactly this amount. A payment that was only partly a loan cannot be linked: '
          'add it without a payment.');
    }
    _checkFree(ids, exceptIou: exceptIou, exceptPart: exceptPart);
  }

  /// Throws when another live link ([_linked]) holds one of [ids].
  void _checkFree(Set<String> ids, {String? exceptIou, String? exceptPart}) {
    final held = _linked(exceptIou: exceptIou, exceptPart: exceptPart);
    if (ids.any(held.contains)) throw ArgumentError('This payment is already linked to an IOU.');
  }

  /// Adds an IOU and returns its id (`o…`): [person] (1..[Iou.maxPerson] characters after trimming), [direction],
  /// [amount] (cents, above 0, at most [WalletSettings.maxAmount]) in [currency] (three capital letters), on [date]
  /// (`YYYY-MM-DD`), an optional [note] (≤ [Iou.maxNote]) and an optional payment [tx] that was the loan itself (lent:
  /// money out, borrowed: money in, of exactly [amount]; see [_checkLink]).
  String addIou(
      {required String person,
      required IouDirection direction,
      required int amount,
      required String currency,
      required String date,
      String? note,
      String? tx}) {
    final p = _checkPerson(person);
    _checkIouAmount(amount);
    if (!_currency.hasMatch(currency)) throw ArgumentError('Bad currency (three capital letters, like EUR).');
    _checkIouDate(date);
    final n = _checkNote(note);
    if (tx != null) _checkLink(tx, amount: amount, currency: currency, outflow: direction == IouDirection.lent);
    final id = _newId('o');
    _write([
      (
        'iou',
        id,
        {
          'person': p,
          'direction': direction.name,
          'amount': amount,
          'currency': currency,
          'date': date,
          'note': n,
          'tx': tx,
          'closed': 0,
          'deleted': 0
        }
      )
    ]);
    logEvent(_log, Level.INFO, 'iou.add', {'direction': direction.name, 'linked': tx != null});
    return id;
  }

  /// Changes the given fields of live IOU [id]; [clearNote] / [clearTx] remove the note / the linked payment. The
  /// result is checked as in [addIou]; the amount cannot drop below what was paid back, and every linked payment (the
  /// IOU's and its repayments') must still fit the direction and currency. Only changed fields are written. A thin
  /// wrapper over [patch] (F2).
  void updateIou(String id,
          {String? person,
          IouDirection? direction,
          int? amount,
          String? currency,
          String? date,
          String? note,
          String? tx,
          bool clearNote = false,
          bool clearTx = false}) =>
      patch(IouCols.entity, id, {
        if (person != null) IouCols.person: person,
        if (direction != null) IouCols.direction: direction,
        if (amount != null) IouCols.amount: amount,
        if (currency != null) IouCols.currency: currency,
        if (date != null) IouCols.date: date,
        if (clearNote) IouCols.note: clearValue else if (note != null) IouCols.note: note,
        if (clearTx) IouCols.tx: clearValue else if (tx != null) IouCols.tx: tx,
      });

  static const _iouEdited = <Col>{
    IouCols.person,
    IouCols.direction,
    IouCols.amount,
    IouCols.currency,
    IouCols.date,
    IouCols.note,
    IouCols.tx
  };

  /// [patch] of an IOU: [updateIou]'s rules.
  int _patchIou(String id, Map<Col, Object?> v) {
    WalletRepoPatch._needValues(v);
    final old = _iou(id);
    if (old.deleted) throw ArgumentError('No such IOU.');
    final person = v[IouCols.person] as String?, note = v[IouCols.note] as String?;
    final p = person == null ? old.person : _checkPerson(person);
    final d = v[IouCols.direction] as IouDirection? ?? old.direction;
    final a = v[IouCols.amount] as int? ?? old.amount;
    _checkIouAmount(a);
    final c = v[IouCols.currency] as String? ?? old.currency;
    if (!_currency.hasMatch(c)) throw ArgumentError('Bad currency (three capital letters, like EUR).');
    final dt = v[IouCols.date] as String? ?? old.date;
    _checkIouDate(dt);
    final n = v.containsKey(IouCols.note) && note == null ? null : (note == null ? old.note : _checkNote(note));
    final t = v.containsKey(IouCols.tx) ? v[IouCols.tx] as String? : old.tx;
    final parts = _liveParts(id);
    final repaid = parts.fold(0, (s, x) => s + x.amount);
    if (a < repaid) throw ArgumentError('The amount cannot be less than what was already paid back.');
    // An unchanged link is not checked again: its payment may since have been replaced by its bank row, deleted,
    // re-tagged or paired, and the owner must still be able to edit the IOU (clearTx removes such a link).
    final relink = t != old.tx || a != old.amount || c != old.currency || d != old.direction;
    if (t != null && relink) _checkLink(t, amount: a, currency: c, outflow: d == IouDirection.lent, exceptIou: id);
    if (d != old.direction || c != old.currency) {
      for (final x in parts) {
        if (x.tx case final xt?) _checkLink(xt, amount: x.amount, currency: c, outflow: d == IouDirection.borrowed, exceptPart: x.id);
      }
    }
    final fields = <String, Object?>{
      if (p != old.person) 'person': p,
      if (d != old.direction) 'direction': d.name,
      if (a != old.amount) 'amount': a,
      if (c != old.currency) 'currency': c,
      if (dt != old.date) 'date': dt,
      if (n != old.note) 'note': n,
      if (t != old.tx) 'tx': t,
      ..._patchRest(v, _iouEdited),
    };
    if (fields.isEmpty) return 0;
    _write([('iou', id, fields)]);
    logEvent(_log, Level.INFO, 'iou.edit', {'fields': fields.length, 'linked': t != null});
    return fields.length;
  }

  /// Deletes IOU [id] (its repayments stay stored and come back with [undeleteIou]); its links stop counting.
  /// Already deleted: nothing is written. Unknown id: [ArgumentError].
  void deleteIou(String id) {
    if (_iou(id).deleted) return;
    _write([
      ('iou', id, {'deleted': 1})
    ]);
    logEvent(_log, Level.INFO, 'iou.delete');
  }

  /// Undo of [deleteIou]: writes `deleted: 0` (synced; the later write by HLC wins, like `undeleteGoal`). A live IOU:
  /// nothing is written. Unknown id, or a payment of it (or of its repayments) another live IOU took meanwhile
  /// (`matched_to` included): [ArgumentError].
  void undeleteIou(String id) {
    final i = _iou(id);
    if (!i.deleted) return;
    // Its links (and its repayments') may have been taken by another IOU while it was deleted.
    final held = _linked();
    for (final x in [i.tx, for (final p in _liveParts(id)) p.tx]) {
      if (x != null && _linkRows(x).$2.any(held.contains)) throw ArgumentError('A payment of this IOU is now linked to another IOU.');
    }
    _write([
      ('iou', id, {'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'repo.undelete', {'entity': 'iou'});
  }

  /// Marks live IOU [id] settled ([closed]) or open again. A closed IOU keeps its links (they still count as neither
  /// spending nor income) and may close with money still owed (forgiven). Same state: nothing is written.
  void closeIou(String id, {bool closed = true}) {
    final i = _iou(id);
    if (i.deleted) throw ArgumentError('No such IOU.');
    if (i.closed == closed) return;
    _write([
      ('iou', id, {'closed': closed ? 1 : 0})
    ]);
    logEvent(_log, Level.INFO, 'iou.close', {'closed': closed});
  }

  /// Adds a repayment of [amount] (cents, above 0, at most what is still owed) on [date] to live IOU [iouId] and
  /// returns its id (`r…`); [tx] is the payment that repaid it (lent: money in, borrowed: money out, of exactly
  /// [amount]; see [_checkLink]).
  String addIouPart(String iouId, {required int amount, required String date, String? tx}) {
    final i = _iou(iouId);
    if (i.deleted) throw ArgumentError('No such IOU.');
    _checkIouAmount(amount);
    _checkIouDate(date);
    final owed = i.amount - _liveParts(iouId).fold(0, (s, x) => s + x.amount);
    if (amount > owed) throw ArgumentError('That is more than is still owed.');
    if (tx != null) _checkLink(tx, amount: amount, currency: i.currency, outflow: i.direction == IouDirection.borrowed);
    final id = _newId('r');
    _write([
      ('iou_part', id, {'iou_id': iouId, 'amount': amount, 'date': date, 'tx': tx, 'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'iou.part.add', {'linked': tx != null});
    return id;
  }

  /// Deletes repayment [id]. Already deleted: nothing is written. Unknown id: [ArgumentError].
  void deleteIouPart(String id) {
    if (_iouPart(id).deleted) return;
    _write([
      ('iou_part', id, {'deleted': 1})
    ]);
    logEvent(_log, Level.INFO, 'iou.part.delete');
  }

  /// Undo of [deleteIouPart]: writes `deleted: 0`. A live repayment: nothing is written. Unknown id, or one that would
  /// now pay back more than is owed (another repayment was added in between): [ArgumentError].
  void undeleteIouPart(String id) {
    final x = _iouPart(id);
    if (!x.deleted) return;
    final rs = db.select('SELECT amount FROM ious WHERE id = ?', [x.iouId]);
    final owed = rs.isEmpty ? 0 : (rs.first['amount'] as int) - _liveParts(x.iouId).fold(0, (s, p) => s + p.amount);
    if (x.amount > owed) throw ArgumentError('That is more than is still owed.');
    if (x.tx case final xt?) _checkFree(_linkRows(xt).$2, exceptPart: id);
    _write([
      ('iou_part', id, {'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'repo.undelete', {'entity': 'iou_part'});
  }

  /// The live IOUs (closed ones only with [includeClosed]), newest first (date, then id), each with its live
  /// repayments (oldest first) and what is still owed (never below 0). One read of each table.
  List<IouView> ious({bool includeClosed = true}) {
    final parts = <String, List<IouPart>>{};
    for (final r in db.select('SELECT * FROM iou_parts WHERE deleted = 0 ORDER BY date, id')) {
      final p = IouPart.fromRow(r);
      (parts[p.iouId] ??= []).add(p);
    }
    final res = <IouView>[];
    for (final r
        in db.select('SELECT * FROM ious WHERE deleted = 0 ${includeClosed ? '' : 'AND closed = 0 '}ORDER BY date DESC, id DESC')) {
      final i = Iou.fromRow(r);
      final ps = parts[i.id] ?? const <IouPart>[];
      res.add(IouView(i, ps, max(0, i.amount - ps.fold(0, (s, p) => s + p.amount))));
    }
    logEvent(_log, Level.FINER, 'iou.list', {'count': res.length});
    return res;
  }

  /// Ids of the payments linked to a live IOU or to a live repayment of a live IOU, closed ones included, plus the
  /// bank row that replaced a linked hand-added entry (`matched_to`), so the link survives the match.
  Set<String> iouLinkedTx() => _linked();

  /// [iouLinkedTx] without the own link of IOU [exceptIou] and without repayment [exceptPart].
  Set<String> _linked({String? exceptIou, String? exceptPart}) {
    final rs = db.select(
        'WITH l(id) AS ( '
        "SELECT tx FROM ious WHERE deleted = 0 AND tx IS NOT NULL AND tx != '' AND id IS NOT ? "
        'UNION SELECT p.tx FROM iou_parts p JOIN ious i ON i.id = p.iou_id '
        "WHERE p.deleted = 0 AND i.deleted = 0 AND p.tx IS NOT NULL AND p.tx != '' AND p.id IS NOT ?) "
        'SELECT id FROM l UNION SELECT t.matched_to FROM tx t JOIN l ON t.id = l.id WHERE t.matched_to IS NOT NULL',
        [exceptIou, exceptPart]);
    return {for (final r in rs) r['id'] as String};
  }
}
