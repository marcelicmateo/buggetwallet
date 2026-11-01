part of 'repo.dart';

/// UX-FX: ECB reference rates per payment date. The full downloaded history lives in the device-local table
/// `ecb_rates` (never synced, never backed up); only the rates the wallet needs become synced `fx_day` rows
/// ([fillFxDays]), so every device converts with the same values. The app downloads ([ecbFetchPlan] says which file and
/// when) and hands the bytes to [importEcbHistory]; core never fetches.
extension WalletRepoFx on WalletRepo {
  static const _importedKey = 'ecbImported', _attemptKey = 'ecbAttempt';

  /// The wallet's ECB rates (its live `fx_day` rows; read once per [dataVersion]). [settings] carries them
  /// ([WalletSettings.ecb]).
  EcbRates ecbRates() {
    final c = _ecbCache;
    if (c != null && c.$1 == dataVersion) return c.$2;
    final rows = [
      for (final r in db.select('SELECT * FROM fx_days WHERE deleted = 0'))
        if ((FxDayCols.cur.read(r), FxDayCols.date.read(r), FxDayCols.perEur.read(r)) case (final c?, final d?, final p?)) FxDay(c, d, p)
    ];
    final e = EcbRates(rows);
    _ecbCache = (dataVersion, e);
    return e;
  }

  /// What the wallet converts by an ECB rate ([fxNeeds] over the currency and date of every live payment, bill
  /// (its date, else its due date), IOU and account opening not in the wallet currency of [st] (default: [settings])).
  List<FxNeed> walletFxNeeds([WalletSettings? st]) {
    final s = st ?? settings();
    final w = s.currency;
    final pairs = <(String, String?)>[];
    void add(String sql) {
      for (final r in db.select(sql, [w])) {
        if ((r['c'], r['d']) case (final String c, final String? d)) pairs.add((c, d));
      }
    }

    add('SELECT DISTINCT currency AS c, date AS d FROM tx WHERE deleted = 0 AND currency != ?');
    add('SELECT DISTINCT currency AS c, COALESCE(date, due_date) AS d FROM bills WHERE deleted = 0 AND currency != ?');
    add('SELECT DISTINCT currency AS c, date AS d FROM ious WHERE deleted = 0 AND currency != ?');
    add('SELECT DISTINCT currency AS c, opening_date AS d FROM accounts WHERE deleted = 0 AND currency != ?');
    return fxNeeds(pairs, s);
  }

  /// The needs ([walletFxNeeds]) dated up to today that the wallet's `fx_day` rows cannot convert yet: shown as "not
  /// counted" until the rates arrive (a sync, or a download: [ecbFetchPlan], [importEcbHistory]). A date after today
  /// (a future bill or IOU) is never missing: its day is not published yet.
  List<FxNeed> fxMissing() {
    final st = settings();
    final today = _today();
    return [
      for (final n in walletFxNeeds(st))
        if (n.date.compareTo(today) <= 0 && st.ecb.pairOn(n.currency, st.currency, n.date) == null) n
    ];
  }

  /// Writes the `fx_day` rows the wallet needs ([walletFxNeeds]) from the device-local ECB cache: per need, the latest
  /// cached ECB day on or before its date within [ecbMaxGapDays] that has both its currency and the wallet currency
  /// (EUR is 1), when the wallet holds no rate for that need yet or only an older day's (answered early, before its own
  /// day was published, here or on another device): every device ends on the same, best day. One internal write (never
  /// refused for the clock); returns how many rows it wrote. A row the wallet holds with the same value is not written
  /// again. Runs by itself after every change that can add a need (`_fillFxAfterChange`: rows, bills, IOUs, accounts,
  /// the wallet currency or a hand rate, here or from a sync) and after [importEcbHistory]. Logs counts only.
  int fillFxDays() {
    if (db.select('SELECT 1 FROM ecb_rates LIMIT 1').isEmpty) return 0;
    final t = PerfTimer('fx.fill');
    final st = settings();
    final w = st.currency;
    final planned = <String, int>{};
    final changes = <(String, String, Map<String, Object?>)>[];
    var needs = 0, unanswered = 0, newer = 0;
    for (final n in walletFxNeeds(st)) {
      needs++;
      final have = st.ecb.pairOn(n.currency, w, n.date)?.day;
      if (have == n.date) continue; // its own day: nothing can be better
      final curs = {n.currency, w}..remove('EUR');
      final byDay = <String, Map<String, int>>{};
      for (final r in db.select(
          'SELECT cur, date, per_eur FROM ecb_rates WHERE cur IN (${List.filled(curs.length, '?').join(', ')}) AND date <= ? AND date >= ?',
          [...curs, n.date, addDays(n.date, -ecbMaxGapDays)])) {
        (byDay[r['date'] as String] ??= {})[r['cur'] as String] = r['per_eur'] as int;
      }
      final day = (byDay.keys.where((d) => byDay[d]!.length == curs.length).toList()..sort()).lastOrNull;
      if (day == null) {
        if (have == null) unanswered++;
        continue;
      }
      if (have != null && have.compareTo(day) >= 0) continue;
      if (have != null) newer++;
      for (final c in curs) {
        final per = byDay[day]![c]!, id = fxDayId(c, day);
        if (st.ecb.perEurOn(c, day) == per || planned[id] == per) continue;
        planned[id] = per;
        changes.add(('fx_day', id, {'cur': c, 'date': day, 'per_eur': per, 'source': 'ecb'}));
      }
    }
    if (changes.isNotEmpty) _writeInternal(changes);
    t.done({'needs': needs, 'written': changes.length, 'unanswered': unanswered, 'newer': newer});
    return changes.length;
  }

