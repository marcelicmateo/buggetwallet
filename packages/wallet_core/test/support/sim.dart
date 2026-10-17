// Multi-device sync simulator and table dumps for wallet_core tests. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

/// Iterations for randomized tests: [base] by default, `BW_FUZZ_ITERATIONS` to run longer (or shorter).
int fuzzIterations(int base) => int.tryParse(Platform.environment['BW_FUZZ_ITERATIONS'] ?? '') ?? base;

/// Base seed: fixed by default so runs are reproducible; `BW_FUZZ_SEED` to explore other seeds.
int fuzzSeed(int base) => int.tryParse(Platform.environment['BW_FUZZ_SEED'] ?? '') ?? base;

/// Entity name in ops -> table, and the syncable columns (written down independently of repo.dart).
const entityTables = {
  'tx': ('tx', ['source', 'date', 'amount', 'currency', 'bank_type', 'description', 'category', 'note', 'manual', 'matched_to', 'deleted']),
  'goal': ('goals', ['name', 'target', 'saved', 'monthly', 'sort', 'deleted']),
  'wish': ('wish', ['name', 'price', 'added', 'status', 'decided', 'deleted']),
  'setting': ('settings', ['value', 'deleted']),
  'rule': ('merchant_rules', ['category', 'deleted']),
};

const dataTables = ['tx', 'goals', 'wish', 'settings', 'merchant_rules'];

/// Every row of the data tables (and the field clocks), in a stable order, as plain maps.
Map<String, List<Map<String, Object?>>> dump(WalletRepo r, {bool clocks = true}) => {
      for (final t in dataTables) t: [for (final row in r.db.select('SELECT * FROM $t ORDER BY id')) Map<String, Object?>.from(row)],
      if (clocks)
        'clocks': [for (final row in r.db.select('SELECT * FROM clocks ORDER BY entity, id, field')) Map<String, Object?>.from(row)],
    };

/// Row counts of the bookkeeping tables.
Map<String, int> bookkeeping(WalletRepo r) => {
      for (final t in ['outbox', 'peer_files', 'clocks']) t: r.db.select('SELECT COUNT(*) AS n FROM $t').first['n'] as int,
    };

/// All files under [dir], keyed by path relative to it.
Map<String, Uint8List> filesUnder(Directory dir) {
  if (!dir.existsSync()) return {};
  return {
    for (final f in dir.listSync(recursive: true).whereType<File>())
      f.path.substring(dir.path.length + 1).replaceAll(Platform.pathSeparator, '/'): f.readAsBytesSync(),
  };
}

/// What a file-sync tool (Syncthing) has seen so far: every file any device uploaded, by relative path.
class Net {
  final Map<String, Uint8List> files = {};
}

/// One simulated device: its own database, its own copy of the shared folder, and a skewed wall clock.
class Device {
  final String name;
  final Directory dir;
  final VaultKey key;
  int Function() clock;
  late final WalletRepo repo;
  Device(this.name, this.dir, this.key, this.clock) {
    repo = WalletRepo.inMemory(now: () => clock());
  }

  FolderSync get sync => FolderSync(dir.path, key);
  Directory get root => Directory('${dir.path}/budget-wallet');

  Future<SyncReport> run() => sync.run(repo);

  /// Copies files this device wrote into the network.
  void upload(Net net) {
    for (final e in filesUnder(root).entries) {
      if (e.key.split('/').last.startsWith('.')) continue; // half-written temp files never leave the device
      net.files.putIfAbsent(e.key, () => e.value);
    }
  }

  /// Delivers network files to this device. Each missing file arrives with probability [p] (so later files can
  /// arrive before earlier ones); with probability [dup] an already present file comes again as a conflict copy.
  void deliver(Net net, Random r, {double p = 1, double dup = 0}) {
    for (final e in net.files.entries) {
      final f = File('${root.path}/${e.key}');
      if (f.existsSync()) {
        if (dup > 0 && r.nextDouble() < dup && e.key.endsWith('.bwop') && !e.key.contains('conflict')) {
          final copy = File('${f.path.substring(0, f.path.length - 5)}.sync-conflict-20261016-${r.nextInt(1 << 20)}.bwop');
          copy.writeAsBytesSync(e.value);
        }
        continue;
      }
      if (r.nextDouble() >= p) continue;
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(e.value);
    }
  }

  void close() => repo.close();
}

/// Every op in the network's sync files (decrypted), conflict copies included.
Future<List<Op>> opsInNet(Net net, VaultKey key) async {
  final out = <Op>[];
  for (final e in net.files.entries) {
    if (!e.key.endsWith('.bwop')) continue;
    final clear = await unseal(e.value, key);
    for (final j in jsonDecode(utf8.decode(clear)) as List) {
      out.add(Op.fromJson(Map<String, Object?>.from(j as Map)));
    }
  }
  return out;
}

/// Expected value per (table, id, column) under "highest HLC wins per field", from all ops ever written.
Map<(String, String, String), Object?> lastWriterWins(Iterable<Op> ops) {
  final best = <(String, String, String), (String, Object?)>{};
  for (final op in ops) {
    final def = entityTables[op.entity];
    if (def == null) continue;
    for (final f in op.fields.entries) {
      if (!def.$2.contains(f.key)) continue;
      final k = (def.$1, op.id, f.key);
      final cur = best[k];
      if (cur == null || cur.$1.compareTo(op.hlc) < 0) {
        final v = f.value;
        best[k] = (op.hlc, v is bool ? (v ? 1 : 0) : v);
      }
    }
  }
  return {for (final e in best.entries) e.key: e.value.$2};
}

/// Differences between a device's tables and the expected last-writer-wins values (empty = all match).
List<String> lwwDiff(WalletRepo r, Map<(String, String, String), Object?> want) {
  final rows = <String, Map<String, Map<String, Object?>>>{
    for (final t in dataTables) t: {for (final row in r.db.select('SELECT * FROM $t')) row['id'] as String: Map<String, Object?>.from(row)},
  };
  final out = <String>[];
  for (final e in want.entries) {
    final (table, id, col) = e.key;
    final row = rows[table]![id];
    if (row == null) {
      out.add('$table/$id missing');
    } else if (row[col] != e.value) {
      out.add('$table/$id.$col = ${row[col]}, want ${e.value}');
    }
  }
  return out;
}

/// A synthetic bank row with a v1-compatible id.
NormalizedTransaction bankRow(String date, int cents, String type, String desc, {String source = 'pbz'}) => NormalizedTransaction(
      id: transactionId(date, cents, desc, 0),
      source: source,
      date: date,
      amountMinor: cents,
      currency: 'EUR',
      bankType: type,
      description: desc,
    );
