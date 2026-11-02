// Explore (ENG E4, docs/context/ENG_UI_SPEC.md §5.3): ask one question of the whole history. A query bar (measure, series, bucket size, range)
// over a line chart with a crosshair tooltip, and the same numbers as a table under it. Beside it (desktop) or below it (phone): a heatmap
// of the first series, "do two series move together?" and the saved views. All sums are core's (`runQuery`, `heatmap`, `moveTogether`),
// cached by the controller per data version; nothing is computed here.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../explore_text.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/explore_chart.dart';
import '../widgets/sheets.dart';
import 'insights.dart';
import 'search.dart';

final _log = Logger('bw.explore.ui');

const _kinds = {
  SeriesKind.mainTag: 'Main tag',
  SeriesKind.tag: 'Tag or project',
  SeriesKind.payee: 'Payee',
  SeriesKind.account: 'Account',
};

/// How many series the chart takes (one data colour each).
const maxSeries = 6;

/// More series than this become small multiples instead of lines on one chart.
const maxLines = 4;

/// Rows of the table before "Show more".
const tableRows = 24;

Color seriesColor(WalletColors c, int i) => [c.s1, c.s2, c.s3, c.s4, c.s5, c.s6][i % 6];

class ExploreScreen extends StatefulWidget {
  final WalletController wc;

  /// Counts the Ctrl+F / Ctrl+K presses; the search view opens on each.
  final Listenable? searchRequest;
  final void Function(int tab)? openTab;
  final VoidCallback? openBills;

