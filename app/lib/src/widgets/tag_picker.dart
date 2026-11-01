// Extra tags in the UI (T1): the small `#tag` chips on a payment row, and the editor in the transaction sheet and the add-expense sheet
// (tags on the payment, suggestions, every tag in recommended order, a new tag, and the payee rule). The main tag is the row's category
// (category_picker.dart); extra tags only track, they never move money.
//
// Nothing is tagged without a tap: a suggestion is a faded chip with a "+". Taps are a draft: the sheet's Save writes them (core's
// `setTxTag` / `setRuleTag`), closing it writes nothing.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../theme.dart';
import 'common.dart';

/// How many extra tags a picker shows before "More…".
const int extraTagTop = 20;

/// Extra tags a row shows as chips before "+N".
const int rowTagsShown = 3;

/// `#name` for tag [id].
String tagText(TagTable t, String id) => '#${t.label(id)}';

/// One small read-only `#tag` chip.
class TagChip extends StatelessWidget {
  final String text;
  const TagChip(this.text, {super.key});
  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 140),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(border: Border.all(color: context.c.line), borderRadius: BorderRadius.circular(6)),
          child:
              Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
        ),
      );
}

/// The chips of a row: the first [rowTagsShown] extra tags as `#name`, then "+N" for the rest (key `rowTags`).
List<Widget> rowTagChips(TagTable table, List<String> tags) => [
      for (final id in tags.take(rowTagsShown)) TagChip(tagText(table, id), key: ValueKey('rowTag:$id')),
      if (tags.length > rowTagsShown)
        Text('+${tags.length - rowTagsShown}',
            key: const ValueKey('rowTagsMore'),
            style: const TextStyle(fontSize: BwType.metaSize),
            semanticsLabel: '${tags.length - rowTagsShown} more tags'),
    ];

/// The extra tags of one payment, as a draft: a tap changes only what this widget holds and reports it through [onChanged] (the tags on the
/// payment and the tags its payee gives to every payment). The sheet writes them with its Save (`WalletController.saveTagChanges`, or
/// `addExpense(tags:)` for a payment being added); closing the sheet writes nothing. Only "New tag" writes at once: it makes the tag.
class ExtraTagsEditor extends StatefulWidget {
  final WalletController wc;

  /// The saved payment, or null for one being added.
  final CategorizedTx? tx;

  /// The tags chosen so far for a payment being added.
  final Set<String> initial;
  final void Function(Set<String> on, Set<String> rule)? onChanged;

  /// Offer "Also tag every payment from this payee with…" (a bank row with a payee).
  final bool payeeRule;
  const ExtraTagsEditor({super.key, required this.wc, this.tx, this.initial = const {}, this.onChanged, this.payeeRule = false});
  @override
  State<ExtraTagsEditor> createState() => _ExtraTagsEditorState();
}

class _ExtraTagsEditorState extends State<ExtraTagsEditor> {
  late final Set<String> _rule0 = widget.tx == null ? {} : widget.wc.ruleTagsOf(widget.tx!.tx);
  late final Set<String> _on = widget.tx != null ? {...widget.tx!.tags} : {...widget.initial};
  late final Set<String> _rule = {..._rule0};

  /// The tags the payee rule chips ever showed (they stay while toggled, so a tap can be undone).
  late final Set<String> _ruleChips = {..._rule0, ..._on};

  /// Recommended order and suggestions: read once per sheet (core's ordering reads every row).
  late final List<String> _recommended = widget.wc.recommendedTagsFor(widget.tx?.tx);
  late final List<String> _suggested = widget.tx == null ? const [] : widget.wc.suggestedTagsFor(widget.tx!.tx);
  bool _adding = false, _all = false, _removedFromRule = false;
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  TagTable get _table => widget.wc.tagTable;

  void _report() => widget.onChanged?.call({..._on}, {..._rule});

  void _set(String id, bool on) {
    setState(() {
      if (on) {
        _on.add(id);
        _ruleChips.add(id);
      } else {
        _on.remove(id);
      }
      _removedFromRule = !on && _rule.contains(id);
      _error = null;
    });
    _report();
  }

  void _setRule(String id, bool on) {
    setState(() {
      if (on) {
        _rule.add(id);
        _on.add(id);
      } else {
        _rule.remove(id);
        // A tag the row had only because of the rule goes with it; one the owner added to this payment stays.
        if (_rule0.contains(id) && widget.wc.tagContext.links[widget.tx!.tx.id]?[id] != true) _on.remove(id);
      }
      _removedFromRule = false;
      _error = null;
    });
    _report();
  }

