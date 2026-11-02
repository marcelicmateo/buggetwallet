part of 'repo.dart';

/// One generic write for "set these properties" (FIELDS_PLAN F1): `repo.patch(BillCols.entity, id, {BillCols.returnBy:
/// '2027-05-01', BillCols.note: clearValue})`. Business actions (confirm, link, delete …) keep their own methods.
extension WalletRepoPatch on WalletRepo {
  /// Sets the given columns of row [id] of [entity] (the op entity name, e.g. `bill`) in one owner write: one op with
  /// those fields, one clock (as every edit method writes). Every value is checked first: its Dart type ([Col.accepts]),
  /// then [Col.problem]; a bad one is an `ArgumentError('<label>: <reason>')` and nothing is written. [clearValue] or
  /// null sets a nullable column to none; a non-nullable one refuses both. The keys' order is the op's field order.
  ///
  /// Entity rules run as well: a bill must be live and not an attachment (`No such bill.`); its planned row follows and
  /// an edit of its due date, total or category is held to the category rule ([updateBill]); status, links, file,
  /// source, currency, unsure count and `deleted` change through their own actions only; a confirmed bill keeps its
  /// total and date (clearing one: `<label>: needed on a confirmed bill.`). An account is checked like
  /// [updateAccount] (name, kind, source, institution, uniqueness; opening and opening date written as a pair; only
  /// changed fields are written; its currency never changes). Another entity's row must exist (`No such row.`).
  /// Logs the entity and the field count only.
  void patch(String entity, String id, Map<Col, Object?> values) {
    final def = entitySchema[entity];
    if (def == null) throw ArgumentError('Unknown entity.');
    if (_actionEntities.contains(entity)) throw ArgumentError('Changed by its own actions, not edited.');
    final checked = <Col, Object?>{};
    for (final e in values.entries) {
      final c = e.key;
      if (c.entity != entity || !identical(def.column(c.name), c)) throw ArgumentError('${c.label}: not a field of this $entity.');
      final v = identical(e.value, clearValue) ? null : e.value;
      if (!c.accepts(v)) throw ArgumentError('${c.label}: wrong kind of value.');
      checked[c] = v;
    }
    final locked = _actionFields[entity] ?? const {};
    for (final c in checked.keys) {
      if (locked.contains(c.name)) throw ArgumentError('${c.label}: changed by its own action, not edited.');
    }
    final int written;
    switch (entity) {
      case BillCols.entity:
        written = _patchBill(id, checked);
      case AccountCols.entity:
        written = _patchAccount(id, checked);
      case IouCols.entity:
        written = _patchIou(id, checked);
      case PlannedCols.entity:
        written = _patchPlanned(id, checked);
      case RecurringCols.entity:
        written = _patchRecurring(id, checked);
      case CategoryCols.entity:
        written = _patchCategory(id, checked);
      case TagCols.entity:
        written = _patchTag(id, checked);
      default:
        final fields = _patchFields(checked);
        final live = def.columnNames.contains('deleted') ? ' AND deleted = 0' : '';
        if (db.select('SELECT 1 FROM ${def.table} WHERE id = ?$live', [id]).isEmpty) throw ArgumentError('No such row.');
        if (fields.isNotEmpty) _write([(entity, id, fields)]);
        written = fields.length;
    }
    logEvent(_log, Level.FINE, 'repo.patch', {'entity': entity, 'fields': written});
  }

  /// [values] checked by their columns' [Col.problem] (an `ArgumentError('<label>: <reason>')` for the first bad one),
  /// as stored values by column name, in the same order.
  Map<String, Object?> _patchFields(Map<Col, Object?> values) {
    final today = _today();
    for (final e in values.entries) {
      final p = e.key.problem(e.value, today: today);
      if (p != null) throw ArgumentError('${e.key.label}: $p');
    }
    return {for (final MapEntry(key: c, value: v) in values.entries) c.name: v == null ? null : c.encode(v)};
  }

  /// The given values of the columns not in [handled], checked ([_patchFields]): a column an entity's own rules do not
  /// know (one added later) is written as given.
  Map<String, Object?> _patchRest(Map<Col, Object?> values, Set<Col> handled) => _patchFields({
        for (final e in values.entries)
          if (!handled.contains(e.key)) e.key: e.value
      });

  /// None (null) for a non-nullable column: `ArgumentError('<label>: Needs a value.')`, before an entity's own checks.
  static void _needValues(Map<Col, Object?> values) {
    for (final e in values.entries) {
      if (e.value == null && !e.key.nullable) throw ArgumentError('${e.key.label}: Needs a value.');
    }
  }

