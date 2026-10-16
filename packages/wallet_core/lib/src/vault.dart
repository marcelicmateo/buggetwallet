import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class VaultException implements Exception {
  final String message;
  const VaultException(this.message);
  @override
  String toString() => message;
}

const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

String _base32(List<int> bytes) {
  final sb = StringBuffer();
  var buffer = 0, bits = 0;
  for (final b in bytes) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      sb.write(_alphabet[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) sb.write(_alphabet[(buffer << (5 - bits)) & 31]);
  return sb.toString();
}

List<int> _unbase32(String s) {
  final out = <int>[];
  var buffer = 0, bits = 0;
  for (final ch in s.split('')) {
    final v = _alphabet.indexOf(ch);
    if (v < 0) throw const VaultException('The key contains characters that are not allowed.');
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      out.add((buffer >> (bits - 8)) & 0xFF);
      bits -= 8;
    }
    buffer &= (1 << bits) - 1;
  }
  return out;
}

/// The wallet's secret key. Everything written to the sync folder is encrypted with it.
/// It never leaves the user's devices except as text/QR the user moves themselves.
class VaultKey {
  final Uint8List bytes;
  VaultKey(List<int> b) : bytes = Uint8List.fromList(b) {
    if (bytes.length != 32) throw const VaultException('A wallet key is 32 bytes.');
  }

  static VaultKey generate() {
    final r = Random.secure();
    return VaultKey(List<int>.generate(32, (_) => r.nextInt(256)));
  }

  static Future<List<int>> _check(List<int> b) async => (await Sha256().hash(b)).bytes.sublist(0, 2);

  /// Human-transferable form: `BW1-XXXXX-XXXXX-...` with a 2-byte checksum.
  Future<String> toText() async {
    final body = _base32([...bytes, ...await _check(bytes)]);
    final groups = <String>[];
    for (var i = 0; i < body.length; i += 5) {
      groups.add(body.substring(i, i + 5 > body.length ? body.length : i + 5));
    }
    return 'BW1-${groups.join('-')}';
  }

  static Future<VaultKey> parse(String text) async {
    var s = text.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (!s.startsWith('BW1')) throw const VaultException('This is not a Budget Wallet key (it should start with BW1).');
    s = s.substring(3);
    final raw = _unbase32(s);
    if (raw.length < 34) throw const VaultException('The key is too short. Check that you copied all of it.');
    final key = raw.sublist(0, 32), sum = raw.sublist(32, 34);
    final want = await _check(key);
    if (want[0] != sum[0] || want[1] != sum[1]) throw const VaultException('The key has a typo. Check it and try again.');
    return VaultKey(key);
  }

  /// Short public fingerprint, safe to store next to the data.
  Future<String> keyId() async =>
      (await Sha256().hash([...utf8.encode('budget-wallet-key-id'), ...bytes])).bytes.sublist(0, 8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

final _magic = utf8.encode('BWOP1');
final _aead = Xchacha20.poly1305Aead();

/// gzip + XChaCha20-Poly1305. Layout: "BWOP1" | nonce(24) | mac(16) | ciphertext.
Future<Uint8List> seal(List<int> plain, VaultKey key) async {
  final box = await _aead.encrypt(gzip.encode(plain), secretKey: SecretKey(key.bytes));
  return Uint8List.fromList([..._magic, ...box.nonce, ...box.mac.bytes, ...box.cipherText]);
}

Future<Uint8List> unseal(List<int> data, VaultKey key) async {
  if (data.length < 5 + 24 + 16) throw const VaultException('Sync file is damaged.');
  for (var i = 0; i < 5; i++) {
    if (data[i] != _magic[i]) throw const VaultException('Not a Budget Wallet sync file.');
  }
  final nonce = data.sublist(5, 29), mac = data.sublist(29, 45), cipher = data.sublist(45);
  try {
    final clear = await _aead.decrypt(SecretBox(cipher, nonce: nonce, mac: Mac(mac)), secretKey: SecretKey(key.bytes));
    return Uint8List.fromList(gzip.decode(clear));
  } on SecretBoxAuthenticationError {
    throw const VaultException('Sync file was made with a different key, or was changed.');
  }
}
