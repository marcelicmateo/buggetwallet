// Settings › Sync › Recent changes (Q9): the newest changed rows on this device, from this device and from the others, read-only.
// "Today 14:02 · other device 3fa9 · Payment Konzum · category". A payment opens its sheet. The labels are shown here and never logged.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart' show CategorizedTx, ChangeEntry, isoDate;

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../memo_key.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// How many changes show at first, and how many more each "Show more" adds.
const changesPage = 30;

/// "Today 14:02", "Yesterday 09:30" or "3 Oct 17:45": the local time of [millis] against [now].
String changeWhenText(int millis, DateTime now) {
  final t = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toLocal();
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final day = isoDate(t), today = isoDate(now);
  if (day == today) return 'Today $hm';
  if (day == isoDate(DateTime(now.year, now.month, now.day - 1))) return 'Yesterday $hm';
  return '${shortDate(day)} $hm';
}

/// The line of one change (the owner's words, not column names or setting keys; never a value).
String changeLine(ChangeEntry e, DateTime now) {
  final who = e.thisDevice ? 'this device' : 'other device${e.node.length >= 4 ? ' ${e.node.substring(0, 4)}' : ''}';
  final String named, what;
  switch (e.entity) {
    case 'setting':
      named = changeSettingWord(e.id);
      what = e.deleted ? 'removed' : 'changed';
    case 'rule' || 'ruletag':
      named = changeEntityWord(e.entity); // the label is the payee's key: not shown
      what = e.deleted ? 'deleted' : changeFieldsText(e.fields);
    default:
      var label = e.label;
      if (e.entity == 'tx') label = label.replaceFirst(RegExp(r' · \d{4}-\d{2}-\d{2}$'), '');
      final word = changeEntityWord(e.entity);
      named = label.isEmpty || label == e.entity ? word : '$word $label';
      what = e.deleted ? 'deleted' : changeFieldsText(e.fields);
  }
  return '${changeWhenText(e.millis, now)} · $who · $named · $what';
}

class RecentChanges extends StatefulWidget {
  final WalletController wc;
  const RecentChanges({super.key, required this.wc});
  @override
  State<RecentChanges> createState() => _RecentChangesState();
}

class _RecentChangesState extends State<RecentChanges> {
  int _limit = changesPage;

  Future<void> _open(CategorizedTx t) async {
    logNav('changes.open', {'entity': 'tx'});
    final r = await showSheet<String>(context, TxSheet(wc: widget.wc, t: t));
    if (mounted) txSheetToast(context, widget.wc, r);
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    // One more than shown: the extra row says there is more (no "Show more" at exactly a full page).
    final fetched = wc.recentChangesList(limit: _limit + 1);
    final more = fetched.length > _limit;
    final list = more ? fetched.sublist(0, _limit) : fetched;
    final byId = wc.memo(const MemoKey('changes.txById'), () => {for (final c in wc.wholeTxs) c.tx.id: c}); // once per data version
    final c = context.c;
    return Column(key: const ValueKey('recentChanges'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('Recent changes', size: BwType.headingSize),
      const SizedBox(height: 4),
      const Muted('What changed on this device, and on the others you synced with. Read-only.'),
      if (list.isEmpty)
        const EmptyNote('Nothing changed yet.', key: ValueKey('changesEmpty'))
      else
        Rows(children: [
          for (final e in list)
            InkWell(
              key: ValueKey('change:${e.entity}:${e.id}'),
              onTap: e.entity == 'tx' && !e.deleted && byId[e.id] != null ? () => _open(byId[e.id]!) : null,
              mouseCursor: SystemMouseCursors.click,
              hoverColor: c.surface2,
              child: Container(
                constraints: const BoxConstraints(minHeight: rowMin),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(changeLine(e, wc.now), style: const TextStyle(fontSize: BwType.metaSize, height: 1.4)),
              ),
            ),
        ]),
      if (more)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
              key: const ValueKey('changesMore'),
              style: TextButton.styleFrom(minimumSize: const Size(0, touchMin)),
              onPressed: () {
                logNav('changes.more');
                setState(() => _limit += changesPage);
              },
              child: const Text('Show more')),
        ),
    ]);
  }
}
