// HP-R1b: a sync file the relay lists but lost (power cut before its folder entry was written) no longer stalls a
// reader when a snapshot covers it, and RelayTransport's deadline grows with the bytes sent or received.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:relay/relay.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

Matcher fails(TransportFailure f) => throwsA(isA<TransportException>().having((e) => e.failure, 'failure', f));

/// Answers every request through [answer]; a request whose future never completes stands for a relay that never answers.
class _Stub extends http.BaseClient {
  _Stub(this.answer);

  final Future<http.StreamedResponse> Function(http.BaseRequest r) answer;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => answer(request);
}

void main() {
  final key = VaultKey.generate();

  group('a listed file lost on the relay (two devices, real relay)', () {
    test('the writer\'s newest file is gone after a restart: the reader catches up from the snapshot covering it', () async {
      var now = DateTime.utc(2026, 10, 1, 9);
      final dir = Directory.systemTemp.createTempSync('bw-hpr1b-');
      var relay = Relay(data: dir, log: (_) {}, now: () => now);
      var base = Uri.parse('http://127.0.0.1:${(await relay.serve(port: 0)).port}');
      addTearDown(() async {
        await relay.close();
        dir.deleteSync(recursive: true);
      });
      final a = WalletRepo.inMemory(), b = WalletRepo.inMemory();
      addTearDown(a.close);
      addTearDown(b.close);
      Future<SyncReport> run(WalletRepo r) async {
        final t = RelayTransport(base, key, now: () => now);
        try {
          return await SyncEngine(t, key, now: () => now).run(r);
        } finally {
          t.close();
        }
      }

      a.updateSettings({'salary': 1000});
      await run(a);
      await run(b);
      expect(b.settings().salary, 1000);
      a.updateSettings({'salary': 2000});
      await run(a);
      // The newest file of A's stream is lost on disk; the relay restarts and still lists it (its meta says so).
      final wallet = dir.listSync().whereType<Directory>().single;
      final lost = [
        for (final d in Directory('${wallet.path}/d').listSync().whereType<Directory>())
          for (final f in d.listSync().whereType<File>()) f,
      ].reduce((x, y) => int.parse(x.uri.pathSegments.last) >= int.parse(y.uri.pathSegments.last) ? x : y);
      lost.deleteSync();
      await relay.close();
      relay = Relay(data: dir, log: (_) {}, now: () => now);
      base = Uri.parse('http://127.0.0.1:${(await relay.serve(port: 0)).port}');
      // A week later the writer, caught up, writes its snapshot (it covers its own last file).
      now = now.add(const Duration(days: 8));
      await run(a);
      final check = RelayTransport(base, key, now: () => now);
      addTearDown(check.close);
      expect((await check.state()).snapshot, isNotNull);
      final r = await run(b);
      expect(b.settings().salary, 2000, reason: 'waiting: ${r.waiting}');
      expect(r.caughtUp, isTrue, reason: 'not waiting on the lost file');
    });
  });

  group('RelayTransport deadline grows with the body (30 s + 1 s per 64 KiB)', () {
    test('deadlineFor', () {
      final t = RelayTransport(Uri.parse('http://relay.test'), key);
      addTearDown(t.close);
      expect(t.deadlineFor(0), const Duration(seconds: 30));
      expect(t.deadlineFor(64 * 1024), const Duration(seconds: 31));
      expect(t.deadlineFor(15 << 20), const Duration(seconds: 30 + 240));
    });

    test('a big upload outlives the base timeout that cuts off a small request', () async {
      final release = Completer<void>();
      final t = RelayTransport(Uri.parse('http://relay.test'), key, timeout: const Duration(milliseconds: 100), client: _Stub((r) async {
        if (r.url.path.contains('/d/')) {
          await release.future;
          return http.StreamedResponse(Stream.value('{"seq":2}'.codeUnits), 201);
        }
        return Completer<http.StreamedResponse>().future; // never answers
      }));
      addTearDown(t.close);
      final upload = t.put('dev1', 2, Uint8List(640 * 1024)); // 100 ms + 10 s
      await expectLater(t.state(), fails(TransportFailure.unreachable)); // 100 ms: the small request's deadline
      release.complete();
      await upload;
    });

    test('a big answer outlives the base timeout: its deadline follows its Content-Length', () async {
      final rest = Completer<void>();
      const size = 640 * 1024;
      final t = RelayTransport(Uri.parse('http://relay.test'), key, timeout: const Duration(milliseconds: 100), client: _Stub((r) async {
        if (r.url.path.contains('/d/')) {
          Stream<List<int>> body() async* {
            yield Uint8List(1024);
            await rest.future;
            yield Uint8List(size - 1024);
          }

          return http.StreamedResponse(body(), 200, contentLength: size);
        }
        return Completer<http.StreamedResponse>().future;
      }));
      addTearDown(t.close);
      final download = t.get('dev1', 1);
      await expectLater(t.state(), fails(TransportFailure.unreachable));
      rest.complete();
      expect((await download).length, size);
    });
  });
}