  /// The segmented switch the Explore tab puts on top (null when the page stands alone).
  final Widget? switcher;
  final FileChooser chooser;
  const ExploreScreen(
      {super.key, required this.wc, this.searchRequest, this.openTab, this.openBills, this.switcher, this.chooser = const FileChooser()});
  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  WalletController get wc => widget.wc;
  Measure _measure = Measure.spent;
  List<SeriesKey>? _keys; // null = the controller's defaults
  String _range = '3y'; // 1y 3y 5y All, or custom (a loaded view)
  DateRange? _custom;
  Bucket? _bucket; // null = the size the window calls for
  SeriesKey? _moveA, _moveB;
  HeatCell? _heatPick;
  int _shown = tableRows;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    widget.searchRequest?.addListener(_openSearch);
  }

  @override
  void didUpdateWidget(ExploreScreen old) {
    super.didUpdateWidget(old);
    if (old.searchRequest != widget.searchRequest) {
      old.searchRequest?.removeListener(_openSearch);
      widget.searchRequest?.addListener(_openSearch);
    }
  }

  @override
  void dispose() {
    widget.searchRequest?.removeListener(_openSearch);
    super.dispose();
  }

  void _openSearch() {
    if (mounted && !_searching) setState(() => _searching = true);
  }

  List<SeriesKey> get keys => _keys ?? wc.exploreDefaultKeys();

  DateRange _window() => _custom ?? wc.exploreWindow(_range);

  bool _fits(DateRange w, Bucket b) {
    try {
      bucketsOf(w, b);
      return true;
    } on ArgumentError {
      return false; // day, week and month buckets stop at 5 years
    }
  }

  Bucket _bucketFor(DateRange w) {
    final b = _bucket ?? bucketFor(w, maxBars: 72);
    return _fits(w, b) ? b : Bucket.quarter;
  }

  SeriesQuery _query() {
    final w = _window();
    return SeriesQuery(measure: _measure, keys: keys, bucket: _bucketFor(w), window: w);
  }

  void _setRange(String r) {
    logNav('explore.range', {'range': r});
    setState(() {
      _range = r;
      _custom = null;
      _shown = tableRows;
    });
  }

  Future<void> _addSeries() async {
    final taken = keys.toSet();
    final k = await showSheet<SeriesKey>(context, SeriesPickerSheet(wc: wc, taken: taken));
    if (k == null || !mounted) return;
    logNav('explore.add', {'kind': k.kind.name});
    setState(() => _keys = [...keys, k]);
  }

  void _removeSeries(SeriesKey k) => setState(() {
        _keys = [...keys]..remove(k);
        if (_moveA == k) _moveA = null;
        if (_moveB == k) _moveB = null;
      });

  Future<void> _save(SeriesQuery q) async {
    final name = await _askName(context, 'Save view', q.keys.map(wc.seriesLabel).join(', '));
    if (name == null || !mounted) return;
    try {
      wc.saveExploreView(name, q);
      toast(context, 'Saved "$name"');
    } on ArgumentError catch (e) {
      toast(context, e.message.toString());
    }
  }

  void _load(SeriesQuery q) {
    final first = wc.exploreIndex.first, today = wc.today();
    var w = q.window;
    var range = 'custom';
    if (first != null && w.start.compareTo(first) <= 0) {
      w = DateRange(start: first, end: today);
      range = 'All';
    } else {
      // A saved window rolls: the same length, ending today.
      final shift = daysBetween(w.end, today);
      if (shift > 0) w = DateRange(start: addDays(w.start, shift), end: today);
    }
    logNav('explore.view.load', {'series': q.keys.length});
    setState(() {
      _measure = q.measure;
      _keys = q.keys;
      _bucket = q.bucket;
      _range = range;
      _custom = range == 'All' ? null : w;
      _moveA = _moveB = null;
      _heatPick = null;
      _shown = tableRows;
    });
  }

  Future<void> _export(SeriesQuery q) async {
    logNav('export.pressed', {'what': 'explore'});
    final f = wc.exploreCsv(q);
    if (f.rows == 0) {
      toast(context, 'Nothing to export in this range');
      return;
    }
    try {
      final uri = await widget.chooser.saveText(fileName: f.name, bytes: f.bytes, title: 'Save CSV');
      logEvent(_log, Level.INFO, 'export.saved', {'what': 'explore', 'saved': uri != null, 'rows': f.rows});
      if (uri != null && mounted) toast(context, 'Saved ${f.name}');
    } catch (e, st) {
      logError(_log, 'export.saveFailed', e, st, fields: {'type': e.runtimeType.toString()});
      if (mounted) toast(context, chooserFailedMessage);
    }
  }

  @override
  Widget build(BuildContext context) => MarginLine(
          child: IndexedStack(index: _searching ? 1 : 0, sizing: StackFit.expand, children: [
        _page(context),
        if (_searching)
          SearchPane(
              wc: wc,
              onClose: () => setState(() => _searching = false),
              onOpenTab: (i) => widget.openTab?.call(i),
              onOpenBills: () => widget.openBills?.call())
        else
          const SizedBox.shrink(),
      ]));

  Widget _page(BuildContext context) {
    final q = _query();
    final cur = wc.currency;
    final rows = q.keys.isEmpty ? const <QueryRow>[] : wc.exploreRows(q);
    final actions = Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      OutlinedButton(
          key: const ValueKey('exploreSave'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, touchMin)),
          onPressed: q.keys.isEmpty ? null : () => _save(q),
          child: const Text('Save view')),
      OutlinedButton(
          key: const ValueKey('exploreExport'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, touchMin)),
          onPressed: q.keys.isEmpty ? null : () => _export(q),
          child: const Text('Export CSV')),
      TextButton.icon(
        key: const ValueKey('insightsOpen'),
        style: TextButton.styleFrom(minimumSize: const Size(0, touchMin)),
        icon: const Icon(Icons.insights_outlined),
        label: const Text('Insights', maxLines: 1),
        onPressed: () {
          logNav('spending.insights');
          openInsights(context, wc);
        },
      ),
      IconButton(
        key: const ValueKey('searchOpen'),
        tooltip: hasKeyboard ? 'Search (Ctrl+F)' : 'Search',
        icon: const Icon(Icons.search),
        onPressed: () => setState(() => _searching = true),
      ),
    ]);
    final main = <Widget>[
      _queryBar(q),
      if (q.keys.isEmpty)
        const Panel(children: [EmptyNote('Add a main tag, tag, payee or account to see it over time.')])
      else if (rows.isEmpty)
        const Panel(children: [EmptyNote('Nothing to show in this range.')])
      else ...[
        _chartPanel(q, rows, cur),
        _table(q, rows, cur),
      ],
    ];
    final side = <Widget>[
      if (q.keys.isNotEmpty && rows.isNotEmpty) _heatPanel(q, cur),
      _movePanel(q),
      _viewsPanel(),
    ];
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 980;
      return ListView(
        padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
        children: gapped([
          if (widget.switcher != null) widget.switcher!,
          HeadingRow(const Text('Explore', style: TextStyle(fontSize: BwType.displaySize, fontWeight: FontWeight.w800)), actions),
          if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: gapped(main, gap: 16))),
              const SizedBox(width: 16),
              SizedBox(width: 340, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: gapped(side, gap: 16))),
            ])
          else ...[...gapped(main, gap: 16), const SizedBox(height: 2), ...gapped(side, gap: 16)],
        ], gap: 14),
      );
    });
  }

  // ---- query bar ----

  Widget _queryBar(SeriesQuery q) {
    final c = context.c;
    const qw = TextStyle(fontSize: BwType.bodySize, fontWeight: FontWeight.w500);
    Widget word(String s) => Text(s, style: qw.copyWith(color: c.muted));
    final canAdd = q.keys.length < maxSeries;
    return Panel(children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        word('Show'),
        PopupMenuButton<Measure>(
          key: const ValueKey('exploreMeasure'),
          tooltip: 'What to show',
          onSelected: (m) => setState(() => _measure = m),
          itemBuilder: (_) =>
              [for (final m in Measure.values) PopupMenuItem(value: m, key: ValueKey('measure:${m.name}'), child: Text(measureName(m)))],
          child: _Face('${measureName(_measure)} ▾'),
        ),
        word('on'),
        for (var i = 0; i < q.keys.length; i++)
          _SeriesChip(
            key: ValueKey('series:$i'),
            label: wc.seriesLabel(q.keys[i]),
            color: seriesColor(c, i),
            onRemove: () => _removeSeries(q.keys[i]),
          ),
        InkWell(
          key: const ValueKey('exploreAdd'),
          borderRadius: BorderRadius.circular(10),
          onTap: canAdd ? _addSeries : () => toast(context, 'Up to $maxSeries series.'),
          child: const _Face('+ tag, payee or project', dashed: true),
        ),
        word('by'),
        PopupMenuButton<Bucket>(
          key: const ValueKey('exploreBucket'),
          tooltip: 'Bar size',
          onSelected: (b) => setState(() {
            _bucket = b;
            _shown = tableRows;
          }),
          itemBuilder: (_) => [
            for (final b in [Bucket.week, Bucket.month, Bucket.quarter, Bucket.year])
              PopupMenuItem(value: b, key: ValueKey('bucket:${b.name}'), enabled: _fits(q.window, b), child: Text(b.name)),
          ],
          child: _Face('${q.bucket.name} ▾'),
        ),
      ]),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final r in const ['1y', '3y', '5y', 'All'])
          ChoiceChip(
            key: ValueKey('exploreRange:$r'),
            label: Text(r),
            selected: _range == r,
            onSelected: (_) => _setRange(r),
          ),
        if (_range == 'custom')
          Chip(key: const ValueKey('exploreRange:custom'), label: Text('${shortDate(q.window.start)} – ${shortDate(q.window.end)}')),
      ]),
    ]);
  }

  // ---- chart ----

  Widget _chartPanel(SeriesQuery q, List<QueryRow> rows, String cur) {
    final c = context.c;
    final buckets = [for (final r in rows) r.bucket];
    final partial = [for (final r in rows) r.partial];
    final series = [
      for (var i = 0; i < q.keys.length; i++)
        ChartSeries(wc.seriesLabel(q.keys[i]), seriesColor(c, i), [for (final r in rows) r.cents[q.keys[i]] ?? 0]),
    ];
    String bucketText(int i) => exploreBucketLabel(buckets[i], q.bucket);
    String value(int v) => measureValue(_measure, v, cur);
    String axis(int v) => axisValue(_measure, v, cur);
    final spoken =
        '${measureName(_measure)} on ${series.map((s) => s.name).join(', ')} by ${q.bucket.name}, ${shortDate(q.window.start)} to ${shortDate(q.window.end)}. The table below has the exact values.';
    final many = series.length > maxLines;
    final shared = niceRange([for (final s in series) ...s.values]);
    return Panel(key: const ValueKey('exploreChart'), children: [
      Wrap(spacing: 14, runSpacing: 4, children: [
        for (final s in series)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 6),
            Flexible(
                child: Text(s.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: BwType.metaSize, color: c.muted))),
          ]),
      ]),
      if (!many)
        ExploreChart(
            buckets: buckets, partial: partial, series: series, bucketText: bucketText, valueText: value, axisText: axis, spoken: spoken)
      else
        LayoutBuilder(
          builder: (context, box) {
            final cols = box.maxWidth >= 560 ? 2 : 1;
            final w = (box.maxWidth - (cols - 1) * 12) / cols;
            return Wrap(spacing: 12, runSpacing: 12, children: [
              for (final s in series)
                SizedBox(
                  width: w,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ExploreChart(
                        key: ValueKey('multiple:${s.name}'),
                        buckets: buckets,
                        partial: partial,
                        series: [s],
                        bucketText: bucketText,
                        valueText: value,
                        axisText: axis,
                        spoken: '${s.name}: $spoken',
                        range: shared,
                        height: 140,
                        directLabels: false),
                  ]),
                ),
            ]);
          },
        ),
      Muted(hasKeyboard ? 'Hover or tap the chart for exact amounts.' : 'Tap the chart for exact amounts.'),
    ]);
  }

  // ---- table ----

  Widget _table(SeriesQuery q, List<QueryRow> rows, String cur) {
    final c = context.c;
    final newest = rows.reversed.toList();
    final shown = newest.take(_shown).toList();
    final several = q.keys.length > 1;
    // A payment with two of the series' tags is counted once in Together, so it can be less than the sum.
    final overlap = several && rows.any((r) => r.together != r.cents.values.fold<int>(0, (a, b) => a + b));
    const first = 104.0, col = 116.0;
    final head = TextStyle(fontSize: BwType.metaSize, color: c.muted, fontWeight: FontWeight.w600);
    Widget cell(String s, double w, {Key? key, TextStyle? style, bool bold = false}) => SizedBox(
        width: w,
        child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            child: Text(s,
                key: key,
                textAlign: TextAlign.end,
                style: (style ?? numStyle.copyWith(fontSize: 13)).copyWith(fontWeight: bold ? FontWeight.w700 : null))));
    return Panel(key: const ValueKey('exploreTable'), children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            SizedBox(
                width: first,
                child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                    child: Text(q.bucket.name[0].toUpperCase() + q.bucket.name.substring(1), style: head))),
            for (final k in q.keys) cell(wc.seriesLabel(k), col, style: head),
            if (several)
              cell(overlap ? 'Together · overlaps counted once' : 'Together', col, key: const ValueKey('exploreTogetherHead'), style: head),
          ]),
          for (final r in shown)
            DecoratedBox(
              key: ValueKey('exploreRow:${r.bucket.start}'),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: c.line))),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                    width: first,
                    child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                        child: Text('${exploreBucketLabel(r.bucket, q.bucket)}${r.partial ? ' · so far' : ''}',
                            style: const TextStyle(fontSize: 13)))),
                for (var i = 0; i < q.keys.length; i++)
                  cell(measureValue(_measure, r.cents[q.keys[i]] ?? 0, cur), col, key: ValueKey('exploreCell:${r.bucket.start}:$i')),
                if (several)
                  cell(measureValue(_measure, r.together, cur), col, key: ValueKey('exploreCell:${r.bucket.start}:together'), bold: true),
              ]),
            ),
        ]),
      ),
      if (newest.length > shown.length)
        TextButton(
            key: const ValueKey('exploreMore'),
            style: TextButton.styleFrom(minimumSize: const Size(0, touchMin)),
            onPressed: () => setState(() => _shown += 60),
            child: Text('Show more (${newest.length - shown.length} left)')),
    ]);
  }

  // ---- side panels ----

  Widget _heatPanel(SeriesQuery q, String cur) {
    final c = context.c;
    final key = q.keys.first;
    final cells = wc.exploreHeat(key, _measure);
    if (cells.isEmpty) return const SizedBox.shrink();
    final byYear = <int, Map<int, HeatCell>>{};
    for (final h in cells) {
      (byYear[h.year] ??= {})[h.month] = h;
    }
    final sentence = topMonthSentence(cells, int.parse(wc.today().substring(0, 4)), _measure);
    final pick = _heatPick;
    return Panel(key: const ValueKey('exploreHeat'), children: [
      Eyebrow('${wc.seriesLabel(key)} · month × year'),
      Column(children: [
        Row(children: [
          const SizedBox(width: 40),
          for (final m in 'JFMAMJJASOND'.split('')) Expanded(child: Center(child: Text(m, style: TextStyle(fontSize: 10, color: c.muted)))),
        ]),
        for (final y in byYear.keys.toList()..sort())
          // One spoken label per year row (every month's value); the cells are 22 dp to look at but the whole 48 dp band is the target.
          Semantics(
            container: true,
            label: '$y: ${[
              for (var m = 1; m <= 12; m++)
                if (byYear[y]![m] case final h?)
                  '${monthShort('$y-${m.toString().padLeft(2, '0')}')} ${measureValue(_measure, h.cents, cur)}'
            ].join(', ')}',
            child: ExcludeSemantics(
              child: Row(children: [
                SizedBox(width: 40, child: Text('$y', style: monoSmall(c))),
                for (var m = 1; m <= 12; m++) Expanded(child: _heatCell(c, y, m, byYear[y]![m], pick)),
              ]),
            ),
          ),
      ]),
      SplitRow(
        start: Text('less', style: TextStyle(fontSize: 12, color: c.muted)),
        end: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final h in c.heat)
            Container(
                width: 16,
                height: 10,
                margin: const EdgeInsets.only(left: 3),
                decoration: BoxDecoration(color: h, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 6),
          Text('more', style: TextStyle(fontSize: 12, color: c.muted)),
        ]),
        maxEnd: 0.8,
      ),
      Text(
          pick == null
              ? 'Tap a month for its exact amount.'
              : '${monthYear(pick.year, pick.month)} · ${measureValue(_measure, pick.cents, cur)}',
          key: const ValueKey('heatReadout'),
          style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
      if (sentence != null) Text(sentence, key: const ValueKey('heatSentence')),
    ]);
  }

  Widget _heatCell(WalletColors c, int y, int m, HeatCell? h, HeatCell? pick) {
    final box = Container(
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 1.5),
      decoration: BoxDecoration(
        color: h == null ? null : c.heat[h.level],
        borderRadius: BorderRadius.circular(3),
        border: h == null ? Border.all(color: c.line) : (pick == h ? Border.all(color: c.ink, width: 1.5) : null),
      ),
    );
    final band = SizedBox(height: touchMin, child: Center(child: box));
    if (h == null) return band;
    return InkWell(
      key: ValueKey('heat:$y-${m.toString().padLeft(2, '0')}'),
      borderRadius: BorderRadius.circular(3),
      onTap: () => setState(() => _heatPick = h),
      child: band,
    );
  }

  TextStyle monoSmall(WalletColors c) => TextStyle(fontSize: 11, color: c.muted, fontFamily: monoFamily);

  Widget _movePanel(SeriesQuery q) {
    final c = context.c;
    final a = _moveA ?? (q.keys.isNotEmpty ? q.keys.first : null);
    final b = _moveB ?? (q.keys.length > 1 ? q.keys[1] : null);
    Future<void> pick(bool first) async {
      final k = await showSheet<SeriesKey>(context, SeriesPickerSheet(wc: wc, taken: const {}));
      if (k != null && mounted) setState(() => first ? _moveA = k : _moveB = k);
    }

    Widget chip(SeriesKey? k, bool first) => InkWell(
        key: ValueKey(first ? 'moveA' : 'moveB'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => pick(first),
        child: _Face(k == null ? 'Pick one ▾' : '${wc.seriesLabel(k)} ▾'));
    final m = a != null && b != null && a != b ? wc.exploreMove(a, b, q.window) : null;
    final ready = a != null && b != null && a != b;
    return Panel(key: const ValueKey('exploreMove'), children: [
      const Eyebrow('Do two series move together?'),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        chip(a, true),
        Text('vs', style: TextStyle(color: c.muted)),
        chip(b, false),
      ]),
      if (!ready)
        const Muted('Pick two different series.')
      else ...[
        Wrap(spacing: 10, crossAxisAlignment: WrapCrossAlignment.end, children: [
          if (m != null)
            Text(strengthText(m.strength),
                key: const ValueKey('moveStrength'), style: numStyle.copyWith(fontSize: 30, fontWeight: FontWeight.w700)),
          Text(moveWords(m), key: const ValueKey('moveWords'), style: TextStyle(fontSize: BwType.bodySize, color: c.ink2)),
        ]),
        const Muted("Compares monthly spending. Moving together isn't proof that one causes the other."),
      ],
    ]);
  }

  // Only this panel listens: a view write changes no payment, so the rest of the page keeps as it is.
  Widget _viewsPanel() => ListenableBuilder(
        listenable: wc,
        builder: (context, _) {
          final views = wc.exploreViews();
          return Panel(key: const ValueKey('exploreViews'), children: [
            const Eyebrow('Saved views'),
            if (views.isEmpty)
              const Muted('Save a question to come back to it. Pin it to show it on Overview.')
            else
              Rows(children: [for (final v in views) _viewRow(v)]),
          ]);
        },
      );

  Widget _viewRow(SavedView v) {
    final c = context.c;
    final q = v.parsed;
    return Row(children: [
      Expanded(
        child: InkWell(
          key: ValueKey('view:${v.id}'),
          onTap: q == null ? null : () => _load(q),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: rowMin),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text.rich(TextSpan(children: [
                  if (v.pinned)
                    const WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.push_pin, size: 14))),
                  TextSpan(text: v.name),
                  if (q == null) TextSpan(text: '  needs a newer app', style: TextStyle(color: c.muted, fontSize: BwType.metaSize)),
                ])),
              ),
            ),
          ),
        ),
      ),
      PopupMenuButton<String>(
        key: ValueKey('viewMenu:${v.id}'),
        tooltip: 'View actions',
        onSelected: (a) => _viewAction(v, a),
        itemBuilder: (_) => [
          PopupMenuItem(value: 'pin', key: const ValueKey('viewPin'), child: Text(v.pinned ? 'Unpin' : 'Pin to Overview')),
          const PopupMenuItem(value: 'rename', key: ValueKey('viewRename'), child: Text('Rename')),
          const PopupMenuItem(value: 'delete', key: ValueKey('viewDelete'), child: Text('Delete')),
        ],
      ),
    ]);
  }

  Future<void> _viewAction(SavedView v, String a) async {
    switch (a) {
      case 'pin':
        wc.pinExploreView(v.id, !v.pinned);
      case 'rename':
        final name = await _askName(context, 'Rename view', v.name);
        if (name == null || !mounted) return;
        try {
          wc.renameExploreView(v.id, name);
        } on ArgumentError catch (e) {
          toast(context, e.message.toString());
        }
      case 'delete':
        wc.deleteExploreView(v.id);
        toast(context, 'Deleted "${v.name}"', actionLabel: 'Undo', onAction: () => wc.undeleteExploreView(v.id));
    }
  }
}

