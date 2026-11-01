// Is the network metered (UX-FX)? Android asks ConnectivityManager through the `budget_wallet/network` channel (MainActivity.kt);
// every other platform (Linux, the browser) is treated as unmetered. A failure answers false: the owner can still tap "Get rates now".
// Web-safe: no dart:io.
import 'package:flutter/services.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'platform.dart';

final _log = Logger('bw.fx');

const _channel = MethodChannel('budget_wallet/network');

/// Whether the active network is metered (mobile data, a hotspot). False off Android and when the phone cannot say.
Future<bool> networkIsMetered() async {
  if (!isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('isMetered') ?? false;
  } catch (e) {
    logEvent(_log, Level.FINE, 'fx.meteredUnknown', {'type': e.runtimeType.toString()});
    return false;
  }
}

/// The ECB download for tests: no network, always "no connection". A test that wants rates injects its own fetcher.
Future<List<int>> noEcbFetch(EcbFile f) async =>
    throw const EcbFetchException(EcbFetchFailure.unreachable, 'The exchange rates could not be downloaded: no connection.');
