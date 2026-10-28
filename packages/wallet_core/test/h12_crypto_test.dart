// Stage H12 (crypto): nonce uniqueness, fixed-key fixed-nonce `seal` vectors (BWOP2 with AAD), AAD binding, truncated and
// damaged boxes, BWOP1 files still readable, decompression bombs for `unseal`, and a sync file is never a backup.
// Written from the Stage H spec: the vectors check the layout `magic | nonce(24) | mac(16) | ciphertext` with an
// independent XChaCha20-Poly1305 and gunzip, never `unseal`. Tests of the new API skip until the build has it
// (`seal(aad:)`, `seal(nonce:)`, `UnsealFailure.tooLarge`). All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/engine_spec_sim.dart';
import 'support/h_compat.dart';
import 'support/h_sim.dart';

const _t = Timeout(Duration(seconds: 60));

final _key = VaultKey(List<int>.generate(32, (i) => i));
final _aead = Xchacha20.poly1305Aead();

/// A BWOP1 box built by hand (the format of every file written before Stage H): magic | nonce | mac | ct.
Future<Uint8List> _box1(List<int> gz, VaultKey key, {List<int>? nonce, String magic = 'BWOP1'}) async {
  final n = nonce ?? List<int>.generate(24, (i) => 200 - i);
  final box = await _aead.encrypt(gz, secretKey: SecretKey(key.bytes), nonce: n);
  return Uint8List.fromList([...utf8.encode(magic), ...box.nonce, ...box.mac.bytes, ...box.cipherText]);
}

Future<void> _expectFailure(Future<Object?> f, UnsealFailure want, {String? reason}) async {
  try {
    await f;
    fail('expected a VaultException(${want.name})${reason == null ? '' : ': $reason'}');
  } on VaultException catch (e) {
    expect(e.failure, want, reason: reason);
  }
}

