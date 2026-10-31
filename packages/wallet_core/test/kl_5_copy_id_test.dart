// KL-A item 5: "Add as new" copies of a stored slip get an id that holds the device (`<ext>#<deviceId>-<n>`), so two
// offline devices adding a copy make two bills; copies made before keep their ids. Synthetic data only.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

const _ext = 'hub3:synthetic-slip-0001';
NormalizedBill slip({String due = '2026-03-10'}) =>
    NormalizedBill(source: BillSource.hub3, externalId: _ext, date: '2026-03-01', dueDate: due, total: 4599, payee: 'Synth Utility');

void main() {
  test('the copy id holds the device id; numbers count up per device', () {
    final r = WalletRepo.inMemory(deviceId: 'a1b2c3d4e5f60001');
    addTearDown(r.close);
    final (first, _) = r.importBill(slip());
    expect(first, Bill.idFor(_ext));
    final (c1, n1) = r.importBill(slip(due: '2026-04-10'), asNew: true);
    final (c2, _) = r.importBill(slip(due: '2026-05-10'), asNew: true);
    expect((c1, n1), (Bill.idFor('$_ext#a1b2c3d4e5f60001-1'), true));
    expect(c2, Bill.idFor('$_ext#a1b2c3d4e5f60001-2'));
    expect(r.bill(c1)!.externalId, _ext, reason: 'the external id is unchanged');
  });

  test('a copy made before KL-A keeps its id and is left alone', () {
    final r = WalletRepo.inMemory(deviceId: 'a1b2c3d4e5f60001');
    addTearDown(r.close);
    r.importBill(slip());
    // What an older build stored for its copy: `<ext>#1`.
    final old = Bill.idFor('$_ext#1');
    r.applyRemote([
      Op('bill', old, {'source': 'hub3', 'status': 'review', 'external_id': _ext, 'total': 4599, 'deleted': 0},
          '001772000000000:00000:feedfeedfeedfeed'),
    ]);
    final (c, _) = r.importBill(slip(due: '2026-04-10'), asNew: true);
    expect(c, Bill.idFor('$_ext#a1b2c3d4e5f60001-1'));
    expect(r.bill(old)!.dueDate, isNull, reason: 'the old copy is not overwritten');
    expect(r.bills(), hasLength(3));
  });

  test('the device id is never logged', () {
    final lines = <String>[];
    final was = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen((rec) => lines.add(formatLogRecord(rec)));
    addTearDown(() {
      sub.cancel();
      Logger.root.level = was;
    });
    final r = WalletRepo.inMemory(deviceId: 'a1b2c3d4e5f60009');
    addTearDown(r.close);
    r.importBill(slip());
    r.importBill(slip(due: '2026-04-10'), asNew: true);
    expect(lines.join('\n'), isNot(contains('a1b2c3d4e5f60009')));
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    var now = 0;
    final devices = <Device>[];
    Device device(String name, String id) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now, deviceId: id);
      devices.add(d);
      return d;
    }

    Future<void> round(Net net) async {
      for (final d in devices) {
        now += 1000;
        d.deliver(net, Random(1));
        await d.run();
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-kl5-');
      key = VaultKey.generate();
      devices.clear();
      now = DateTime.utc(2026, 3, 2, 12).millisecondsSinceEpoch;
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      tmp.deleteSync(recursive: true);
    });

    test('two offline devices "Add as new" the same slip: two bills after sync', () async {
      final net = Net();
      final a = device('a', 'a1b2c3d4e5f60001'), b = device('b', 'a1b2c3d4e5f60002');
      a.repo.importBill(slip());
      await round(net);
      await round(net);
      expect(b.repo.bills(), hasLength(1));
      a.repo.importBill(slip(due: '2026-04-10'), asNew: true);
      now += 10;
      b.repo.importBill(slip(due: '2026-04-10'), asNew: true);
      await round(net);
      await round(net);
      for (final d in [a, b]) {
        expect(d.repo.bills(), hasLength(3), reason: d.name);
        expect(d.repo.bills().map((x) => x.id).toSet(),
            {Bill.idFor(_ext), Bill.idFor('$_ext#a1b2c3d4e5f60001-1'), Bill.idFor('$_ext#a1b2c3d4e5f60002-1')},
            reason: d.name);
      }
    });
  });
}
