// Stage V1 spec tests (BWOP3: the key id travels in the sealed file). Written from docs/context/STAGE_V_PLAN.md only.
// Layout: "BWOP3" | keyId(8) | nonce(24) | mac(16) | ciphertext. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

const _t = Timeout(Duration(seconds: 60));
final _key = VaultKey(List<int>.generate(32, (i) => i));
final _other = VaultKey(List<int>.generate(32, (i) => 100 + i));
final _aead = Xchacha20.poly1305Aead();
final _aad = utf8.encode('bw-sync-file\nabcd1234abcd1234\n7');
final _plain = utf8.encode('${'{"ops":[]} ' * 20}synthetic payload for the BWOP3 tests');

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// A box in the old layout `magic | nonce | mac | ct` (BWOP1 has no AAD, BWOP2 binds [aad]).
Future<Uint8List> _oldBox(String magic, List<int> plain, VaultKey key, {List<int> aad = const []}) async {
  final box = await _aead.encrypt(
    gzip.encode(plain),
    secretKey: SecretKey(key.bytes),
    nonce: List<int>.generate(24, (i) => 200 - i),
    aad: aad,
  );
  return Uint8List.fromList([...utf8.encode(magic), ...box.nonce, ...box.mac.bytes, ...box.cipherText]);
}

Future<void> _fails(Future<Object?> f, UnsealFailure want, {String? reason}) async {
  try {
    await f;
    fail('expected VaultException(${want.name})${reason == null ? '' : ': $reason'}');
  } on VaultException catch (e) {
    expect(e.failure, want, reason: reason);
  }
}

/// The failure of [f], or fails when it opened.
Future<UnsealFailure> _failure(Future<Object?> f) async {
  try {
    await f;
  } on VaultException catch (e) {
    return e.failure;
  }
  fail('opened but must not');
}

void _addTx(WalletRepo r) => r.addTransaction(date: '2026-01-05', amount: -1250, category: 'Groceries');