void main() {
  final tooLarge = UnsealFailure.values.where((f) => f.name == 'tooLarge');

  group('nonces', () {
    test('2000 seals of the same plaintext use 2000 different nonces and different ciphertexts', () async {
      final nonces = <String>{}, cts = <String>{};
      for (var i = 0; i < 2000; i++) {
        final s = await sealC(utf8.encode('same plaintext'), _key);
        nonces.add(base64.encode(s.sublist(5, 29)));
        cts.add(base64.encode(s.sublist(45)));
      }
      expect(nonces.length, 2000);
      expect(cts.length, 2000);
    }, timeout: _t);

    test('no nonce is all zeros or repeated bytes (a fixed or counter nonce would be)', () async {
      for (var i = 0; i < 50; i++) {
        final n = (await sealC([i], _key)).sublist(5, 29);
        expect(n.toSet().length, greaterThan(4));
      }
    }, timeout: _t);

    test('a random key per device: keys do not repeat either', () {
      expect({for (var i = 0; i < 200; i++) VaultKey.generate().bytes.join(',')}.length, 200);
    });
  });

  group('known-answer vectors (BWOP2, written only with legacyFormat: the web key)', () {
    final nonce = List<int>.generate(24, (i) => 0xa0 + i);
    final aad = utf8.encode('bw-sync-file\nabcd1234abcd1234\n7');
    final plain = utf8.encode('{"ops":[]} synthetic known answer');
    final skip = bugUnless(sealHasNonce, 'H8', 'seal(plain, key, aad:, nonce:) test seam');
    Future<Uint8List> sealC(List<int> plain, VaultKey key, {required List<int> aad, List<int>? nonce}) =>
        seal(plain, key, aad: aad, nonce: nonce, legacyFormat: true);

    test('layout: magic, the given nonce, then mac and ciphertext that an independent XChaCha20-Poly1305 opens with the AAD', () async {
      final s = await sealC(plain, _key, aad: aad, nonce: nonce);
      expect(utf8.decode(s.sublist(0, 5)), 'BWOP2');
      expect(s.sublist(5, 29), nonce);
      final box = SecretBox(s.sublist(45), nonce: s.sublist(5, 29), mac: Mac(s.sublist(29, 45)));
      final gz = await _aead.decrypt(box, secretKey: SecretKey(_key.bytes), aad: aad);
      expect(gzip.decode(gz), plain);
    }, skip: skip, timeout: _t);

    test('deterministic for a fixed nonce, and a different nonce, key or AAD changes the bytes', () async {
      final a = await sealC(plain, _key, aad: aad, nonce: nonce);
      expect(await sealC(plain, _key, aad: aad, nonce: nonce), a);
      expect(await sealC(plain, _key, aad: aad, nonce: List<int>.filled(24, 1)), isNot(a));
      expect(await sealC(plain, VaultKey(List<int>.filled(32, 9)), aad: aad, nonce: nonce), isNot(a));
      expect(await sealC(plain, _key, aad: utf8.encode('bw-sync-file\nabcd1234abcd1234\n8'), nonce: nonce), isNot(a));
    }, skip: skip, timeout: _t);

    test('the mac covers the AAD: the same box opens only with the exact AAD, one byte off fails as badKey', () async {
      final s = await sealC(plain, _key, aad: aad, nonce: nonce);
      expect(await unsealC(s, _key, aad: aad), plain);
      await _expectFailure(unsealC(s, _key, aad: utf8.encode('bw-sync-file\nabcd1234abcd1234\n8')), UnsealFailure.badKey,
          reason: 'another seq: a file moved to another slot');
      await _expectFailure(unsealC(s, _key, aad: utf8.encode('bw-backup')), UnsealFailure.badKey, reason: 'a sync file used as a backup');
      await _expectFailure(unsealC(s, _key, aad: const []), UnsealFailure.badKey);
    }, skip: skip, timeout: _t);

    test('every use has its own AAD: a snapshot, a backup, a blob and a sync file never open as one another', () async {
      final uses = [
        utf8.encode('bw-sync-file\ndev\n1'),
        utf8.encode('bw-snapshot\ns7-1-ab'),
        utf8.encode('bw-backup'),
        utf8.encode('bw-blob'),
      ];
      for (var i = 0; i < uses.length; i++) {
        final s = await sealC(plain, _key, aad: uses[i]);
        for (var j = 0; j < uses.length; j++) {
          if (i == j) {
            expect(await unsealC(s, _key, aad: uses[j]), plain);
          } else {
            await _expectFailure(unsealC(s, _key, aad: uses[j]), UnsealFailure.badKey, reason: 'use $i opened as $j');
          }
        }
      }
    }, skip: bugUnless(sealHasAad, 'H8', 'seal/unseal take an AAD per use'), timeout: _t);

    test('any single flipped bit anywhere in the box is refused (magic, nonce, mac, ciphertext)', () async {
      final s = await sealC(plain, _key, aad: aad, nonce: nonce);
      for (var i = 0; i < s.length; i++) {
        final bad = Uint8List.fromList(s)..[i] ^= 0x01;
        try {
          await unsealC(bad, _key, aad: aad);
          fail('byte $i flipped but the box opened');
        } on VaultException {
          // refused, as it must be
        }
      }
    }, skip: skip, timeout: _t);
  });

  group('known-answer vectors (BWOP3, V1)', () {
    final nonce = List<int>.generate(24, (i) => 0xa0 + i);
    final aad = utf8.encode('bw-sync-file\nabcd1234abcd1234\n7');
    final plain = utf8.encode('{"ops":[]} synthetic known answer');

    test('keyIdBytes: SHA-256("budget-wallet-key-id" || key)[0:8], and keyId() is its lowercase hex', () async {
      final want = (await Sha256().hash([...utf8.encode('budget-wallet-key-id'), ..._key.bytes])).bytes.sublist(0, 8);
      final id = await _key.keyIdBytes();
      expect(id, want);
      expect(await _key.keyId(), id.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
      expect(await VaultKey(List<int>.filled(32, 9)).keyIdBytes(), isNot(id));
    }, timeout: _t);

    test('layout: magic, key id, the given nonce, then mac and ciphertext that open with AAD || key id', () async {
      final s = await seal(plain, _key, aad: aad, nonce: nonce);
      final id = await _key.keyIdBytes();
      expect(utf8.decode(s.sublist(0, 5)), 'BWOP3');
      expect(s.sublist(5, 13), id);
      expect(s.sublist(13, 37), nonce);
      final box = SecretBox(s.sublist(53), nonce: s.sublist(13, 37), mac: Mac(s.sublist(37, 53)));
      final gz = await _aead.decrypt(box, secretKey: SecretKey(_key.bytes), aad: [...aad, ...id]);
      expect(gzip.decode(gz), plain);
      // Without the key id in the AAD the box does not open: the id is bound to the MAC.
      await expectLater(_aead.decrypt(box, secretKey: SecretKey(_key.bytes), aad: aad), throwsA(isA<SecretBoxAuthenticationError>()));
    }, timeout: _t);

    test('deterministic for a fixed nonce; 8 bytes longer than BWOP2', () async {
      final a = await seal(plain, _key, aad: aad, nonce: nonce);
      expect(await seal(plain, _key, aad: aad, nonce: nonce), a);
      expect(a.length, (await seal(plain, _key, aad: aad, nonce: nonce, legacyFormat: true)).length + 8);
    }, timeout: _t);

    test('another key is otherKey (nothing decrypted); the right key with another AAD is damaged', () async {
      final s = await seal(plain, _key, aad: aad, nonce: nonce);
      expect(await unseal(s, _key, aad: aad), plain);
      await _expectFailure(unseal(s, VaultKey(List<int>.filled(32, 9)), aad: aad), UnsealFailure.otherKey);
      await _expectFailure(unseal(s, _key, aad: utf8.encode('bw-backup')), UnsealFailure.damaged, reason: 'a sync file used as a backup');
      await _expectFailure(unseal(s, _key, aad: const []), UnsealFailure.damaged);
    }, timeout: _t);

    test('every use has its own AAD: sealed for one use, opened as another is damaged', () async {
      final uses = [aadSyncFile('dev', 1), aadSnapshot('s7-1-ab'), aadBackup, aadBlob];
      for (var i = 0; i < uses.length; i++) {
        final s = await seal(plain, _key, aad: uses[i]);
        for (var j = 0; j < uses.length; j++) {
          if (i == j) {
            expect(await unseal(s, _key, aad: uses[j]), plain);
          } else {
            await _expectFailure(unseal(s, _key, aad: uses[j]), UnsealFailure.damaged, reason: 'use $i opened as $j');
          }
        }
      }
    }, timeout: _t);

    test('a flipped bit: in the key id = otherKey, in nonce, mac or ciphertext = damaged, in the magic = refused', () async {
      final s = await seal(plain, _key, aad: aad, nonce: nonce);
      for (var i = 0; i < s.length; i++) {
        final bad = Uint8List.fromList(s)..[i] ^= 0x01;
        try {
          await unseal(bad, _key, aad: aad);
          fail('byte $i flipped but the box opened');
        } on VaultException catch (e) {
          if (i >= 5 && i < 13) {
            expect(e.failure, UnsealFailure.otherKey, reason: 'key id byte $i');
          } else if (i >= 13) {
            expect(e.failure, UnsealFailure.damaged, reason: 'byte $i');
          }
        }
      }
    }, timeout: _t);

    test('a key id swapped for the other key\'s id: that key reads it as its own, but the MAC fails: damaged', () async {
      final other = VaultKey(List<int>.filled(32, 9));
      final s = Uint8List.fromList(await seal(plain, _key, aad: aad, nonce: nonce))..setRange(5, 13, await other.keyIdBytes());
      await _expectFailure(unseal(s, other, aad: aad), UnsealFailure.damaged);
      await _expectFailure(unseal(s, _key, aad: aad), UnsealFailure.otherKey);
    }, timeout: _t);

    test('cut inside the header (under 53 bytes) is damaged', () async {
      final s = await seal(plain, _key, aad: aad, nonce: nonce);
      for (final n in [45, 46, 52]) {
        await _expectFailure(unseal(s.sublist(0, n), _key, aad: aad), UnsealFailure.damaged, reason: 'cut to $n');
      }
    }, timeout: _t);
  });

  group('boxes written by older builds and damaged boxes', () {
    test('a hand-built BWOP1 box (no AAD) still opens, whatever AAD the caller passes', () async {
      final b = await _box1(gzip.encode(utf8.encode('old build file')), _key);
      expect(utf8.decode(await unsealC(b, _key, aad: utf8.encode('bw-sync-file\nx\n1'))), 'old build file');
      expect(utf8.decode(await unsealC(b, _key, aad: utf8.encode('bw-backup'))), 'old build file');
    }, timeout: _t);

    test('a BWOP1 box with the wrong key is badKey, with one byte changed is badKey', () async {
      final b = await _box1(gzip.encode(utf8.encode('old build file')), _key);
      await _expectFailure(unsealC(b, VaultKey(List<int>.filled(32, 3))), UnsealFailure.badKey);
      final bad = Uint8List.fromList(b)..[b.length - 1] ^= 0x80;
      await _expectFailure(unsealC(bad, _key), UnsealFailure.badKey);
    }, timeout: _t);

    test('every truncation of a valid box (0..len-1 bytes) is a VaultException, never another error', () async {
      final s = await sealC(utf8.encode('truncate me please, some synthetic text'), _key);
      for (var n = 0; n < s.length; n++) {
        try {
          await unsealC(s.sublist(0, n), _key);
          fail('a box cut to $n of ${s.length} bytes opened');
        } on VaultException catch (e) {
          expect(e.failure, anyOf(UnsealFailure.damaged, UnsealFailure.badKey), reason: 'cut to $n');
        }
      }
    }, timeout: _t);

    test('a newer magic (BWOP4 .. BWOP9) is newerFormat, BWOP0 and other text is damaged; an empty file too', () async {
      final base = await _box1(gzip.encode([1, 2, 3]), _key);
      for (final d in '456789'.split('')) {
        final b = Uint8List.fromList(base)..[4] = d.codeUnitAt(0);
        await _expectFailure(unsealC(b, _key), UnsealFailure.newerFormat, reason: 'BWOP$d');
      }
      await _expectFailure(unsealC(Uint8List.fromList(base)..[4] = 0x30, _key), UnsealFailure.damaged);
      await _expectFailure(unsealC(utf8.encode('{"ops":[]}'), _key), UnsealFailure.damaged);
      await _expectFailure(unsealC(const [], _key), UnsealFailure.damaged);
    }, timeout: _t);

    test('a box that authenticates but holds no gzip is damaged; a cut-off gzip is damaged', () async {
      await _expectFailure(unsealC(await _box1(utf8.encode('not gzip at all, just text........'), _key), _key), UnsealFailure.damaged);
      final gz = gzip.encode(List<int>.generate(5000, (i) => i * 7));
      await _expectFailure(unsealC(await _box1(gz.sublist(0, gz.length - 20), _key), _key), UnsealFailure.damaged);
    }, timeout: _t);
  });

  group('decompression bombs (H8)', () {
    test('a sealed gzip of 20 MiB of zeros (a ratio of ~1000) below the cap opens', () async {
      final b = await _box1(gzip.encode(Uint8List(20 << 20)), _key);
      expect((await unsealC(b, _key)).length, 20 << 20);
    }, timeout: _t);

    test('a sealed gzip that inflates past 256 MiB is refused as tooLarge, quickly, without holding the result', () async {
      final gz = gzip.encode(Uint8List(257 << 20));
      expect(gz.length, lessThan(1 << 20), reason: 'it is a bomb: under 1 MiB sealed');
      final b = await _box1(gz, _key);
      final sw = Stopwatch()..start();
      await _expectFailure(unsealC(b, _key), tooLarge.first, reason: 'cap is 256 MiB');
      expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
    }, skip: bugUnless(tooLarge.isNotEmpty, 'H8', '256 MiB inflate cap in unseal (UnsealFailure.tooLarge)'), timeout: _t);

    test('a sync file that is a bomb is quarantined, not applied, and the other devices\' files still apply', () async {
      final clock = SimClock();
      final mem = MemoryTransport(now: () => clock.t);
      final c = Cluster(mem, clock);
      addTearDown(c.closeAll);
      final [a, b, d] = [c.add(), c.add(), c.add()];
      a.repo.addTransaction(date: '2026-01-14', amount: -100, category: 'Groceries', note: 'from the bomb\'s device');
      await a.sync();
      d.repo.addTransaction(date: '2026-01-14', amount: -200, category: 'Groceries', note: 'from the other device');
      await d.sync();
      mem.replace(a.id, 1, await _box1(gzip.encode(Uint8List(257 << 20)), c.key));
      final r = await b.sync();
      expect(r.problems, hasLength(1));
      expect(b.repo.transactions().map((t) => t.note), ['from the other device']);
    }, skip: bugUnless(tooLarge.isNotEmpty, 'H8', 'a file inflating past the cap is refused'), timeout: _t);
  });

  group('a sync file moved to another slot is refused (the AAD names device and seq)', () {
    final skip = bugUnless(sealHasAad, 'H8', 'BWOP2 binds each sync file to its device and seq');

    Future<(Cluster, MemoryTransport, Dev, Dev, Dev)> setup() async {
      final clock = SimClock();
      final mem = MemoryTransport(now: () => clock.t);
      final c = Cluster(mem, clock);
      addTearDown(c.closeAll);
      final [a, b, d] = [c.add(), c.add(), c.add()];
      a.repo.addTransaction(date: '2026-01-14', amount: -100, category: 'Groceries', note: 'x');
      await a.sync();
      a.repo.addTransaction(date: '2026-01-14', amount: -110, category: 'Groceries', note: 'y');
      await a.sync();
      d.repo.addTransaction(date: '2026-01-14', amount: -120, category: 'Groceries', note: 'z');
      await d.sync();
      return (c, mem, a, b, d);
    }

    test(
        'device D\'s file put in A\'s slot: one problem, nothing of D\'s file applied through it, A\'s first file and D\'s own slot are fine',
        () async {
      final (_, mem, a, b, d) = await setup();
      mem.replace(a.id, 2, mem.files['d/${d.id}/1']!);
      final r = await b.sync();
      expect(r.problems, hasLength(1));
      expect(r.problems.single.device, a.short);
      expect(b.repo.transactions().map((t) => t.note).toSet(), {'x', 'z'}, reason: 'y was in the moved file; z arrives from D\'s own slot');
    }, skip: skip, timeout: _t);

    test('A\'s first file copied into A\'s second slot: refused, the second edit is not invented', () async {
      final (_, mem, a, b, _) = await setup();
      mem.replace(a.id, 2, mem.files['d/${a.id}/1']!);
      final r = await b.sync();
      expect(r.problems, hasLength(1));
      expect(b.repo.transactions().map((t) => t.note), isNot(contains('y')));
      expect(b.repo.transactions().map((t) => t.note), contains('x'));
    }, skip: skip, timeout: _t);
  });

  group('a sync file is never a backup, and the other way round', () {
    test('restoring a sealed sync file as a backup throws and leaves the wallet empty', () async {
      final clock = SimClock();
      final mem = MemoryTransport(now: () => clock.t);
      final c = Cluster(mem, clock);
      addTearDown(c.closeAll);
      final a = c.add();
      a.repo.addTransaction(date: '2026-01-14', amount: -100, category: 'Groceries');
      await a.sync();
      final file = mem.files['d/${a.id}/1']!;
      final fresh = WalletRepo.inMemory();
      addTearDown(fresh.close);
      await expectLater(restoreBackupBytes(fresh, file, c.key), throwsA(anyOf(isA<VaultException>(), isA<BackupException>())));
      expect(fresh.isEmpty, isTrue);
    }, timeout: _t);

    test('a backup placed on the relay as a device file is refused by the peer (not applied as ops)', () async {
      final clock = SimClock();
      final mem = MemoryTransport(now: () => clock.t);
      final c = Cluster(mem, clock);
      addTearDown(c.closeAll);
      final [a, b] = [c.add(), c.add()];
      a.repo.addTransaction(date: '2026-01-14', amount: -100, category: 'Groceries', note: 'real');
      await a.sync();
      final backup = await backupBytes(a.repo, c.key);
      mem.replace(a.id, 1, backup);
      final r = await b.sync();
      if (sealHasAad) {
        expect(r.problems, hasLength(1), reason: 'the AAD says "backup", not "sync file 1"');
        expect(b.repo.transactions(), isEmpty);
      } else {
        // Before BWOP2 the same bytes are a valid ops list, which is exactly why the AAD is added.
        expect(r.problems.length, lessThanOrEqualTo(1));
      }
    }, timeout: _t);

    test('a backup made now restores into an empty wallet on any build', () async {
      final a = WalletRepo.inMemory();
      addTearDown(a.close);
      a.addTransaction(date: '2026-01-14', amount: -100, category: 'Groceries', note: 'backed up');
      final bytes = await backupBytes(a, _key);
      final b = WalletRepo.inMemory();
      addTearDown(b.close);
      expect(await restoreBackupBytes(b, bytes, _key), greaterThan(0));
      expect(b.transactions().single.note, 'backed up');
      expect(utf8.decode(bytes.sublist(0, 4)), 'BWOP');
    }, timeout: _t);
  });
}
