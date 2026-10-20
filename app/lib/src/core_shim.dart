// TEMPORARY: stands in for the M5 Polish API of wallet_core until branch `polish-core` is merged.
// Delete this file after `git merge polish-core` (and the `core_shim.dart` import in controller.dart).
import 'dart:convert';
import 'dart:io';

import 'package:wallet_core/wallet_core.dart';

class BackupInfo {
  final String name;
  final String date;
  const BackupInfo(this.name, this.date);
}

class BackupException implements Exception {
  final String message;
  const BackupException(this.message);
  @override
  String toString() => message;
}

extension WalletRepoIsEmpty on WalletRepo {
  bool get isEmpty => transactions().isEmpty && goals().isEmpty && wishlist().isEmpty;
}

String _dir(String folder) => '$folder${Platform.pathSeparator}budget-wallet${Platform.pathSeparator}backups';

Future<String> writeBackup(WalletRepo repo, String syncFolder, VaultKey key, {required String today}) async {
  final d = Directory(_dir(syncFolder))..createSync(recursive: true);
  final name = 'bw-backup-$today.bwb';
  File('${d.path}${Platform.pathSeparator}$name').writeAsBytesSync(await seal(utf8.encode('{"rows":${repo.transactions().length}}'), key));
  return name;
}

Future<int> restoreBackup(WalletRepo repo, String file, VaultKey key) async {
  if (!repo.isEmpty) throw StateError('wallet is not empty');
  final j = jsonDecode(utf8.decode(await unseal(File(file).readAsBytesSync(), key))) as Map<String, Object?>;
  return j['rows'] as int;
}

Future<List<BackupInfo>> listBackups(String syncFolder) async {
  final d = Directory(_dir(syncFolder));
  if (!d.existsSync()) return [];
  final out = <BackupInfo>[];
  for (final f in d.listSync()) {
    final n = f.uri.pathSegments.last;
    final m = RegExp(r'^bw-backup-(\d{4}-\d{2}-\d{2})\.bwb$').firstMatch(n);
    if (m != null) out.add(BackupInfo(n, m.group(1)!));
  }
  out.sort((a, b) => b.date.compareTo(a.date));
  return out;
}

String _csv(Iterable<Object?> cells) => cells.map((c) {
      final s = '$c';
      return s.contains(RegExp('[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
    }).join(',');

String _dec(int c) => '${c < 0 ? '-' : ''}${c.abs() ~/ 100}.${(c.abs() % 100).toString().padLeft(2, '0')}';

String transactionsCsv(List<CategorizedTx> txs) => '${_csv(['date', 'amount', 'category', 'description', 'source', 'note'])}\n'
    '${txs.map((t) => '${_csv([t.date, _dec(t.amount), t.category, merchantName(t.tx), t.tx.source, t.tx.note])}\n').join()}';

String monthlySummaryCsv(List<CategorizedTx> txs) {
  final m = <String, int>{};
  for (final t in txs) {
    m.update('${t.date.substring(0, 7)}|${t.category}', (v) => v + t.amount, ifAbsent: () => t.amount);
  }
  final keys = m.keys.toList()..sort();
  return '${_csv(['month', 'category', 'total'])}\n${keys.map((k) => '${_csv([...k.split('|'), _dec(m[k]!)])}\n').join()}';
}

int? parseAmountQuery(String q) => null;

class SearchResult {
  final List<CategorizedTx> txs;
  final List<Goal> goals;
  final List<WishItem> wishlist;
  final List<RecurringBill> bills;
  const SearchResult({this.txs = const [], this.goals = const [], this.wishlist = const [], this.bills = const []});
  bool get isEmpty => txs.isEmpty && goals.isEmpty && wishlist.isEmpty && bills.isEmpty;
}

SearchResult searchAll(String query,
    {required List<CategorizedTx> txs, required List<Goal> goals, required List<WishItem> wishlist, required List<RecurringBill> bills}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const SearchResult();
  bool has(String s) => s.toLowerCase().contains(q);
  return SearchResult(
    txs: txs.where((t) => has(merchantName(t.tx)) || has(t.tx.note ?? '') || has(t.category)).toList(),
    goals: goals.where((g) => has(g.name)).toList(),
    wishlist: wishlist.where((w) => has(w.name)).toList(),
    bills: bills.where((b) => has(b.label) || has(b.payee)).toList(),
  );
}