/// The name dialog of Save view and Rename.
Future<String?> _askName(BuildContext context, String title, String initial) =>
    showDialog<String>(context: context, builder: (ctx) => _NameDialog(title: title, initial: initial));

class _NameDialog extends StatefulWidget {
  final String title, initial;
  const _NameDialog({required this.title, required this.initial});
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _ctl = TextEditingController(
      text: widget.initial.length > ViewCols.maxName ? widget.initial.substring(0, ViewCols.maxName) : widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          key: const ValueKey('viewName'),
          controller: _ctl,
          autofocus: true,
          maxLength: ViewCols.maxName,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(key: const ValueKey('viewNameCancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('viewNameSave'), onPressed: () => Navigator.pop(context, _ctl.text), child: const Text('Save')),
        ],
      );
}

/// A chip face for the query bar: border, label, 48 dp tall. The caller adds the tap.
class _Face extends StatelessWidget {
  final String text;
  final bool dashed;
  const _Face(this.text, {this.dashed = false});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    // A Container with an alignment would fill the whole row of a Wrap: size to the text and centre it in a 48 dp box instead.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: touchMin),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.lineStrong),
          ),
          child: Text(text,
              maxLines: 2, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: BwType.bodySize)),
        ),
      ),
    );
  }
}

class _SeriesChip extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onRemove;
  const _SeriesChip({super.key, required this.label, required this.color, required this.onRemove});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      constraints: const BoxConstraints(minHeight: touchMin),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.lineStrong)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 8),
        Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: BwType.bodySize))),
        IconButton(
          key: const ValueKey('seriesRemove'),
          tooltip: 'Remove $label',
          constraints: const BoxConstraints(minWidth: touchMin, minHeight: touchMin),
          icon: const Icon(Icons.close, size: 16),
          onPressed: onRemove,
        ),
      ]),
    );
  }
}

