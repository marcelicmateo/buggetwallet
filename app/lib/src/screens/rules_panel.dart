// Settings › Tags and rules (rules) (P7, spec docs/context/P7_SPEC.md): the rules that choose a payment's main tag, with how many payments each one decided.
// Payee rules ("always use this main tag for <payee>", maybe with tags), text patterns (description contains / regex, with an optional
// amount range) and the built-in rules (collapsed; editable like the others). Rules never use the amount alone: a range only narrows a text rule.
// The lists and counts come from the controller (once per data version); core's `ArgumentError` text shows under the field.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/category_picker.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import '../widgets/tag_picker.dart';
import 'builtin_rule_sheet.dart';

final _log = Logger('bw.rules.ui');

String _problem(Object e) {
  if (e is! ArgumentError) return 'Could not save. Try again.';
  final m = e.message.toString();
  return m.isEmpty ? m : '${m[0].toUpperCase()}${m.substring(1)}${m.endsWith('.') ? '' : '.'}';
}

/// "12.00–30.00 €", "from 12.00 €" or "up to 30.00 €": exact cents.
String rangeText(int? lo, int? hi, String currency) {
  String num(int c) => money(c, currency, decimals: 2).split(' ').first;
  if (lo != null && hi != null) return '${num(lo)}–${money(hi, currency, decimals: 2)}';
  if (lo != null) return 'from ${money(lo, currency, decimals: 2)}';
  return 'up to ${money(hi!, currency, decimals: 2)}';
}

enum _Act { edit, up, down, delete, off, on, reset }

class RulesPanel extends StatefulWidget {
  final WalletController wc;
  const RulesPanel({super.key, required this.wc});
  @override
  State<RulesPanel> createState() => _RulesPanelState();
}

class _RulesPanelState extends State<RulesPanel> {
  bool _builtIn = false;

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final rules = wc.rulesList; // memoized per data version
    final counts = wc.ruleUseCounts();
    final own = [
      for (final r in rules)
        if (r.kind != RuleKind.builtIn) r
    ];
    final builtIn = [
      for (final r in rules)
        if (r.kind == RuleKind.builtIn) r
    ];
    final patterns = [
      for (final r in own)
        if (r.kind == RuleKind.pattern) r.id
    ];
    return Panel(children: [
      const SectionHead('Rules'),
      Explainer(
          wc,
          'rules',
          'Rules choose the main tag of a payment. A payee rule covers every payment from one payee. A text rule looks for words in the '
              'description, and can also check the amount. An amount alone never makes a rule. Text rules go in the order shown: the first '
              'that fits wins.'),
      if (own.isEmpty)
        const EmptyNote('No rules of your own yet. Tap Add above, or "Make a rule…" on a payment.', key: ValueKey('rulesEmpty'))
      else
        Rows(children: [
          for (final r in own)
            _RuleRow(
                wc: wc,
                rule: r,
                count: counts[r.id] ?? 0,
                first: patterns.isNotEmpty && patterns.first == r.id,
                last: patterns.isNotEmpty && patterns.last == r.id),
        ]),
      if (builtIn.isNotEmpty) ...[
        TextButton.icon(
            key: const ValueKey('builtInToggle'),
            style: TextButton.styleFrom(alignment: Alignment.centerLeft, minimumSize: const Size(0, touchMin)),
            icon: Icon(_builtIn ? Icons.expand_less : Icons.expand_more, size: 20),
            label: Text('Built in · ${builtIn.length}'),
            onPressed: () => setState(() => _builtIn = !_builtIn)),
        if (_builtIn) Rows(children: [for (final r in builtIn) _RuleRow(wc: wc, rule: r, count: counts[r.id] ?? 0)]),
      ],
    ]);
  }
}

/// A small icon + word under a rule: "edited" or "off".
class _Badge extends StatelessWidget {
  final String text;
  final IconData icon;
  const _Badge(this.text, this.icon, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(border: Border.all(color: context.c.line), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: context.c.ink2),
          const SizedBox(width: 3),
          Text(text, style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
        ]),
      );
}

