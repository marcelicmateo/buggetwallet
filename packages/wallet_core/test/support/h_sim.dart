// Stage H12 helpers: a cluster of simulated devices over any transport (memory or the real relay), the sync
// invariants of the spec, and a real relay on a temp folder. All data is SYNTHETIC.
import 'dart:io';

import 'package:relay/relay.dart';
import 'package:wallet_core/wallet_core.dart';

import 'engine_spec_sim.dart';
import 'h_compat.dart';

/// Devices sharing one transport and one fake clock (so "91 days later" is [SimClock.advance]).
class Cluster {
  Cluster(this.transport, this.clock, [VaultKey? key]) : key = key ?? VaultKey.generate();

  final SyncTransport transport;
  final SimClock clock;
  final VaultKey key;
  final List<Dev> devs = [];
  int _made = 0;

  /// A device with an in-memory database; [skewMs] shifts its wall clock (for repo clock and engine alike). Device ids are
  /// fixed (`c0de…01`, `c0de…02`, …) where the build lets a repo be given one, so seeds and traces reproduce.
  Dev add({int skewMs = 0, String appVersion = '1.0.0'}) {
    final repo = repoWithDeviceId('c0de${(++_made).toRadixString(16).padLeft(12, '0')}', now: () => clock.ms + skewMs);
    final d = Dev(repo, SyncEngine(transport, key, appVersion: appVersion, now: () => clock.t.add(Duration(milliseconds: skewMs))));
    devs.add(d);
    return d;
  }

  void tick([Duration d = const Duration(minutes: 1)]) => clock.advance(d);

  /// Every device syncs [rounds] times, in order.
  Future<void> syncAll({int rounds = 3, List<Dev>? only}) async {
    for (var i = 0; i < rounds; i++) {
      for (final d in only ?? devs) {
        await d.sync();
        tick(const Duration(seconds: 1));
      }
    }
  }

  void closeAll() {
    for (final d in devs) {
      d.close();
    }
  }
}

/// The wallet's data as one sorted list, for equality between devices (no clocks).
List<String> data(Dev d) => canon(d.repo);

/// Violations of the sync invariants (empty = fine), from the relay's state and each device's own bookkeeping:
/// `ack <= cursor <= last` and `ack <= last` for every pair, and every kept snapshot's `covers` is at most the relay's
/// `last` for that device and at most what some device (the writer) holds of it (a cursor, or its own last).
Future<List<String>> invariantViolations(SyncTransport t, List<Dev> devs) async {
  final s = await t.state();
  final out = <String>[];
  final held = <String, int>{}; // best any device holds of relay stream P's files
  for (final d in devs) {
    final sent = int.tryParse(d.repo.localValue(SyncEngine.sentKey) ?? '') ?? 0;
    final own = ownStream(s, d);
    if (sent > (held[own] ?? 0)) held[own] = sent;
    for (final e in d.repo.syncCursors().entries) {
      if (e.value > (held[e.key] ?? 0)) held[e.key] = e.value;
    }
  }
  for (final MapEntry(key: p, value: dev) in s.devices.entries) {
    for (final MapEntry(key: q, value: ack) in dev.acks.entries) {
      final qLast = s.devices[q]?.last ?? 0;
      if (ack > qLast) out.add('ack of ${_s(p)} for ${_s(q)} = $ack above last $qLast');
    }
  }
  for (final d in devs) {
    final mine = s.devices[ownStream(s, d)];
    final cursors = d.repo.syncCursors();
    for (final MapEntry(key: p, value: c) in cursors.entries) {
      final last = s.devices[p]?.last ?? 0;
      // A cursor above `last` is legal only until this device's next run (the relay lost files); we check after runs.
      if (c > last) out.add('cursor of ${d.short} for ${_s(p)} = $c above last $last');
      final ack = mine?.acks[p] ?? 0;
      if (ack > c) out.add('ack of ${d.short} for ${_s(p)} = $ack above its cursor $c');
    }
    if (mine != null) {
      final sent = int.tryParse(d.repo.localValue(SyncEngine.sentKey) ?? '') ?? 0;
      if (sent > mine.last) out.add('${d.short} sent $sent above relay last ${mine.last}');
    }
  }
  for (final snap in [s.snapshot, s.previous]) {
    if (snap == null) continue;
    for (final MapEntry(key: p, value: c) in snap.covers.entries) {
      final last = s.devices[p]?.last ?? 0;
      if (c > last) out.add('snapshot covers ${_s(p)} = $c above last $last');
      if (c > (held[p] ?? 0)) out.add('snapshot covers ${_s(p)} = $c above anything a device holds (${held[p] ?? 0})');
    }
  }
  return out;
}

