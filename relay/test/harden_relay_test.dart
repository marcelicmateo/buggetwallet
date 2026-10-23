// Stage H (core-builder B): v3 signatures name the host (H8), the relay instance id (H5) and the fault-injection
// seam. Synthetic wallets and keys only (support.dart).
import 'dart:convert';
import 'dart:io';

import 'package:relay/relay.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('v3 signatures name the host', () {
    test('a request signed for another host is 401 bad signature, also on creation; the right host works', () async {
      final h = await freshHarness();
      h.signHost = 'other-relay.example:8787';
      final r = await h.putData(w1, 'dev1', 1, 'one');
      expect(r.statusCode, 401);
      expect(jsonDecode(r.body), {'error': 'bad signature'});
      expect(h.relay.walletCount, 0, reason: 'nothing created');
      h.signHost = null;
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 201);
      h.signHost = '127.0.0.1';
      expect((await h.get('/v2/w/$w1/state', key: keyA)).statusCode, 401, reason: 'the port is part of the host');
      expect(apiVersion, 3);
    });

    test('behind a proxy: --public-host is the host checked, whatever Host the proxy sends', () async {
      final h = await Harness.start(publicHost: 'bw.example.org');
      addTearDown(h.stop);
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 401, reason: 'signed for 127.0.0.1:<port>');
      h.signHost = 'BW.example.org';
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 401, reason: 'clients sign the host in lower case');
      h.signHost = 'bw.example.org';
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 201);
      expect((await h.get('/v2/w/$w1/state', key: keyA)).statusCode, 200);
    });
  });

  group('relay instance id', () {
    test('state carries a 32-hex instance id kept in meta.json across a restart; another data folder has another', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      final id = (await h.state(w1))['instance'] as String;
      expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
      final meta = jsonDecode(File('${h.dir.path}/$w1/meta.json').readAsStringSync()) as Map<String, Object?>;
      expect(meta['instance'], id);
      await h.restart();
      expect((await h.state(w1))['instance'], id);
      final other = await freshHarness();
      await other.putData(w1, 'dev1', 1, 'one');
      expect((await other.state(w1))['instance'], isNot(id));
    });

    test('a meta from before instance ids gets one at the first load and keeps it', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      final f = File('${h.dir.path}/$w1/meta.json');
      final meta = jsonDecode(f.readAsStringSync()) as Map<String, Object?>..remove('instance');
      f.writeAsStringSync(jsonEncode(meta));
      await h.restart();
      final id = (await h.state(w1))['instance'] as String;
      expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect((jsonDecode(f.readAsStringSync()) as Map)['instance'], id, reason: 'saved at once');
      await h.restart();
      expect((await h.state(w1))['instance'], id);
      expect((await h.device(w1, 'dev1'))['last'], 1);
    });

    test('a malformed instance in meta.json is replaced by a new one, not served', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      final f = File('${h.dir.path}/$w1/meta.json');
      final meta = jsonDecode(f.readAsStringSync()) as Map<String, Object?>..['instance'] = 'NOT-HEX';
      f.writeAsStringSync(jsonEncode(meta));
      await h.restart();
      expect((await h.state(w1))['instance'], matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });

  group('fault-injection seam', () {
    test('a throw after the file write leaves the file; after a restart it counts (files win over meta)', () async {
      var armed = true;
      final h = await Harness.start(hooks: RelayTestHooks(afterFileWrite: (wid, device, seq) {
        if (armed && seq == 2) throw StateError('synthetic crash');
      }));
      addTearDown(h.stop);
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 201);
      expect((await h.putData(w1, 'dev1', 2, 'two')).statusCode, greaterThanOrEqualTo(500));
      armed = false;
      await h.restart();
      expect((await h.device(w1, 'dev1'))['last'], 2);
      expect((await h.putData(w1, 'dev1', 2, 'two')).statusCode, 200);
    });

    test('beforeMetaSave runs before every request meta save, not for the save of a load', () async {
      final saves = <String>[];
      final h = await Harness.start(hooks: RelayTestHooks(beforeMetaSave: saves.add));
      addTearDown(h.stop);
      await h.putData(w1, 'dev1', 1, 'one');
      expect(saves, [w1]);
      final f = File('${h.dir.path}/$w1/meta.json');
      f.writeAsStringSync(jsonEncode((jsonDecode(f.readAsStringSync()) as Map<String, Object?>)..remove('instance')));
      await h.restart();
      expect(saves, [w1], reason: 'the load saved the new instance id without the hook');
    });
  });
}
