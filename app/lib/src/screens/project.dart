// Project (ENG E5, docs/context/ENG_UI_SPEC.md §5.4): any extra tag seen as a project. What it cost, how it built up, what it went on, and
// the payments at the same places that are not tagged yet. Every figure is core's `projectStats` (cached by the controller); the total is
// the sum of the tagged rows, of the main-tag rows and of the year chips. "Still coming" is not here: planned costs carry no tags yet.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../explore_text.dart';
import '../format.dart';
import '../layout.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// Opens the project of extra tag [tag] (a page on a phone, a dialog from 600 dp).
Future<void> openProject(BuildContext context, WalletController wc, String tag) =>
    openPageOrDialog<void>(context, ProjectScreen(wc: wc, tag: tag), width: 840, logName: 'ProjectScreen');

class ProjectScreen extends StatefulWidget {
  final WalletController wc;
  final String tag;
  const ProjectScreen({super.key, required this.wc, required this.tag});
  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  int? _year; // null = all years
  bool _reviewing = false;

  /// Payments skipped in this review: hidden until the screen is opened again. The tag flow has no "not this one" mark for a payment
  /// that never carried the tag (`setTxTag` off is a no-op there), so a skip is not written.
  final _skipped = <String>{};

  WalletController get wc => widget.wc;

  Future<void> _tag(List<Tx> rows, {required bool on, required String done}) async {
    final ids = [for (final t in rows) t.id];
    await wc.tagPayments(ids, widget.tag, on);
    if (!mounted) return;
    toast(context, done, actionLabel: 'Undo', onAction: () => wc.tagPayments(ids, widget.tag, !on));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: wc,
        builder: (context, _) {
          final s = wc.projectOf(widget.tag);
          final name = '#${wc.tagTable.label(widget.tag)}';
          return Scaffold(
            appBar: DialogAppBar(title: name),
            body: ColoredBox(
              color: context.c.desk,
              child: ListView(
                key: const ValueKey('projectPage'),
                padding: const EdgeInsets.fromLTRB(pagePad, 12, pagePad, 88),
                children: gapped([
                  const Eyebrow('Project · tag'),
                  if (s.isEmpty)
                    const Panel(key: ValueKey('projectEmpty'), children: [EmptyNote('Nothing is tagged with this yet.')])
                  else ...[
                    _summary(s),
                    _running(s),
                    _split(s),
                    if (_open(s).isNotEmpty) _nudge(s),
                    if (s.overlaps.isNotEmpty) _overlap(s),
                  ],
                ], gap: 16),
              ),
            ),
          );
        },
      );

