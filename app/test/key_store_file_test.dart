// The desktop key file (lib/src/key_store_io.dart): private folder (0700), key file 0600, written through a temp file and
// renamed. Real files in a temp folder; all keys are random and SYNTHETIC. POSIX modes: skipped on Windows.
import 'dart:io';

import 'package:budget_wallet/src/key_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

/// The permission bits of [path] as an octal string, e.g. `600`.
String mode(String path) => (FileStat.statSync(path).mode & 0xFFF).toRadixString(8);

void main() {
  late Directory dir;
  late Directory keyDir;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux; // flutter test reports android: that would use the system keystore
    dir = await Directory.systemTemp.createTemp('bw-key-');
    keyDir = Directory('${dir.path}/support');
    KeyStore.keyDirOverride = keyDir;
  });

  tearDown(() async {
    KeyStore.keyDirOverride = null;
    debugDefaultTargetPlatformOverride = null;
    await dir.delete(recursive: true);
  });

  final posix = Platform.isWindows ? 'POSIX modes' : null;

  test('write creates a private folder and a 0600 key file; read gives the key back', () async {
    final key = VaultKey.generate();
    await KeyStore.write(key);
    final file = File('${keyDir.path}/wallet.key');
    expect(file.existsSync(), isTrue);
    expect(mode(keyDir.path), '700');
    expect(mode(file.path), '600');
    expect((await KeyStore.read())!.bytes, key.bytes);
  }, skip: posix);

  test('a folder that already exists with open permissions is made private', () async {
    await keyDir.create();
    await Process.run('chmod', ['755', keyDir.path]);
    await KeyStore.write(VaultKey.generate());
    expect(mode(keyDir.path), '700');
  }, skip: posix);

  test('writing again replaces the key atomically: no temp file is left, the mode stays 0600', () async {
    final first = VaultKey.generate();
    final second = VaultKey.generate();
    await KeyStore.write(first);
    await KeyStore.write(second);
    final names = keyDir.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last).toList();
    expect(names, ['wallet.key']);
    expect(mode('${keyDir.path}/wallet.key'), '600');
    expect((await KeyStore.read())!.bytes, second.bytes);
  }, skip: posix);

  test('a stale temp file from a crashed write does not break the next write and the old key survives until the rename', () async {
    final old = VaultKey.generate();
    await KeyStore.write(old);
    File('${keyDir.path}/wallet.key.tmp').writeAsStringSync('half');
    expect((await KeyStore.read())!.bytes, old.bytes);
    final fresh = VaultKey.generate();
    await KeyStore.write(fresh);
    expect((await KeyStore.read())!.bytes, fresh.bytes);
    expect(File('${keyDir.path}/wallet.key.tmp').existsSync(), isFalse);
  }, skip: posix);

  test('reading an older install tightens its open folder and key file (no write needed)', () async {
    final key = VaultKey.generate();
    await keyDir.create();
    final file = File('${keyDir.path}/wallet.key')..writeAsStringSync(await key.toText());
    await Process.run('chmod', ['755', keyDir.path]);
    await Process.run('chmod', ['644', file.path]);
    expect(mode(keyDir.path), '755');
    expect((await KeyStore.read())!.bytes, key.bytes);
    expect(mode(keyDir.path), '700');
    expect(mode(file.path), '600');
  }, skip: posix);

  test('reading with no key file leaves the folder alone and gives null', () async {
    await keyDir.create();
    await Process.run('chmod', ['755', keyDir.path]);
    expect(await KeyStore.read(), isNull);
    expect(mode(keyDir.path), '755');
  }, skip: posix);

  test('the key file holds only the key text, forget deletes it, read then gives null', () async {
    final key = VaultKey.generate();
    await KeyStore.write(key);
    expect(File('${keyDir.path}/wallet.key').readAsStringSync().trim(), await key.toText());
    await KeyStore.forget();
    expect(File('${keyDir.path}/wallet.key').existsSync(), isFalse);
    expect(await KeyStore.read(), isNull);
  });

  group('device id (H6)', () {
    test('none stored reads null; written it is read back from device.id beside wallet.key, 0600 in a 0700 folder', () async {
      expect(await KeyStore.readDeviceId(), isNull);
      await KeyStore.writeDeviceId('abcDEF0123456789');
      expect(await KeyStore.readDeviceId(), 'abcDEF0123456789');
      expect(File('${keyDir.path}/device.id').readAsStringSync(), 'abcDEF0123456789');
      expect(mode('${keyDir.path}/device.id'), '600');
      expect(mode(keyDir.path), '700');
    }, skip: posix);

    test('writing again replaces it atomically (no temp file left) and a stale temp file does not break it', () async {
      await keyDir.create(recursive: true);
      File('${keyDir.path}/device.id.tmp').writeAsStringSync('stale');
      await KeyStore.writeDeviceId('first1');
      await KeyStore.writeDeviceId('second2');
      expect(await KeyStore.readDeviceId(), 'second2');
      final names = keyDir.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last).toList();
      expect(names, ['device.id']);
    }, skip: posix);

    test('the key and the id are separate files; forget removes both', () async {
      await KeyStore.write(VaultKey.generate());
      await KeyStore.writeDeviceId('idid1234');
      await KeyStore.forget();
      expect(await KeyStore.read(), isNull);
      expect(await KeyStore.readDeviceId(), isNull);
    });

    test('an empty file reads as none', () async {
      await keyDir.create(recursive: true);
      File('${keyDir.path}/device.id').writeAsStringSync('\n');
      expect(await KeyStore.readDeviceId(), isNull);
    });
  });
}
