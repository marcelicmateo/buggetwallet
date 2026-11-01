// UX-FX: the ECB download (`fetchEcbFile`) over MockClient: the plain GET of the ECB's own address, bytes back, a
// status, a timeout, a cut connection and an oversized answer as short exceptions; logs carry outcomes and counts only.
// No real network; the bytes are synthetic.
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

Matcher _fails(EcbFetchFailure r) => throwsA(isA<EcbFetchException>().having((e) => e.reason, 'reason', r));

void main() {
  test('a plain GET of the ECB address only (no query, no header of ours); the bytes come back as sent', () async {
    final seen = <http.BaseRequest>[];
    final body = List<int>.generate(3000, (i) => i % 251);
    final c = MockClient((r) async {
      seen.add(r);
      return http.Response.bytes(body, 200);
    });
    expect(await fetchEcbFile(EcbFile.history, client: c), body);
    expect(await fetchEcbFile(EcbFile.recent, client: c), body);
    expect([for (final r in seen) (r.method, r.url.toString())], [('GET', ecbHistoryUrl), ('GET', ecbRecentUrl)]);
    for (final r in seen) {
      expect(r.url.scheme, 'https');
      expect(r.url.hasQuery, isFalse);
      expect(r.headers, isEmpty);
    }
  });

  test('404 and 500: a status failure', () async {
    for (final code in [404, 500]) {
      await expectLater(
          fetchEcbFile(EcbFile.recent, client: MockClient((_) async => http.Response('no', code))), _fails(EcbFetchFailure.status));
    }
  });

  test('no answer within the timeout: a timeout failure', () async {
    final never = Completer<http.Response>();
    final c = MockClient((_) => never.future);
    await expectLater(fetchEcbFile(EcbFile.recent, client: c, timeout: const Duration(milliseconds: 50)), _fails(EcbFetchFailure.timeout));
  });

  test('no connection or a cut stream: unreachable, the message names no address', () async {
    final c = MockClient((_) async => throw http.ClientException('failed host lookup www.ecb.europa.eu'));
    await expectLater(
        fetchEcbFile(EcbFile.history, client: c),
        throwsA(isA<EcbFetchException>()
            .having((e) => e.reason, 'reason', EcbFetchFailure.unreachable)
            .having((e) => e.message, 'message', isNot(contains('ecb.europa')))));
    Stream<List<int>> cutOff() async* {
      yield const [1, 2];
      throw http.ClientException('reset');
    }

    final cut = MockClient.streaming((_, __) async => http.StreamedResponse(cutOff(), 200));
    await expectLater(fetchEcbFile(EcbFile.history, client: cut), _fails(EcbFetchFailure.unreachable));
  });

  test('oversize: refused by its length, or while reading one without a length', () async {
    final big =
        MockClient.streaming((_, __) async => http.StreamedResponse(Stream.value(const [1]), 200, contentLength: maxEcbDownloadBytes + 1));
    await expectLater(fetchEcbFile(EcbFile.history, client: big), _fails(EcbFetchFailure.tooLarge));
    final chunk = List<int>.filled(1024 * 1024, 7);
    final endless = MockClient.streaming((_, __) async => http.StreamedResponse(Stream.fromIterable(List.filled(9, chunk)), 200));
    await expectLater(fetchEcbFile(EcbFile.history, client: endless), _fails(EcbFetchFailure.tooLarge));
    final exact = MockClient.streaming((_, __) async => http.StreamedResponse(Stream.fromIterable(List.filled(8, chunk)), 200));
    expect((await fetchEcbFile(EcbFile.history, client: exact)).length, maxEcbDownloadBytes);
  });

  test('logs: the file and the outcome, never the address', () async {
    final lines = <String>[];
    final was = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    try {
      await fetchEcbFile(EcbFile.recent, client: MockClient((_) async => http.Response.bytes(const [1, 2, 3], 200)));
      await expectLater(
          fetchEcbFile(EcbFile.recent, client: MockClient((_) async => http.Response('', 404))), throwsA(isA<EcbFetchException>()));
    } finally {
      await sub.cancel();
      Logger.root.level = was;
    }
    final all = lines.where((l) => l.contains('fx.ecbFetch')).join('\n');
    expect(all, allOf(contains('recent'), contains('ok'), contains('404')));
    for (final s in ['ecb.europa', 'https', 'eurofxref']) {
      expect(all, isNot(contains(s)));
    }
  });
}
