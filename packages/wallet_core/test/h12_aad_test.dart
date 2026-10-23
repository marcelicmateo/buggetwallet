@Skip(
    'BUG: H8 - needs the AAD constants of the Stage H contract (aadSyncFile, aadSnapshot, aadBackup, aadBlob, aadWebKey); lift this skip and the ignores below when they are exported')
@TestOn('vm')
library;

// ignore_for_file: undefined_identifier, undefined_function, argument_type_not_assignable
// Stage H12 (AAD constants of BWOP2). Written against the contract names: `aadSyncFile(device, seq)`,
// `aadSnapshot(id)`, `aadBackup`, `aadBlob`, `aadWebKey`, all `List<int>` (UTF-8 of `bw-sync-file\n<device>\n<seq>`,
// `bw-snapshot\n<id>`, `bw-backup`, `bw-blob` and the web key wrap's own text). The names do not exist on v2, so the file
// is skipped as a whole (never loaded) and the analyzer errors are ignored until they do. Synthetic data only.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/h_compat.dart';

final _key = VaultKey(List<int>.generate(32, (i) => i));

void main() {
  test('the constants spell what the spec says', () {
    expect(aadSyncFile('abcd1234abcd1234', 7), utf8.encode('bw-sync-file\nabcd1234abcd1234\n7'));
    expect(aadSnapshot('s8-1-ab'), utf8.encode('bw-snapshot\ns8-1-ab'));
    expect(aadBackup, utf8.encode('bw-backup'));
    expect(aadBlob, utf8.encode('bw-blob'));
    expect(aadWebKey, isNotEmpty);
  });

  test('every use, device and seq has its own AAD: nothing opens under another one', () async {
    final uses = <String, List<int>>{
      'file a/1': aadSyncFile('aaaa', 1),
      'file a/2': aadSyncFile('aaaa', 2),
      'file b/1': aadSyncFile('bbbb', 1),
      'snapshot s1': aadSnapshot('s1'),
      'snapshot s2': aadSnapshot('s2'),
      'backup': aadBackup,
      'blob': aadBlob,
      'web key': aadWebKey,
    };
    final plain = utf8.encode('synthetic');
    for (final MapEntry(key: from, value: aad) in uses.entries) {
      final sealed = await sealC(plain, _key, aad: aad);
      for (final MapEntry(key: to, value: other) in uses.entries) {
        if (from == to) {
          expect(await unsealC(sealed, _key, aad: other), plain, reason: from);
        } else {
          await expectLater(unsealC(sealed, _key, aad: other), throwsA(isA<VaultException>()), reason: '$from opened as $to');
        }
      }
    }
  });

  test('backups and blobs written now carry their own AAD: a backup does not open as a blob', () async {
    final a = WalletRepo.inMemory();
    addTearDown(a.close);
    a.addTransaction(date: '2026-01-14', amount: -100, category: 'Groceries');
    final backup = await backupBytes(a, _key);
    expect(await unsealC(backup, _key, aad: aadBackup), isNotEmpty);
    await expectLater(unsealC(backup, _key, aad: aadBlob), throwsA(isA<VaultException>()));
  });
}
