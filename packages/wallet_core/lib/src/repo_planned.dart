part of 'repo.dart';

/// Planned costs (§4.3): hand-added future costs and calendar events given an amount (see [PlannedCost]).
extension WalletRepoPlanned on WalletRepo {
  /// The row id of a planned cost from a source: `<source>:<ref>` (the same on every device, so two devices confirming
  /// or dismissing one calendar event write one row, last writer wins per field), else a new random `p…` id.
  String _plannedId(PlannedSource source, String? sourceRef) =>
      sourceRef != null && sourceRef.isNotEmpty ? '${source.name}:$sourceRef' : _newId('p');

  static void _checkPlanned({String? date, int? amount}) {
    if (date != null && !isIsoDate(date)) throw ArgumentError('Bad date.');
    if (amount != null && (amount <= 0 || amount > WalletSettings.maxAmount)) throw ArgumentError('Bad amount.');
  }

  /// Adds an open planned cost and returns its id. [amount] (positive cents) null = no amount yet: listed, never
  /// reserved. With a [sourceRef] (a calendar event's [calendarEventRef]) the id is `<source>:<sourceRef>`: confirming an
  /// event that was dismissed before (or confirmed on another device) reopens and overwrites that one row. A bad
  /// [date] or an amount ≤ 0 is an [ArgumentError].
  String addPlanned(
      {required String title,
      required String date,
      int? amount,
      String? category,
      PlannedSource source = PlannedSource.manual,
      String? sourceRef}) {
    _checkPlanned(date: date, amount: amount);
    final id = _plannedId(source, sourceRef);
    _write([
      (
        'planned',
        id,
        {
          'title': title,
          'date': date,
          'amount': amount,
          'category': category,
          'source': source.name,
          'source_ref': sourceRef,
          'status': PlannedStatus.open.name,
          'paid_tx': null,
          'deleted': 0,
        }
      )
    ]);
    logEvent(_log, Level.INFO, 'planned.add', {'source': source.name, 'withAmount': amount != null});
    return id;
  }

  void _setPlanned(String id, Map<String, Object?> fields, String event) {
    if (db.select('SELECT 1 FROM planned WHERE id = ?', [id]).isEmpty) throw ArgumentError('No such planned cost.');
    if (fields.isEmpty) return;
    _write([('planned', id, fields)]);
    logEvent(_log, Level.INFO, event);
  }

  /// Changes the given fields only (null = unchanged); [clearAmount] / [clearCategory] set those to none. Unknown id,
  /// bad date or amount ≤ 0: [ArgumentError].
  void updatePlanned(String id,
      {String? title, String? date, int? amount, String? category, bool clearAmount = false, bool clearCategory = false}) {
    _checkPlanned(date: date, amount: amount);
    _setPlanned(
        id,
        {
          if (title != null) 'title': title,
          if (date != null) 'date': date,
          if (clearAmount) 'amount': null else if (amount != null) 'amount': amount,
          if (clearCategory) 'category': null else if (category != null) 'category': category,
        },
        'planned.update');
  }

  /// The owner picked [txId] as the transaction that paid it ([paidCandidates]): no longer listed or reserved.
  void markPlannedPaid(String id, String txId) => _setPlanned(id, {'status': PlannedStatus.paid.name, 'paid_tx': txId}, 'planned.paid');

  /// Not coming: no longer listed or reserved. `paid_tx` cleared (it means something only while paid).
  void skipPlanned(String id) => _setPlanned(id, {'status': PlannedStatus.skipped.name, 'paid_tx': null}, 'planned.skip');

  /// Back to open (undo of Paid or Skip, and the Undo of an auto-Paid): `paid_tx` cleared. A cost reopened from Paid
  /// adds that row to its `auto_off` (KL-A, schema 19), so auto-Paid ([planAutoPaid]) never closes it with the same
  /// row again, on any device; the owner can still pick it by hand ([markPlannedPaid]). Leaves [autoPaidPlanned].
  void reopenPlanned(String id) {
    final rs = db.select('SELECT paid_tx, auto_off FROM planned WHERE id = ?', [id]);
    final paid = rs.isEmpty ? null : rs.first['paid_tx'] as String?;
    final off = paid == null ? null : PlannedCost.fromRow({'id': id, 'auto_off': rs.first['auto_off']}).autoOff;
    _setPlanned(
        id,
        {
          'status': PlannedStatus.open.name,
          'paid_tx': null,
          if (paid != null) 'auto_off': encodeMatchOff([...off!.where((t) => t != paid), paid]),
        },
        'planned.reopen');
    ackAutoPaidPlanned([id]);
  }

  /// Device-local key of the auto-Paid list ([autoPaidPlanned]).
  static const _autoPaidKey = 'autoPaidPlanned';

  /// Most entries [autoPaidPlanned] keeps (the newest).
  static const maxAutoPaid = 50;

  /// The planned costs this device closed by itself ([planAutoPaid]) and the owner has not acknowledged yet, oldest
  /// first, at most [maxAutoPaid]: the app's "Marked paid" toast with Undo ([reopenPlanned]). Device-local, never
  /// synced. An entry whose cost is no longer paid by that row (reopened, deleted, or changed on another device) is
  /// left out.
  List<AutoPaid> autoPaidPlanned() {
    final all = _readAutoPaid();
    if (all.isEmpty) return const [];
    final still = {
      for (final r in db.select("SELECT id, paid_tx FROM planned WHERE deleted = 0 AND status = 'paid' AND paid_tx IS NOT NULL"))
        '${r['id']}\u0000${r['paid_tx']}'
    };
    return [
      for (final a in all)
        if (still.contains('${a.plannedId}\u0000${a.txId}')) a
    ];
  }

