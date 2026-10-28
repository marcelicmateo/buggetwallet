// The desktop key file (lib/src/key_store_io.dart): private folder (0700), key file 0600, written through a temp file and
// renamed. Real files in a temp folder; all keys are random and SYNTHETIC. POSIX modes: skipped on Windows.
import 'dart:io';

import 'package:budget_wallet/src/device_key.dart';
import 'package:budget_wallet/src/key_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

/// The permission bits of [path] as an octal string, e.g. `600`.
String mode(String path) => (FileStat.statSync(path).mode & 0xFFF).toRadixString(8);

void main() {
  late Directory dir;
  late Directory keyDir;
  late KeyStore ks;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux; // flutter test reports android: that would use the system keystore
    dir = await Directory.systemTemp.createTemp('bw-key-');
    keyDir = Directory('${dir.path}/support');
    ks = KeyStore(keyDir: keyDir);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await dir.delete(recursive: true);
  });

  final posix = Platform.isWindows ? 'POSIX modes' : null;

  test('write creates a private folder and a 0600 key file; read gives the key back', () async {
    final key = VaultKey.generate();
    await ks.write(key);
    final file = File('${keyDir.path}/wallet.key');
    expect(file.existsSync(), isTrue);
    expect(mode(keyDir.path), '700');
    expect(mode(file.path), '600');
    expect((await ks.read())!.bytes, key.bytes);
  }, skip: posix);

  test('writeAside keeps a set-aside wallet\'s key in its own private slot next to the active key (never over it)', () async {
    final active = VaultKey.generate();
    final old = VaultKey.generate();
    await ks.write(active);
    final slot = await ks.writeAside('2026-10-25', old);
    expect(slot, 'aside.2026-10-25');
    final file = File('${keyDir.path}/wallet.key.$slot');
    expect(file.existsSync(), isTrue);
    expect(mode(file.path), '600');
    expect((await VaultKey.parse(file.readAsStringSync())).bytes, old.bytes);
    expect((await ks.read())!.bytes, active.bytes, reason: 'the active key is untouched');
    // The same day again: a new slot, the first one is never overwritten.
    final other = VaultKey.generate();
    expect(await ks.writeAside('2026-10-25', other), 'aside.2026-10-25-2');
    expect((await VaultKey.parse(file.readAsStringSync())).bytes, old.bytes);
    // Only a slot made for a set-aside that did not happen is taken back.
    await ks.removeAside('aside.2026-10-25-2');
    expect(File('${keyDir.path}/wallet.key.aside.2026-10-25-2').existsSync(), isFalse);
    expect(file.existsSync(), isTrue);
    // forget() (the web "Forget this browser" path and tests) leaves aside keys alone.
    await ks.forget();
    expect(file.existsSync(), isTrue);
  }, skip: posix);

  test('the join-pending marker is a private side file: written, read back, cleared', () async {
    expect(await ks.readJoinMarker(), isNull);
    await ks.writeJoinMarker('{"v":1}');
    final f = File('${keyDir.path}/join.pending');
    expect(mode(f.path), '600');
    expect(await ks.readJoinMarker(), '{"v":1}');
    await ks.clearJoinMarker();
    expect(f.existsSync(), isFalse);
    expect(await ks.readJoinMarker(), isNull);
  }, skip: posix);

  test('a folder that already exists with open permissions is made private', () async {
    await keyDir.create();
    await Process.run('chmod', ['755', keyDir.path]);
    await ks.write(VaultKey.generate());
    expect(mode(keyDir.path), '700');
  }, skip: posix);

  test('writing again replaces the key atomically: no temp file is left, the mode stays 0600', () async {
    final first = VaultKey.generate();
    final second = VaultKey.generate();
    await ks.write(first);
    await ks.write(second);
    final names = keyDir.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last).toList();
    expect(names, ['wallet.key']);
    expect(mode('${keyDir.path}/wallet.key'), '600');
    expect((await ks.read())!.bytes, second.bytes);
  }, skip: posix);

  test('a stale temp file from a crashed write does not break the next write and the old key survives until the rename', () async {
    final old = VaultKey.generate();
    await ks.write(old);
    File('${keyDir.path}/wallet.key.tmp').writeAsStringSync('half');
    expect((await ks.read())!.bytes, old.bytes);
    final fresh = VaultKey.generate();
    await ks.write(fresh);
    expect((await ks.read())!.bytes, fresh.bytes);
    expect(File('${keyDir.path}/wallet.key.tmp').existsSync(), isFalse);
  }, skip: posix);

  test('reading an older install tightens its open folder and key file (no write needed)', () async {
    final key = VaultKey.generate();
    await keyDir.create();
    final file = File('${keyDir.path}/wallet.key')..writeAsStringSync(await key.toText());
    await Process.run('chmod', ['755', keyDir.path]);
    await Process.run('chmod', ['644', file.path]);
    expect(mode(keyDir.path), '755');
    expect((await ks.read())!.bytes, key.bytes);
    expect(mode(keyDir.path), '700');
    expect(mode(file.path), '600');
  }, skip: posix);

  test('reading with no key file leaves the folder alone and gives null', () async {
    await keyDir.create();
    await Process.run('chmod', ['755', keyDir.path]);
    expect(await ks.read(), isNull);
    expect(mode(keyDir.path), '755');
  }, skip: posix);

  test('the key file holds only the key text, forget deletes it, read then gives null', () async {
    final key = VaultKey.generate();
    await ks.write(key);
    expect(File('${keyDir.path}/wallet.key').readAsStringSync().trim(), await key.toText());
    await ks.forget();
    expect(File('${keyDir.path}/wallet.key').existsSync(), isFalse);
    expect(await ks.read(), isNull);
  });

  group('device id (H6)', () {
    test('none stored reads null; written it is read back from device.id beside wallet.key, 0600 in a 0700 folder', () async {
      expect(await ks.readDeviceId(), isNull);
      await ks.writeDeviceId('abcDEF0123456789');
      expect(await ks.readDeviceId(), 'abcDEF0123456789');
      expect(File('${keyDir.path}/device.id').readAsStringSync(), 'abcDEF0123456789');
      expect(mode('${keyDir.path}/device.id'), '600');
      expect(mode(keyDir.path), '700');
    }, skip: posix);

    test('writing again replaces it atomically (no temp file left) and a stale temp file does not break it', () async {
      await keyDir.create(recursive: true);
      File('${keyDir.path}/device.id.tmp').writeAsStringSync('stale');
      await ks.writeDeviceId('first1');
      await ks.writeDeviceId('second2');
      expect(await ks.readDeviceId(), 'second2');
      final names = keyDir.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last).toList();
      expect(names, ['device.id']);
    }, skip: posix);

    test('the key and the id are separate files; forget removes both', () async {
      await ks.write(VaultKey.generate());
      await ks.writeDeviceId('idid1234');
      await ks.forget();
      expect(await ks.read(), isNull);
      expect(await ks.readDeviceId(), isNull);
    });

    test('an empty file reads as none', () async {
      await keyDir.create(recursive: true);
      File('${keyDir.path}/device.id').writeAsStringSync('\n');
      expect(await ks.readDeviceId(), isNull);
    });
  });

  group('device key (DK)', () {
    test('none stored reads null; written it is read back from device.key, 0600 in a 0700 folder', () async {
      expect(await ks.readDeviceKey(), isNull);
      final seed = List<int>.generate(32, (i) => i * 7 % 256);
      await ks.writeDeviceKey(seed);
      expect(await ks.readDeviceKey(), seed);
      expect(mode('${keyDir.path}/device.key'), '600');
      expect(mode(keyDir.path), '700');
      expect(File('${keyDir.path}/device.key').readAsStringSync(), isNot(contains('\n')));
    }, skip: posix);

    test('deviceKeyOf makes a key once and gives the same one afterwards', () async {
      final first = await deviceKeyOf(ks);
      expect(first, hasLength(32));
      expect(await deviceKeyOf(ks), first);
      expect(await ks.readDeviceKey(), first);
      // Another install (another folder) makes another key.
      final other = KeyStore(keyDir: Directory('${dir.path}/other'));
      expect(await deviceKeyOf(other), isNot(first));
    });

    test('forget removes it with the wallet key and the id; a wallet joined afterwards makes a new one', () async {
      await ks.write(VaultKey.generate());
      await ks.writeDeviceId('idid1234');
      final first = await deviceKeyOf(ks);
      await ks.forget();
      expect(await ks.readDeviceKey(), isNull);
      expect(File('${keyDir.path}/device.key').existsSync(), isFalse);
      expect(await deviceKeyOf(ks), isNot(first));
    });

    test('a damaged or short file reads as none (a new key is made on the next need)', () async {
      await keyDir.create(recursive: true);
      for (final bad in ['', '\n', 'not base64 !!', 'AAAA']) {
        File('${keyDir.path}/device.key').writeAsStringSync(bad);
        expect(await ks.readDeviceKey(), isNull, reason: bad);
      }
      expect(decodeDeviceKey(null), isNull);
      expect(decodeDeviceKey(encodeDeviceKey(List.filled(32, 9))), List.filled(32, 9));
    });

    test('the key text is never in the log', () async {
      final lines = <String>[];
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((r) => lines.add(r.message));
      addTearDown(sub.cancel);
      final seed = List<int>.generate(32, (i) => 200 - i);
      await ks.writeDeviceKey(seed);
      await ks.readDeviceKey();
      expect(lines.join('\n'), isNot(contains(encodeDeviceKey(seed))));
      expect(lines.join('\n'), contains('deviceKey'));
    });
  });
}
