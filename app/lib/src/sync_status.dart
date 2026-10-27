// Plain-language texts for Plan › Sync (pure: the controller and the tests use them, the screen only shows them).
import 'package:wallet_sync/wallet_sync.dart';

/// The one-line state of the last sync: [good] is false while something waits.
({String text, bool good}) syncStatusLine({required bool caughtUp, required List<SyncWaiting> waiting}) {
  if (waiting.isNotEmpty) {
    final w = waiting.first;
    final more = waiting.length > 1 ? ' (and ${waiting.length - 1} more)' : '';
    final why = w.reason == null ? '' : ', which could not be read';
    return (text: 'Waiting for file ${w.seq} from device ${w.device}$why$more', good: false);
  }
  if (!caughtUp) return (text: 'Not caught up yet: matching waits', good: false);
  return (text: 'Up to date', good: true);
}

/// "3 bill files waiting to upload" (shown only when something waits).
String blobsWaitingText(int n) => '$n bill ${n == 1 ? 'file' : 'files'} waiting to upload';

/// What Plan › Sync says when the relay cannot keep bill files.
const blobsUnsupportedText = "This relay can't keep bill photos yet. Update the relay on the home server.";

/// Plan › Sync: the relay was wiped, restored or replaced, so this device sent everything again.
const relayChangedText = 'This relay is new or was reset; this device sent everything again.';

/// Information only: another install used this device's id; core moved this device to a new stream by itself.
const deviceIdInUseText = 'Another install used this device id; this device now syncs under a new stream.';

/// A peer's newest file waits because its clock is ahead of this device's.
const clockDriftText = "A device's clock is ahead; its changes wait until the clocks agree.";

/// The text under the relay address when the relay needs a creation token.
const createTokenText = 'The relay needs its creation token.';

/// The saved relay address is plain `http://` to a public host (saved before the https rule): it still works, the creation token is not sent.
const storedAddressNeedsHttpsText =
    'This relay address uses plain http. Switch to its https:// address; the creation token is not sent over http.';

/// Why a typed relay address was refused.
const addressNotAnAddressText = 'Enter an address like http://homeserver:8787';
const addressNeedsHttpsText = 'Use the https:// address of your relay. http:// is only for your home network.';

/// "just now", "5 min ago", "3 h ago", "2 days ago"; "never" without a time.
String lastSeenText(DateTime? seen, DateTime now) {
  if (seen == null) return 'never';
  final d = now.difference(seen);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  final days = d.inDays;
  return days == 1 ? '1 day ago' : '$days days ago';
}

/// "14:05" for the last-sync line.
String clockText(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// What "Test connection" says for a failure.
String relayTestFailureText(TransportFailure f) => switch (f) {
      TransportFailure.newerApi => 'This relay needs a newer app',
      TransportFailure.clockSkew =>
        "This device's clock and the relay's clock differ by more than a day. Check the date and time settings.",
      TransportFailure.createToken => createTokenText,
      TransportFailure.olderApi => 'This relay is older than the app. Update the relay on the home server.',
      TransportFailure.unreachable => "Can't reach the relay",
      _ => 'The relay answered, but not as expected',
    };
