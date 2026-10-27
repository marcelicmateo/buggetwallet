// After a sync run that failed part-way, the controller reloads when wallet data changed during the run, also when the
// change is a peer edit with a clock older than the newest one here. SYNTHETIC; no device.
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

Op _setting(String key, String value, int millis) => Op('setting', key, {'value': value, 'deleted': 0}, Hlc(millis, 0, 'peer').toString());

void main() {
  test('a peer edit older than the newest clock, applied by a failed run, still reloads the screens', () async {
    final wc = emptyWallet();
    addTearDown(wc.dispose);
    wc.relayUrl = Uri.parse('http://relay.local:8787');
    final now = DateTime.now().millisecondsSinceEpoch;
    wc.repo.applyRemote([_setting('salary', '1000', now - 3000), _setting('rent', '500', now - 1000)]);
    wc.reload();
    expect(wc.settings.salary, 1000);
    wc.seams.syncRunner = (relay, k, repo) async {
      // Newer than salary's clock, older than rent's (the newest): the newest-clock mark cannot see it.
      repo.applyRemote([_setting('salary', '2000', now - 2000)]);
      throw const SyncException('The relay went away.');
    };
    await wc.syncNow();
    expect(wc.syncError, 'The relay went away.');
    expect(wc.settings.salary, 2000, reason: 'the controller reloaded: the screens show the peer edit');
  });
}
