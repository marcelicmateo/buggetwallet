// Budget › Tags (tags) (T1): the owner's extra tags, with how many payments each has. Add / rename / hide / move / delete with Undo. A tag only
// tracks: the main tag (the Main tags section) decides the money. The name rules (1-40 characters, unique, not a main tag's name, at most
// 500) are core's; its `ArgumentError` text is shown under the field or in a toast.
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

final _log = Logger('bw.tags.ui');

enum _Act { rename, hide, up, down, delete }

class TagsPanel extends StatelessWidget {
  final WalletController wc;
  const TagsPanel({super.key, required this.wc});

  @override
  Widget build(BuildContext context) {
    final t = wc.tagTable;
    final counts = wc.tagUseCounts();
    final ids = t.ids; // once per build: the rows get their place in it
    // Sync duplicates (the same name added on two devices) are listed apart: the original counts their payments.
    final dups = [
      for (final id in t.liveIds)
        if (t.duplicateOf(id) != null) id
    ];
    return Panel(children: [
      const SectionHead('Tags'),
      Explainer(
          wc,
          'tags',
          'Tags track what a payment was for, as deep as you like. A payment can have any number of them. They never change your budget: '
              'its main tag does that.'),
      if (ids.isEmpty && dups.isEmpty)
        const Padding(
            padding: EdgeInsets.only(top: 6),
            child: EmptyNote('No tags yet. Tap Add above, or tag a payment from its sheet.', key: ValueKey('tagsEmpty')))
      else
        Rows(children: [
          for (var i = 0; i < ids.length; i++) _TagRow(wc: wc, id: ids[i], count: counts[ids[i]] ?? 0, pos: i, last: ids.length - 1),
          for (final id in dups) _DuplicateRow(wc: wc, id: id),
        ]),
    ]);
  }
}

class _DuplicateRow extends StatelessWidget {
  final WalletController wc;
  final String id;
  const _DuplicateRow({required this.wc, required this.id});
  @override
  Widget build(BuildContext context) {
    final t = wc.tagTable;
    return Padding(
      key: ValueKey('tagDuplicate:$id'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Icon(Icons.content_copy_outlined, size: 18, color: context.c.muted),
        const SizedBox(width: 8),
        Expanded(child: Muted('${t.label(id)}: same name as ${t.label(t.duplicateOf(id)!)}, merged', size: BwType.bodySize)),
        TextButton(
            key: ValueKey('tagDelete:$id'),
            onPressed: () => deleteTagWithUndo(context, wc, id, duplicate: true),
            child: const Text('Delete')),
      ]),
    );
  }
}

class _TagRow extends StatelessWidget {
  final WalletController wc;
  final String id;
  final int count;

  /// This tag's place in the list and the last place (Move up / down are off at the ends).
  final int pos, last;
  const _TagRow({required this.wc, required this.id, required this.count, required this.pos, required this.last});

