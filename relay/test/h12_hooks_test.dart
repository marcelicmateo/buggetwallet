@TestOn('vm')
library;

// Stage H12 (relay fault injection through the contract seam). Written against the contract names in
// docs/context/ (Stage H API): `Relay(..., hooks: RelayTestHooks(afterFileWrite: ..., beforeMetaSave: ...))` in
// relay/lib/src/wallet.dart; a throw inside a hook simulates a crash or a full disk between the two writes. The names
// do not exist on v2, so the file is skipped as a whole (the runner never loads it) and the analyzer errors are ignored
// until the seam lands; adjust the argument name `hooks:` and the callback shapes to the final signatures.
import 'dart:io';

import 'package:relay/relay.dart';
import 'package:test/test.dart';

import 'support.dart';

class _Boom implements Exception {}

Future<(Relay, Uri)> _boot(Directory dir, DateTime Function() now, {RelayTestHooks? hooks}) async {
  final relay = Relay(data: dir, now: now, log: (_) {}, hooks: hooks);
  final s = await relay.serve(port: 0);
  return (relay, Uri.parse('http://127.0.0.1:${s.port}'));
}

void main() {
  test(
      'a throw after the file write (before the meta save): the client sees 5xx; after a restart the file counts and the retry is accepted',
      () async {
    final h = await freshHarness();
    await h.putData(w1, 'dev1', 1, 'one');
    var armed = true;
    await h.relay.close();
    final hooks = RelayTestHooks(afterFileWrite: (String wid, String device, int seq) async {
      if (armed && seq == 2) throw _Boom();
    });
    final (r, base) = await _boot(h.dir, () => h.clock, hooks: hooks);
    h.base = base;
    h.relay = r;
    final failed = await h.putData(w1, 'dev1', 2, 'two');
    expect(failed.statusCode, greaterThanOrEqualTo(500));
    armed = false;
    await r.close();
    await h.restart(); // a normal relay over the same folder
    expect((await h.device(w1, 'dev1'))['last'], 2, reason: 'files win over the meta');
    expect((await h.putData(w1, 'dev1', 2, 'two')).statusCode, 200);
    expect((await h.putData(w1, 'dev1', 3, 'three')).statusCode, 201);
  });

  test('a throw before the meta save of an ack: the ack is not recorded after a restart, and the same ack later is', () async {
    final h = await freshHarness();
    await h.putData(w1, 'dev1', 1, 'one');
    await h.putData(w1, 'dev2', 1, 'x');
    await h.relay.close();
    var fail = true;
    final hooks = RelayTestHooks(beforeMetaSave: (String wid) async {
      if (fail) throw _Boom();
    });
    final (r, base) = await _boot(h.dir, () => h.clock, hooks: hooks);
    h.base = base;
    h.relay = r;
    expect((await h.ack(w1, 'dev2', {'dev1': 1})).statusCode, greaterThanOrEqualTo(500));
    fail = false;
    await r.close();
    await h.restart();
    expect((await h.device(w1, 'dev2'))['acks'], isEmpty);
    expect((await h.ack(w1, 'dev2', {'dev1': 1})).statusCode, 204);
    expect((await h.device(w1, 'dev2'))['acks'], {'dev1': 1});
  });

  test('the hooks run once per accepted file, the file write first and the meta save after it', () async {
    final h = await freshHarness();
    await h.relay.close();
    final order = <String>[];
    final hooks = RelayTestHooks(
      afterFileWrite: (String wid, String device, int seq) async => order.add('file $seq'),
      beforeMetaSave: (String wid) async => order.add('meta'),
    );
    final (r, base) = await _boot(h.dir, () => h.clock, hooks: hooks);
    h.base = base;
    h.relay = r;
    await h.putData(w1, 'dev1', 1, 'one');
    await h.putData(w1, 'dev1', 1, 'one'); // idempotent: nothing written
    await h.putData(w1, 'dev1', 2, 'two');
    expect(order.where((e) => e.startsWith('file')).toList(), ['file 1', 'file 2']);
    expect(order.indexOf('file 1'), lessThan(order.indexOf('meta')));
  });

  test('a throw in a hook never takes the process down: health stays 200 and other wallets keep working', () async {
    final h = await freshHarness();
    await h.relay.close();
    final hooks = RelayTestHooks(afterFileWrite: (String wid, String device, int seq) async {
      if (wid == w1) throw _Boom();
    });
    final (r, base) = await _boot(h.dir, () => h.clock, hooks: hooks);
    h.base = base;
    h.relay = r;
    expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, greaterThanOrEqualTo(500));
    expect((await h.putData(w2, 'devX', 1, 'ok', key: keyB)).statusCode, 201);
    expect((await h.get('/v2/health')).statusCode, 200);
  });
}