void main() {
  group('V1 BWOP3 layout and round trip', () {
    test('a new seal starts with BWOP3 and bytes 5..13 are the key id', () async {
      final s = await seal(_plain, _key, aad: _aad);
      expect(utf8.decode(s.sublist(0, 5)), 'BWOP3');
      final id = await _key.keyIdBytes();
      expect(id.length, 8);
      expect(s.sublist(5, 13), id);
      expect(_hex(id), await _key.keyId(), reason: 'one definition of the fingerprint');
    }, timeout: _t);

    test('another key has another key id; the id is stable for one key', () async {
      expect(await _key.keyIdBytes(), await VaultKey(List<int>.generate(32, (i) => i)).keyIdBytes());
      expect(await _key.keyIdBytes(), isNot(await _other.keyIdBytes()));
    }, timeout: _t);

    test('round trip, also for an empty payload and with empty AAD', () async {
      expect(await unseal(await seal(_plain, _key, aad: _aad), _key, aad: _aad), _plain);
      expect(await unseal(await seal(const [], _key, aad: _aad), _key, aad: _aad), isEmpty);
      expect(await unseal(await seal(_plain, _key, aad: const []), _key, aad: const []), _plain);
    }, timeout: _t);

    test('the layout opens with an independent XChaCha20-Poly1305 using aad || keyId', () async {
      final s = await seal(_plain, _key, aad: _aad);
      final id = s.sublist(5, 13);
      final box = SecretBox(s.sublist(53), nonce: s.sublist(13, 37), mac: Mac(s.sublist(37, 53)));
      final gz = await _aead.decrypt(box, secretKey: SecretKey(_key.bytes), aad: [..._aad, ...id]);
      expect(gzip.decode(gz), _plain);
    }, timeout: _t);
  });

  group('V1 refusals', () {
    test('another key -> otherKey (not badKey)', () async {
      final s = await seal(_plain, _key, aad: _aad);
      await _fails(unseal(s, _other, aad: _aad), UnsealFailure.otherKey);
    }, timeout: _t);

    test('a flipped byte in nonce, mac or ciphertext -> damaged', () async {
      final s = await seal(_plain, _key, aad: _aad);
      for (final i in [13, 20, 36, 37, 45, 52, 53, 60, s.length - 1]) {
        final bad = Uint8List.fromList(s)..[i] ^= 0x01;
        await _fails(unseal(bad, _key, aad: _aad), UnsealFailure.damaged, reason: 'byte $i');
      }
    }, timeout: _t);

    test('a flipped key id byte never opens: otherKey or damaged', () async {
      final s = await seal(_plain, _key, aad: _aad);
      for (var i = 5; i < 13; i++) {
        final bad = Uint8List.fromList(s)..[i] ^= 0x01;
        final f = await _failure(unseal(bad, _key, aad: _aad));
        expect(f, anyOf(UnsealFailure.otherKey, UnsealFailure.damaged), reason: 'byte $i');
      }
    }, timeout: _t);

    test('the key id is bound into the MAC: another key\'s id swapped in does not open with that key', () async {
      final s = await seal(_plain, _key, aad: _aad);
      final swapped = Uint8List.fromList(s)..setRange(5, 13, await _other.keyIdBytes());
      await _fails(unseal(swapped, _other, aad: _aad), UnsealFailure.damaged, reason: 'id matches the opener, MAC does not');
      await _fails(unseal(swapped, _key, aad: _aad), UnsealFailure.otherKey);
    }, timeout: _t);

    test('every truncation is a VaultException; once the header is whole it is damaged', () async {
      final s = await seal(_plain, _key, aad: _aad);
      for (var n = 0; n < s.length; n++) {
        final f = await _failure(unseal(s.sublist(0, n), _key, aad: _aad));
        if (n >= 13) expect(f, UnsealFailure.damaged, reason: 'cut to $n');
      }
    }, timeout: _t);

    test('an AAD mismatch with the right key -> damaged (a sync file used as a backup)', () async {
      final s = await seal(_plain, _key, aad: _aad);
      await _fails(unseal(s, _key, aad: aadBackup), UnsealFailure.damaged);
      await _fails(unseal(s, _key, aad: utf8.encode('bw-sync-file\nabcd1234abcd1234\n8')), UnsealFailure.damaged);
      await _fails(unseal(s, _key, aad: const []), UnsealFailure.damaged);
    }, timeout: _t);

    test('BWOP4 and later -> newerFormat, whatever the key', () async {
      final s = await seal(_plain, _key, aad: _aad);
      for (final magic in ['BWOP4', 'BWOP9']) {
        final f = Uint8List.fromList(s)..setRange(0, 5, utf8.encode(magic));
        await _fails(unseal(f, _key, aad: _aad), UnsealFailure.newerFormat);
        await _fails(unseal(f, _other, aad: _aad), UnsealFailure.newerFormat);
      }
    }, timeout: _t);
  });

  group('V1 older boxes', () {
    test('a hand-built BWOP2 box still opens', () async {
      final b = await _oldBox('BWOP2', _plain, _key, aad: _aad);
      expect(await unseal(b, _key, aad: _aad), _plain);
    }, timeout: _t);

    test('BWOP2 with a wrong key stays badKey (no key id in it); wrong AAD and a changed byte too', () async {
      final b = await _oldBox('BWOP2', _plain, _key, aad: _aad);
      await _fails(unseal(b, _other, aad: _aad), UnsealFailure.badKey);
      await _fails(unseal(b, _key, aad: aadBackup), UnsealFailure.badKey);
      final bad = Uint8List.fromList(b)..[b.length - 1] ^= 0x01;
      await _fails(unseal(bad, _key, aad: _aad), UnsealFailure.badKey);
    }, timeout: _t);

    test('a hand-built BWOP1 box opens whatever AAD is given; wrong key stays badKey', () async {
      final b = await _oldBox('BWOP1', _plain, _key);
      expect(await unseal(b, _key, aad: _aad), _plain);
      expect(await unseal(b, _key, aad: aadBackup), _plain);
      await _fails(unseal(b, _other, aad: _aad), UnsealFailure.badKey);
    }, timeout: _t);
  });

  group('V1 backups', () {
    test('a backup made with key A restored or merged with key B: otherKey reaches the caller', () async {
      final a = WalletRepo.inMemory();
      _addTx(a);
      final bytes = await backupBytes(a, _key);
      expect(utf8.decode(bytes.sublist(0, 5)), 'BWOP3');
      final b = WalletRepo.inMemory();
      // API: assumed: the exception is the VaultException from unseal (as for badKey today), carrying otherKey.
      await _fails(restoreBackupBytes(b, bytes, _other), UnsealFailure.otherKey);
      expect(b.isEmpty, isTrue, reason: 'nothing applied');
      await _fails(mergeBackupBytes(b, bytes, _other), UnsealFailure.otherKey);
      expect(await restoreBackupBytes(b, bytes, _key), greaterThan(0));
      a.close();
      b.close();
    }, timeout: _t);

    test('a damaged backup with the right key is damaged, not otherKey', () async {
      final a = WalletRepo.inMemory();
      _addTx(a);
      final bytes = await backupBytes(a, _key);
      final bad = Uint8List.fromList(bytes)..[bytes.length - 2] ^= 0x10;
      final b = WalletRepo.inMemory();
      await _fails(restoreBackupBytes(b, bad, _key), UnsealFailure.damaged);
      a.close();
      b.close();
    }, timeout: _t);

    test('BackupFailure has otherKey', () {
      expect(BackupFailure.values, contains(BackupFailure.otherKey));
    });
  });
}
