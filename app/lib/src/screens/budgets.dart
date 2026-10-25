import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'suggest_budgets_dialog.dart';

/// Plan › "Budgets per category": one amount field per category (empty = no budget), a button that fills the empty
/// fields from the last 6 months, and Save. Only fields the user edited are saved, on top of the latest saved budgets.
class BudgetsPanel extends StatefulWidget {
  final WalletController wc;
  const BudgetsPanel({super.key, required this.wc});
  @override
  State<BudgetsPanel> createState() => _BudgetsPanelState();
}

class _BudgetsPanelState extends State<BudgetsPanel> {
  /// The main spending categories (own ones included; subcategories count in their parent's budget).
  List<String> get _cats => widget.wc.categoryTable.spending;
  final Map<String, TextEditingController> _f = {};
  TextEditingController _ctl(String k) => _f.putIfAbsent(k, TextEditingController.new);

  /// The text each field last got from the saved budgets: a field whose text differs was edited.
  final Map<String, String> _shown = {};
  final Map<String, String> _errors = {};

  @override
  void initState() {
    super.initState();
    _fill();
    widget.wc.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.wc.removeListener(_onChange);
    for (final c in _f.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(_fill);
  }

  /// Shows the saved budgets in every field the user has not edited.
  void _fill() {
    final saved = widget.wc.categoryBudgets;
    for (final k in _cats) {
      final t = saved[k] == null ? '' : centsToFieldText(saved[k]!), c = _ctl(k);
      if (c.text.trim() == (_shown[k] ?? '') && c.text != t) c.text = t;
      _shown[k] = t;
    }
  }

  /// Suggest (core's `budgetProposals`): empty fields are filled at once; a field that already has a number is changed only when
  /// the owner ticks it in the dialog. Nothing is saved here: Save does that.
  Future<void> _suggest() async {
    final wc = widget.wc;
    final s = wc.suggestedBudgets(monthOf(wc.today()));
    // What the fields show now (typed, not yet saved, included). A blank or zero field counts as empty; a field with text that
    // is not a number is left alone.
    final current = <String, int>{};
    final untouched = <String>{};
    for (final k in _cats) {
      final text = _ctl(k).text.trim(), v = parseMoney(text);
      if (text.isNotEmpty && v == null) untouched.add(k);
      if (v != null && v > 0) current[k] = v;
    }
    final proposals = [
      for (final p in budgetProposals(current, s))
        if (_cats.contains(p.category) && !untouched.contains(p.category)) p,
    ];
    var filled = 0, changed = 0;
    for (final p in proposals.where((p) => p.fillsEmpty)) {
      _ctl(p.category).text = centsToFieldText(p.suggested);
      _errors.remove(p.category);
      filled++;
    }
    final existing = proposals.where((p) => !p.fillsEmpty).toList();
    if (existing.isNotEmpty) {
      logNav('budgets.suggestAsk', {'count': existing.length});
      final picked = await showDialog<Set<String>>(
          context: context, builder: (_) => SuggestBudgetsDialog(proposals: existing, currency: wc.currency, table: wc.categoryTable));
      if (!mounted) return;
      for (final p in existing.where((p) => picked?.contains(p.category) ?? false)) {
        _ctl(p.category).text = centsToFieldText(p.suggested);
        _errors.remove(p.category);
        changed++;
      }
    }
    logNav('budgets.suggest', {'filled': filled, 'changed': changed});
    setState(() {});
    final n = filled + changed;
    toast(
        context,
        n > 0
            ? 'Filled $n ${n == 1 ? 'budget' : 'budgets'}. Check them, then save.'
            : existing.isNotEmpty
                ? 'No budgets changed.'
                : s.isEmpty
                    ? 'Not enough history yet.'
                    : 'Nothing new to suggest.');
  }

  void _save() {
    final wc = widget.wc;
    final edits = <String, int?>{}; // null = cleared
    final errors = <String, String>{};
    for (final k in _cats) {
      final text = _ctl(k).text.trim();
      if (text == _shown[k]) continue;
      if (text.isEmpty) {
        edits[k] = null;
        continue;
      }
      final v = parseMoney(text);
      if (v == null) {
        errors[k] = 'Numbers only';
      } else {
        edits[k] = v == 0 ? null : v; // 0 means no budget
      }
    }
    if (errors.isNotEmpty) {
      logNav('budgets.invalid', {'count': errors.length});
      setState(() => _errors
        ..clear()
        ..addAll(errors));
      toast(context, invalidAmountMessage);
      return;
    }
    if (_errors.isNotEmpty) setState(_errors.clear);
    final next = {...wc.categoryBudgets};
    edits.forEach((k, v) => v == null ? next.remove(k) : next[k] = v);
    if (_same(next, wc.categoryBudgets)) {
      // Show what is saved (e.g. "300.0" or "0" in a field), and say nothing was written.
      setState(_resetShown);
      toast(context, 'Nothing to save');
      return;
    }
    wc.saveCategoryBudgets(next);
    setState(_resetShown);
    toast(context, 'Budgets saved');
  }

  void _resetShown() {
    _shown.clear();
    for (final k in _cats) {
      _ctl(k).text = '';
    }
    _fill();
  }

  static bool _same(Map<String, int> a, Map<String, int> b) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  @override
  Widget build(BuildContext context) {
    final sym = currencySymbol(widget.wc.currency);
    return Panel(children: [
      const SectionHead('Budgets per category'),
      Explainer(widget.wc, 'budgets', 'A limit for each month. Leave a field empty for no budget.'),
      Rows(children: [
        for (final k in _cats)
          Container(
            constraints: const BoxConstraints(minHeight: touchMin),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SplitRow(
              maxEnd: 0.5,
              gap: 12,
              start: Text(widget.wc.categoryTable.label(k), style: const TextStyle(fontSize: BwType.bodySize)),
              end: SizedBox(
                width: 132,
                child: Semantics(
                  label: 'Monthly budget for ${widget.wc.categoryTable.label(k)}',
                  child: MoneyField(
                    fieldKey: ValueKey('budget:$k'),
                    controller: _ctl(k),
                    onChanged: (_) {
                      if (_errors.containsKey(k)) setState(() => _errors.remove(k));
                    },
                    decoration: InputDecoration(
                        isDense: true,
                        suffix: ExcludeSemantics(child: Text(sym, style: numStyle.copyWith(color: context.c.ink2))),
                        hintText: 'None',
                        errorText: _errors[k],
                        errorMaxLines: 2),
                  ),
                ),
              ),
            ),
          ),
      ]),
      OutlinedButton.icon(
          key: const ValueKey('budgetsSuggest'),
          style: accentOutlined(context),
          icon: const Icon(Icons.auto_awesome_outlined),
          label: const Text('Suggest from the last 6 months'),
          onPressed: _suggest),
      FilledButton(key: const ValueKey('budgetsSave'), onPressed: _save, child: const Text('Save budgets')),
    ]);
  }
}
