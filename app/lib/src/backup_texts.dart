import 'package:wallet_core/wallet_core.dart' show MergeResult;

/// Plain names of the synced entities (`entitySchema` keys) for the merge preview: (one, many).
const _entityNames = <String, (String, String)>{
  'tx': ('payment', 'payments'),
  'goal': ('goal', 'goals'),
  'wish': ('wishlist item', 'wishlist items'),
  'setting': ('setting', 'settings'),
  'rule': ('payee rule', 'payee rules'),
  'goal_contrib': ('goal deposit', 'goal deposits'),
  'recurring': ('expected bill', 'expected bills'),
  'planned': ('planned cost', 'planned costs'),
  'bill': ('bill', 'bills'),
  'account': ('account', 'accounts'),
  'category': ('main tag', 'main tags'),
  'tag': ('tag', 'tags'),
  'txtag': ('tag link', 'tag links'),
  'ruletag': ('tag link', 'tag links'),
  'split': ('split', 'splits'),
};

String _count(int n, String one, String many) => n == 1 ? '1 $one' : '$n $many';

/// "1 bill file" / "3 bill files".
String billFilesText(int n) => _count(n, 'bill file', 'bill files');

/// "30 payments, 8 tags, 4 settings" (largest first; entities that share a name are added up; unknown ones are "other").
String changeBreakdown(Map<String, int> byEntity) {
  final names = <String, int>{};
  for (final e in byEntity.entries) {
    if (e.value <= 0) continue;
    final n = _entityNames[e.key]?.$2 ?? 'other';
    names.update(n, (v) => v + e.value, ifAbsent: () => e.value);
  }
  final rows = names.entries.toList()
    ..sort((a, b) {
      if ((a.key == 'other') != (b.key == 'other')) return a.key == 'other' ? 1 : -1; // "other" last
      return b.value != a.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key);
    });
  return [
    for (final r in rows)
      if (r.key == 'other') '${r.value} other' else _count(r.value, _entityNames.values.firstWhere((v) => v.$2 == r.key).$1, r.key)
  ].join(', ');
}

/// The preview sentence of a merge ([MergeResult] from a dry run).
String mergePreviewText(MergeResult r) {
  const rule = 'Newer changes win; nothing is doubled.';
  final files = r.blobs > 0 ? billFilesText(r.blobs) : '';
  if (r.changed == 0) return 'This brings in $files. $rule';
  final head = 'This brings in ${_count(r.changed, 'update', 'updates')}: ${changeBreakdown(r.changedByEntity)}';
  return '$head${files.isEmpty ? '' : ' and $files'}. $rule';
}

/// The toast after a merge.
String mergedToastText(MergeResult r) {
  if (r.changed == 0) return 'Merged ${billFilesText(r.blobs)}';
  return 'Merged ${_count(r.changed, 'update', 'updates')}${r.blobs > 0 ? ' and ${billFilesText(r.blobs)}' : ''}';
}
