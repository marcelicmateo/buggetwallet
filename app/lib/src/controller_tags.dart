// Extra tags in the controller (stage T1, core API in docs/context/T1_SPEC.md). A `part` of controller.dart so it can use the cache and
// `_changed`. The main tag is the row's category (controller_categories.dart); an extra tag only tracks, it never moves money.
//
// Privacy: logs carry counts and enum words only, never tag names or ids.
part of 'controller.dart';

final _tagLog = Logger('bw.tags.ui');

/// A hand-added expense without a note has no payee, so recommendations for a new expense go by overall use.
const _placeholderTx = Tx(id: 'new', source: 'manual', date: '2000-01-01', amount: 0, manual: true);

/// "Saved; one tag could not be added" for [n] tag writes that failed in a save, or null when none did.
String? tagFailureText(int n) => n <= 0 ? null : (n == 1 ? 'Saved; one tag could not be added' : 'Saved; $n tags could not be added');

extension TagsDb on WalletController {
  /// The owner's tags as the shown rows were computed with (rebuilt on every [reload], from the categorizer).
  TagTable get tagTable => categorizer.tagContext?.tags ?? TagTable.empty;

  /// The three tag tables as read for the shown rows (rule tags, links).
  TagContext get tagContext => categorizer.tagContext ?? TagContext.empty;

  /// The tag ids [t]'s payee gives to every payment (rule tags), resolved through duplicates; empty for a row without a payee.
  Set<String> ruleTagsOf(Tx t) {
    final payee = tagPayee(t);
    if (payee == null) return const {};
    final ids = tagContext.ruleTags[payee];
    if (ids == null) return const {};
    final table = tagTable;
    return {
      for (final id in ids)
        if (table.resolve(id) case final r?) r
    };
  }

  /// The main tags to offer for [t] (null: a new hand-added expense), payee first, then by use. Cached per data version
  /// (core's ordering reads every row, so never call it per row or per keystroke).
  List<String> recommendedMainFor(Tx? t, {Set<BudgetKind>? kinds}) => memo(
      MemoKey('tags.main', (t?.id, kinds?.map((k) => k.name).join(','))),
      () => timed('tags.recommendedMain', () => recommendedMainTags(t ?? _placeholderTx, wholeTxs, categoryTable, kinds: kinds),
          fields: {'tx': wholeTxs.length}, warnMs: 50));

  /// The extra tags to offer for [t] (null: a new expense), payee first, then by use, then the table order. Cached per data version.
  List<String> recommendedTagsFor(Tx? t) => memo(
      MemoKey('tags.recommended', t?.id),
      () => timed('tags.recommended', () => recommendedTags(t ?? _placeholderTx, wholeTxs, tagTable),
          fields: {'tx': wholeTxs.length}, warnMs: 50));

  /// The tags suggested for [t] from what the same payee had before (never applied). Cached per data version.
  List<String> suggestedTagsFor(Tx t) => memo(
      MemoKey('tags.suggest', t.id),
      () => timed('tags.suggest', () => suggestTags(t, wholeTxs, tagTable, limit: 5, off: tagContext.offTags(t)),
          fields: {'tx': wholeTxs.length}, warnMs: 50));

  /// Live rows per tag (a duplicate's rows count for its original): the numbers in Plan › Tags. Cached per data version.
  Map<String, int> tagUseCounts() => memo(const MemoKey('tags.use'), () {
        final out = <String, int>{};
        final seen = <String>{}; // a payment counts once per tag, however many of its parts carry it
        for (final t in txs) {
          if (!t.tx.live) continue;
          for (final g in t.tags) {
            if (seen.add('${t.tx.id}|$g')) out[g] = (out[g] ?? 0) + 1;
          }
        }
        return out;
      });

  /// Adds a tag and returns its id. A refused name is an [ArgumentError] with core's text.
  Future<String> addTag(String name) async {
    final id = await repo.addTag(name);
    logEvent(_tagLog, Level.INFO, 'tags.add', {'live': repo.tags().length});
    _changed();
    return id;
  }

