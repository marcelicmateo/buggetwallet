import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ArchiveException, GZipDecoder, GZipEncoder;
import 'package:cryptography/cryptography.dart';

import 'logs.dart';

final _log = Logger('bw.vault');

// gzip from `package:archive` so this file compiles for the web too: on the VM it delegates to `dart:io`'s codec
// (the same bytes as before), in the browser it is pure Dart. Both write one standard gzip member, which is all
// [_wholeGzip] and older builds rely on.
const _gzip = GZipEncoder();
const _gunzip = GZipDecoder();

/// Why [unseal] refused a file, for sync bookkeeping (the message is for people).
enum UnsealFailure {
  /// Authentication failed: sealed with another key, or changed after sealing.
  badKey,

  /// Too short, not a sync file, or authenticated content that is not whole gzip.
  damaged,

  /// A sync file of a newer format (`BWOP3` and up) that this build cannot read yet.
  newerFormat,

  /// Authenticated, but it would inflate past [maxUnsealBytes] (a decompression bomb or a writer bug).
  tooLarge,
}

class VaultException implements Exception {
  final String message;

  /// Set by [unseal]; null for key errors.
  final UnsealFailure? failure;
  const VaultException(this.message, {this.failure});
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
    // Base32 has no digit 0, so a typed 0 can only mean the letter O. 1 stays refused (I or L).
    s = s.substring(3).replaceAll('0', 'O');
    final raw = _unbase32(s);
    if (raw.length < 34) throw const VaultException('The key is too short. Check that you copied all of it.');
    final key = raw.sublist(0, 32), sum = raw.sublist(32, 34);
    final want = await _check(key);
    if (want[0] != sum[0] || want[1] != sum[1]) throw const VaultException('The key has a typo. Check it and try again.');
    return VaultKey(key);
  }

  /// Short public fingerprint, safe to store next to the data.
  Future<String> keyId() async => (await Sha256().hash([...utf8.encode('budget-wallet-key-id'), ...bytes]))
      .bytes
      .sublist(0, 8)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

final _magic1 = utf8.encode('BWOP1');
final _magic2 = utf8.encode('BWOP2');
final _aead = Xchacha20.poly1305Aead();

/// The most [unseal] inflates (256 MiB); more is [UnsealFailure.tooLarge].
const maxUnsealBytes = 256 * 1024 * 1024;

// Associated data per use (H8): a sealed file opens only where it was sealed for, so whoever holds the files (the
// relay, a copied folder) cannot pass one device's file off as another's, a snapshot as a sync file, or a blob as a
// backup.

/// AAD of sync file [seq] of device [device].
List<int> aadSyncFile(String device, int seq) => utf8.encode('bw-sync-file\n$device\n$seq');

/// AAD of snapshot [id].
List<int> aadSnapshot(String id) => utf8.encode('bw-snapshot\n$id');

/// AAD of a backup file (`.bwb`).
final List<int> aadBackup = List.unmodifiable(utf8.encode('bw-backup'));

/// AAD of a bill file (blob).
final List<int> aadBlob = List.unmodifiable(utf8.encode('bw-blob'));

/// AAD of the web app's wrapped wallet key.
final List<int> aadWebKey = List.unmodifiable(utf8.encode('bw-web-key'));

/// gzip + XChaCha20-Poly1305 with [aad] as associated data. Layout: "BWOP2" | nonce(24) | mac(16) | ciphertext.
/// [nonce] (24 bytes) is a test seam for known-answer vectors only; otherwise a fresh random one is drawn.
/// Logs `vault.seal` on `bw.perf` with the plain and sealed sizes.
Future<Uint8List> seal(List<int> plain, VaultKey key, {required List<int> aad, List<int>? nonce}) async {
  final t = PerfTimer('vault.seal', warnMs: 500);
  if (nonce != null && nonce.length != 24) throw ArgumentError.value(nonce.length, 'nonce', 'must be 24 bytes');
  final zipped = _gzip.encodeBytes(plain);
  final box = await _aead.encrypt(zipped, secretKey: SecretKey(key.bytes), nonce: nonce, aad: aad);
  final out = Uint8List.fromList([..._magic2, ...box.nonce, ...box.mac.bytes, ...box.cipherText]);
  t.done({'plainBytes': plain.length, 'bytes': out.length});
  return out;
}

