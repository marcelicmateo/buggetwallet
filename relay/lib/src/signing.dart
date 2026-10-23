// Request signatures of protocol v3 (docs/context/RELAY_PROTOCOL.md, "Signed requests"): the relay only verifies.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// Allowed distance between `X-BW-Time` and the relay clock.
const Duration signatureWindow = Duration(minutes: 5);

/// The string a v3 request signs (UTF-8): method, the host the client addressed (lower case, `:port` only when not the
/// scheme's default), path from `/v2/` on, the `X-BW-Covers` value (or empty), the body's SHA-256 as lowercase hex, and
/// the `X-BW-Time` value, joined by LF. The relay accepts only v3.
String signedText(String method, String host, String path, String covers, String bodyHash, String time) =>
    'bw-relay-v3\n$method\n$host\n$path\n$covers\n$bodyHash\n$time';

/// Lowercase hex SHA-256 of [bytes].
String sha256OfBytes(List<int> bytes) {
  final h = const DartSha256().hashSync(bytes);
  return [for (final b in h.bytes) b.toRadixString(16).padLeft(2, '0')].join();
}

final _b64u = RegExp(r'^[A-Za-z0-9_-]+$');

/// [s] decoded as base64url without padding when it is exactly [bytes] long, else null.
Uint8List? decodeBase64Url(String s, int bytes) {
  final chars = (bytes * 4 + 2) ~/ 3;
  if (s.length != chars || !_b64u.hasMatch(s)) return null;
  try {
    final out = base64Url.decode(s.padRight((chars + 3) ~/ 4 * 4, '='));
    return out.length == bytes ? out : null;
  } on FormatException {
    return null;
  }
}

final _ed25519 = DartEd25519();

/// Whether [signature] (64 bytes) signs [text] for the Ed25519 public key [pub] (32 bytes). Never throws.
Future<bool> verifySignature(Uint8List pub, Uint8List signature, String text) async {
  try {
    return await _ed25519.verify(
      utf8.encode(text),
      signature: Signature(signature, publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519)),
    );
  } on Object {
    return false;
  }
}