  Future<void> renameTag(String id, String name) async {
    repo.patch(TagCols.entity, id, {TagCols.name: name});
    logEvent(_tagLog, Level.INFO, 'tags.rename');
    _changed();
  }

  Future<void> setTagHidden(String id, bool hidden) async {
    repo.patch(TagCols.entity, id, {TagCols.hidden: hidden});
    logEvent(_tagLog, Level.INFO, 'tags.hide', {'hidden': hidden});
    _changed();
  }

  /// Moves [id] one place up ([delta] -1) or down (+1) in the tag list. The order is handed out again as 0, 1, 2… (only the
  /// positions that change are written), so ties never leave a move without effect.
  Future<void> moveTag(String id, int delta) async {
    final t = tagTable;
    final order = [...t.ids];
    final i = order.indexOf(id), j = i + delta;
    if (i < 0 || j < 0 || j >= order.length) return;
    final other = order[j];
    order[j] = order[i];
    order[i] = other;
    var written = 0;
    for (var k = 0; k < order.length; k++) {
      if (t.position(order[k]) != k) {
        repo.patch(TagCols.entity, order[k], {TagCols.position: k});
        written++;
      }
    }
    logEvent(_tagLog, Level.INFO, 'tags.move', {'written': written, 'tags': order.length});
    _changed();
  }

  Future<void> deleteTag(String id) async {
    await repo.deleteTag(id);
    logEvent(_tagLog, Level.INFO, 'tags.delete');
    _changed();
  }

  /// Undo of [deleteTag].
  Future<void> undeleteTag(String id) async {
    await repo.undeleteTag(id);
    logEvent(_tagLog, Level.INFO, 'tags.undelete');
    _changed();
  }

  /// Turns [tagId] on or off for one payment. Off for a tag a rule gives is written for this payment only.
  Future<void> setPaymentTag(String txId, String tagId, bool on) async {
    await repo.setTxTag(txId, tagId, on);
    logEvent(_tagLog, Level.INFO, 'tags.payment', {'on': on});
    _changed();
  }

  /// Gives (or stops giving) [tagId] to every payment of [t]'s payee.
  Future<void> setPayeeTag(Tx t, String tagId, bool on) async {
    final payee = tagPayee(t);
    if (payee == null) throw ArgumentError('This payment has no payee.');
    await repo.setRuleTag(payee, tagId, on);
    logEvent(_tagLog, Level.INFO, 'tags.payee', {'on': on});
    _changed();
  }

  /// Links [tags] to the new payment [txId]; a tag that is no longer live, or a write that fails, is counted in [takeTagFailures] and
  /// logged. Core writes synchronously (nothing awaits inside), so the caller can reload right after.
  void _linkNewTags(String txId, Iterable<String> tags) {
    final table = tagTable;
    for (final g in tags) {
      if (!table.isLive(g)) {
        _tagFailures++;
        continue;
      }
      repo.setTxTag(txId, g, true).catchError((Object e, StackTrace st) {
        _tagFailures++;
        logError(_tagLog, 'tags.link.failed', e, st);
      });
    }
  }

  /// How many tag writes of the last save could not be made (a tag deleted while the sheet was open, a refused write), then 0. The
  /// toast after a save says so ([tagFailureText]).
  int takeTagFailures() {
    final n = _tagFailures;
    _tagFailures = 0;
    return n;
  }

