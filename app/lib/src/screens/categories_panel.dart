// Budget › Tags (main tags) (P1, T1): the built-in categories and the owner's own, grouped by kind. A main tag decides the money (budgets, plan,
// safe-to-spend); the extra tags for tracking are in tags_panel.dart. Add / rename / hide / move / delete with Undo. The rules (unique
// names, at most 200) are core's; its `ArgumentError` text is shown under the field or in a toast.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// The readable text of an [ArgumentError] from core.
String _problem(Object e) => e is ArgumentError ? e.message.toString() : 'Could not save. Try again.';

/// The kinds a new main category can have, with the words the panel and the form use.
const _kindChoices = <(BudgetKind, String)>[
  (BudgetKind.fixed, 'Fixed cost (rent, bills)'),
  (BudgetKind.flex, 'Flexible spending'),
  (BudgetKind.income, 'Income'),
  (BudgetKind.extra, 'Extra income'),
  (BudgetKind.transfer, 'Transfer'),
];

/// The panel's groups: heading, the kinds in it.
const _groups = <(String, String, Set<BudgetKind>)>[
  ('fixed', 'Spending: fixed', {BudgetKind.fixed}),
  ('flex', 'Spending: flexible', {BudgetKind.flex}),
  ('income', 'Income', {BudgetKind.income, BudgetKind.extra}),
  ('transfer', 'Transfers', {BudgetKind.transfer}),
];

enum _Act { rename, hide, up, down, delete }

class CategoriesPanel extends StatelessWidget {
  final WalletController wc;
  const CategoriesPanel({super.key, required this.wc});

  @override
  Widget build(BuildContext context) {
    final t = wc.categoryTable;
    return Panel(children: [
      const SectionHead('Main tags'),
      Explainer(wc, 'categories',
          'A payment has one main tag. It decides what the payment counts for: budgets, your plan and what is safe to spend. Hide one to stop it showing in pickers.'),
      for (final (id, title, kinds) in _groups) ...[
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Heading(title, size: BwType.headingSize, key: ValueKey('categoryGroup:$id')),
        ),
        Rows(children: [
          for (final c in t.topLevelIds)
            if (kinds.contains(t.kindOf(c))) _CategoryRow(wc: wc, id: c),
        ]),
      ],
    ]);
  }
}

class _CategoryRow extends StatelessWidget {
  final WalletController wc;
  final String id;
  const _CategoryRow({required this.wc, required this.id});

  @override
  Widget build(BuildContext context) {
    final t = wc.categoryTable;
    final c = context.c;
    final label = t.label(id);
    final dupOf = t.duplicateOf(id);
    if (dupOf != null) {
      return Padding(
        key: ValueKey('categoryDuplicate:$id'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(Icons.content_copy_outlined, size: 18, color: c.muted),
          const SizedBox(width: 8),
          Expanded(child: Muted('$label: same name as ${t.label(dupOf)}, not offered', size: BwType.bodySize)),
          TextButton(
              key: ValueKey('categoryDelete:$id'),
              onPressed: () => deleteCategoryWithUndo(context, wc, id, duplicate: true),
              child: const Text('Delete')),
        ]),
      );
    }
    final hidden = t.isHidden(id);
    final sibs = wc.categorySiblings(id);
    final pos = sibs.indexOf(id);
    final custom = t.isCustom(id);
    return Container(
      key: ValueKey('category:$id'),
      constraints: const BoxConstraints(minHeight: touchMin),
      child: Row(children: [
        Expanded(
          child: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(label, style: const TextStyle(fontSize: BwType.bodySize, fontWeight: FontWeight.w500)),
            if (hidden)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.visibility_off_outlined, size: 14, color: c.ink2, semanticLabel: 'Hidden'),
                const SizedBox(width: 3),
                Text('hidden', key: ValueKey('categoryHidden:$id'), style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
              ]),
            if (!custom) const Tag('built in'),
          ]),
        ),
        PopupMenuButton<_Act>(
          key: ValueKey('categoryMenu:$id'),
          tooltip: 'Actions for $label',
          icon: const Icon(Icons.more_vert),
          constraints: const BoxConstraints(minWidth: 180),
          onSelected: (a) => _act(context, a),
          itemBuilder: (_) => [
            PopupMenuItem(key: ValueKey('categoryRename:$id'), value: _Act.rename, child: const Text('Rename')),
            PopupMenuItem(key: ValueKey('categoryHide:$id'), value: _Act.hide, child: Text(hidden ? 'Show' : 'Hide')),
            PopupMenuItem(key: ValueKey('categoryUp:$id'), value: _Act.up, enabled: pos > 0, child: const Text('Move up')),
            PopupMenuItem(
                key: ValueKey('categoryDown:$id'),
                value: _Act.down,
                enabled: pos >= 0 && pos < sibs.length - 1,
                child: const Text('Move down')),
            if (custom) PopupMenuItem(key: ValueKey('categoryDeleteItem:$id'), value: _Act.delete, child: const Text('Delete')),
          ],
        ),
      ]),
    );
  }

  Future<void> _act(BuildContext context, _Act a) async {
    logNav('categories.${a.name}');
    switch (a) {
      case _Act.rename:
        await showSheet<bool>(context, CategoryFormSheet(wc: wc, rename: id));
      case _Act.hide:
        _run(context, () => wc.setCategoryHidden(id, !wc.categoryTable.isHidden(id)));
      case _Act.up:
        _run(context, () => wc.moveCategory(id, -1));
      case _Act.down:
        _run(context, () => wc.moveCategory(id, 1));
      case _Act.delete:
        await deleteCategoryWithUndo(context, wc, id);
    }
  }

  void _run(BuildContext context, void Function() body) {
    final messenger = ScaffoldMessenger.of(context);
    final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
    try {
      body();
    } catch (e, st) {
      logError(Logger('bw.categories.ui'), 'categories.action.failed', e, st);
      toastOn(messenger, _problem(e), wide: wide, accessible: accessible);
    }
  }
}