/// Whether [z] is one whole gzip member that decoded to [length] bytes: gzip magic, at least header + trailer, and
/// the trailer's size field (length mod 2^32) agrees. The decoder can return what it got from a cut-off stream
/// without an error.
bool _wholeGzip(List<int> z, int length) {
  final n = z.length;
  if (n < 18 || z[0] != 0x1f || z[1] != 0x8b) return false;
  final size = z[n - 4] | z[n - 3] << 8 | z[n - 2] << 16 | z[n - 1] << 24;
  return size == length & 0xFFFFFFFF;
}

/// Opens what [seal] made. `BWOP2` is checked against [aad] (sealed for another use, device, seq or snapshot id =
/// `badKey`, like a changed file); `BWOP1` from older builds carries no associated data and is still read with any
/// [aad]. Inflates at most [maxBytes] ([maxUnsealBytes]; lower only in tests) ([UnsealFailure.tooLarge]).
/// Logs `vault.unseal` on `bw.perf` with the sealed and plain sizes.
Future<Uint8List> unseal(List<int> data, VaultKey key, {required List<int> aad, int maxBytes = maxUnsealBytes}) async {
  final t = PerfTimer('vault.unseal', warnMs: 500);
  if (data.length < 5 + 24 + 16) {
    logEvent(_log, Level.WARNING, 'vault.unseal.short', {'bytes': data.length});
    throw const VaultException('Sync file is damaged.', failure: UnsealFailure.damaged);
  }
  var bwop = true;
  for (var i = 0; i < 4; i++) {
    if (data[i] != _magic1[i]) bwop = false;
  }
  final digit = data[4];
  if (!bwop || digit < _magic1[4] || digit > 0x39) {
    logEvent(_log, Level.WARNING, 'vault.unseal.magic', {'bytes': data.length, 'newer': false});
    throw const VaultException('Not a Budget Wallet sync file.', failure: UnsealFailure.damaged);
  }
  if (digit > _magic2[4]) {
    // "BWOP" and a version digit above 2: a format from a newer build, readable after an upgrade.
    logEvent(_log, Level.WARNING, 'vault.unseal.magic', {'bytes': data.length, 'newer': true});
    throw const VaultException('Not a Budget Wallet sync file.', failure: UnsealFailure.newerFormat);
  }
  final format = digit - 0x30;
  final nonce = data.sublist(5, 29), mac = data.sublist(29, 45), cipher = data.sublist(45);
  try {
    final clear = await _aead.decrypt(SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(key.bytes), aad: format >= 2 ? aad : const <int>[]);
    final out = _gunzip.decodeBytes(clear, maxOutputSize: maxBytes);
    if (!_wholeGzip(clear, out.length)) throw const FormatException('gzip data is cut off');
    t.done({'bytes': data.length, 'plainBytes': out.length, 'format': format});
    return out;
  } on SecretBoxAuthenticationError catch (e, st) {
    logError(_log, 'vault.unseal.auth', e, st, fields: {'bytes': data.length, 'format': format});
    throw const VaultException('Sync file was made with a different key, or was changed.', failure: UnsealFailure.badKey);
  } on Object catch (e, st) {
    if (e is ArchiveException && '$e'.contains('larger than')) {
      logError(_log, 'vault.unseal.tooLarge', e, st, fields: {'bytes': data.length, 'maxBytes': maxBytes});
      throw const VaultException('Sync file is too large to open.', failure: UnsealFailure.tooLarge);
    }
    // Authenticated, so made with this key, but not gzip: a writer bug or a format this build does not know.
    logError(_log, 'vault.unseal.format', e, st, fields: {'bytes': data.length});
    throw const VaultException('Sync file is damaged.', failure: UnsealFailure.damaged);
  }
}

/// HKDF-SHA256 of the wallet key with an empty salt and [info] (UTF-8), [length] bytes. Gives the relay's wallet id
/// and request-signing seed (`bw-relay-id-v1`, `bw-relay-sign-v1`, docs/context/RELAY_PROTOCOL.md) and the local
/// database key, so one wallet key is all a device needs. Different [info] strings give unrelated keys.
Future<Uint8List> deriveKey(VaultKey key, String info, {int length = 32}) async {
  final out = await Hkdf(hmac: Hmac.sha256(), outputLength: length)
      .deriveKey(secretKey: SecretKey(key.bytes), nonce: const <int>[], info: utf8.encode(info));
  return Uint8List.fromList(await out.extractBytes());
}
