// Plain-language texts for Plan › Sync (pure: the controller and the tests use them, the screen only shows them).
import 'package:wallet_core/wallet_core.dart';

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
      TransportFailure.olderApi => 'This relay is older than the app. Update the relay on the home server.',
      TransportFailure.unreachable => "Can't reach the relay",
      _ => 'The relay answered, but not as expected',
    };