/// Deletes the own main tag [id] and offers Undo in the toast. A sync duplicate ([duplicate]) is only removed (it was never offered).
Future<void> deleteCategoryWithUndo(BuildContext context, WalletController wc, String id, {bool duplicate = false}) async {
  logNav('categories.delete');
  // A category with a plan line: say what goes with it before it is deleted.
  final line = wc.settings.planLines[id] ?? 0;
  if (line > 0) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('categoryDeleteConfirm'),
        title: const Text('Delete this main tag?'),
        content: Text('Its plan line (${moneyExact(line, wc.currency)}) goes too. Its bills then count under the automatic category.'),
        actions: [
          TextButton(key: const ValueKey('categoryDeleteCancel'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('categoryDeleteGo'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
  void say(String m, {String? label, VoidCallback? action}) =>
      toastOn(messenger, m, wide: wide, accessible: accessible, actionLabel: label, onAction: action);
  try {
    await wc.deleteOwnCategory(id);
  } catch (e, st) {
    logError(Logger('bw.categories.ui'), 'categories.delete.failed', e, st);
    say(_problem(e));
    return;
  }
  if (duplicate) {
    say('Removed');
    return;
  }
  say('Main tag removed', label: 'Undo', action: () async {
    try {
      await wc.undeleteOwnCategory(id);
    } catch (e, st) {
      logError(Logger('bw.categories.ui'), 'categories.undelete.failed', e, st);
      say(_problem(e));
    }
  });
}

Future<void> openAddCategory(BuildContext context, WalletController wc) async {
  logNav('categories.add');
  await showSheet<bool>(context, CategoryFormSheet(wc: wc));
}

/// The add / rename form: a name, and for a new main tag its kind. [rename] set = the label of that main tag. Pops `true` once saved;
/// core's refusal shows under the field.
class CategoryFormSheet extends StatefulWidget {
  final WalletController wc;
  final String? rename;
  const CategoryFormSheet({super.key, required this.wc, this.rename});
  @override
  State<CategoryFormSheet> createState() => _CategoryFormSheetState();
}

class _CategoryFormSheetState extends State<CategoryFormSheet> {
  late final _name = TextEditingController(text: widget.rename == null ? '' : widget.wc.categoryTable.label(widget.rename!));
  BudgetKind _kind = BudgetKind.flex;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      if (widget.rename != null) {
        widget.wc.renameCategory(widget.rename!, _name.text);
      } else {
        await widget.wc.addOwnCategory(name: _name.text, kind: _kind);
      }
      if (mounted) Navigator.pop(context, true);
    } on ArgumentError catch (e) {
      setState(() => _error = e.message.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.rename != null ? 'Rename main tag' : 'Add main tag';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(title),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('categoryName'),
        controller: _name,
        autofocus: true,
        maxLength: CategoryRow.maxName,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        decoration: InputDecoration(labelText: 'Name', errorText: _error, errorMaxLines: 3, counterText: ''),
      ),
      if (widget.rename == null) ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<BudgetKind>(
          key: const ValueKey('categoryKind'),
          isExpanded: true,
          initialValue: _kind,
          decoration: const InputDecoration(labelText: 'Kind'),
          items: [for (final (k, label) in _kindChoices) DropdownMenuItem(value: k, child: Text(label))],
          onChanged: (v) => setState(() => _kind = v ?? _kind),
        ),
      ],
      const SizedBox(height: 14),
      FilledButton(
          key: const ValueKey('categorySave'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: _save,
          child: const Text('Save')),
    ]);
  }
}