  Widget _summary(ProjectStats s) {
    final c = context.c, cur = wc.currency;
    return Panel(key: const ValueKey('projectSummary'), children: [
      Text(projectSpanText(s), key: const ValueKey('projectSpan'), style: TextStyle(fontSize: BwType.metaSize, color: c.muted)),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(moneyExact(s.total, cur),
            key: const ValueKey('projectTotal'), style: numStyle.copyWith(fontSize: 44, fontWeight: FontWeight.w700)),
      ),
      Text.rich(
        key: const ValueKey('projectShare'),
        TextSpan(children: [
          TextSpan(
              text: s.sharePermille > 0
                  ? '${permilleText(s.sharePermille)} of everything you spent in that time'
                  : 'Share of your spending: none'),
          if (s.hoursTenths != null) ...[
            const TextSpan(text: ' · about '),
            TextSpan(text: hoursText(s.hoursTenths!), style: numStyle.copyWith(color: c.ink)),
            const TextSpan(text: ' of work'),
          ],
        ]),
        style: TextStyle(fontSize: BwType.bodySize, color: c.ink2),
      ),
    ]);
  }

  Widget _running(ProjectStats s) {
    final c = context.c, cur = wc.currency;
    final years = [for (final y in s.byYear) y.$1];
    final yearTotal = _year == null ? s.total : s.byYear.firstWhere((y) => y.$1 == _year).$2;
    final slot = wc.tagTable.liveIds.indexOf(widget.tag).clamp(0, 5);
    final color = [c.s1, c.s2, c.s3, c.s4, c.s5, c.s6][slot];
    return Panel(key: const ValueKey('projectRunning'), children: [
      HeadingRow(
        const Heading('Running total', size: BwType.headingSize),
        Text(_year == null ? 'all years: ${moneyExact(s.total, cur)}' : '$_year: ${moneyExact(yearTotal, cur)}',
            key: const ValueKey('projectYearText'), style: numStyle.copyWith(fontSize: BwType.metaSize, color: c.muted)),
      ),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final y in <int?>[null, ...years])
          ChoiceChip(
            key: ValueKey('projectYear:${y ?? 'All'}'),
            label: Text(y == null ? 'All' : '$y'),
            selected: _year == y,
            onSelected: (_) => setState(() => _year = y),
          ),
      ]),
      Semantics(
        label: 'Running total from ${s.running.first.$1} to ${s.running.last.$1}, ending at ${moneyExact(s.total, cur)}.',
        image: true,
        child: ExcludeSemantics(
          child: SizedBox(
            height: 150,
            child: CustomPaint(
              key: const ValueKey('projectChart'),
              size: Size.infinite,
              painter: _RunningPainter(s.running, _year, color, c.lineStrong, c.muted, c.ink),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _split(ProjectStats s) {
    final c = context.c, cur = wc.currency;
    // The five biggest main tags, the rest as "Other": the rows still add up to the total.
    final parts = <(String, int)>[for (final p in s.byMainTag.take(5)) (wc.categoryTable.label(p.$1), p.$2)];
    final rest = s.byMainTag.skip(5).fold<int>(0, (a, p) => a + p.$2);
    if (s.byMainTag.length > 5) parts.add(('Other', rest));
    final colors = [c.s1, c.s2, c.s3, c.s4, c.s5, c.s6];
    final bar = [
      for (var i = 0; i < parts.length; i++)
        if (parts[i].$2 > 0) (i, parts[i].$2)
    ];
    final sum = bar.fold<int>(0, (a, b) => a + b.$2);
    return Panel(key: const ValueKey('projectSplit'), padding: const EdgeInsets.only(top: 12), children: [
      const Heading('What it went on', size: BwType.headingSize),
      if (sum > 0)
        Semantics(
          label: parts.map((p) => '${p.$1} ${moneyExact(p.$2, cur)}').join('; '),
          child: ExcludeSemantics(
            child: SizedBox(
              height: 14,
              child: Row(children: [
                for (var j = 0; j < bar.length; j++) ...[
                  if (j > 0) const SizedBox(width: 2),
                  Expanded(
                    flex: (bar[j].$2 * 1000 ~/ sum).clamp(1, 1000),
                    child: DecoratedBox(
                        decoration: BoxDecoration(
                            color: colors[bar[j].$1],
                            borderRadius: BorderRadius.horizontal(
                                left: Radius.circular(j == 0 ? 4 : 0), right: Radius.circular(j == bar.length - 1 ? 4 : 0)))),
                  ),
                ],
              ]),
            ),
          ),
        ),
      Rows(children: [
        for (var i = 0; i < parts.length; i++)
          LineItem(parts[i].$1, moneyExact(parts[i].$2, cur),
              key: ValueKey('projectPart:$i'),
              leading:
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: colors[i], borderRadius: BorderRadius.circular(3)))),
      ]),
    ]);
  }

  List<Tx> _open(ProjectStats s) => [
        for (final t in s.candidates)
          if (!_skipped.contains(t.id)) t
      ];

  Widget _nudge(ProjectStats s) {
    final c = context.c, cur = wc.currency, rows = _open(s), n = rows.length;
    final tagName = wc.tagTable.label(widget.tag);
    final card = Panel(
      key: const ValueKey('projectNudge'),
      color: c.accentSoft,
      children: [
        Row(children: [
          Icon(Icons.sell_outlined, color: c.accent),
          const SizedBox(width: 12),
          Expanded(child: Text("$n ${n == 1 ? 'payment' : 'payments'} at the same places ${n == 1 ? "isn't" : "aren't"} tagged yet.")),
        ]),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: const ValueKey('projectReview'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, touchMin)),
            onPressed: () => setState(() => _reviewing = !_reviewing),
            child: Text(_reviewing ? 'Close' : 'Review $n'),
          ),
        ),
      ],
    );
    if (!_reviewing) return card;
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: gapped([
          card,
          Panel(key: const ValueKey('projectCandidates'), children: [
            HeadingRow(
              Heading('Tag as #$tagName?', size: BwType.headingSize),
              FilledButton(
                key: const ValueKey('projectTagAll'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, touchMin)),
                onPressed: () => _tag(rows, on: true, done: n == 1 ? 'Tagged 1 payment' : 'Tagged $n payments'),
                child: Text('Tag all $n'),
              ),
            ),
            const Muted('Skip hides a payment until you open this page again. Tag has Undo.'),
            Rows(children: [
              for (final t in rows)
                Padding(
                  key: ValueKey('candidate:${t.id}'),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SplitRow(
                      start: Text(merchantName(t),
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                      end: Text(moneyExact(-t.amount, cur), style: numStyle, textAlign: TextAlign.end),
                    ),
                    Text(longDateOrRaw(t.date), style: TextStyle(fontSize: BwType.metaSize, color: c.muted)),
                    const SizedBox(height: 4),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      FilledButton.tonal(
                          key: ValueKey('projectTag:${t.id}'),
                          style: FilledButton.styleFrom(minimumSize: const Size(0, touchMin)),
                          onPressed: () => _tag([t], on: true, done: 'Tagged'),
                          child: const Text('Tag')),
                      TextButton(
                          key: ValueKey('projectSkip:${t.id}'),
                          style: TextButton.styleFrom(minimumSize: const Size(0, touchMin)),
                          // shortcut: Skip only hides the row for this visit; the decision is "not this project" and should be saved as an off link,
                          // which needs core's setTxTag(off) to write one when no link exists. Switch to tagPayments(.., on: false) then.
                          onPressed: () => setState(() => _skipped.add(t.id)),
                          child: const Text('Skip')),
                    ]),
                  ]),
                ),
            ]),
          ]),
        ], gap: 12));
  }

  Widget _overlap(ProjectStats s) {
    final t = wc.tagTable;
    final others = s.overlaps.map((o) => '#${t.label(o.$1)} on ${o.$2} ${o.$2 == 1 ? 'payment' : 'payments'}').join(', ');
    return Panel(key: const ValueKey('projectOverlap'), children: [
      Muted('Also tagged $others. Those payments count in each of the tags.'),
    ]);
  }
}