  /// The sheet's Save for tags: makes the payment [row] have exactly the tags [on] and its payee give exactly [rule] to every payment,
  /// writing only what differs (nothing for an untouched draft). Tags that are no longer live are not written; they and any write that
  /// fails are counted in [takeTagFailures]. Reloads once when something was written. Returns the number of failures.
  Future<int> saveTagChanges(CategorizedTx row, {required Set<String> on, required Set<String> rule}) async {
    final tx = row.tx;
    final table = repo.tagTable();
    var failed = 0, wrote = 0;
    Set<String> resolved(Iterable<String> ids) => {
          for (final id in ids)
            if (table.resolve(id) case final r?) r
        };
    // The payee rule first, so the row's tags below are judged with it.
    final payee = tagPayee(tx);
    if (payee != null) {
      final now = resolved(repo.ruleTags()[payee] ?? const <String>{});
      final want = resolved(rule);
      for (final id in want.difference(now)) {
        try {
          await repo.setRuleTag(payee, id, true);
          wrote++;
        } catch (e, st) {
          failed++;
          logError(_tagLog, 'tags.rule.failed', e, st);
        }
      }
      for (final id in now.difference(want)) {
        try {
          await repo.setRuleTag(payee, id, false);
          wrote++;
        } catch (e, st) {
          failed++;
          logError(_tagLog, 'tags.rule.failed', e, st);
        }
      }
    }
    final want = resolved(on);
    // A tag that was picked and is gone now cannot be added; one the payment had before and that is gone just disappears.
    failed += on.where((id) => table.resolve(id) == null && !row.tags.contains(id)).length;
    final have = {...tagsOf(tx, tags: table, ruleTags: repo.ruleTags(), links: repo.tagLinks())};
    for (final id in want.difference(have)) {
      try {
        await repo.setTxTag(tx.id, id, true);
        wrote++;
      } catch (e, st) {
        failed++;
        logError(_tagLog, 'tags.link.failed', e, st);
      }
    }
    for (final id in have.difference(want)) {
      try {
        await repo.setTxTag(tx.id, id, false);
        wrote++;
      } catch (e, st) {
        failed++;
        logError(_tagLog, 'tags.link.failed', e, st);
      }
    }
    _tagFailures += failed;
    logEvent(_tagLog, Level.INFO, 'tags.save', {'written': wrote, 'failed': failed});
    if (wrote > 0) _changed();
    return failed;
  }

  // ---------- Insights ----------
  /// Spending per extra tag over [r] (overlapping totals). Cached per data version.
  TagShare tagShareFor(DateRange r) => memo(MemoKey('ins.tags', (r.start, r.end)),
      () => timed('insights.tags', () => tagShare(txs, r, currency: currency), fields: {'days': r.days, 'tx': txs.length}, warnMs: 50));

  /// The payments behind [tag]'s total over [r], newest first (they add up to it).
  List<CategorizedTx> rowsOfTag(String tag, DateRange r) =>
      memo(MemoKey('ins.tagrows', (r.start, r.end, tag)), () => rowsForTag(tag, txs, r, currency: currency));

  /// [tag]'s total over [r] and the payments behind it. Core's slice when the tag has net spending; a tag whose rows are refunds only
  /// has no slice, so its total is the rows' sum (negative), the same rows [rowsOfTag] lists.
  ({int spent, int count}) tagTotalFor(String tag, DateRange r) => memo(MemoKey('ins.tagtotal', (r.start, r.end, tag)), () {
        final slice = tagShareFor(r).slices.where((s) => s.tag == tag).firstOrNull;
        if (slice != null) return (spent: slice.spent, count: slice.count);
        final rows = rowsOfTag(tag, r);
        return (spent: -rows.fold<int>(0, (s, t) => s + t.amount), count: {for (final t in rows) t.tx.id}.length);
      });

  /// [tag] in the month of [r] (`monthIn`) against the month before and the 6-month average.
  CategoryCompare compareTagFor(String tag, DateRange r) =>
      memo(MemoKey('ins.tagcompare', (r.start, r.end, tag)), () => compareTag(tag, txs, monthIn(r), today: today(), currency: currency));

  /// [tag]'s spending per month over [r].
  List<MonthBar> tagBars(String tag, DateRange r) =>
      memo(MemoKey('ins.tagtrend', (r.start, r.end, tag)), () => tagTrend(tag, txs, r, today: today(), currency: currency));
}
