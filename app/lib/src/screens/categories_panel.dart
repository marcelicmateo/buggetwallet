// Plan › Categories (P1): the built-in categories and the owner's own, grouped by kind, each main category with its subcategories
// indented under it. Add / add subcategory / rename / hide / move / delete with Undo. The rules (one level, same kind as the parent,
// unique names, at most 200) are core's; its `ArgumentError` text is shown under the field or in a toast.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
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

enum _Act { rename, hide, up, down, addChild, delete }

class CategoriesPanel extends StatelessWidget {
  final WalletController wc;
  const CategoriesPanel({super.key, required this.wc});

  @override
  Widget build(BuildContext context) {
    final t = wc.categoryTable;
    return Panel(children: [
      SectionHead('Categories',
          trailing: TextButton.icon(
              key: const ValueKey('categoryAdd'),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
              onPressed: () => openAddCategory(context, wc))),
      Explainer(wc, 'categories',
          'Your own categories sit next to the built-in ones. A subcategory counts in its main category. Hide one to stop it showing in pickers.'),
      for (final (id, title, kinds) in _groups) ...[
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Heading(title, size: BwType.headingSize, key: ValueKey('categoryGroup:$id')),
        ),
        Rows(children: [
          for (final c in t.topLevelIds)
            if (kinds.contains(t.kindOf(c))) ...[
              _CategoryRow(wc: wc, id: c),
              for (final k in t.childrenOf(c)) _CategoryRow(wc: wc, id: k, child: true),
            ],
        ]),
      ],
    ]);
  }
}

class _CategoryRow extends StatelessWidget {
  final WalletController wc;
  final String id;
  final bool child;
  const _CategoryRow({required this.wc, required this.id, this.child = false});

  @override
  Widget build(BuildContext context) {
    final t = wc.categoryTable;
    final c = context.c;
    final label = t.label(id);
    final indent = child ? categoryRowIndent : 0.0;
    final dupOf = t.duplicateOf(id);
    if (dupOf != null) {
      return Padding(
        key: ValueKey('categoryDuplicate:$id'),
        padding: EdgeInsets.only(left: indent, top: 8, bottom: 8),
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
      padding: EdgeInsets.only(left: indent),
      child: Row(children: [
        if (child) ...[Icon(Icons.subdirectory_arrow_right, size: 16, color: c.muted), const SizedBox(width: 4)],
        Expanded(
          child: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(label, style: TextStyle(fontSize: BwType.bodySize, fontWeight: child ? FontWeight.w400 : FontWeight.w500)),
            if (hidden)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.visibility_off_outlined, size: 14, color: c.ink2, semanticLabel: 'Hidden'),
                const SizedBox(width: 3),
                Text('hidden', key: ValueKey('categoryHidden:$id'), style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
              ]),
            if (!custom && !child) const Tag('built in'),
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
            if (!child) PopupMenuItem(key: ValueKey('categoryAddChild:$id'), value: _Act.addChild, child: const Text('Add subcategory')),
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
      case _Act.addChild:
        await showSheet<bool>(context, CategoryFormSheet(wc: wc, parent: id));
      case _Act.hide:
        await _run(context, () => wc.setCategoryHidden(id, !wc.categoryTable.isHidden(id)));
      case _Act.up:
        await _run(context, () => wc.moveCategory(id, -1));
      case _Act.down:
        await _run(context, () => wc.moveCategory(id, 1));
      case _Act.delete:
        await deleteCategoryWithUndo(context, wc, id);
    }
  }

  Future<void> _run(BuildContext context, Future<void> Function() body) async {
    final messenger = ScaffoldMessenger.of(context);
    final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
    try {
      await body();
    } catch (e, st) {
      logError(Logger('bw.categories.ui'), 'categories.action.failed', e, st);
      toastOn(messenger, _problem(e), wide: wide, accessible: accessible);
    }
  }
}

/// How far a subcategory row is indented in the panel.
const double categoryRowIndent = 24;

/// Deletes the own category [id] and offers Undo in the toast. Core refuses while it has subcategories: its message is shown
/// instead. A sync duplicate ([duplicate]) is only removed (it was never offered).
Future<void> deleteCategoryWithUndo(BuildContext context, WalletController wc, String id, {bool duplicate = false}) async {
  logNav('categories.delete');
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
  say('Category removed', label: 'Undo', action: () async {
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

/// The add / add-subcategory / rename form: a name, and for a new main category its kind. [parent] set = a subcategory (its kind is
/// the parent's); [rename] set = the label of that category. Pops `true` once saved; core's refusal shows under the field.
class CategoryFormSheet extends StatefulWidget {
  final WalletController wc;
  final String? parent;
  final String? rename;
  const CategoryFormSheet({super.key, required this.wc, this.parent, this.rename});
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
        await widget.wc.renameCategory(widget.rename!, _name.text);
      } else {
        await widget.wc.addOwnCategory(name: _name.text, kind: _kind, parent: widget.parent);
      }
      if (mounted) Navigator.pop(context, true);
    } on ArgumentError catch (e) {
      setState(() => _error = e.message.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.wc.categoryTable;
    final title = widget.rename != null
        ? 'Rename category'
        : widget.parent != null
            ? 'Add subcategory'
            : 'Add category';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(title),
      if (widget.parent != null) ...[
        const SizedBox(height: 4),
        Muted('In ${t.label(widget.parent!)}. It counts in that category.', size: BwType.metaSize),
      ],
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
      if (widget.rename == null && widget.parent == null) ...[
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
