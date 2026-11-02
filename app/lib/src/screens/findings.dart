// The Findings screen (ENG E3, docs/context/ENG_UI_SPEC.md §5.2): what the app noticed in the owner's data, each with its evidence chart
// and basis line. Read-only: a finding never changes data; "Not interesting" only hides it (synced setting), Undo shows it again.
// Every sentence, number and ratio comes from the controller (core's `findings`); nothing is worked out here.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dash.dart';
import '../widgets/finding_charts.dart';
import '../widgets/sheets.dart';

/// Opens Findings as a page (phone) or a dialog (wide). [openExplore] runs after it closed, for "Open in Explore" (E4 will pass the query;
/// until then it opens Explore).
Future<void> openFindings(BuildContext context, WalletController wc, {VoidCallback? openExplore}) {
  logNav('findings.open');
  return openPageOrDialog<void>(context, FindingsScreen(wc, openExplore: openExplore), width: 640, logName: 'findings');
}

class FindingsScreen extends StatelessWidget {
  final WalletController wc;
  final VoidCallback? openExplore;
  const FindingsScreen(this.wc, {super.key, this.openExplore});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: wc,
        builder: (context, _) {
          final c = context.c;
          final cards = wc.foundCards();
          final milestones = [
            for (final k in cards)
              if (k.finding.kind == FindingKind.milestone) k
          ];
          final others = [
            for (final k in cards)
              if (k.finding.kind != FindingKind.milestone) k
          ];
          void explore() {
            Navigator.pop(context);
            openExplore?.call();
          }

          return Scaffold(
            backgroundColor: c.desk,
            appBar: const DialogAppBar(title: 'Findings'),
            body: ListView(
              key: const ValueKey('findingsPage'),
              padding: const EdgeInsets.fromLTRB(pagePad, 12, pagePad, pageBottomPad),
              children: [
                Text('Found in ${groupInt(wc.trackedDays)} days of your data. A link is not proof of a cause.',
                    key: const ValueKey('findingsSubtitle'), style: TextStyle(fontSize: BwType.metaSize, color: c.muted)),
                const SizedBox(height: 14),
                if (cards.isEmpty)
                  Tile(
                      key: const ValueKey('findingsEmpty'),
                      padding: const EdgeInsets.all(16),
                      child: Text('Nothing found yet. It needs a few months of payments.', style: TextStyle(color: c.ink2)))
                else ...[
                  for (final k in others) ...[FindingCardView(wc: wc, card: k, onExplore: explore), const SizedBox(height: 14)],
                  if (milestones.isNotEmpty) MilestonesCard(wc: wc, cards: milestones),
                ],
              ],
            ),
          );
        },
      );
}

/// Hides the findings [ids] and says so with an Undo.
void _dismiss(BuildContext context, WalletController wc, List<String> ids) {
  wc.dismissFindings(ids);
  toast(context, 'Hidden', actionLabel: 'Undo', onAction: () => wc.undismissFindings(ids));
}

/// One finding: kind, sentence, evidence chart, basis and the two actions.
class FindingCardView extends StatelessWidget {
  final WalletController wc;
  final FindingCard card;
  final VoidCallback onExplore;
  const FindingCardView({super.key, required this.wc, required this.card, required this.onExplore});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final f = card.finding;
    return Tile(
      key: ValueKey('finding:${f.id}'),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Eyebrow(card.eyebrow),
        const SizedBox(height: 8),
        Text(card.sentence, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, height: 1.3)),
        const SizedBox(height: 10),
        _evidence(context),
        const SizedBox(height: 10),
        Text(card.basis, key: ValueKey('findingBasis:${f.id}'), style: TextStyle(fontSize: BwType.metaSize, color: c.muted)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(key: ValueKey('findingExplore:${f.id}'), onPressed: onExplore, child: const Text('Open in Explore')),
          OutlinedButton(
              key: ValueKey('findingDismiss:${f.id}'),
              onPressed: () => _dismiss(context, wc, [f.id]),
              child: const Text('Not interesting')),
        ]),
      ]),
    );
  }

  Widget _evidence(BuildContext context) {
    final f = card.finding;
    final cur = wc.currency;
    String amt(int v) => wc.amountText(v, cur);
    final cents = [for (final p in f.series) p.$2];
    switch (f.kind) {
      case FindingKind.weeklyRhythm:
        return WeekBars(values: cents, texts: [for (final v in cents) amt(v)]);
      case FindingKind.movesTogether:
        return ScatterChart(
            xs: cents,
            ys: [for (final p in f.otherSeries) p.$2],
            xName: '${card.subjectName} per month',
            yName: '${card.otherName} per month',
            semanticLabel: '${f.n} months: ${card.subjectName} on one axis, ${card.otherName} on the other. ${card.basis}');
      case FindingKind.slowCreep:
        return StepLine(
            values: cents,
            firstText: cents.isEmpty ? '' : amt(cents.first),
            lastText: cents.isEmpty ? '' : amt(cents.last),
            semanticLabel:
                'Per month, from ${cents.isEmpty ? '' : amt(cents.first)} to ${cents.isEmpty ? '' : amt(cents.last)} over ${f.n} months');
      case FindingKind.aboveUsual:
      case FindingKind.seasonality:
      case FindingKind.milestone:
        return Sparkline(
            values: [for (final v in cents) v.toDouble()],
            color: context.c.s2,
            height: 56,
            semanticLabel: '${card.sentence}. ${card.basis}');
    }
  }
}

/// The milestones as one card of up to three big numbers.
class MilestonesCard extends StatelessWidget {
  final WalletController wc;
  final List<FindingCard> cards;
  const MilestonesCard({super.key, required this.wc, required this.cards});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    String unit(String subject) => switch (subject) {
          'days' => 'days tracked',
          'payments' => 'payments',
          _ => 'best streak, weeks',
        };
    return Tile(
      key: const ValueKey('finding:milestones'),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Wrap(alignment: WrapAlignment.spaceEvenly, spacing: 16, runSpacing: 12, children: [
          for (final k in cards)
            Column(mainAxisSize: MainAxisSize.min, children: [
              Text(groupInt(k.finding.series.first.$2),
                  key: ValueKey('milestone:${k.finding.subjectKey}'),
                  style: numStyle.copyWith(fontSize: 22, fontWeight: FontWeight.w700, color: c.ink)),
              Text(unit(k.finding.subjectKey), textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: c.muted)),
            ]),
        ]),
        const SizedBox(height: 10),
        Text(cards.map((k) => k.basis).toSet().join(' '),
            key: const ValueKey('findingBasis:milestones'), style: TextStyle(fontSize: BwType.metaSize, color: c.muted)),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
              key: const ValueKey('findingDismiss:milestones'),
              onPressed: () => _dismiss(context, wc, [for (final k in cards) k.finding.id]),
              child: const Text('Not interesting')),
        ),
      ]),
    );
  }
}
