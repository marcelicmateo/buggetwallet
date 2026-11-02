// The new parts of Overview (ENG E2, docs/context/ENG_UI_SPEC.md §5.1): the header, the € | hours switch, "Found this week", "Pinned" and
// the nearest goal. Dumb widgets: everything arrives from [TodayView] already worked out and formatted; the amounts go through
// `view.amount`, which is hours when the switch is on.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dash.dart';
import 'today_view.dart';

/// Eyebrow ("Mon 2 Nov · period day 18/31", opens the period report), the title, and the two icon buttons: ask a question (Explore with
/// search) and Needs you with its count.
class OverviewHeader extends StatelessWidget {
  final String eyebrow;
  final int needsYou;
  final VoidCallback onPeriod, onSearch, onNeedsYou;
  const OverviewHeader(
      {super.key, required this.eyebrow, required this.needsYou, required this.onPeriod, required this.onSearch, required this.onNeedsYou});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            key: const ValueKey('overviewEyebrow'),
            onTap: onPeriod,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: touchMin, minWidth: touchMin),
              child: Align(
                  alignment: Alignment.bottomLeft, child: Text(eyebrow.toUpperCase(), style: BwType.eyebrow.copyWith(color: c.muted))),
            ),
          ),
          const FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text('Overview',
                key: ValueKey('overviewTitle'),
                maxLines: 1,
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
          ),
        ]),
      ),
      const SizedBox(width: 8),
      _IconBox(key: const ValueKey('overviewSearch'), icon: Icons.search, tooltip: 'Ask a question about your money', onTap: onSearch),
      const SizedBox(width: 8),
      _IconBox(
          key: const ValueKey('overviewNeedsYou'),
          icon: Icons.inbox_outlined,
          tooltip: needsYou == 0 ? 'Needs you' : 'Needs you, $needsYou ${needsYou == 1 ? 'item' : 'items'}',
          badge: needsYou,
          onTap: onNeedsYou),
    ]);
  }
}

class _IconBox extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final int badge;
  final VoidCallback onTap;
  const _IconBox({super.key, required this.icon, required this.tooltip, required this.onTap, this.badge = 0});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        onTap: onTap,
        child: Stack(clipBehavior: Clip.none, children: [
          Material(
            color: c.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: c.line)),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: SizedBox(width: touchMin, height: touchMin, child: Icon(icon, size: 20, color: c.ink)),
            ),
          ),
          if (badge > 0)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                key: const ValueKey('needsYouBadge'),
                constraints: const BoxConstraints(minWidth: 18),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(color: c.bad, borderRadius: BorderRadius.circular(999)),
                child: Text('$badge',
                    textAlign: TextAlign.center, style: numStyle.copyWith(fontSize: 11, fontWeight: FontWeight.w700, color: c.bg)),
              ),
            ),
        ]),
      ),
    );
  }
}

/// The € | hours of work switch: a track with two buttons, the chosen one filled. Device-local.
class HoursSwitch extends StatelessWidget {
  final bool hours;
  final String symbol;
  final ValueChanged<bool> onChanged;
  const HoursSwitch({super.key, required this.hours, required this.symbol, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget seg(Key key, String text, bool on, bool toHours) => Semantics(
          button: true,
          selected: on,
          label: text,
          excludeSemantics: true,
          onTap: () => onChanged(toHours),
          child: InkWell(
            key: key,
            borderRadius: BorderRadius.circular(8),
            onTap: () => onChanged(toHours),
            child: Container(
              constraints: const BoxConstraints(minHeight: touchMin, minWidth: touchMin),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: on ? c.lineStrong : null, borderRadius: BorderRadius.circular(8)),
              child: Text(text,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: on ? c.ink : c.muted)),
            ),
          ),
        );
    return Container(
      key: const ValueKey('hoursSwitch'),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.line)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: seg(const ValueKey('amountsMoney'), symbol, !hours, false)),
        Flexible(child: seg(const ValueKey('amountsHours'), 'hours of work', hours, true)),
      ]),
    );
  }
}

/// A section heading with a link on the right ("Found this week" … "All 7 ›").
class OverviewHeading extends StatelessWidget {
  final String text;
  final String? action;
  final Key? actionKey;
  final VoidCallback? onAction;
  const OverviewHeading(this.text, {super.key, this.action, this.actionKey, this.onAction});

