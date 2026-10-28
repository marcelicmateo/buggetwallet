// M1: vault invariants that survived mutation testing. Synthetic data only.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

void main() {
  final aad = utf8.encode('m1');

  test('a file shorter than any header is damaged, never a RangeError (BWOP2 and BWOP3)', () async {
    final key = VaultKey.generate();
    for (final magic in ['BWOP1', 'BWOP2', 'BWOP3']) {
      for (final extra in [0, 3, 30, 38]) {
        final data = [...ascii.encode(magic), ...List<int>.filled(extra, 7)];
        await expectLater(
            unseal(data, key, aad: aad), throwsA(isA<VaultException>().having((e) => e.failure, 'failure', UnsealFailure.damaged)),
            reason: '$magic + $extra bytes');
      }
    }
  });

  test('a BWOP2 file of 5 + 24 + 16 bytes (empty box) is read as a file, a shorter one as too short', () async {
    final key = VaultKey.generate();
    final exact = [...ascii.encode('BWOP2'), ...List<int>.filled(24 + 16, 1)];
    // Long enough to be opened: the MAC fails (badKey), it is not "too short" (damaged).
    await expectLater(
        unseal(exact, key, aad: aad), throwsA(isA<VaultException>().having((e) => e.failure, 'failure', UnsealFailure.badKey)));
    await expectLater(unseal(exact.sublist(0, exact.length - 1), key, aad: aad),
        throwsA(isA<VaultException>().having((e) => e.failure, 'failure', UnsealFailure.damaged)));
  });

  test('deriveKey gives 32 bytes by default and the length asked for', () async {
    final key = VaultKey.generate();
    expect((await deriveKey(key, 'bw-m1')).length, 32);
    expect((await deriveKey(key, 'bw-m1', length: 16)).length, 16);
    expect((await deriveKey(key, 'bw-m1', length: 64)).length, 64);
  });

  test('a key written as text is BW1- plus groups of five, and parses back', () async {
    final key = VaultKey.generate();
    final text = await key.toText();
    expect(text, startsWith('BW1-'));
    final groups = text.substring(4).split('-');
    for (final g in groups.take(groups.length - 1)) {
      expect(g.length, 5);
    }
    expect(groups.last.length, inInclusiveRange(1, 5));
    expect((await VaultKey.parse(text)).bytes, key.bytes);
  });

  test('generated keys are 32 bytes and differ', () {
    final a = VaultKey.generate(), b = VaultKey.generate();
    expect(a.bytes.length, 32);
    expect(a.bytes, isNot(b.bytes));
  });
}