String _s(String id) => SyncProblem.shortId(id);

/// The relay name this device's files go under now: its id, or `<id>-<n>` after the relay lost some of its files (a
/// restored copy starts a new stream of the same device, Stage H5b). The newest stream the relay lists for the device.
String ownStream(RelayState s, Dev d) {
  // Later builds keep the install's current stream name as a device-local value ('syncStream' = SyncEngine.streamKey).
  final current = d.repo.localValue('syncStream');
  if (current != null && current.startsWith(d.id)) return current;
  var best = d.id, bestEpoch = 0;
  for (final name in s.devices.keys) {
    if (!name.startsWith('${d.id}-')) continue;
    final epoch = int.tryParse(name.substring(d.id.length + 1)) ?? 0;
    if (epoch > bestEpoch) (best, bestEpoch) = (name, epoch);
  }
  return best;
}

/// Transfer symmetry: whenever a live row names a partner, the partner is live and names it back.
List<String> transferAsymmetries(WalletRepo r) {
  final out = <String>[];
  final rows = {for (final t in r.transactions(includeHidden: true)) t.id: t};
  for (final t in rows.values) {
    final to = t.transferTo;
    if (to == null || t.deleted) continue;
    final p = rows[to];
    if (p == null) {
      out.add('${t.id} -> $to: partner missing');
    } else if (p.deleted) {
      out.add('${t.id} -> $to: partner deleted');
    } else if (p.transferTo != t.id) {
      out.add('${t.id} -> $to: partner points at ${p.transferTo}');
    }
  }
  return out;
}

/// Bill payment uniqueness: no transaction is the payment of two live bills.
List<String> duplicatePayments(WalletRepo r) {
  final by = <String, List<String>>{};
  for (final b in r.bills()) {
    final tx = b.linkedTx;
    if (tx != null) (by[tx] ??= []).add(b.id);
  }
  return [
    for (final e in by.entries)
      if (e.value.length > 1) '${e.key} pays ${e.value.length} bills'
  ];
}

/// Planned rows that are not paid must not carry a payment (`paid_tx` is meaningful only when `status == paid`).
List<String> strayPaidTx(WalletRepo r) => [
      for (final row
          in r.db.select("SELECT id, status, paid_tx FROM planned WHERE deleted = 0 AND status != 'paid' AND paid_tx IS NOT NULL"))
        '${row['id']} is ${row['status']} but holds paid_tx ${row['paid_tx']}'
    ];

NormalizedBill synthBill(String ext, {int total = 4500, String due = '2026-02-20'}) =>
    NormalizedBill(source: BillSource.hub3, externalId: ext, date: '2026-02-01', dueDate: due, total: total, payee: 'Synth Utility');

/// A real relay on a temp folder with the cluster's fake clock. [restart] keeps the folder.
class RelayRig {
  RelayRig(this.clock, {Directory? dir}) : dir = dir ?? Directory.systemTemp.createTempSync('bw-h12-relay-');

  final SimClock clock;
  final Directory dir;
  final List<String> logs = [];
  late Relay relay;
  late Uri base;
  final List<RelayTransport> _transports = [];

  Future<void> start({int port = 0}) async {
    relay = Relay(data: dir, now: () => clock.t, log: logs.add);
    final server = await relay.serve(port: port);
    base = Uri.parse('http://127.0.0.1:${server.port}');
  }

  /// Stops the relay and starts a new one on the same port over the same folder (clients keep their address).
  Future<void> restart() async {
    final port = base.port;
    await relay.close();
    await start(port: port);
  }

  /// A client for the current port. After [restart] the port changes, so make the transport again.
  RelayTransport transport(VaultKey key) {
    final t = RelayTransport(base, key, now: () => clock.t);
    _transports.add(t);
    return t;
  }

  Future<void> stopRelay() => relay.close();

  Future<void> dispose() async {
    for (final t in _transports) {
      t.close();
    }
    await relay.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// Recursive copy of the relay's data folder (a backup of the home server).
  Directory copyData() {
    final to = Directory.systemTemp.createTempSync('bw-h12-copy-');
    copyDir(dir, to);
    return to;
  }

  /// Replaces the data folder's content with [from] (restoring an older copy). The relay must be stopped.
  void restoreFrom(Directory from) {
    for (final e in dir.listSync()) {
      e.deleteSync(recursive: true);
    }
    copyDir(from, dir);
  }
}

void copyDir(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final e in from.listSync()) {
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (e is Directory) {
      copyDir(e, Directory('${to.path}/$name'));
    } else if (e is File) {
      e.copySync('${to.path}/$name');
    }
  }
}