  @override
  Widget build(BuildContext context) {
    final t = wc.tagTable;
    final c = context.c;
    final label = t.label(id);
    final hidden = t.isHidden(id);
    return Container(
      key: ValueKey('tag:$id'),
      constraints: const BoxConstraints(minHeight: touchMin),
      child: Row(children: [
        Expanded(
          child: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('#$label', style: const TextStyle(fontSize: BwType.bodySize, fontWeight: FontWeight.w500)),
            Text(count == 1 ? '1 payment' : '$count payments',
                key: ValueKey('tagCount:$id'), style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
            if (hidden)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.visibility_off_outlined, size: 14, color: c.ink2, semanticLabel: 'Hidden'),
                const SizedBox(width: 3),
                Text('hidden', key: ValueKey('tagHidden:$id'), style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
              ]),
          ]),
        ),
        PopupMenuButton<_Act>(
          key: ValueKey('tagMenu:$id'),
          tooltip: 'Actions for $label',
          icon: const Icon(Icons.more_vert),
          constraints: const BoxConstraints(minWidth: 180),
          onSelected: (a) => _act(context, a),
          itemBuilder: (_) => [
            PopupMenuItem(key: ValueKey('tagRename:$id'), value: _Act.rename, child: const Text('Rename')),
            PopupMenuItem(key: ValueKey('tagHide:$id'), value: _Act.hide, child: Text(hidden ? 'Show' : 'Hide')),
            PopupMenuItem(key: ValueKey('tagUp:$id'), value: _Act.up, enabled: pos > 0, child: const Text('Move up')),
            PopupMenuItem(key: ValueKey('tagDown:$id'), value: _Act.down, enabled: pos < last, child: const Text('Move down')),
            PopupMenuItem(key: ValueKey('tagDeleteItem:$id'), value: _Act.delete, child: const Text('Delete')),
          ],
        ),
      ]),
    );
  }

  Future<void> _act(BuildContext context, _Act a) async {
    logNav('tags.${a.name}');
    switch (a) {
      case _Act.rename:
        await showSheet<bool>(context, TagFormSheet(wc: wc, rename: id));
      case _Act.hide:
        await _run(context, () => wc.setTagHidden(id, !wc.tagTable.isHidden(id)));
      case _Act.up:
        await _run(context, () => wc.moveTag(id, -1));
      case _Act.down:
        await _run(context, () => wc.moveTag(id, 1));
      case _Act.delete:
        await deleteTagWithUndo(context, wc, id);
    }
  }

  Future<void> _run(BuildContext context, Future<void> Function() body) async {
    final messenger = ScaffoldMessenger.of(context);
    final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
    try {
      await body();
    } catch (e, st) {
      logError(_log, 'tags.action.failed', e, st);
      toastOn(messenger, _problem(e), wide: wide, accessible: accessible);
    }
  }
}

/// Deletes the tag [id] and offers Undo in the toast. A sync duplicate ([duplicate]) is only removed.
Future<void> deleteTagWithUndo(BuildContext context, WalletController wc, String id, {bool duplicate = false}) async {
  logNav('tags.delete');
  final messenger = ScaffoldMessenger.of(context);
  final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
  void say(String m, {String? label, VoidCallback? action}) =>
      toastOn(messenger, m, wide: wide, accessible: accessible, actionLabel: label, onAction: action);
  try {
    await wc.deleteTag(id);
  } catch (e, st) {
    logError(_log, 'tags.delete.failed', e, st);
    say(_problem(e));
    return;
  }
  if (duplicate) {
    say('Removed');
    return;
  }
  say('Tag removed', label: 'Undo', action: () async {
    try {
      await wc.undeleteTag(id);
    } catch (e, st) {
      logError(_log, 'tags.undelete.failed', e, st);
      say(_problem(e));
    }
  });
}

Future<void> openAddTag(BuildContext context, WalletController wc) async {
  logNav('tags.add');
  await showSheet<bool>(context, TagFormSheet(wc: wc));
}

/// The add / rename form: a name. [rename] set = the tag being renamed. Pops `true` once saved; core's refusal shows under the field.
class TagFormSheet extends StatefulWidget {
  final WalletController wc;
  final String? rename;
  const TagFormSheet({super.key, required this.wc, this.rename});
  @override
  State<TagFormSheet> createState() => _TagFormSheetState();
}

class _TagFormSheetState extends State<TagFormSheet> {
  late final _name = TextEditingController(text: widget.rename == null ? '' : widget.wc.tagTable.label(widget.rename!));
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      if (widget.rename != null) {
        await widget.wc.renameTag(widget.rename!, _name.text);
      } else {
        await widget.wc.addTag(_name.text);
      }
      if (mounted) Navigator.pop(context, true);
    } on ArgumentError catch (e) {
      setState(() => _error = e.message.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Heading(widget.rename != null ? 'Rename tag' : 'Add tag'),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('tagName'),
          controller: _name,
          autofocus: true,
          maxLength: TagRow.maxName,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _save(),
          decoration: InputDecoration(labelText: 'Name', errorText: _error, errorMaxLines: 3, counterText: ''),
        ),
        const SizedBox(height: 14),
        FilledButton(
            key: const ValueKey('tagSave'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
            onPressed: _save,
            child: const Text('Save')),
      ]);
}