/// "+ tag, payee or project": the four kinds of series with a search box. Pops the chosen [SeriesKey].
class SeriesPickerSheet extends StatefulWidget {
  final WalletController wc;
  final Set<SeriesKey> taken;
  const SeriesPickerSheet({super.key, required this.wc, required this.taken});
  @override
  State<SeriesPickerSheet> createState() => _SeriesPickerSheetState();
}

class _SeriesPickerSheetState extends State<SeriesPickerSheet> {
  SeriesKind _kind = SeriesKind.mainTag;
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final all = wc.seriesChoices(_kind).where((s) => !widget.taken.contains(s.key)).toList();
    final needle = _q.trim().toLowerCase();
    final hits = [
      for (final s in all)
        if (needle.isEmpty || s.label.toLowerCase().contains(needle)) s
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      const Heading('Add a series', size: BwType.headingSize),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final e in _kinds.entries)
          ChoiceChip(
            key: ValueKey('seriesKind:${e.key.name}'),
            label: Text(e.value),
            selected: _kind == e.key,
            onSelected: (_) => setState(() => _kind = e.key),
          ),
      ]),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('seriesSearch'),
        decoration: const InputDecoration(labelText: 'Search', prefixIcon: Icon(Icons.search)),
        onChanged: (v) => setState(() => _q = v),
      ),
      if (hits.isEmpty)
        const EmptyNote('Nothing to add here.')
      else
        for (final s in hits.take(40))
          InkWell(
            key: ValueKey('seriesPick:${s.key.kind.name}:${s.key.id}'),
            onTap: () => Navigator.pop(context, s.key),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: rowMin),
              child: Align(
                  alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(s.label))),
            ),
          ),
    ]);
  }
}