/// The running total as a step line over a light area, with a tick at each January and the chosen year as a band.
class _RunningPainter extends CustomPainter {
  final List<(String, int)> running;
  final int? year;
  final Color color, axis, muted, ink;
  _RunningPainter(this.running, this.year, this.color, this.axis, this.muted, this.ink);

  @override
  void paint(Canvas canvas, Size size) {
    final n = running.length;
    const top = 8.0, bottomPad = 20.0;
    final base = size.height - bottomPad;
    var lo = 0, hi = 0;
    for (final r in running) {
      if (r.$2 < lo) lo = r.$2;
      if (r.$2 > hi) hi = r.$2;
    }
    if (hi == lo) hi = lo + 1;
    double y(int v) => base - (v - lo) / (hi - lo) * (base - top);
    double x(int i) => n == 1 ? size.width / 2 : 2 + (size.width - 4) * i / (n - 1);
    if (year != null) {
      final idx = [
        for (var i = 0; i < n; i++)
          if (running[i].$1.startsWith('$year')) i
      ];
      if (idx.isNotEmpty) {
        final a = x(idx.first) - (idx.first == 0 ? 0 : (x(1) - x(0)) / 2), b = x(idx.last) + (idx.last == n - 1 ? 0 : (x(1) - x(0)) / 2);
        canvas.drawRect(Rect.fromLTRB(a, top - 2, b, base), Paint()..color = ink.withValues(alpha: 0.08));
      }
    }
    canvas.drawLine(Offset(0, y(0)), Offset(size.width, y(0)), Paint()..color = axis);
    final line = Path()..moveTo(x(0), y(0));
    var prev = 0;
    for (var i = 0; i < n; i++) {
      line.lineTo(x(i), y(prev));
      line.lineTo(x(i), y(running[i].$2));
      prev = running[i].$2;
    }
    final area = Path.from(line)
      ..lineTo(x(n - 1), y(0))
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.16));
    canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round);
    var lastLabel = -100.0;
    for (var i = 0; i < n; i++) {
      if ((i == 0 || running[i].$1.endsWith('-01')) && x(i) - lastLabel >= 44) {
        lastLabel = x(i);
        canvas.drawLine(Offset(x(i), base - 4), Offset(x(i), base + 4), Paint()..color = axis);
        final t = TextPainter(
            text: TextSpan(text: running[i].$1.substring(0, 4), style: TextStyle(color: muted, fontSize: 11, fontFamily: monoFamily)),
            textDirection: TextDirection.ltr)
          ..layout();
        t.paint(canvas, Offset((x(i) + 3).clamp(0.0, size.width - t.width), base + 5));
      }
    }
  }

  @override
  bool shouldRepaint(_RunningPainter o) => o.running != running || o.year != year || o.color != color;
}