  /// [fillFxDays] after a committed change that can add or answer a need (`_tx`, `_fxPending`): never fails the change
  /// itself (an error is logged), never runs inside itself, and costs one query when the cache is empty.
  void _fillFxAfterChange() {
    if (_fxFilling) return;
    _fxFilling = true;
    try {
      fillFxDays();
    } catch (e, st) {
      logError(_log, 'fx.fill.failed', e, st);
    } finally {
      _fxFilling = false;
    }
  }

  /// Stores an ECB file the app downloaded ([ecbFetchPlan]; zip, CSV or XML, [parseEcbRates]) in the device-local
  /// cache, then writes the `fx_day` rows the wallet needs ([fillFxDays]). A damaged, cut or foreign file is a
  /// [FormatException] with a short message for the owner, and nothing is written. Logs the outcome and counts.
  EcbImport importEcbHistory(List<int> bytes) {
    final t = PerfTimer('fx.ecbImport');
    final EcbHistory h;
    try {
      h = parseEcbRates(bytes);
    } on FormatException catch (e, st) {
      logError(_log, 'fx.ecbImport.refused', e, st, fields: {'bytes': bytes.length});
      rethrow;
    }
    _tx(() {
      final stmt = db.prepare('INSERT OR REPLACE INTO ecb_rates(cur, date, per_eur) VALUES(?, ?, ?)');
      try {
        for (final MapEntry(key: cur, value: days) in h.rates.entries) {
          for (final MapEntry(key: date, value: per) in days.entries) {
            stmt.execute([cur, date, per]);
          }
        }
      } finally {
        stmt.close();
      }
    });
    setLocalValue(_importedKey, _today());
    final written = fillFxDays();
    t.done({'days': h.days, 'currencies': h.rates.length, 'written': written});
    return EcbImport(days: h.days, currencies: h.rates.length, oldest: h.oldest, newest: h.newest, written: written);
  }

  /// The device-local ECB cache: its days and range, the last good import and the last download attempt.
  EcbCacheInfo ecbCacheInfo() {
    final r = db.select('SELECT COUNT(DISTINCT date) AS n, MIN(date) AS lo, MAX(date) AS hi FROM ecb_rates').first;
    return EcbCacheInfo(
        days: r['n'] as int,
        oldest: r['lo'] as String?,
        newest: r['hi'] as String?,
        importedOn: localValue(_importedKey),
        attemptOn: localValue(_attemptKey));
  }

  /// Records a download attempt today (the app calls it before each fetch, whatever the outcome), so [ecbFetchPlan]
  /// asks at most once a day.
  void noteEcbAttempt() => setLocalValue(_attemptKey, _today());

  /// Which ECB file the app should download now, or null (nothing to do). Automatic (default): at most once a day
  /// ([noteEcbAttempt]), and only when a download could bring a rate the wallet needs ([walletFxNeeds], dates up to
  /// today, not before [ecbFirstDay]): a missing one ([fxMissing]) whose window (the date back [ecbMaxGapDays]) reaches
  /// past the cache (newer than its newest day, or older than its oldest), or one answered by an older day whose date
  /// is newer than the cache's newest day (its own day may be published by now). A currency the ECB does not publish,
  /// inside the cached range, never triggers a fetch; neither does a future date. [EcbFile.history] when the cache is
  /// empty, the recent file cannot reach back far enough (needs older than about 80 days, or a cache whose newest day
  /// is older than that), else [EcbFile.recent]. [force] (the owner's "Get rates now"): always a file, ignoring the
  /// daily limit. The app's order: [ecbFetchPlan] → [noteEcbAttempt] → download → [importEcbHistory].
  EcbFile? ecbFetchPlan({bool force = false}) {
    final today = _today();
    final info = ecbCacheInfo();
    final lo = info.oldest, hi = info.newest;
    final recentFrom = addDays(today, -80);
    if (force) return hi == null || hi.compareTo(recentFrom) < 0 ? EcbFile.history : EcbFile.recent;
    if (info.attemptOn == today) return null;
    final st = settings();
    final want = <String>[];
    for (final n in walletFxNeeds(st)) {
      final d = n.date;
      if (d.compareTo(today) > 0 || d.compareTo(ecbFirstDay) < 0) continue;
      final have = st.ecb.pairOn(n.currency, st.currency, d)?.day;
      if (have == d) continue;
      final from = addDays(d, -ecbMaxGapDays);
      final newerThanCache = hi != null && d.compareTo(hi) > 0;
      if (have != null) {
        if (newerThanCache) want.add(from);
        continue;
      }
      // Older than the cache helps only while the cache does not start at the ECB's first day already.
      if (lo == null || hi == null || newerThanCache || (from.compareTo(lo) < 0 && lo.compareTo(ecbFirstDay) > 0)) want.add(from);
    }
    if (want.isEmpty) return null;
    final full = hi == null || hi.compareTo(recentFrom) < 0 || want.any((from) => from.compareTo(recentFrom) < 0);
    final plan = full ? EcbFile.history : EcbFile.recent;
    logEvent(_log, Level.INFO, 'fx.fetchPlan', {'missing': want.length, 'file': plan.name});
    return plan;
  }
}
