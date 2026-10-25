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
  'tx': (
    'tx',
    [
      'source',
      'date',
      'amount',
      'currency',
      'bank_type',
      'description',
      'category',
      'note',
      'manual',
      'matched_to',
      'deleted',
      'seen_bank',
      'kind_hint',
      'transfer_to'
    ]
  ),
  'goal': ('goals', ['name', 'target', 'saved', 'monthly', 'sort', 'deleted']),
  'wish': ('wish', ['name', 'price', 'added', 'status', 'decided', 'deleted']),
  'setting': ('settings', ['value', 'deleted']),
  'rule': ('merchant_rules', ['category', 'deleted']),
  'goal_contrib': ('goal_contrib', ['goal_id', 'amount', 'date', 'deleted']),
  'recurring': (
    'recurring',
    ['payee', 'label', 'category', 'expected_amount', 'interval_days', 'next_due', 'status', 'last_paid_tx', 'deleted']
  ),
  'planned': ('planned', ['title', 'date', 'amount', 'category', 'source', 'source_ref', 'status', 'paid_tx', 'deleted']),
  'bill': (
    'bills',
    [
      'source', 'status', 'external_id', 'date', 'due_date', 'payee', 'iban', 'reference', 'description', 'category', 'note', //
      'total', 'currency', 'items', 'unsure', 'linked_tx', 'warranty_until', 'return_by', 'blob', 'blob_type', 'blob_bytes', 'deleted',
    ]
  ),
  'account': ('accounts', ['name', 'source', 'currency', 'opening', 'opening_date', 'deleted']),
  'category': ('categories', ['name', 'kind', 'parent', 'position', 'hidden', 'deleted']),
  'tag': ('tags', ['name', 'position', 'hidden', 'deleted']),
  'txtag': ('tx_tags', ['tx', 'tag', 'state']),
  'ruletag': ('rule_tags', ['payee', 'tag', 'deleted']),
};

const dataTables = [
  'tx',
  'goals',
  'wish',
  'settings',
  'merchant_rules',
  'goal_contrib',
  'recurring',
  'planned',
  'bills',
  'accounts',
  'categories',
  'tags',
  'tx_tags',
  'rule_tags'
];

/// Every row of the data tables (and the field clocks), in a stable order, as plain maps.
Map<String, List<Map<String, Object?>>> dump(WalletRepo r, {bool clocks = true}) => {
      for (final t in dataTables) t: [for (final row in r.db.select('SELECT * FROM $t ORDER BY id')) Map<String, Object?>.from(row)],
      if (clocks)
        'clocks': [for (final row in r.db.select('SELECT * FROM clocks ORDER BY entity, id, field')) Map<String, Object?>.from(row)],
    };

/// Row counts of the bookkeeping tables.
Map<String, int> bookkeeping(WalletRepo r) => {
      for (final t in ['outbox', 'sync_cursor', 'clocks']) t: r.db.select('SELECT COUNT(*) AS n FROM $t').first['n'] as int,
    };

/// The relay the devices of a test sync through ([MemoryTransport]). A [Device] without its own net uses the latest
/// one made, so `net = Net()` in `setUp` connects every device of the test.
class Net {
  static Net? _current;
  final MemoryTransport relay;
  Net({DateTime Function()? now}) : relay = MemoryTransport(now: now) {
    _current = this;
  }

  /// What the relay stores: `d/<device>/<seq>` and `snapshot/<id>`.
  Map<String, Uint8List> get files => relay.files;
}

/// Fails each file GET with probability `1 - p` (a flaky link: the device stops at that file of that device).
class _Flaky implements SyncTransport {
  final SyncTransport inner;
  final Random? r;
  final double p;
  _Flaky(this.inner, this.r, this.p);
  @override
  Future<RelayState> state() => inner.state();
  @override
  Future<void> put(String device, int seq, List<int> bytes) => inner.put(device, seq, bytes);
  @override
  Future<List<int>> get(String device, int seq) async {
    if (r != null && p < 1 && r!.nextDouble() >= p) throw const TransportException(TransportFailure.unreachable, 'flaky');
    return inner.get(device, seq);
  }

  @override
  Future<void> ack(String device, Map<String, int> cursors) => inner.ack(device, cursors);
  @override
  Future<void> putSnapshot(String id, Map<String, int> covers, List<int> bytes) => inner.putSnapshot(id, covers, bytes);
  @override
  Future<List<int>> getSnapshot(String id) => inner.getSnapshot(id);
  @override
  Future<void> putBlob(String hash, List<int> bytes) => inner.putBlob(hash, bytes);
  @override
  Future<List<int>?> getBlob(String hash) => inner.getBlob(hash);
  @override
  Future<void> deleteBlob(String hash) => inner.deleteBlob(hash);
}

/// One simulated device: its own database and a skewed wall clock, syncing through a [Net]. With [dbPath] the
/// database is a file, so [reopen] can simulate an app restart (or upgrade). [dir] is scratch space for the test.
class Device {
  final String name;
  final Directory? dir;
  final VaultKey key;
  final String? dbPath;

  /// With [dbPath]: the local database key (`localDbKey`); the file is then encrypted, like the app's.
  final List<int>? dbKey;
  int Function() clock;
  late WalletRepo repo;
  Net? net;
  Random? _r;
  double _p = 1;

  /// The install's own device id (H6, `WalletRepo.open(deviceId:)`); null = the one stored in the database.
  String? deviceId;
  Device(this.name, this.dir, this.key, this.clock, {this.dbPath, this.dbKey, this.net, this.deviceId}) {
    repo = _open();
  }

  WalletRepo _open() => dbPath == null
      ? WalletRepo.inMemory(now: () => clock(), deviceId: deviceId)
      : WalletRepo.open(dbPath!, dbKey: dbKey, now: () => clock(), deviceId: deviceId);

  /// Closes and opens the database again (file-backed devices only), as an app restart would.
  void reopen() {
    repo.close();
    repo = _open();
  }

  Net get _net => net ??= Net._current ?? Net();
  MemoryTransport get relay => _net.relay;

  SyncEngine engine({String appVersion = ''}) => SyncEngine(_Flaky(relay, _r, _p), key, appVersion: appVersion);

  /// One sync run: uploads this device's changes, then applies what it can fetch (see [deliver]).
  Future<SyncReport> run({String appVersion = ''}) async {
    final e = engine(appVersion: appVersion);
    _p = 1;
    return e.run(repo);
  }

  /// Files go out during [run]; kept so the folder-era helpers read the same.
  void upload(Net net) => this.net ??= net;

  /// The next [run] fetches each file with probability [p] (a failed GET stops that device's later files until a
  /// later run). [dup] is ignored: a relay has no conflict copies.
  void deliver(Net net, Random r, {double p = 1, double dup = 0}) {
    this.net ??= net;
    _r = r;
    _p = p;
  }

  void close() => repo.close();
}

/// Every op on the relay (decrypted): device files and snapshots.
Future<List<Op>> opsInNet(Net net, VaultKey key) async {
  final out = <Op>[];
  for (final e in net.files.entries) {
    // `d/<device>/<seq>` or `snapshot/<id>`: each sealed for its own place (BWOP2 associated data).
    final p = e.key.split('/');
    final clear = await unseal(e.value, key, aad: p[0] == 'd' ? aadSyncFile(p[1], int.parse(p[2])) : aadSnapshot(p[1]));
    final j = jsonDecode(utf8.decode(clear));
    for (final o in (j is Map ? j['ops'] : j) as List) {
      out.add(Op.fromJson(Map<String, Object?>.from(o as Map)));
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