  Future<void> _create() async {
    final text = _name.text;
    try {
      final id = await widget.wc.addTag(text);
      _name.clear();
      if (mounted) _set(id, true);
    } on ArgumentError catch (e) {
      setState(() => _error = e.message.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final table = _table;
    final onIds = [
      for (final id in table.ids)
        if (_on.contains(id)) id
    ];
    // A tag turned on that is gone from the table (deleted since) is not shown.
    final suggested = [
      for (final id in _suggested)
        if (!_on.contains(id) && table.isLive(id)) id
    ];
    // The recommended order first, then every other tag that can be picked (one made or hidden since the sheet opened).
    final rest = [
      for (final id in table.pickable())
        if (!_recommended.contains(id)) id
    ];
    final others = [
      for (final id in [..._recommended.where(table.pickable().contains), ...rest])
        if (!_on.contains(id) && !suggested.contains(id)) id
    ];
    final shown = _all ? others : others.take(extraTagTop).toList();
    final payee = widget.tx == null ? null : merchantName(widget.tx!.tx);
    final ruleIds = [
      for (final id in table.ids)
        if (_ruleChips.contains(id)) id
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, key: const ValueKey('extraTags'), children: [
      InputDecorator(
        decoration: const InputDecoration(labelText: 'Tags'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (onIds.isEmpty)
            const Muted('No extra tags on this payment.', key: ValueKey('noTags'))
          else
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final id in onIds)
                FilterChip(
                  key: ValueKey('tagOn:$id'),
                  selected: true,
                  tooltip: _rule.contains(id) ? 'From a rule. Tap to remove it from this payment only.' : 'Tap to remove',
                  label: Text(_rule.contains(id) ? '${tagText(table, id)} · from rule' : tagText(table, id)),
                  onSelected: (_) => _set(id, false),
                ),
            ]),
          if (_removedFromRule) ...[
            const SizedBox(height: 6),
            const Muted('Removed from this payment only. A rule still adds it to the other payments from this payee.',
                key: ValueKey('ruleOffNote')),
          ],
          if (suggested.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Muted('Suggested from this payee. Tap to add.'),
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final id in suggested)
                Opacity(
                  opacity: 0.72,
                  child: ActionChip(
                    key: ValueKey('tagSuggest:$id'),
                    avatar: const Icon(Icons.add, size: 16),
                    label: Text(tagText(table, id)),
                    onPressed: () => _set(id, true),
                  ),
                ),
            ]),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('tagAdd'),
              icon: Icon(_adding ? Icons.expand_less : Icons.add, size: 18),
              label: Text(_adding ? 'Hide tags' : 'Add a tag'),
              onPressed: () => setState(() => _adding = !_adding),
            ),
          ),
          if (_adding) ...[
            if (shown.isNotEmpty)
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final id in shown)
                  FilterChip(
                    key: ValueKey('tagPick:$id'),
                    selected: false,
                    label: Text(tagText(table, id)),
                    onSelected: (_) => _set(id, true),
                  ),
                if (!_all && others.length > extraTagTop)
                  ActionChip(key: const ValueKey('tagMore'), label: const Text('More…'), onPressed: () => setState(() => _all = true)),
              ]),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('tagNew'),
              controller: _name,
              maxLength: TagRow.maxName,
              textCapitalization: TextCapitalization.none,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _create(),
              decoration: InputDecoration(
                labelText: 'New tag',
                counterText: '',
                errorText: _error,
                errorMaxLines: 3,
                suffixIcon:
                    IconButton(key: const ValueKey('tagNewGo'), tooltip: 'Add tag', icon: const Icon(Icons.add), onPressed: _create),
              ),
            ),
          ] else if (_error != null)
            Text(_error!, style: TextStyle(color: c.bad, fontSize: BwType.metaSize)),
        ]),
      ),
      if (widget.payeeRule && payee != null) ...[
        const SizedBox(height: 10),
        Text('Also tag every payment from $payee with…',
            key: const ValueKey('payeeRuleTitle'), style: const TextStyle(fontSize: BwType.bodySize)),
        const SizedBox(height: 4),
        if (ruleIds.isEmpty)
          const Muted('Tag this payment first, then pick the tags here.', key: ValueKey('payeeRuleEmpty'))
        else
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final id in ruleIds)
              FilterChip(
                key: ValueKey('ruleTag:$id'),
                selected: _rule.contains(id),
                label: Text(tagText(table, id)),
                onSelected: (v) => _setRule(id, v),
              ),
          ]),
      ],
    ]);
  }
}