  /// Per entity, the columns only their own actions change (confirm, link, attach, delete, import, pay, close …).
  static const _actionFields = <String, Set<String>>{
    'bill': {
      'source', 'status', 'external_id', 'currency', 'unsure', 'linked_tx', 'blob', 'blob_type', 'blob_bytes', 'deleted', //
      'attached_tx',
    },
    'iou': {'closed', 'deleted'},
    'planned': {'source', 'source_ref', 'status', 'paid_tx', 'deleted', 'auto_off'},
    'recurring': {'payee', 'status', 'last_paid_tx', 'deleted', 'manual', 'own_category', 'direction'},
    'goal': {'saved', 'deleted'}, // a total changes by contributions (saveGoal), never by its base
    'wish': {'added', 'status', 'decided', 'deleted'},
    'category': {'kind', 'deleted'},
    'tag': {'deleted'},
    'view': {'deleted'},
    'loan': {'closed_at', 'goal_id', 'deleted'}, // closeLoan, buyGoal, deleteLoan (ENG E6)
  };

  /// Entities changed by their own actions only (their writes keep rules a field edit would skip: matching, totals,
  /// links, repayments). Loan rate rows and balance checks are append-only (`addLoanRate`, `addLoanCheck`).
  static const _actionEntities = {
    'tx', 'iou_part', 'goal_contrib', 'rule', 'txtag', 'ruletag', 'split', 'review', 'payee_alias', 'loanrate', 'loancheck', //
  };

  int _patchBill(String id, Map<Col, Object?> values) {
    final fields = _patchFields(values);
    final b = _liveBill(id);
    if (fields.isEmpty) return 0;
    // A confirmed bill keeps its total and date (confirmBill / addExpenseFromBill need them): clearing either would
    // drop its planned row, so the money it reserves would come back without a word.
    if (b.confirmed) {
      for (final c in const <Col>[BillCols.total, BillCols.date]) {
        if (fields.containsKey(c.name) && fields[c.name] == null) throw ArgumentError('${c.label}: needed on a confirmed bill.');
      }
    }
    // Only an edit that changes the reserve (due date, total, category) is held to the category rule; a note,
    // payee or warranty edit on a bill without one (confirmed before categories were asked for, or reopened) still saves: such a bill's
    // planned row is listed, not reserved ([PlannedCost.needsCategory]), so nothing counts twice either way.
    _write(_billWrites(b, fields, _today(), needCategory: fields.keys.any(WalletRepoBills._billReserveFields.contains)));
    logEvent(_log, Level.INFO, 'bills.update', {'fields': fields.length});
    return fields.length;
  }

  int _patchAccount(String id, Map<Col, Object?> values) {
    if (values.containsKey(AccountCols.currency)) {
      throw ArgumentError('${AccountCols.currency.label}: never changes; delete the account and add a new one.');
    }
    if (values.containsKey(AccountCols.deleted)) {
      throw ArgumentError('${AccountCols.deleted.label}: changed by delete and undo, not edited.');
    }
    final stored = Account.fromRow(_accountRow(id));
    // The texts as typed: the name and institution trimmed (a blank institution is none), as addAccount stores them.
    final v = {
      for (final e in values.entries)
        e.key: switch (e.value) {
          final String s when e.key == AccountCols.name || e.key == AccountCols.institution => s.trim(),
          final x => x,
        }
    };
    if (v[AccountCols.name] == '') throw ArgumentError('Give the account a name.');
    if (v[AccountCols.institution] == '') v[AccountCols.institution] = null;
    _patchFields(v);
    final n = v[AccountCols.name] as String?;
    final has = v.containsKey;
    final k = has(AccountCols.kind) ? v[AccountCols.kind] as AccountKind? : stored.kind;
    final src = has(AccountCols.source) ? v[AccountCols.source] as String? : stored.source;
    final kind = k ?? (src == null ? AccountKind.cash : AccountKind.bank);
    final inst = has(AccountCols.institution) ? v[AccountCols.institution] as String? : stored.institution;
    final mk = has(AccountCols.matchKey) ? v[AccountCols.matchKey] as String? : stored.matchKey;
    if (kind != stored.kind || src != stored.source || mk != stored.matchKey) {
      _checkShape(kind, src, stored.currency);
      // UX-ACC: only a new key is checked (shape, bank account); a kept one has no effect once the source is cleared.
      if (mk != stored.matchKey) WalletRepoAccounts._checkMatchKey(mk, src, kind);
      if (!stored.deleted) _checkUnique(src, stored.currency, exceptId: id, kind: kind, matchKey: mk);
    }
    final pair = has(AccountCols.opening) || has(AccountCols.openingDate);
    final fields = {
      if (n != null && n != stored.name) 'name': n,
      if (pair) 'opening': v[AccountCols.opening] as int? ?? stored.opening,
      if (pair) 'opening_date': v[AccountCols.openingDate] as String? ?? stored.openingDate,
      // The kind is written whenever the source changes too: a row from before schema 20 derives it from the source.
      if (kind != stored.kind || src != stored.source) 'kind': kind.name,
      if (src != stored.source) 'source': src,
      if (inst != stored.institution) 'institution': inst,
      if (mk != stored.matchKey) 'match_key': mk,
    };
    if (fields.isEmpty) return 0;
    _write([('account', id, fields)]);
    logEvent(_log, Level.INFO, 'account.update', {'fields': fields.length});
    return fields.length;
  }
}
