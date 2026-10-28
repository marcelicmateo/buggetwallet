// Vault edge cases: key text (BW1-...) parsing and file sealing/unsealing under bad input.
// Every refusal must be a VaultException, never a different key, a crash or garbage plaintext. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// A fixed, made-up key so the checksum behaviour is deterministic.
VaultKey _fixed() => VaultKey([for (var i = 0; i < 32; i++) (i * 7 + 3) & 0xFF]);

/// The associated data these tests seal for (any use works; `BWOP2` checks it on open).
final _aad = aadBackup;

Matcher get _refused => throwsA(isA<VaultException>());

/// A correctly authenticated file whose content is [inner] as is (no gzip), laid out like `seal`.
Future<Uint8List> _sealRaw(List<int> inner, VaultKey key) async {
  final box = await Xchacha20.poly1305Aead().encrypt(inner, secretKey: SecretKey(key.bytes));
  return Uint8List.fromList([...utf8.encode('BWOP1'), ...box.nonce, ...box.mac.bytes, ...box.cipherText]);
}

void main() {
  group('VaultKey construction', () {
    test('only exactly 32 bytes are a key', () {
      for (final len in [0, 1, 16, 31, 33, 64]) {
        expect(() => VaultKey(List.filled(len, 1)), _refused, reason: '$len bytes');
      }
      expect(VaultKey(List.filled(32, 0)).bytes.length, 32);
    });

    test('the key keeps its own copy of the bytes', () {
      final src = List<int>.filled(32, 9);
      final k = VaultKey(src);
      src[0] = 200;
      expect(k.bytes[0], 9);
    });

    test('generated keys differ and have the documented text shape', () async {
      final a = VaultKey.generate(), b = VaultKey.generate();
      expect(a.bytes, isNot(b.bytes));
      final text = await a.toText();
      expect(text, matches(RegExp(r'^BW1(-[A-Z2-7]{5}){11}$')));
    });

    test('all-zero and all-0xFF keys round-trip', () async {
      for (final fill in [0, 0xFF]) {
        final k = VaultKey(List.filled(32, fill));
        expect((await VaultKey.parse(await k.toText())).bytes, k.bytes);
      }
    });

    test('keyId is 16 hex characters, stable, differs per key and does not reveal the key text', () async {
      final k = _fixed();
      final id = await k.keyId();
      expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(await k.keyId(), id);
      expect(await VaultKey.generate().keyId(), isNot(id));
      final text = (await k.toText()).replaceAll('-', '');
      expect(text.contains(id.toUpperCase()), isFalse);
      // One bit of difference gives another id.
      final other = Uint8List.fromList(k.bytes)..[31] ^= 1;
      expect(await VaultKey(other).keyId(), isNot(id));
    });
  });

  group('key text refused', () {
    late String good;
    setUp(() async => good = await _fixed().toText());

    test('empty, blank and prefix-only input', () async {
      for (final s in ['', ' ', '\n', '\t\r\n', 'BW1', 'bw1-', 'BW1-', '-', '---']) {
        await expectLater(VaultKey.parse(s), _refused, reason: jsonEncode(s));
      }
    });

    test('wrong or missing prefix', () async {
      final body = good.substring(4);
      for (final p in ['BW2-', 'BW0-', 'BW-', 'B1-', 'XW1-', 'WB1-', 'KEY-', 'BWOP1-', ' 1BW-']) {
        await expectLater(VaultKey.parse('$p$body'), _refused, reason: p);
      }
      await expectLater(VaultKey.parse(body), _refused, reason: 'no prefix');
    });

    test('too short: every truncation of a good key is refused', () async {
      final plain = good.replaceAll('-', '');
      for (var cut = 0; cut < plain.length; cut++) {
        await expectLater(VaultKey.parse(plain.substring(0, cut)), _refused, reason: 'cut at $cut');
      }
    });

    test('characters outside the alphabet are refused, not skipped', () async {
      final body = good.substring(4);
      // No '0' here: it is read as the letter O (see 'key text accepted').
      const bad = ['1', '8', '9', '!', '=', '_', '.', '/', 'Š', '€', '🙂', '\u0000', 'Ｂ', '２', '٣'];
      for (final c in bad) {
        await expectLater(VaultKey.parse('BW1-$c$body'), _refused, reason: 'inserted ${c.codeUnits}');
        await expectLater(VaultKey.parse('BW1-${body.replaceRange(0, 1, c)}'), _refused, reason: 'replaced by ${c.codeUnits}');
      }
    });

    test('lookalike letters from other scripts are refused, never read as ASCII', () async {
      final body = good.substring(4);
      // Cyrillic В (U+0412), Greek Β (U+0392), fullwidth digit one and W.
      for (final p in ['ВW1-', 'BＷ 1-', 'BW１-', 'ΒW1-']) {
        await expectLater(VaultKey.parse('$p$body'), _refused, reason: p.codeUnits.toString());
      }
      for (final c in ['А', 'Е', 'С', 'Α', 'Ε']) {
        await expectLater(VaultKey.parse('BW1-${body.replaceRange(2, 3, c)}'), _refused, reason: c.codeUnits.toString());
      }
    });

    test('every single-character substitution gives a refusal or the same key, never another key', () async {
      final want = _fixed().bytes;
      final plain = good.replaceAll('-', '').substring(3);
      var refused = 0;
      for (var i = 0; i < plain.length; i++) {
        for (final c in _alphabet.split('')) {
          if (c == plain[i]) continue;
          final s = 'BW1${plain.replaceRange(i, i + 1, c)}';
          try {
            expect((await VaultKey.parse(s)).bytes, want, reason: 'position $i -> $c parsed to another key');
          } on VaultException {
            refused++;
          }
        }
      }
      expect(refused, greaterThan(plain.length * 25)); // nearly all of them
    });

    test('every swap of two neighbouring characters gives a refusal or the same key', () async {
      final want = _fixed().bytes;
      final plain = good.replaceAll('-', '').substring(3);
      for (var i = 0; i < plain.length - 1; i++) {
        if (plain[i] == plain[i + 1]) continue;
        final swapped = plain.replaceRange(i, i + 2, plain[i + 1] + plain[i]);
        try {
          expect((await VaultKey.parse('BW1$swapped')).bytes, want, reason: 'swap at $i');
        } on VaultException {
          // fine
        }
      }
    });

    test('a deleted or doubled character anywhere gives a refusal or the same key', () async {
      final plain = good.replaceAll('-', '').substring(3);
      for (var i = 0; i < plain.length; i++) {
        for (final s in ['BW1${plain.replaceRange(i, i + 1, '')}', 'BW1${plain.replaceRange(i, i + 1, plain[i] + plain[i])}']) {
          try {
            expect((await VaultKey.parse(s)).bytes, _fixed().bytes, reason: 'position $i');
          } on VaultException {
            // fine
          }
        }
      }
    });

    test('a key pasted twice or with text around it never parses to a different key', () async {
      for (final s in ['$good $good', '$good\n$good', 'key: $good', '$good.', '$good\nthanks']) {
        try {
          expect((await VaultKey.parse(s)).bytes, _fixed().bytes, reason: s);
        } on VaultException {
          // fine
        }
      }
    });

    test('a very long input is refused quickly', () async {
      final sw = Stopwatch()..start();
      await expectLater(VaultKey.parse('BW1${'A' * 200000}'), _refused);
      await expectLater(VaultKey.parse(' ' * 200000), _refused);
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('the refusal message never contains the key text', () async {
      final typo = good.replaceRange(8, 9, good[8] == 'A' ? 'B' : 'A');
      try {
        await VaultKey.parse(typo);
        fail('accepted a typo');
      } on VaultException catch (e) {
        expect(e.message.contains(good.substring(4, 14)), isFalse);
      }
    });
  });

  group('key text accepted', () {
    test('case, spaces, tabs, CRLF and missing/extra dashes do not matter', () async {
      final k = _fixed();
      final t = await k.toText();
      final plain = t.replaceAll('-', '');
      final variants = [
        t.toLowerCase(),
        t.replaceAll('-', ' '),
        t.replaceAll('-', '\r\n'),
        t.replaceAll('-', '\t'),
        plain,
        '  \n$t\n\n',
        t.replaceAll('-', '--'),
        plain.split('').join(' '),
        t.replaceAll('-', '-\n'),
      ];
      for (final v in variants) {
        expect((await VaultKey.parse(v)).bytes, k.bytes, reason: jsonEncode(v));
      }
    });

    test('the padding bits of the last character are not part of the key', () async {
      // 34 bytes = 272 bits = 54.4 characters: the last character has 3 unused bits.
      final t = (await _fixed().toText()).replaceAll('-', '');
      final last = _alphabet.indexOf(t[t.length - 1]);
      final other = _alphabet[last ^ 1];
      expect((await VaultKey.parse(t.substring(0, t.length - 1) + other)).bytes, _fixed().bytes);
    });

    group('digit 0 is read as the letter O', () {
      /// Deterministic synthetic keys whose text holds at least one O.
      Future<List<(VaultKey, String)>> withO() async {
        final r = Random(42);
        final out = <(VaultKey, String)>[];
        for (var i = 0; i < 40; i++) {
          final k = VaultKey(List<int>.generate(32, (_) => r.nextInt(256)));
          final t = await k.toText();
          if (t.contains('O')) out.add((k, t));
        }
        expect(out, isNotEmpty);
        return out;
      }

      test('every O written as 0 parses to the same key', () async {
        for (final (k, t) in await withO()) {
          final typed = t.replaceAll('O', '0');
          expect((await VaultKey.parse(typed)).bytes, k.bytes, reason: typed);
        }
      });

      test('a mix of 0 and O, and lowercase o, parse to the same key', () async {
        for (final (k, t) in await withO()) {
          final first = t.indexOf('O');
          final mixed = t.replaceRange(first, first + 1, '0');
          expect((await VaultKey.parse(mixed)).bytes, k.bytes, reason: mixed);
          expect((await VaultKey.parse(t.toLowerCase())).bytes, k.bytes);
          expect((await VaultKey.parse(t.toLowerCase().replaceAll('o', '0'))).bytes, k.bytes);
        }
      });

      test('the BW1 prefix is not affected: BW0 is still not a key', () async {
        final body = (await _fixed().toText()).substring(4);
        for (final p in ['BW0-', 'bw0-', 'BWO-']) {
          await expectLater(VaultKey.parse('$p$body'), _refused, reason: p);
        }
      });

      test('1, 8 and 9 are still refused as not allowed', () async {
        final body = (await _fixed().toText()).substring(4);
        for (final c in ['1', '8', '9']) {
          await expectLater(
            VaultKey.parse('BW1-${body.replaceRange(0, 1, c)}'),
            throwsA(isA<VaultException>().having((e) => e.message, 'message', contains('not allowed'))),
            reason: c,
          );
        }
      });

      test('a 0 typed for a letter other than O is a typo the checksum catches, never another key', () async {
        final k = _fixed();
        final plain = (await k.toText()).replaceAll('-', '').substring(3);
        var refused = 0, tried = 0;
        for (var i = 0; i < plain.length; i++) {
          if (plain[i] == 'O') continue;
          tried++;
          final s = 'BW1${plain.replaceRange(i, i + 1, '0')}';
          try {
            expect((await VaultKey.parse(s)).bytes, k.bytes, reason: 'position $i parsed to another key');
          } on VaultException catch (e) {
            expect(e.message, contains('typo'), reason: 'position $i');
            refused++;
          }
        }
        // Only the last character's padding bits can change without changing the key.
        expect(refused, greaterThanOrEqualTo(tried - 1));
      });
    });

    test('the text is deterministic for a key', () async {
      expect(await _fixed().toText(), await _fixed().toText());
    });
  });

  group('seal / unseal', () {
    late VaultKey key;
    setUp(() => key = _fixed());

    test('empty, one byte, binary and multi-MB payloads round-trip', () async {
      final r = Random(3);
      final cases = <List<int>>[
        const [],
        const [0],
        List<int>.generate(1000, (_) => r.nextInt(256)),
        List<int>.filled(4 * 1024 * 1024, 65), // compresses to almost nothing
        List<int>.generate(1024 * 1024, (_) => r.nextInt(256)), // does not compress
      ];
      for (final p in cases) {
        final back = await unseal(await seal(p, key, aad: _aad), key, aad: _aad);
        expect(back.length, p.length);
        expect(back, p);
      }
    });

    test('layout: BWOP3, 8-byte key id, 24-byte nonce, 16-byte tag; two seals of one payload differ', () async {
      final a = await seal(utf8.encode('hello'), key, aad: _aad), b = await seal(utf8.encode('hello'), key, aad: _aad);
      expect(a.sublist(0, 5), utf8.encode('BWOP3'));
      expect(a.sublist(5, 13), await key.keyIdBytes());
      expect(a.length, greaterThanOrEqualTo(5 + 8 + 24 + 16 + 1));
      expect(a.sublist(13, 37), isNot(b.sublist(13, 37)), reason: 'nonce reused');
      expect(a, isNot(b));
      expect(await unseal(a, key, aad: _aad), await unseal(b, key, aad: _aad));
    });

    test('the sealed bytes do not contain the plaintext', () async {
      final sealed = await seal(utf8.encode('Synthetic Groceries LIDL ' * 20), key, aad: _aad);
      expect(latin1.decode(sealed, allowInvalid: true).contains('LIDL'), isFalse);
    });

    test('a plain List<int> (not a Uint8List) is accepted', () async {
      final sealed = (await seal(utf8.encode('abc'), key, aad: _aad)).toList();
      expect(utf8.decode(await unseal(sealed, key, aad: _aad)), 'abc');
    });

    test('wrong key, including a key that differs by one bit', () async {
      final sealed = await seal(utf8.encode('secret'), key, aad: _aad);
      await expectLater(unseal(sealed, VaultKey.generate(), aad: _aad), _refused);
      final near = Uint8List.fromList(key.bytes)..[0] ^= 1;
      await expectLater(unseal(sealed, VaultKey(near), aad: _aad), _refused);
    });

    test('nothing shorter than 45 bytes is accepted, and 45 bytes with an empty body is refused', () async {
      final good = await seal(utf8.encode('x'), key, aad: _aad);
      for (var len = 0; len <= 45; len++) {
        await expectLater(unseal(good.sublist(0, len), key, aad: _aad), _refused, reason: 'length $len');
      }
      await expectLater(unseal(List<int>.filled(45, 0), key, aad: _aad), _refused);
      await expectLater(unseal([...utf8.encode('BWOP1'), ...List.filled(40, 0)], key, aad: _aad), _refused);
    });

    test('every truncation of a real file is refused', () async {
      final good = await seal(utf8.encode(jsonEncode({'a': List.generate(40, (i) => 'Synthetic $i')})), key, aad: _aad);
      for (var len = 0; len < good.length; len++) {
        await expectLater(unseal(good.sublist(0, len), key, aad: _aad), _refused, reason: 'length $len of ${good.length}');
      }
    });

    test('bytes appended to a real file are refused', () async {
      final good = await seal(utf8.encode('payload'), key, aad: _aad);
      for (final extra in [
        [0],
        [0, 0, 0, 0],
        utf8.encode('\n')
      ]) {
        await expectLater(unseal([...good, ...extra], key, aad: _aad), _refused, reason: '${extra.length} extra bytes');
      }
    });

    test('flipping a bit in any byte of a small file is refused (nonce, tag, ciphertext)', () async {
      final good = await seal(utf8.encode('{"k":"v"}'), key, aad: _aad);
      for (var i = 0; i < good.length; i++) {
        for (final bit in [0, 7]) {
          final bad = Uint8List.fromList(good)..[i] ^= 1 << bit;
          await expectLater(unseal(bad, key, aad: _aad), _refused, reason: 'byte $i bit $bit');
        }
      }
    });

    test('swapping the nonce or the tag with those of another file is refused', () async {
      final a = await seal(utf8.encode('first'), key, aad: _aad), b = await seal(utf8.encode('second'), key, aad: _aad);
      await expectLater(unseal([...a.sublist(0, 5), ...b.sublist(5, 29), ...a.sublist(29)], key, aad: _aad), _refused);
      await expectLater(unseal([...a.sublist(0, 29), ...b.sublist(29, 45), ...a.sublist(45)], key, aad: _aad), _refused);
    });

    test('version byte and magic: BWOP0, BWOP4, lowercase, truncated and zero magic are refused as not a sync file', () async {
      final good = await seal(utf8.encode('x'), key, aad: _aad);
      for (final magic in [
        [...'BWOP0'.codeUnits],
        [...'BWOP4'.codeUnits],
        [...'BWOP9'.codeUnits],
        [...'bwop1'.codeUnits],
        [...'WBOP1'.codeUnits],
        [...'BW1-K'.codeUnits],
        [...'BWOP'.codeUnits, 0],
        [0, 0, 0, 0, 0],
      ]) {
        final bytes = [...magic, ...good.sublist(5)];
        await expectLater(unseal(bytes, key, aad: _aad),
            throwsA(isA<VaultException>().having((e) => e.message, 'message', contains('Not a Budget Wallet'))),
            reason: String.fromCharCodes(magic));
      }
      // A future file with a longer header is never read as BWOP3.
      await expectLater(unseal([...utf8.encode('BWOP4'), ...good.sublist(5), ...List.filled(8, 1)], key, aad: _aad), _refused);
    });

    test('a file of plain JSON or plain gzip (not sealed) is refused', () async {
      await expectLater(unseal(utf8.encode('[{"e":"tx","id":"a","f":{},"h":"1:1:a"}]' * 3), key, aad: _aad), _refused);
      await expectLater(unseal(gzip.encode(utf8.encode('x' * 100)), key, aad: _aad), _refused);
    });

    test('authenticated content that is not gzip is refused with a VaultException (writer bug or future format)', () async {
      final cases = <List<int>>[
        utf8.encode('not gzip at all'),
        const [0x1f, 0x8b], // gzip magic only
        gzip.encode(utf8.encode('some data to cut')).sublist(0, 8), // truncated gzip
      ];
      for (final inner in cases) {
        final file = await _sealRaw(inner, key);
        await expectLater(unseal(file, key, aad: _aad), _refused, reason: 'inner ${inner.length} bytes');
      }
    });

    test('refusal messages do not contain key bytes or the payload', () async {
      final sealed = await seal(utf8.encode('Synthetic Payload Text'), key, aad: _aad);
      final bad = Uint8List.fromList(sealed)..[sealed.length - 1] ^= 1;
      try {
        await unseal(bad, key, aad: _aad);
        fail('accepted');
      } on VaultException catch (e) {
        expect(e.toString(), isNot(contains('Synthetic')));
        expect(e.toString(), isNot(contains(await key.keyId())));
      }
    });
  });
}
