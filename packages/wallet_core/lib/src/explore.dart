part of 'series.dart';

// Explore (ENG_UI_SPEC §5.3, §6.3): a query over the [DayIndex] — one measure, several series, one bucket size, any
// window (quarters and years: the whole history). Pure, ints only. Saved queries are the synced entity `view`.

/// What a query sums: spending (the "Where it goes" rule, refunds subtracted), money in (income + extra, as
/// `monthSummary`), kept (money in − spending) or the number of payments out.
enum Measure { spent, cameIn, kept, count }

/// What one series filters on: the row's main tag (its category), an extra tag, a payee (`merchantGroupKey`) or an
/// account (`tx.account`).
enum SeriesKind { mainTag, tag, payee, account }

class SeriesKey {
  final SeriesKind kind;
  final String id;
  const SeriesKey(this.kind, this.id);

  @override
  bool operator ==(Object other) => other is SeriesKey && other.kind == kind && other.id == id;
  @override
  int get hashCode => Object.hash(kind, id);
  @override
  String toString() => 'SeriesKey(${kind.name})';
}

class SeriesQuery {
  final Measure measure;
  final List<SeriesKey> keys;
  final Bucket bucket;
  final DateRange window;
  const SeriesQuery({required this.measure, required this.keys, required this.bucket, required this.window});

  Map<String, Object?> toJson() => {
        'measure': measure.name,
        'keys': [
          for (final k in keys) {'kind': k.kind.name, 'id': k.id}
        ],
        'bucket': bucket.name,
        'window': {'start': window.start, 'end': window.end},
      };

  /// Throws ([ArgumentError], [TypeError]) on anything [toJson] does not write: an unknown name, a missing field, a
  /// bad date.
  factory SeriesQuery.fromJson(Map<String, dynamic> j) {
    final w = j['window'] as Map<String, dynamic>;
    return SeriesQuery(
      measure: Measure.values.byName(j['measure'] as String),
      keys: [
        for (final k in (j['keys'] as List).cast<Map<String, dynamic>>())
          SeriesKey(SeriesKind.values.byName(k['kind'] as String), k['id'] as String)
      ],
      bucket: Bucket.values.byName(j['bucket'] as String),
      window: DateRange(start: w['start'] as String, end: w['end'] as String),
    );
  }
}

/// [ViewCols.query]'s check: null when [text] is a query [SeriesQuery.fromJson] reads.
String? seriesQueryProblem(String text) {
  try {
    SeriesQuery.fromJson(jsonDecode(text) as Map<String, dynamic>);
    return null;
  } catch (_) {
    return 'Not a saved query.';
  }
}

/// One bucket of [runQuery]: exact cents (or a payment count) per key, and [together] = the union of the keys (a row
/// carrying two of them counted once).
class QueryRow {
  final DateRange bucket;
  final bool partial;
  final Map<SeriesKey, int> cents;
  final int together;
  const QueryRow({required this.bucket, required this.partial, required this.cents, required this.together});
}

/// [q] per bucket of its window, oldest first ([bucketsOf]; day, week and month buckets keep the 5-year limit). Spending
/// of a main tag, tag or payee is exactly `spendingSeries` with that filter. [today] marks the partial bucket.
List<QueryRow> runQuery(DayIndex ix, SeriesQuery q, {required String today}) {
  final (lo, hi) = _window(q.window, q.bucket);
  final t = _today(today);
  final out = <QueryRow>[];
  _spans(lo, hi, q.bucket, (s, e, fs, fe) {
    out.add(QueryRow(
      bucket: _range(s, e),
      partial: _isPartial(s, e, fs, fe, t),
      cents: {
        for (final k in q.keys) k: ix._value(q.measure, [k], s, e)
      },
      together: ix._value(q.measure, q.keys, s, e),
    ));
  });
  return out;
}

/// One month of [heatmap].
class HeatCell {
  final int year, month;
  final int cents;

  /// 0 = nothing (or below zero); 1–4 = the quartile of [cents] among the map's cells above zero.
  final int level;
  const HeatCell({required this.year, required this.month, required this.cents, required this.level});
}

/// [measure] of [key] per calendar month, from January of the index's first year to [today]'s month, oldest first.
/// Level by quartile of the cells above zero (ties share a level: a cell's rank = the cells below it).
List<HeatCell> heatmap(DayIndex ix, SeriesKey key, {required String today, Measure measure = Measure.spent}) {
  final first = ix.first;
  if (first == null) return const [];
  final (y0, _, _) = _civil(_epoch(first));
  final (y1, m1, _) = _civil(_today(today));
  final cells = <(int, int, int)>[];
  for (var y = y0; y <= y1; y++) {
    for (var m = 1; m <= (y == y1 ? m1 : 12); m++) {
      final (s, e) = _bucketAt(_days(y, m, 1), Bucket.month);
      cells.add((y, m, ix._value(measure, [key], s, e)));
    }
  }
  final pos = [
    for (final c in cells)
      if (c.$3 > 0) c.$3
  ]..sort();
  int below(int v) {
    var a = 0, b = pos.length;
    while (a < b) {
      final mid = (a + b) >> 1;
      if (pos[mid] < v) {
        a = mid + 1;
      } else {
        b = mid;
      }
    }
    return a;
  }

  return [for (final (y, m, c) in cells) HeatCell(year: y, month: m, cents: c, level: c > 0 ? 1 + 4 * below(c) ~/ pos.length : 0)];
}