  /// The owner saw (or undid) the toast for [plannedIds]: they leave [autoPaidPlanned].
  void ackAutoPaidPlanned(Iterable<String> plannedIds) {
    final ids = plannedIds.toSet();
    if (ids.isEmpty) return;
    final all = _readAutoPaid();
    final keep = [
      for (final a in all)
        if (!ids.contains(a.plannedId)) a
    ];
    if (keep.length != all.length) _writeAutoPaid(keep);
  }

  List<AutoPaid> _readAutoPaid() {
    final v = localValue(_autoPaidKey);
    if (v == null || v.isEmpty) return const [];
    try {
      final l = jsonDecode(v);
      if (l is! List) return const [];
      return [
        for (final j in l)
          if (AutoPaid.fromJson(j) case final a?) a
      ];
    } on FormatException catch (e, st) {
      logError(_log, 'planned.autoPaid.invalid', e, st, level: Level.FINE);
      return const [];
    }
  }

  void _writeAutoPaid(List<AutoPaid> list) {
    final keep = list.length > maxAutoPaid ? list.sublist(list.length - maxAutoPaid) : list;
    setLocalValue(_autoPaidKey, keep.isEmpty ? null : jsonEncode([for (final a in keep) a.toJson()]));
  }

  /// KL-A: closes the open planned costs exactly one bank row pays ([planAutoPaid]: same category, the exact amount, ±3
  /// days; rows in the wallet currency, not linked to a bill), as [markPlannedPaid] does, in one write, and lists them
  /// in [autoPaidPlanned]. Runs in `_reconcile` (only while caught up). Logged as `planned.autoPaid` on `bw.perf` with
  /// counts only.
  void _autoPayPlanned() {
    final all = plannedCosts(includeClosed: true);
    final open = [
      for (final p in all)
        if (p.isOpen && !p.isBill && p.source != PlannedSource.bill && (p.amount ?? 0) > 0 && p.category != null) p
    ];
    if (open.isEmpty) return;
    final t = PerfTimer('planned.autoPaid');
    final currency = settings().currency;
    final amounts = {for (final p in open) -p.amount!}.toList();
    final billPaid = {
      for (final r in db.select('SELECT linked_tx FROM bills WHERE deleted = 0 AND linked_tx IS NOT NULL')) r['linked_tx'] as String
    };
    final cz = categorizer(withTags: false);
    final rows = [
      for (final r in db.select(
          '${WalletRepo._txSelect} WHERE tx.manual = 0 AND tx.deleted = 0 AND tx.currency = ? '
          'AND tx.amount IN (${List.filled(amounts.length, '?').join(',')})',
          [currency, ...amounts]))
        if (Tx.fromRow(r) case final tx when tx.live && !billPaid.contains(tx.id)) cz.categorize(tx)
    ];
    final plan = rows.isEmpty ? const <(String, String)>[] : planAutoPaid(all, rows, table: cz.table);
    if (plan.isNotEmpty) {
      _write([
        for (final (id, tx) in plan) ('planned', id, {'status': PlannedStatus.paid.name, 'paid_tx': tx})
      ]);
      final titles = {for (final p in open) p.id: p.title};
      _writeAutoPaid([
        for (final a in _readAutoPaid())
          if (!plan.any((e) => e.$1 == a.plannedId)) a,
        for (final (id, tx) in plan) AutoPaid(plannedId: id, txId: tx, title: titles[id] ?? ''),
      ]);
    }
    t.done({'planned': open.length, 'rows': rows.length, 'paid': plan.length});
  }

  /// Removes it (the row stays, deleted, so the calendar event it came from is not suggested again).
  void deletePlanned(String id) => _setPlanned(id, {'deleted': 1}, 'planned.delete');

  /// "No cost" on a calendar suggestion: a synced row `calendar:<sourceRef>` {source calendar, sourceRef, date,
  /// status skipped}, so no device suggests that event again. Writes no title (the column default '' until a confirm
  /// on another device brings one: that title is kept when the two merge). If the event already has a row (confirmed
  /// earlier, here or elsewhere), only its status becomes skipped.
  ///
  /// KL-A: [legacyRef] = the event's [CalendarEvent.legacyRef]. When the event has no row under [sourceRef] but one
  /// under [legacyRef] (a decision made before KL-A), that row is the one set to skipped, so the event keeps one row.
  void dismissCalendarEvent(String sourceRef, String date, {String? legacyRef}) {
    if (sourceRef.isEmpty) throw ArgumentError('No event ref.');
    _checkPlanned(date: date);
    bool has(String id) => db.select('SELECT 1 FROM planned WHERE id = ?', [id]).isNotEmpty;
    var id = _plannedId(PlannedSource.calendar, sourceRef);
    if (!has(id) && legacyRef != null && legacyRef.isNotEmpty && legacyRef != sourceRef) {
      final old = _plannedId(PlannedSource.calendar, legacyRef);
      if (has(old)) id = old;
    }
    final exists = has(id);
    _write([
      (
        'planned',
        id,
        exists
            ? {'status': PlannedStatus.skipped.name}
            : {
                'date': date,
                'source': PlannedSource.calendar.name,
                'source_ref': sourceRef,
                'status': PlannedStatus.skipped.name,
                'deleted': 0,
              }
      )
    ]);
    logEvent(_log, Level.INFO, 'planned.dismiss', {'existed': exists});
  }
}
