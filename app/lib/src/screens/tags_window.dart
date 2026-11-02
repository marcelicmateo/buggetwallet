// Budget › Tags (UX-B2): main tags, tags and rules in one window. Recommendations first (payees that keep coming back with no main tag,
// payee rules the wallet offers), then the three lists. One "Add" button asks what to add and opens that form. A recommendation changes
// nothing until Accept; Dismiss hides it on this device only.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../layout.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'categories_panel.dart';
import 'rules_panel.dart';
import 'tags_panel.dart';

class TagsWindow extends StatelessWidget {
  final WalletController wc;

  /// The Spending | Plan | Tags switch, shown at the top like on the other two pages.
  final Widget switcher;
  const TagsWindow({super.key, required this.wc, required this.switcher});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: wc,
        builder: (context, _) => MarginLine(
          // Not a lazy list: the three panels build all their rows anyway, and a tap or a test can reach any of them.
          child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: gapped([
                    switcher,
                    Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                            key: const ValueKey('tagsAdd'),
                            style: FilledButton.styleFrom(minimumSize: const Size(0, touchMin)),
                            icon: const Icon(Icons.add, size: 20),
                            label: const Text('Add'),
                            onPressed: () => openTagsAdd(context, wc))),
                    _Recommendations(wc: wc),
                    CategoriesPanel(key: const ValueKey('categoriesPanel'), wc: wc),
                    TagsPanel(key: const ValueKey('tagsPanel'), wc: wc),
                    RulesPanel(key: const ValueKey('rulesPanel'), wc: wc),
                  ]))),
        ),
      );
}

/// The one add flow: asks what to add, then opens that form.
Future<void> openTagsAdd(BuildContext context, WalletController wc) async {
  final what = await showSheet<String>(context, const _AddChoice());
  if (what == null || !context.mounted) return;
  switch (what) {
    case 'main':
      await openAddCategory(context, wc);
    case 'tag':
      await openAddTag(context, wc);
    case 'rule':
      await openRuleForm(context, wc);
  }
}

/// The one add flow: what to add. Pops `'main'`, `'tag'` or `'rule'`.
class _AddChoice extends StatelessWidget {
  const _AddChoice();

  @override
  Widget build(BuildContext context) {
    Widget item(String id, String title, String sub) => ListTile(
          key: ValueKey('tagsAdd:$id'),
          minVerticalPadding: 8,
          title: Text(title),
          subtitle: Text(sub),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.pop(context, id),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('Add'),
      item('main', 'Main tag', 'Decides what a payment counts for.'),
      item('tag', 'Tag', 'Tracks what a payment was for.'),
      item('rule', 'Rule', 'Picks the main tag of matching payments.'),
    ]);
  }
}

class _Recommendations extends StatelessWidget {
  final WalletController wc;
  const _Recommendations({required this.wc});

  @override
  Widget build(BuildContext context) {
    final payees = wc.payeeRecommendations();
    final rules = wc.ruleSuggestionList;
    if (payees.isEmpty && rules.isEmpty) return const SizedBox.shrink();
    return Panel(key: const ValueKey('tagsRecommendations'), children: [
      const SectionHead('Recommendations'),
      const Muted('Nothing changes until you accept. Dismiss hides one on this device.'),
      Rows(children: [
        for (final p in payees) _PayeeCard(wc: wc, p: p),
        for (final s in rules) _RuleCard(wc: wc, s: s),
      ]),
    ]);
  }
}

class _Card extends StatelessWidget {
  final Key cardKey, acceptKey, dismissKey;
  final List<Widget> lines;
  final VoidCallback onAccept, onDismiss;
  const _Card(
      {required this.cardKey,
      required this.lines,
      required this.acceptKey,
      required this.dismissKey,
      required this.onAccept,
      required this.onDismiss});

  @override
  Widget build(BuildContext context) => Container(
        key: cardKey,
        alignment: Alignment.centerLeft,
        constraints: const BoxConstraints(minHeight: touchMin),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ...lines,
          Wrap(spacing: 8, runSpacing: 4, children: [
            FilledButton(
                key: acceptKey,
                style: FilledButton.styleFrom(minimumSize: const Size(0, touchMin)),
                onPressed: onAccept,
                child: const Text('Accept')),
            TextButton(
                key: dismissKey,
                style: TextButton.styleFrom(minimumSize: const Size(0, touchMin)),
                onPressed: onDismiss,
                child: const Text('Dismiss')),
          ]),
        ]),
      );
}

/// A payee that keeps coming back with no main tag: Accept opens the rule form with the payee and a main tag filled in.
class _PayeeCard extends StatelessWidget {
  final WalletController wc;
  final PayeeCount p;
  const _PayeeCard({required this.wc, required this.p});

  @override
  Widget build(BuildContext context) {
    final key = p.merchantKey;
    final tags = wc.setupMainTagIds();
    return _Card(
      cardKey: ValueKey('tagsRecPayee:$key'),
      lines: [Text('${p.merchantName} · ${p.count} payments, no main tag', maxLines: 3, overflow: TextOverflow.ellipsis)],
      acceptKey: ValueKey('tagsRecPayeeAccept:$key'),
      dismissKey: ValueKey('tagsRecPayeeDismiss:$key'),
      onAccept: () => openRuleForm(context, wc, payee: key, category: tags.isEmpty ? null : tags.first),
      onDismiss: () => wc.dismissPayeeRecommendation(key),
    );
  }
}

/// A payee rule the wallet offers (Q6): Accept writes it (with an Undo), Dismiss hides it on this device.
class _RuleCard extends StatelessWidget {
  final WalletController wc;
  final RuleSuggestion s;
  const _RuleCard({required this.wc, required this.s});

  @override
  Widget build(BuildContext context) {
    final key = s.merchantKey;
    return _Card(
      cardKey: ValueKey('ruleSuggest:$key'),
      lines: [
        Text(s.merchantName, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
        Text('→ ${wc.categoryTable.label(s.category)}'),
        Muted('You chose it on ${s.count} payments'),
      ],
      acceptKey: ValueKey('ruleSuggestMake:$key'),
      dismissKey: ValueKey('ruleSuggestDismiss:$key'),
      onAccept: () {
        wc.makeSuggestedRule(s);
        toast(context, 'Rule made', actionLabel: 'Undo', onAction: () => wc.undoSuggestedRule(s));
      },
      onDismiss: () => wc.dismissRuleSuggestion(key),
    );
  }
}
