part of 'repo.dart';

/// Planned costs (§4.3): hand-added future costs and calendar events given an amount (see [PlannedCost]).
extension WalletRepoPlanned on WalletRepo {
  /// The row id of a planned cost from a source: `<source>:<ref>` (the same on every device, so two devices confirming
  /// or dismissing one calendar event write one row, last writer wins per field), else a new random `p…` id.
  String _plannedId(PlannedSource source, String? sourceRef) =>
      sourceRef != null && sourceRef.isNotEmpty ? '${source.name}:$sourceRef' : _newId('p');

  static void _checkPlanned({String? date, int? amount}) {
    if (date != null && !(_isoDate.hasMatch(date) && isoDate(parseIso(date)) == date)) throw ArgumentError('Bad date.');
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

  /// Not coming: no longer listed or reserved.
  void skipPlanned(String id) => _setPlanned(id, {'status': PlannedStatus.skipped.name}, 'planned.skip');

  /// Back to open (undo of Paid or Skip): `paid_tx` cleared.
  void reopenPlanned(String id) => _setPlanned(id, {'status': PlannedStatus.open.name, 'paid_tx': null}, 'planned.reopen');

  /// Removes it (the row stays, deleted, so the calendar event it came from is not suggested again).
  void deletePlanned(String id) => _setPlanned(id, {'deleted': 1}, 'planned.delete');

  /// "No cost" on a calendar suggestion: a synced row `calendar:<sourceRef>` {source calendar, sourceRef, date,
  /// status skipped}, so no device suggests that event again. Writes no title (the column default '' until a confirm
  /// on another device brings one: that title is kept when the two merge). If the event already has a row (confirmed
  /// earlier, here or elsewhere), only its status becomes skipped.
  void dismissCalendarEvent(String sourceRef, String date) {
    if (sourceRef.isEmpty) throw ArgumentError('No event ref.');
    _checkPlanned(date: date);
    final id = _plannedId(PlannedSource.calendar, sourceRef);
    final exists = db.select('SELECT 1 FROM planned WHERE id = ?', [id]).isNotEmpty;
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
