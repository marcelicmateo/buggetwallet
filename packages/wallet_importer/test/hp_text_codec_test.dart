// HP-T3: Windows-1250 decoding and SHA-256 against tables and vectors made outside the code (Python's cp1250 codec,
// hashlib). The shape ids and layout ids of the CSV import hash with this SHA-256, so a wrong digest would orphan every
// saved layout.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_importer/src/text_codec.dart';

const _high = <int>[
  0x20AC, 0xFFFD, 0x201A, 0xFFFD, 0x201E, 0x2026, 0x2020, 0x2021, 0xFFFD, 0x2030, 0x0160, 0x2039, 0x015A, 0x0164, 0x017D, 0x0179, //
  0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0xFFFD, 0x2122, 0x0161, 0x203A, 0x015B, 0x0165, 0x017E, 0x017A, //
  0x00A0, 0x02C7, 0x02D8, 0x0141, 0x00A4, 0x0104, 0x00A6, 0x00A7, 0x00A8, 0x00A9, 0x015E, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x017B, //
  0x00B0, 0x00B1, 0x02DB, 0x0142, 0x00B4, 0x00B5, 0x00B6, 0x00B7, 0x00B8, 0x0105, 0x015F, 0x00BB, 0x013D, 0x02DD, 0x013E, 0x017C, //
  0x0154, 0x00C1, 0x00C2, 0x0102, 0x00C4, 0x0139, 0x0106, 0x00C7, 0x010C, 0x00C9, 0x0118, 0x00CB, 0x011A, 0x00CD, 0x00CE, 0x010E, //
  0x0110, 0x0143, 0x0147, 0x00D3, 0x00D4, 0x0150, 0x00D6, 0x00D7, 0x0158, 0x016E, 0x00DA, 0x0170, 0x00DC, 0x00DD, 0x0162, 0x00DF, //
  0x0155, 0x00E1, 0x00E2, 0x0103, 0x00E4, 0x013A, 0x0107, 0x00E7, 0x010D, 0x00E9, 0x0119, 0x00EB, 0x011B, 0x00ED, 0x00EE, 0x010F, //
  0x0111, 0x0144, 0x0148, 0x00F3, 0x00F4, 0x0151, 0x00F6, 0x00F7, 0x0159, 0x016F, 0x00FA, 0x0171, 0x00FC, 0x00FD, 0x0163, 0x02D9, //
];

const _sha = <int, String>{
  0: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  1: '084fed08b978af4d7d196a7446a86b58009e636b611db16211b65a9aadff29c5',
  55: 'e7313d333c272e639f790978283f9eb392e843d0f29b7016828bb1daa4aac70b',
  56: '4324d65f3c103567f5589c710bc08f8523f929a9272e3af36fc968e52abc6c27',
  57: '35df609437dcfea3279283ab79fd554e2bf78f8f7ae2de532d8ee300b09e8f73',
  63: '81c80242132f230c3bd41b3e63bbcff16107339549214a99614ff26664625055',
  64: '39e3d7b6b5d075d37d053ad89b24b41bef4f3c29760c84447cab3f3be1882241',
  65: 'aacca6ff74fdbb296d165a45cecfa04e5127bc008770fbbdd48006f2d2fae95e',
  119: '9ce7368e4daf32341631b492e80359dc9f594b48453cd0dd5bf0b19279cc177e',
  120: '7836b787757e95e58b3ca5aec90b1b004e8deba1e50e9675af9cabf1a13a04b5',
  127: 'a8d23e75d936f303d248888d9b165ee543f4cbafcad3c9dd2a79bd84faa11d07',
  128: 'd2742f1f4ac6bb7ca2b239ee18402ba8b3f9f8e652d2a72973c2b9ba11c08cf6',
  1000: '1e9bc38cbf860b9ec31918b065f9b52476c549a782e0e7990bed8ce3868d2371',
};

void main() {
  group('decodeWindows1250', () {
    test('every high byte maps to the code page table', () {
      for (var b = 0x80; b <= 0xFF; b++) {
        expect(decodeWindows1250([b]).runes.toList(), [_high[b - 0x80]], reason: 'byte 0x${b.toRadixString(16)}');
      }
    });

    test('every ASCII byte is itself', () {
      for (var b = 0; b < 0x80; b++) {
        expect(decodeWindows1250([b]).codeUnits, [b], reason: 'byte $b');
      }
    });

    test('Croatian letters and empty input', () {
      expect(decodeWindows1250([0x8A, 0x9A, 0xC8, 0xE8, 0xC6, 0xE6, 0x8E, 0x9E, 0xD0, 0xF0]), 'ŠšČčĆćŽžĐđ');
      expect(decodeWindows1250(const []), '');
      expect(decodeWindows1250(Uint8List.fromList([0x41, 0x80, 0x42])), 'A€B');
    });
  });

  group('decodeCsvBytes', () {
    test('valid UTF-8 stays UTF-8', () {
      final (t, e) = decodeCsvBytes(Uint8List.fromList([0xC4, 0x8C, 0x61, 0x6A]));
      expect((t, e), ('Čaj', 'utf-8'));
    });

    test('invalid UTF-8 falls back to Windows-1250', () {
      final (t, e) = decodeCsvBytes(Uint8List.fromList([0xC8, 0x61, 0x6A]));
      expect((t, e), ('Čaj', 'windows-1250'));
    });

    test('empty is UTF-8', () {
      expect(decodeCsvBytes(Uint8List(0)), ('', 'utf-8'));
    });
  });

  group('sha256Hex', () {
    test('known vectors across padding boundaries', () {
      _sha.forEach((n, hex) {
        expect(sha256Hex([for (var i = 0; i < n; i++) (i * 7 + 3) % 256]), hex, reason: 'length $n');
      });
    });

    test('abc', () {
      expect(sha256Hex('abc'.codeUnits), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    test('does not modify its input', () {
      final data = [1, 2, 3];
      sha256Hex(data);
      expect(data, [1, 2, 3]);
    });
  });
}
