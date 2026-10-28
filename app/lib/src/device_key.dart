// This install's relay device key (stage DK): how it is stored as text and made on first need. Pure Dart (web too).
// The key is a 32-byte Ed25519 seed. It is a relay credential only (it can be revoked), never a data key; it is never synced,
// in no backup and never logged.
import 'dart:convert';

import 'package:wallet_sync/wallet_sync.dart';

import 'key_store.dart';

/// The text a device key is stored as (URL-safe base64 of the seed).
String encodeDeviceKey(List<int> seed) => base64Url.encode(seed);

/// The seed in [text], or null when it is missing or damaged (not base64, or not 32 bytes).
List<int>? decodeDeviceKey(String? text) {
  if (text == null || text.trim().isEmpty) return null;
  try {
    final b = base64Url.decode(base64Url.normalize(text.trim()));
    return b.length == 32 ? b : null;
  } on FormatException {
    return null;
  }
}

/// This install's device key: the stored one, else a new one stored now. A key that cannot be stored is not used (the next
/// run would make another one and enrol it again), so the error goes to the caller.
///
/// One call per [store] is in flight at a time and its result is kept: the first sync run and the Devices block asking together
/// (slow secure storage) get the same key, never two different ones (the owner's only device would end up waiting for approval).
/// A failed attempt is forgotten, so the next call tries again; [forgetDeviceKeyMemo] drops a kept key (after the key was deleted).
Future<List<int>> deviceKeyOf(KeyStore store) {
  final kept = _kept[store];
  if (kept != null) return kept;
  final attempt = _readOrMake(store);
  _kept[store] = attempt;
  attempt.then<void>((_) {}, onError: (Object _) {
    if (identical(_kept[store], attempt)) _kept[store] = null;
  });
  return attempt;
}

final _kept = Expando<Future<List<int>>>('deviceKey');

/// Drops the kept device key of [store] (its stored key was deleted).
void forgetDeviceKeyMemo(Object store) => _kept[store] = null;

Future<List<int>> _readOrMake(KeyStore store) async {
  final have = await store.readDeviceKey();
  if (have != null) return have;
  final seed = newDeviceKey();
  await store.writeDeviceKey(seed);
  return seed;
}
