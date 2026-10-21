// The browser's key store (lib/src/key_vault.dart): passphrase wrap and unwrap, locked/unlocked state, forget.
// The browser's localStorage and sessionStorage are replaced by maps. A low round count keeps the tests fast; the real one is a
// constant. All keys here are random and SYNTHETIC.
import 'package:budget_wallet/src/key_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

const _rounds = 1000;
const _pass = 'correct horse battery';

KeyVault vault(MapKeyValueStore local, MapKeyValueStore session) => KeyVault(local: local, session: session, iterations: _rounds);

void main() {
  late List<String> lines;
  setUp(() {
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });

  test('the real round count is 310000 and the shortest passphrase 8', () {
    expect(pbkdf2Iterations, 310000);
    expect(minPassphraseLength, 8);
  });

  group('wrapKey / unwrapKey', () {
    test('round trip gives the same key', () async {
      final key = VaultKey.generate();
      final blob = await wrapKey(key, _pass, iterations: _rounds);
      final back = await unwrapKey(blob, _pass);
      expect(back.bytes, key.bytes);
    });

    test('the blob names its round count and carries neither the key text nor the passphrase', () async {
      final key = VaultKey.generate();
      final blob = await wrapKey(key, _pass, iterations: _rounds);
      expect(blob, startsWith('bwk1.$_rounds.'));
      expect(blob, isNot(contains(_pass)));
      expect(blob, isNot(contains(await key.toText())));
    });

    test('every wrap gets a new salt', () async {
      final key = VaultKey.generate();
      final a = await wrapKey(key, _pass, iterations: _rounds), b = await wrapKey(key, _pass, iterations: _rounds);
      expect(a.split('.')[2], isNot(b.split('.')[2]));
      expect(a, isNot(b));
    });

    test('a wrong passphrase is WrongPassphrase; case and spaces count', () async {
      final blob = await wrapKey(VaultKey.generate(), _pass, iterations: _rounds);
      for (final bad in ['', 'wrong passphrase', _pass.toUpperCase(), '$_pass ', ' $_pass']) {
        await expectLater(unwrapKey(blob, bad), throwsA(isA<WrongPassphrase>()), reason: 'passphrase "$bad"');
      }
    });

    test('a blob that is not ours or is cut off is a FormatException or VaultException, not WrongPassphrase', () async {
      final blob = await wrapKey(VaultKey.generate(), _pass, iterations: _rounds);
      for (final bad in [
        '',
        'nonsense',
        'bwk1.1000.AAAA',
        'bwk2.1000.AAAA.AAAA',
        'bwk1.x.AAAA.AAAA',
        'bwk1.0.AAAA.AAAA',
        'bwk1.1000.!!.!!'
      ]) {
        await expectLater(unwrapKey(bad, _pass), throwsA(isA<FormatException>()), reason: bad);
      }
      final parts = blob.split('.');
      final cut = [...parts.take(3), parts[3].substring(0, 12)].join('.');
      await expectLater(unwrapKey(cut, _pass), throwsA(isA<VaultException>().having((e) => e.failure, 'failure', UnsealFailure.damaged)));
    });

    test('a blob tampered with is not accepted', () async {
      final blob = await wrapKey(VaultKey.generate(), _pass, iterations: _rounds);
      final parts = blob.split('.');
      final sealed = parts[3];
      // Flip a character in the middle of the sealed part.
      final i = sealed.length ~/ 2;
      final flipped = sealed.substring(0, i) + (sealed[i] == 'A' ? 'B' : 'A') + sealed.substring(i + 1);
      await expectLater(unwrapKey([...parts.take(3), flipped].join('.'), _pass), throwsA(anything));
    });
  });

  group('KeyVault', () {
    late MapKeyValueStore local, session;
    late KeyVault v;
    setUp(() {
      local = MapKeyValueStore();
      session = MapKeyValueStore();
      v = vault(local, session);
    });

    test('nothing stored: not locked, no key', () async {
      expect(v.isLocked, isFalse);
      expect(await v.read(), isNull);
    });

    test('write keeps the key for this tab and wraps it in the local store', () async {
      final key = VaultKey.generate();
      await v.write(key, passphrase: _pass);
      expect(v.isLocked, isFalse);
      expect((await v.read())!.bytes, key.bytes);
      expect(local.values[KeyVault.wrappedName], startsWith('bwk1.$_rounds.'));
      expect(local.values.values.join(), isNot(contains(await key.toText())), reason: 'the plain key is not in localStorage');
    });

    test('a new tab (empty session) is locked until unlock; read gives null meanwhile', () async {
      final key = VaultKey.generate();
      await v.write(key, passphrase: _pass);
      final tab2 = vault(local, MapKeyValueStore());
      expect(tab2.isLocked, isTrue);
      expect(await tab2.read(), isNull);
      final opened = await tab2.unlock(_pass);
      expect(opened.bytes, key.bytes);
      expect(tab2.isLocked, isFalse);
      expect((await tab2.read())!.bytes, key.bytes);
    });

    test('a wrong passphrase leaves the tab locked and logs the failure without the passphrase', () async {
      await v.write(VaultKey.generate(), passphrase: _pass);
      final tab2 = vault(local, MapKeyValueStore());
      await expectLater(tab2.unlock('not the passphrase'), throwsA(isA<WrongPassphrase>()));
      expect(tab2.isLocked, isTrue);
      expect(await tab2.read(), isNull);
      final log = lines.join('\n');
      expect(log, contains('key.unlockFailed'));
      expect(log, isNot(contains('not the passphrase')));
    });

    test('unlock with nothing stored is a StateError', () async {
      await expectLater(v.unlock(_pass), throwsStateError);
    });

    test('the web needs a passphrase of at least 8 characters', () async {
      final key = VaultKey.generate();
      await expectLater(v.write(key), throwsArgumentError);
      await expectLater(v.write(key, passphrase: ''), throwsArgumentError);
      await expectLater(v.write(key, passphrase: '1234567'), throwsArgumentError);
      expect(local.values, isEmpty);
      expect(session.values, isEmpty);
      await v.write(key, passphrase: '12345678'); // exactly 8
      expect(v.isLocked, isFalse);
    });

    test('forget removes the wrapped key and the tab copy', () async {
      await v.write(VaultKey.generate(), passphrase: _pass);
      v.forget();
      expect(local.values, isEmpty);
      expect(session.values, isEmpty);
      expect(v.isLocked, isFalse);
      expect(await v.read(), isNull);
    });

    test('logs say browser, found and locked, and never the key, the passphrase or the blob', () async {
      final key = VaultKey.generate();
      await v.write(key, passphrase: _pass);
      final tab2 = vault(local, MapKeyValueStore());
      await tab2.read();
      await tab2.unlock(_pass);
      await tab2.read();
      tab2.forget();
      final log = lines.join('\n');
      expect(log, contains('"store":"browser"'));
      expect(log, contains('key.read {"store":"browser","found":false,"locked":true}'));
      expect(log, contains('key.read {"store":"browser","found":true,"locked":false}'));
      expect(log, contains('key.unlocked'));
      expect(log, contains('key.forgotten'));
      expect(log, isNot(contains(_pass)));
      expect(log, isNot(contains(await key.toText())));
      expect(log, isNot(contains('bwk1')));
    });

    test('a tab that closed and a new one in the same browser: only the wrapped key survives', () async {
      final key = VaultKey.generate();
      await v.write(key, passphrase: _pass);
      session.values.clear(); // sessionStorage ends with the tab
      expect(v.isLocked, isTrue);
      expect((await v.unlock(_pass)).bytes, key.bytes);
    });
  });
}
