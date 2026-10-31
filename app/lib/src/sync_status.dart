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
const relayOlderThanBeforeText =
    'The relay answered with an older version than before. If you reinstalled or downgraded it on purpose, enter its address again.';

const relayChangedText = 'This relay is new or was reset; this device sent everything again.';

/// Information only: another install used this device's id; core moved this device to a new stream by itself.
const deviceIdInUseText = 'Another install used this device id; this device now syncs under a new stream.';

/// A peer's newest file waits because its clock is ahead of this device's.
const clockDriftText = "A device's clock is ahead; its changes wait until the clocks agree.";

/// A file made with another wallet key sits on the relay; sync ignored it.
const otherKeyFileText = 'A file made with another wallet key is on this relay. It was ignored.';

/// The devices' data differs after a sync; the app tried to repair it and the owner should send the logs.
const devicesDisagreeText =
    "Your devices don't agree on some data. The app tried to repair it. Save the logs (Settings › Diagnostics) and send them.";

/// Equal-clock conflicts wait for the owner's choice (V, VC).
String devicesConflictText(int n) =>
    n == 1 ? 'Your devices have 1 different value. Choose the right one.' : 'Your devices have $n different values. Choose the right ones.';

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

// ---------- KL: a sync file that cannot be read and blocks the device's later files ----------

/// The author counts as around until it was last seen more than this many days ago (exactly 7 days is still around), or when
/// its last-seen time is unknown: it is asked, not skipped.
const blockedAuthorDays = 7;

/// "A sync file from device ab12cd can't be read. Changes from that device after it are waiting."
String blockedFileText(String short) => "A sync file from device $short can't be read. Changes from that device after it are waiting.";

/// "That device last synced 3 days ago." (null when the relay never said).
String? blockedAuthorSeenText(BlockedFile f, DateTime now) =>
    f.authorSeen == null ? null : 'That device last synced ${lastSeenText(f.authorSeen, now)}.';

String blockedAskedText(String short) => 'Asked $short to send its data again.';

/// A file of a newer format: only an update reads it.
const blockedUpdateText = 'It was made by a newer version of the app. Update the app to read it.';

const blockedSkipTitle = 'Skip this file?';

String blockedSkipConfirmText(String short) =>
    "Its changes will be missing on this device unless $short syncs again and resends its data. Later changes from $short will sync normally. This can't be undone.";

const blockedSkippedToast = 'Skipped. Syncing again.';

/// What Settings › Sync shows for one blocked file (pure; the screen only draws it).
class BlockedRow {
  final BlockedFile file;

  /// "That device last synced …", when known.
  final String? seen;

  /// A second line: asked / clock / update; null when none applies.
  final String? hint;

  /// Offer "Skip damaged file": a damaged / wrong-key file whose author was last seen MORE than 7 days ago (never when unknown).
  final bool canSkip;
  const BlockedRow(this.file, this.seen, this.hint, this.canSkip);
}

BlockedRow blockedRowOf(BlockedFile f, DateTime now) {
  final seen = f.authorSeen;
  final gone = seen != null && now.difference(seen) > const Duration(days: blockedAuthorDays);
  final damaged = f.reason == SyncProblemReason.corrupt || f.reason == SyncProblemReason.badKey || f.reason == SyncProblemReason.otherKey;
  final hint = switch (f.reason) {
    SyncProblemReason.clockDrift => clockDriftText,
    SyncProblemReason.unknownVersion => blockedUpdateText,
    _ when !gone => blockedAskedText(f.short),
    _ => null,
  };
  return BlockedRow(f, blockedAuthorSeenText(f, now), hint, damaged && gone);
}