class _RuleRow extends StatelessWidget {
  final WalletController wc;
  final RuleView rule;
  final int count;
  final bool first, last;
  const _RuleRow({required this.wc, required this.rule, required this.count, this.first = false, this.last = false});

  String get _kind => switch (rule.kind) {
        RuleKind.payee || RuleKind.payeeTags => 'Payee',
        RuleKind.pattern => rule.match == MerchantPattern.contains ? 'Description contains' : 'Pattern',
        RuleKind.builtIn => 'Built in',
      };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final id = rule.id;
    final meta = TextStyle(fontSize: BwType.metaSize, color: c.ink2);
    final hasRange = rule.minCents != null || rule.maxCents != null;
    return Container(
      key: ValueKey('rule:$id'),
      constraints: const BoxConstraints(minHeight: touchMin),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(rule.text,
                key: ValueKey('ruleText:$id'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: BwType.bodySize, fontWeight: FontWeight.w500)),
            Muted(_kind),
            if (rule.kind == RuleKind.builtIn && (rule.edited || rule.off))
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Wrap(spacing: 6, runSpacing: 4, children: [
                  if (rule.edited) _Badge('edited', Icons.edit_outlined, key: ValueKey('ruleEdited:$id')),
                  if (rule.off) _Badge('off', Icons.block, key: ValueKey('ruleOff:$id')),
                ]),
              ),
            if (rule.categoryLabel != null)
              Text('→ ${rule.categoryLabel}', key: ValueKey('ruleTag:$id'), style: const TextStyle(fontSize: BwType.bodySize)),
            if (rule.tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Wrap(spacing: 4, runSpacing: 4, children: [
                  for (final t in rule.tags) TagChip(tagText(wc.tagTable, t), key: ValueKey('ruleTagChip:$id:$t')),
                ]),
              ),
            if (hasRange)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: MoneyText(rangeText(rule.minCents, rule.maxCents, wc.currency), style: numStyle.copyWith(fontSize: BwType.metaSize)),
              ),
            if (rule.kind != RuleKind.payeeTags)
              Text(count == 1 ? 'used by 1 payment' : 'used by $count payments', key: ValueKey('ruleCount:$id'), style: meta),
          ]),
        ),
        if (rule.editable)
          PopupMenuButton<_Act>(
            key: ValueKey('ruleMenu:$id'),
            tooltip: 'Actions for ${rule.text}',
            icon: const Icon(Icons.more_vert),
            constraints: const BoxConstraints(minWidth: 180),
            onSelected: (a) => _act(context, a),
            itemBuilder: (_) => [
              PopupMenuItem(key: ValueKey('ruleEdit:$id'), value: _Act.edit, child: const Text('Edit')),
              if (rule.kind == RuleKind.pattern) ...[
                PopupMenuItem(key: ValueKey('ruleUp:$id'), value: _Act.up, enabled: !first, child: const Text('Move up')),
                PopupMenuItem(key: ValueKey('ruleDown:$id'), value: _Act.down, enabled: !last, child: const Text('Move down')),
              ],
              if (rule.kind == RuleKind.pattern || rule.kind == RuleKind.payee)
                PopupMenuItem(key: ValueKey('ruleDelete:$id'), value: _Act.delete, child: const Text('Delete')),
              if (rule.kind == RuleKind.builtIn) ...[
                PopupMenuItem(
                    key: ValueKey(rule.off ? 'ruleOn:$id' : 'ruleTurnOff:$id'),
                    value: rule.off ? _Act.on : _Act.off,
                    child: Text(rule.off ? 'Turn on' : 'Turn off')),
                if (rule.edited) PopupMenuItem(key: ValueKey('ruleReset:$id'), value: _Act.reset, child: const Text('Reset')),
              ],
            ],
          ),
      ]),
    );
  }

  Future<void> _act(BuildContext context, _Act a) async {
    logNav('rules.${a.name}');
    switch (a) {
      case _Act.edit:
        if (rule.kind == RuleKind.builtIn) {
          await openBuiltInRuleForm(context, wc, rule);
        } else {
          await openRuleForm(context, wc, edit: rule);
        }
      case _Act.off || _Act.on || _Act.reset:
        _builtInAct(context, a);
      case _Act.up || _Act.down:
        final messenger = ScaffoldMessenger.of(context);
        final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
        try {
          wc.moveRule(rule.id, a == _Act.up ? MoveDirection.up : MoveDirection.down);
        } catch (e, st) {
          logError(_log, 'rules.move.failed', e, st);
          toastOn(messenger, _problem(e), wide: wide, accessible: accessible);
        }
      case _Act.delete:
        _delete(context);
    }
  }

  /// Turn off / on / Reset of a built-in rule, with an Undo that puts back the pattern, the main tag and the switch it had.
  void _builtInAct(BuildContext context, _Act a) {
    final messenger = ScaffoldMessenger.of(context);
    final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
    void say(String m, {String? label, VoidCallback? action}) =>
        toastOn(messenger, m, wide: wide, accessible: accessible, actionLabel: label, onAction: action);
    final (text, cat, off, edited) = (rule.text, rule.category, rule.off, rule.edited);
    try {
      switch (a) {
        case _Act.off:
          wc.setBuiltInRuleOff(rule.id, true);
        case _Act.on:
          wc.setBuiltInRuleOff(rule.id, false);
        default:
          wc.resetBuiltInRule(rule.id);
      }
    } catch (e, st) {
      logError(_log, 'rules.builtIn.failed', e, st);
      say(_problem(e));
      return;
    }
    say(switch (a) { _Act.off => 'Rule turned off', _Act.on => 'Rule turned on', _ => 'Rule reset' }, label: 'Undo', action: () {
      try {
        if (a == _Act.reset && edited) wc.editBuiltInRule(rule.id, pattern: text, category: cat);
        wc.setBuiltInRuleOff(rule.id, off);
      } catch (e, st) {
        logError(_log, 'rules.builtIn.undo.failed', e, st);
        say(_problem(e));
      }
    });
  }

  void _delete(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
    void say(String m, {String? label, VoidCallback? action}) =>
        toastOn(messenger, m, wide: wide, accessible: accessible, actionLabel: label, onAction: action);
    try {
      wc.deleteRule(rule);
    } catch (e, st) {
      logError(_log, 'rules.delete.failed', e, st);
      say(_problem(e));
      return;
    }
    say('Rule removed', label: 'Undo', action: () {
      try {
        wc.restoreRule(rule);
      } catch (e, st) {
        logError(_log, 'rules.undelete.failed', e, st);
        say(_problem(e));
      }
    });
  }
}