  @override
  Widget build(BuildContext context) => HeadingRow(
        Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        action == null
            ? const SizedBox.shrink()
            : TextButton(
                key: actionKey,
                onPressed: onAction,
                style: TextButton.styleFrom(minimumSize: const Size(touchMin, touchMin), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: Text(action!, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              ),
      );
}

/// "Found this week": up to two compact finding cards and "All N ›". Absent (null) without findings.
class FoundSection extends StatelessWidget {
  final TodayView view;
  final VoidCallback onOpen;
  const FoundSection({super.key, required this.view, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final all = view.foundCards();
    if (all.isEmpty) return const SizedBox.shrink();
    // Milestones are the least surprising: they only fill a slot when nothing else was found.
    final first = [
      for (final k in all)
        if (k.finding.kind != FindingKind.milestone) k
    ];
    final shown = (first.isEmpty ? all : first).take(2).toList();
    return Column(key: const ValueKey('foundSection'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      OverviewHeading('Found this week', action: 'All ${all.length} ›', actionKey: const ValueKey('foundAll'), onAction: onOpen),
      const SizedBox(height: 4),
      for (final k in shown) ...[_FoundCard(view: view, card: k, onOpen: onOpen), const SizedBox(height: 8)],
    ]);
  }
}

class _FoundCard extends StatelessWidget {
  final TodayView view;
  final FindingCard card;
  final VoidCallback onOpen;
  const _FoundCard({required this.view, required this.card, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final f = card.finding;
    final cents = [for (final p in f.series) p.$2.toDouble()];
    final Widget mini = switch (f.kind) {
      FindingKind.movesTogether => SizedBox(
          width: 88,
          height: 44,
          child: CustomPaint(painter: _MiniScatter(cents, [for (final p in f.otherSeries) p.$2.toDouble()], c.s5, c.surface))),
      FindingKind.weeklyRhythm => SizedBox(width: 88, height: 44, child: CustomPaint(painter: _MiniBars(cents, c.s1))),
      FindingKind.milestone => SizedBox(
          width: 88,
          child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(groupInt(f.series.first.$2), style: numStyle.copyWith(fontSize: 22, fontWeight: FontWeight.w700, color: c.ink)))),
      _ => SizedBox(width: 88, child: Sparkline(values: cents, color: c.s2, height: 44)),
    };
    return Tile(
      key: ValueKey('foundCard:${f.id}'),
      onTap: onOpen,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      semanticLabel: '${card.sentence}. ${card.basis}',
      child: Row(children: [
        IgnorePointer(child: mini),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(card.sentence, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.3)),
            const SizedBox(height: 2),
            Text(card.basis, style: TextStyle(fontSize: BwType.metaSize, color: c.muted)),
          ]),
        ),
      ]),
    );
  }
}

class _MiniScatter extends CustomPainter {
  final List<double> xs, ys;
  final Color dot, ring;
  _MiniScatter(this.xs, this.ys, this.dot, this.ring);
  @override
  void paint(Canvas canvas, Size size) {
    final n = xs.length < ys.length ? xs.length : ys.length;
    if (n == 0) return;
    double lo(List<double> v) => v.take(n).reduce((a, b) => a < b ? a : b);
    double hi(List<double> v) => v.take(n).reduce((a, b) => a > b ? a : b);
    final x0 = lo(xs), x1 = hi(xs), y0 = lo(ys), y1 = hi(ys);
    for (var i = 0; i < n; i++) {
      final p = Offset(6 + (size.width - 12) * (x1 == x0 ? 0.5 : (xs[i] - x0) / (x1 - x0)),
          size.height - 6 - (size.height - 12) * (y1 == y0 ? 0.5 : (ys[i] - y0) / (y1 - y0)));
      canvas.drawCircle(p, 4.5, Paint()..color = ring);
      canvas.drawCircle(p, 3.5, Paint()..color = dot);
    }
  }

  @override
  bool shouldRepaint(_MiniScatter old) => old.xs != xs || old.ys != ys || old.dot != dot;
}

