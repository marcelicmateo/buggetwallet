// Stage I (IC): the relay's GET state adds "bytes" (Wallet.totalBytes: files + kept snapshots + blobs) and "maxBytes"
// (--max-bytes). Additive: api stays 3. Expected sizes are the lengths of the bodies sent. All data is SYNTHETIC.
//
// Each test skips with a fixed reason until the lead lifts it at merge (the field is not on v2 yet).
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

import 'support.dart';

const _skip = false;

Future<String> _hash(List<int> b) async => [for (final x in (await Sha256().hash(b)).bytes) x.toRadixString(16).padLeft(2, '0')].join();

void main() {
  test('state names maxBytes (the --max-bytes flag) and bytes (11 after one 11-byte file); api stays 3', () async {
    final h = await freshHarness(maxBytes: 4096);
    expect((await h.putData(w1, 'dev1', 1, 'hello world')).statusCode, 201);
    final s = await h.state(w1);
    expect(s['api'], 3);
    expect(s['maxBytes'], 4096);
    expect(s['bytes'], 11);
  }, skip: _skip);

  test('bytes grows with every file, a snapshot and a blob, and equals their sum', () async {
    final h = await freshHarness(maxBytes: 1 << 20);
    expect((await h.putData(w1, 'dev1', 1, 'hello world')).statusCode, 201); // 11
    expect((await h.putData(w1, 'dev1', 2, 'abcde')).statusCode, 201); // 5
    expect((await h.state(w1))['bytes'], 16);
    final blob = bytes('sealed photo bytes'); // 18
    expect((await h.send('PUT', '/v2/w/$w1/blob/${await _hash(blob)}', key: keyA, body: blob)).statusCode, 201);
    expect((await h.state(w1))['bytes'], 34);
  }, skip: _skip);

  test('bytes never exceeds maxBytes: a PUT past the limit is refused and not counted', () async {
    final h = await freshHarness(maxBytes: 20);
    expect((await h.putData(w1, 'dev1', 1, 'hello world')).statusCode, 201); // 11
    expect((await h.putData(w1, 'dev1', 2, 'abcdefghij')).statusCode, 507); // 11 + 10 > 20
    final s = await h.state(w1);
    expect(s['bytes'], 11);
    expect(s['bytes'] as int, lessThanOrEqualTo(s['maxBytes'] as int));
  }, skip: _skip);

  test('maxBytes follows the configured limit, not a fixed one', () async {
    final h = await freshHarness(maxBytes: 12345);
    expect((await h.putData(w1, 'dev1', 1, 'x')).statusCode, 201);
    expect((await h.state(w1))['maxBytes'], 12345);
  }, skip: _skip);

  test('control: the state of a wallet that exists still answers 200 with the old fields', () async {
    final h = await freshHarness();
    expect((await h.putData(w1, 'dev1', 1, 'hello world')).statusCode, 201);
    final s = await h.state(w1);
    expect(s['api'], 3);
    expect((s['devices'] as Map).keys, ['dev1']);
  });
}