/// Opens the Add rule form (or Edit rule for [edit]). [payee] (a `merchantKey`) and [category] fill a new payee rule; [from] is the
/// payment the main tags are recommended for.
Future<bool?> openRuleForm(BuildContext context, WalletController wc, {RuleView? edit, String? payee, String? category, Tx? from}) {
  logNav(edit == null ? 'rules.add' : 'rules.editForm');
  return showSheet<bool>(context, RuleFormSheet(wc: wc, edit: edit, payee: payee, category: category, from: from));
}

/// Opens the form for a built-in rule: its pattern and its main tag.
Future<bool?> openBuiltInRuleForm(BuildContext context, WalletController wc, RuleView rule) {
  logNav('rules.builtInForm');
  return showSheet<bool>(context, BuiltInRuleSheet(wc: wc, rule: rule));
}

enum _Mode { payee, contains, regex }

/// The Add / Edit rule form. Saving a new rule or an edit writes through the controller; core's refusal shows under the field. An edit that
/// would change the main tag of some payments says how many first (computed on Preview, or by the first Save tap), then Save writes it.
class RuleFormSheet extends StatefulWidget {
  final WalletController wc;
  final RuleView? edit;
  final String? payee, category;
  final Tx? from;
  const RuleFormSheet({super.key, required this.wc, this.edit, this.payee, this.category, this.from});
  @override
  State<RuleFormSheet> createState() => _RuleFormSheetState();
}