/// How closely two series' monthly spending moves together over [window].
class MoveTogether {
  /// Pearson r in permille, signed (−1000…1000).
  final int strength;

  /// Months counted: those where both series spent (as findings' movesTogether).
  final int months;
  final String from, to;
  const MoveTogether({required this.strength, required this.months, required this.from, required this.to});
}

/// Spending of [a] and [b] per calendar month of [window] (clipped at its edges; no length limit), over the months
/// where both are nonzero, as findings' movesTogether (`pearsonPermille`). Null when either side is flat there.
MoveTogether? moveTogether(DayIndex ix, SeriesKey a, SeriesKey b, DateRange window) {
  final xs = <int>[], ys = <int>[], spans = <(int, int)>[];
  _spans(_epoch(window.start), _epoch(window.end), Bucket.month, (s, e, fs, fe) {
    final x = ix._value(Measure.spent, [a], s, e), y = ix._value(Measure.spent, [b], s, e);
    if (x == 0 || y == 0) return;
    xs.add(x);
    ys.add(y);
    spans.add((s, e));
  });
  final r = pearsonPermille(xs, ys);
  if (r == null) return null;
  return MoveTogether(strength: r, months: xs.length, from: _iso(spans.first.$1), to: _iso(spans.last.$2));
}

extension _Query on DayIndex {
  /// [m] over epoch days [s]..[e] of the rows matching any of [keys].
  int _value(Measure m, List<SeriesKey> keys, int s, int e) => switch (m) {
        Measure.kept => _sum(_prefix(Measure.cameIn, keys), s, e) - _sum(_prefix(Measure.spent, keys), s, e),
        _ => _sum(_prefix(m, keys), s, e),
      };

  /// Prefix sums over [_days] of [m] (not kept) for the rows matching any of [keys]; made on first use and kept. One
  /// main tag, tag or payee's spending is [_spentPrefix] itself, so it equals `spendingSeries`.
  List<int> _prefix(Measure m, List<SeriesKey> keys) {
    if (m == Measure.spent && keys.length == 1 && keys.single.kind != SeriesKind.account) {
      final k = keys.single;
      return _spentPrefix(
          k.kind == SeriesKind.mainTag ? k.id : null, k.kind == SeriesKind.tag ? k.id : null, k.kind == SeriesKind.payee ? k.id : null);
    }
    final ck = '${m.name}\u0001${keys.map((k) => '${k.kind.index}:${k.id}').join('\u0001')}';
    final hit = _cache[ck];
    if (hit != null) return hit;
    final money = m == Measure.cameIn;
    final rows = money ? _money : _rows, day = money ? _moneyDay : _rowDay, merchant = money ? _moneyMerchant : _merchant;
    final p = List<int>.filled(this._days.length + 1, 0); // `this.`: the top-level _days() shadows the field here
    for (var i = 0; i < rows.length; i++) {
      final t = rows[i];
      final hit = keys.any((k) => switch (k.kind) {
            SeriesKind.mainTag => t.category == k.id,
            SeriesKind.tag => t.tags.contains(k.id),
            SeriesKind.payee => (merchant[i] ??= _keyOf(t.tx)) == k.id,
            SeriesKind.account => t.tx.account ==
                k.id, // shortcut: rows without tx.account (the main account's) match no key; pass accounts if Explore needs RowAccounts' fallback
          });
      if (!hit) continue;
      p[day[i] + 1] += switch (m) {
        Measure.spent => -t.amount,
        Measure.count => t.amount < 0 ? 1 : 0,
        _ => t.amount,
      };
    }
    for (var i = 1; i < p.length; i++) {
      p[i] += p[i - 1];
    }
    return _cache[ck] = p;
  }
}

/// The columns of the synced entity `view` (table `views`): a saved Explore query; [pinned] ones show on Overview.
abstract final class ViewCols {
  static const entity = 'view';
  static const maxName = 60;
  static const name = TextCol(entity, 'name', label: 'Name', maxLength: maxName);
  static const query = JsonCol(entity, 'query', label: 'Query', check: seriesQueryProblem);
  static const pinned = FlagCol(entity, 'pinned', label: 'Pinned');
  static const sort = IntCol(entity, 'sort', label: 'Order', nullable: true);
  static const deleted = FlagCol(entity, 'deleted', label: 'Deleted');

  static const all = <Col>[name, query, pinned, sort, deleted];
}

/// A live saved view (`WalletRepo.views`).
class SavedView {
  final String id, name;

  /// The query as stored (JSON of [SeriesQuery.toJson]).
  final String query;
  final bool pinned;
  final int? sort;
  const SavedView({required this.id, required this.name, required this.query, required this.pinned, this.sort});

  /// The query, or null when this build cannot read it (written by a newer one).
  SeriesQuery? get parsed => seriesQueryProblem(query) == null ? SeriesQuery.fromJson(jsonDecode(query) as Map<String, dynamic>) : null;
}
