import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Plan › "Budgets per category": one amount field per category (empty = no budget), a button that fills the empty
/// fields from the last 6 months, and Save. Only fields the user edited are saved, on top of the latest saved budgets.
class BudgetsPanel extends StatefulWidget {
  final WalletController wc;
  const BudgetsPanel({super.key, required this.wc});
  @override
  State<BudgetsPanel> createState() => _BudgetsPanelState();
}

class _BudgetsPanelState extends State<BudgetsPanel> {
  final _cats = spendingCategories;
  late final Map<String, TextEditingController> _f = {for (final k in _cats) k: TextEditingController()};

  /// The text each field last got from the saved budgets: a field whose text differs was edited.
  final Map<String, String> _shown = {};
  final Map<String, String> _errors = {};

  static String _plain(int cents) => cents % 100 == 0 ? '${cents ~/ 100}' : (cents / 100).toStringAsFixed(2);

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
      final t = saved[k] == null ? '' : _plain(saved[k]!), c = _f[k]!;
      if (c.text.trim() == (_shown[k] ?? '') && c.text != t) c.text = t;
      _shown[k] = t;
    }
  }

  void _suggest() {
    final wc = widget.wc;
    final s = wc.suggestedBudgets(monthOf(wc.today()));
    var filled = 0;
    for (final k in _cats) {
      final cents = s[k], c = _f[k]!;
      if (cents == null || cents <= 0 || c.text.trim().isNotEmpty) continue;
      c.text = _plain(cents);
      _errors.remove(k);
      filled++;
    }
    logNav('budgets.suggest', {'filled': filled});
    setState(() {});
    toast(
        context,
        filled > 0
            ? 'Filled $filled ${filled == 1 ? 'budget' : 'budgets'}. Check them, then save.'
            : s.isEmpty
                ? 'Not enough history yet.'
                : 'Nothing new to suggest.');
  }

  void _save() {
    final wc = widget.wc;
    final edits = <String, int?>{}; // null = cleared
    final errors = <String, String>{};
    for (final k in _cats) {
      final text = _f[k]!.text.trim();
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
      toast(context, 'Enter numbers only, like 300 or 45.50.');
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
      _f[k]!.text = '';
    }
    _fill();
  }

  static bool _same(Map<String, int> a, Map<String, int> b) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  @override
  Widget build(BuildContext context) {
    final sym = currencySymbol(widget.wc.currency);
    return Panel(children: [
      const SectionHead('Budgets per category'),
      const Muted('A limit for each month. Leave a field empty for no budget.'),
      Rows(children: [
        for (final k in _cats)
          Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SplitRow(
              maxEnd: 0.5,
              gap: 12,
              start: Text(k, style: const TextStyle(fontSize: 14.5)),
              end: SizedBox(
                width: 132,
                child: Semantics(
                  label: 'Monthly budget for $k',
                  child: TextField(
                    key: ValueKey('budget:$k'),
                    controller: _f[k],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.end,
                    style: numStyle,
                    onChanged: (_) {
                      if (_errors.containsKey(k)) setState(() => _errors.remove(k));
                    },
                    decoration: InputDecoration(isDense: true, suffixText: sym, hintText: 'None', errorText: _errors[k], errorMaxLines: 2),
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