class _RuleFormSheetState extends State<RuleFormSheet> {
  late _Mode _mode;
  late String? _payee;
  late String? _cat;
  late final Set<String> _tags;
  late final _text = TextEditingController(text: widget.edit?.kind == RuleKind.pattern ? widget.edit!.text : '');
  late final _min = TextEditingController(text: widget.edit?.minCents == null ? '' : centsToFieldText(widget.edit!.minCents!));
  late final _max = TextEditingController(text: widget.edit?.maxCents == null ? '' : centsToFieldText(widget.edit!.maxCents!));
  late final List<String> _mainIds = widget.wc.recommendedMainFor(widget.from);
  late final List<RulePayee> _payees = _withPrefill(widget.wc.recentPayees());
  String? _textError, _rangeError, _payeeError, _catError;
  int? _previewCount;
  String? _previewSig;
  bool _saving = false, _rangeNote = false;

  RuleView? get _edit => widget.edit;
  bool get _tagsOnly => _edit?.kind == RuleKind.payeeTags;

  List<RulePayee> _withPrefill(List<RulePayee> recent) {
    final k = _payee;
    if (k == null || recent.any((p) => p.key == k)) return recent;
    return [RulePayee(k, k.replaceAll('_', ' ')), ...recent];
  }

  @override
  void initState() {
    super.initState();
    final e = _edit;
    if (e != null) {
      _mode = switch (e.kind) {
        RuleKind.pattern => e.match == MerchantPattern.contains ? _Mode.contains : _Mode.regex,
        _ => _Mode.payee,
      };
      _payee = e.kind == RuleKind.pattern ? null : e.id.substring(e.id.indexOf(':') + 1);
      _cat = e.category;
      _tags = {...e.tags};
    } else {
      _payee = widget.payee;
      _mode = widget.payee != null ? _Mode.payee : _Mode.contains;
      _cat = widget.category;
      _tags = {};
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  String get _matchName => switch (_mode) {
        _Mode.payee => 'payee',
        _Mode.contains => MerchantPattern.contains,
        _Mode.regex => MerchantPattern.regex,
      };

  /// The values the preview was computed for; any change makes it stale.
  String get _sig => [_matchName, _payee, _text.text, _min.text, _max.text, _cat].join('\u0001');

  void _clearErrors() {
    if (_textError == null && _rangeError == null && _payeeError == null && _catError == null) return;
    setState(() => _textError = _rangeError = _payeeError = _catError = null);
  }

  /// The draft from the fields, or null with the errors set.
  RuleDraft? _draft() {
    String? te, re, pe, ce;
    int? lo, hi;
    if (_mode != _Mode.payee) {
      if (_mode == _Mode.contains) {
        if (_min.text.trim().isNotEmpty && (lo = parseMoney(_min.text)) == null) re = invalidAmountMessage;
        if (_max.text.trim().isNotEmpty && (hi = parseMoney(_max.text)) == null) re = invalidAmountMessage;
      }
      if (_text.text.trim().isEmpty) {
        te = _min.text.trim().isNotEmpty || _max.text.trim().isNotEmpty ? rangeOnlyMessage : 'Enter what to match.';
      }
    } else if (_payee == null) {
      pe = 'Pick a payee.';
    }
    if (_cat == null && !_tagsOnly) ce = 'Pick a main tag.';
    if (te != null || re != null || pe != null || ce != null) {
      setState(() {
        _textError = te;
        _rangeError = re;
        _payeeError = pe;
        _catError = ce;
      });
      return null;
    }
    return RuleDraft(
        editId: _edit?.kind == RuleKind.pattern ? _edit!.id : null,
        match: _matchName,
        payee: _payee,
        text: _text.text,
        minCents: lo,
        maxCents: hi,
        category: _cat ?? '');
  }

  void _showError(Object e) {
    final m = _problem(e), l = m.toLowerCase();
    setState(() {
      if (l.contains('amount') || l.contains('lower')) {
        _rangeError = m;
      } else if (l.contains('main tag')) {
        _catError = m;
      } else if (l.contains('payee')) {
        _payeeError = m;
      } else {
        _textError = m;
      }
    });
  }

  /// Computes the preview once for the current values. Returns false when the draft is not valid.
  bool _preview() {
    final d = _draft();
    if (d == null) return false;
    try {
      final n = widget.wc.previewRuleChange(d);
      logEvent(_log, Level.INFO, 'rules.preview', {'changed': n});
      setState(() {
        _previewCount = n;
        _previewSig = _sig;
      });
      return true;
    } on ArgumentError catch (e) {
      _showError(e);
      return false;
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_tagsOnly) {
      try {
        await widget.wc.savePayeeTags(_payee!, _tags);
        if (mounted) Navigator.pop(context, true);
      } on ArgumentError catch (e) {
        _showError(e);
      }
      return;
    }
    final d = _draft();
    if (d == null) return;
    // An edit shows what it changes before it writes (a second tap saves).
    if (_edit != null && _previewSig != _sig) {
      if (!_preview()) return;
      if ((_previewCount ?? 0) > 0) return;
    }
    _saving = true;
    try {
      await widget.wc.saveRule(d, tags: d.isPayee ? _tags : const {});
      if (mounted) Navigator.pop(context, true);
    } on ArgumentError catch (e) {
      _saving = false;
      _showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final edit = _edit != null;
    final fresh = _previewSig == _sig;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(edit ? 'Edit rule' : 'Add rule'),
      const SizedBox(height: 12),
      if (!edit) ...[
        const Muted('What to match'),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final (m, label) in [
            (_Mode.payee, 'Payee'),
            (_Mode.contains, 'Description contains'),
            (_Mode.regex, 'Advanced: pattern (regex)'),
          ])
            ChoiceChip(
              key: ValueKey('ruleMode:${m.name}'),
              label: Text(label),
              selected: _mode == m,
              onSelected: (_) => setState(() {
                _mode = m;
                _previewSig = null;
                // An amount range works with "description contains" only: switching away clears it and says so.
                if (m != _Mode.contains && (_min.text.trim().isNotEmpty || _max.text.trim().isNotEmpty)) {
                  _min.clear();
                  _max.clear();
                  _rangeNote = true;
                } else if (m == _Mode.contains) {
                  _rangeNote = false;
                }
                _clearErrors();
              }),
            ),
        ]),
        const SizedBox(height: 12),
      ],
      if (_mode == _Mode.payee) _payeeField(edit) else _textField(),
      if (_mode == _Mode.contains) ...[const SizedBox(height: 14), _rangeFields()],
      if (_mode == _Mode.regex && (_rangeNote || _edit?.minCents != null || _edit?.maxCents != null))
        const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Muted("Amount ranges work with 'description contains' only.", key: ValueKey('rangeNote'))),
      if (!_tagsOnly) ...[
        const SizedBox(height: 14),
        MainTagPicker(
            dropdown: true,
            table: wc.categoryTable,
            ids: _mainIds,
            selected: _cat,
            onPick: (v) => setState(() {
                  _cat = v;
                  _catError = null;
                })),
        if (_catError != null)
          Padding(
              padding: const EdgeInsets.only(top: 4),
              child:
                  Text(_catError!, key: const ValueKey('ruleCatError'), style: TextStyle(color: context.c.bad, fontSize: BwType.metaSize))),
      ],
      if (_mode == _Mode.payee) ...[const SizedBox(height: 14), _tagChips()],
      if (!_tagsOnly) ...[
        const SizedBox(height: 14),
        Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          OutlinedButton(key: const ValueKey('rulePreview'), onPressed: _preview, child: const Text('Preview')),
          if (fresh && _previewCount != null)
            Text(
                _previewCount == 0
                    ? 'No payment changes.'
                    : _previewCount == 1
                        ? 'This changes the main tag of 1 payment.'
                        : 'This changes the main tag of $_previewCount payments.',
                key: const ValueKey('rulePreviewText'),
                style: const TextStyle(fontSize: BwType.bodySize)),
        ]),
      ],
      const SizedBox(height: 14),
      FilledButton(
          key: const ValueKey('ruleSave'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: _save,
          child: const Text('Save')),
    ]);
  }

  Widget _payeeField(bool edit) {
    if (edit) {
      return InputDecorator(
          decoration: const InputDecoration(labelText: 'Payee'),
          child: Text(_payee!.replaceAll('_', ' '), key: const ValueKey('rulePayeeFixed')));
    }
    if (_payees.isEmpty) return const Muted('No payments to pick a payee from yet.');
    return InputDecorator(
      decoration: InputDecoration(labelText: 'Payee', errorText: _payeeError, errorMaxLines: 3),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const ValueKey('rulePayee'),
          isExpanded: true,
          isDense: true,
          value: _payee,
          hint: const Text('Pick a payee'),
          items: [
            for (final p in _payees)
              DropdownMenuItem<String>(
                  value: p.key, child: Text(p.label, key: ValueKey('payeeItem:${p.key}'), overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() {
            _payee = v;
            _payeeError = null;
          }),
        ),
      ),
    );
  }

  Widget _textField() => TextField(
        key: const ValueKey('ruleText'),
        controller: _text,
        autofocus: _edit == null,
        maxLength: _mode == _Mode.contains ? MerchantPattern.maxContainsLength : null,
        onChanged: (_) {
          _clearErrors();
          setState(() {});
        },
        decoration: InputDecoration(
            labelText: _mode == _Mode.contains ? 'Description contains' : 'Pattern (regex)',
            helperText: _mode == _Mode.contains ? 'Capitals and accents do not matter.' : null,
            helperMaxLines: 2,
            errorText: _textError,
            errorMaxLines: 3,
            counterText: ''),
      );

  Widget _rangeFields() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Muted('Only when the amount is between'),
        const SizedBox(height: 6),
        LayoutBuilder(builder: (context, box) {
          final from = _moneyField(_min, 'ruleMin', 'From'), to = _moneyField(_max, 'ruleMax', 'To');
          if (box.maxWidth < 360) return Column(children: [from, const SizedBox(height: 8), to]);
          return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Expanded(child: from), const SizedBox(width: 8), Expanded(child: to)]);
        }),
        if (_rangeError != null)
          Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_rangeError!,
                  key: const ValueKey('ruleRangeError'), style: TextStyle(color: context.c.bad, fontSize: BwType.metaSize))),
      ]);

  Widget _moneyField(TextEditingController c, String key, String label) => MoneyField(
        controller: c,
        fieldKey: ValueKey(key),
        onChanged: (_) {
          _clearErrors();
          setState(() {});
        },
        decoration: InputDecoration(labelText: label, hintText: 'Any', suffixText: _symbol),
      );

  String get _symbol => money(0, widget.wc.currency, decimals: 0).split(' ').last;

  Widget _tagChips() {
    final t = widget.wc.tagTable;
    final ids = [...t.pickable().take(extraTagTop), ..._tags.where((x) => !t.pickable().take(extraTagTop).contains(x) && t.isKnown(x))];
    if (ids.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Muted('Also tag every payment from this payee with'),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final id in ids)
          FilterChip(
            key: ValueKey('rtag:$id'),
            label: Text(tagText(t, id)),
            selected: _tags.contains(id),
            onSelected: (v) => setState(() => v ? _tags.add(id) : _tags.remove(id)),
          ),
      ]),
    ]);
  }
}