class _MiniBars extends CustomPainter {
  final List<double> v;
  final Color color;
  _MiniBars(this.v, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    if (v.isEmpty) return;
    final hi = v.reduce((a, b) => a > b ? a : b);
    final w = size.width / v.length;
    for (var i = 0; i < v.length; i++) {
      final h = hi <= 0 ? 2.0 : 2 + (size.height - 2) * v[i] / hi;
      canvas.drawRRect(
          RRect.fromRectAndCorners(Rect.fromLTWH(i * w + 2, size.height - h, w - 4, h),
              topLeft: const Radius.circular(2), topRight: const Radius.circular(2)),
          Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_MiniBars old) => old.v != v || old.color != color;
}

/// "Pinned": the saved views the owner pinned, two tiles across. Nothing (no heading) when none is pinned.
class PinnedSection extends StatelessWidget {
  final TodayView view;
  final VoidCallback onExplore;
  const PinnedSection({super.key, required this.view, required this.onExplore});

  @override
  Widget build(BuildContext context) {
    final pins = view.pins();
    if (pins.isEmpty) return const SizedBox.shrink();
    final c = context.c;
    final colors = [c.s1, c.s2, c.s3, c.s4, c.s5, c.s6];
    return Column(key: const ValueKey('pinnedSection'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      OverviewHeading('Pinned', action: '+ Pin a series', actionKey: const ValueKey('pinAdd'), onAction: onExplore),
      const SizedBox(height: 4),
      DashGrid(children: [
        for (var i = 0; i < pins.length; i++) PinTile(view: view, pin: pins[i], color: colors[i % colors.length], onOpen: onExplore),
      ]),
    ]);
  }
}

/// One pinned series: name, sparkline, last value and its change. Tap opens it in Explore; long press (or right click) unpins, with Undo.
class PinTile extends StatelessWidget {
  final TodayView view;
  final PinData pin;
  final Color color;
  final VoidCallback onOpen;
  const PinTile({super.key, required this.view, required this.pin, required this.color, required this.onOpen});

  void _unpin(BuildContext context) {
    view.unpin(pin.id);
    toast(context, 'Unpinned', actionLabel: 'Undo', onAction: () => view.repin(pin.id));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final value = pin.isCount ? groupInt(pin.last) : view.amount(pin.last, view.currency);
    final d = pin.deltaPercent;
    final delta = d == null
        ? null
        : '${d > 0 ? '▲' : d < 0 ? '▼' : '–'} ${d.abs()} %';
    return Semantics(
      customSemanticsActions: {const CustomSemanticsAction(label: 'Unpin'): () => _unpin(context)},
      child: Tile(
        key: ValueKey('pin:${pin.id}'),
        onTap: onOpen,
        onLongPress: () => _unpin(context),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        semanticLabel: '${pin.name}, ${pin.span}, $value${delta == null ? '' : ', $delta'}',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(pin.span.toUpperCase(),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: BwType.eyebrow.copyWith(fontSize: 10, color: c.muted)),
          Text(pin.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          IgnorePointer(child: Sparkline(values: pin.values, color: color, height: 40)),
          const SizedBox(height: 4),
          Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.end, spacing: 6, children: [
            Text(value, style: numStyle.copyWith(fontSize: 15, fontWeight: FontWeight.w700, color: c.ink)),
            if (delta != null) Text(delta, style: numStyle.copyWith(fontSize: 12, color: c.muted)),
          ]),
        ]),
      ),
    );
  }
}

/// The nearest big goal: name, a bar and "X of Y". Absent when no goal has a target.
class GoalBar extends StatelessWidget {
  final TodayView view;
  final VoidCallback onOpen;
  const GoalBar({super.key, required this.view, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final g = view.nearestGoal();
    if (g == null) return const SizedBox.shrink();
    final c = context.c;
    final cur = view.currency;
    final share = (g.saved / g.target).clamp(0.0, 1.0); // drawing only; the amounts below are exact
    // TODO(eng-6): "ready ~ <month year>" and "for deposit and costs" from goalPlan once goals carry a price and a deposit share.
    return Tile(
      key: const ValueKey('goalBar'),
      onTap: onOpen,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      semanticLabel: '${g.name}, ${view.amount(g.saved, cur)} of ${view.amount(g.target, cur)}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text(g.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Stack(children: [
              ColoredBox(color: c.lineStrong, child: const SizedBox.expand()),
              FractionallySizedBox(widthFactor: share, child: ColoredBox(color: c.s3, child: const SizedBox.expand())),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Text.rich(
          TextSpan(style: TextStyle(fontSize: BwType.metaSize, color: c.muted), children: [
            TextSpan(text: view.amount(g.saved, cur), style: numStyle.copyWith(fontSize: 13, color: c.ink)),
            const TextSpan(text: ' of '),
            TextSpan(text: view.amount(g.target, cur), style: numStyle.copyWith(fontSize: 13, color: c.ink)),
          ]),
        ),
      ]),
    );
  }
}

/// Opens the weekday-and-date eyebrow text: "Mon 2 Nov · period day 18/31".
String overviewEyebrow(String today, PeriodBudget p) {
  if (p.paydayPassed) return '${weekdayShortDate(today)} · period ended';
  final day = (daysBetween(p.start, today) + 1).clamp(1, p.length);
  return '${weekdayShortDate(today)} · period day $day/${p.length}';
}
