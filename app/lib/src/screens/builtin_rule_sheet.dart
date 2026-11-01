// Edit a built-in merchant rule (UX-A): its pattern (a regex over the description) and its main tag. The same sheet look as the Add / Edit
// rule form; core checks the pattern and the tag and says what is wrong (it never quotes the pattern).
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../layout.dart';
import '../theme.dart';
import '../widgets/category_picker.dart';
import '../widgets/common.dart';

final _log = Logger('bw.rules.ui');

class BuiltInRuleSheet extends StatefulWidget {
  final WalletController wc;
  final RuleView rule;
  const BuiltInRuleSheet({super.key, required this.wc, required this.rule});
  @override
  State<BuiltInRuleSheet> createState() => _BuiltInRuleSheetState();
}

class _BuiltInRuleSheetState extends State<BuiltInRuleSheet> {
  late final _pattern = TextEditingController(text: widget.rule.text);
  late String? _cat = widget.rule.category;
  late final List<String> _ids = widget.wc.recommendedMainFor(null);
  String? _error;

  @override
  void dispose() {
    _pattern.dispose();
    super.dispose();
  }

  void _save() {
    final r = widget.rule;
    if (_cat == null) {
      setState(() => _error = 'Pick a main tag.');
      return;
    }
    try {
      widget.wc.editBuiltInRule(r.id, pattern: _pattern.text == r.text ? null : _pattern.text, category: _cat == r.category ? null : _cat);
      Navigator.pop(context, true);
    } on ArgumentError catch (e, st) {
      logError(_log, 'rules.builtIn.edit.failed', e, st);
      final m = e.message.toString();
      setState(() => _error = m.isEmpty ? 'Could not save. Try again.' : '${m[0].toUpperCase()}${m.substring(1)}');
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Heading('Edit built-in rule', key: ValueKey('builtInRuleHeading')),
        const SizedBox(height: 6),
        const Muted('Built in with the app. Your change stays when the app updates; Reset puts the original back.'),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('builtInPattern'),
          controller: _pattern,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          decoration: const InputDecoration(
              labelText: 'Pattern (regex)', helperText: 'Matched against the description. Capitals do not matter.', helperMaxLines: 2),
        ),
        const SizedBox(height: 14),
        MainTagPicker(
            dropdown: true,
            table: widget.wc.categoryTable,
            ids: _ids,
            selected: _cat,
            onPick: (v) => setState(() {
                  _cat = v;
                  _error = null;
                })),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, key: const ValueKey('builtInRuleError'), style: TextStyle(color: context.c.bad, fontSize: BwType.metaSize)),
        ],
        const SizedBox(height: 14),
        FilledButton(
            key: const ValueKey('builtInRuleSave'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
            onPressed: _save,
            child: const Text('Save')),
      ]);
}
