// KL-UI2: Settings › Sync lists each sync file that blocks the device's later files. "Skip damaged file" is offered only for a
// damaged / wrong-key file whose author was last seen MORE than 7 days ago (never when the last-seen time is unknown). All data is SYNTHETIC.
import 'dart:convert';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/sync_panel.dart';
import 'package:budget_wallet/src/sync_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

final _relay = Uri.parse('http://homeserver.local:8787');
const _device = 'devabcdef12345'; // short id: devabcde
const _short = 'devabcde';

/// Writes the two device-local values a complete run leaves: the quarantine record and the blocked book.
void _block(WalletController wc, SyncProblemReason reason, {int? seenDaysAgo, String file = '3'}) {
  final now = wc.now.millisecondsSinceEpoch;
  wc.repo.setLocalValue(
      'syncBadFiles',
      jsonEncode([
        {'d': _device, 'f': file, 'r': reason.name, 'n': 10, 's': null, 'h': 'abc', 'b': 'x'}
      ]));
  wc.repo.setLocalValue(
      'syncBlocked',
      jsonEncode({
        '$_device/$file': {
          'r': reason.name,
          's': now - 86400000,
          'n': 3,
          if (seenDaysAgo != null) 'w': now - seenDaysAgo * 86400000,
        }
      }));
}

Future<void> _pump(WidgetTester t, WalletController wc, {Size size = const Size(400, 2400), double scale = 1}) =>
    pumpApp(t, Scaffold(body: SingleChildScrollView(child: SyncPanel(wc: wc, onShowKey: () {}))), size: size, textScale: scale);

Finder _k(String key) => find.byKey(ValueKey(key));
String get _rowKey => 'blocked:$_short-3';
String get _skipKey => 'skipBlocked:$_short-3';

SyncReport _report() =>
    const SyncReport(0, 0, 0, caughtUp: true, problems: [SyncProblem('devabcde', SyncProblemReason.corrupt, bytes: 10, isNew: true)]);

void main() {
  late List<String> lines;
  setUp(() {
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });

  group('what is offered', () {
    for (final (reason, days, skip, label) in [
      (SyncProblemReason.corrupt, 10, true, 'damaged, author gone 10 days'),
      (SyncProblemReason.corrupt, null, false, 'damaged, author last-seen unknown: asked, no skip'),
      (SyncProblemReason.badKey, 8, true, 'old file with another key'),
      (SyncProblemReason.otherKey, 30, true, 'sealed with another wallet key'),
      (SyncProblemReason.corrupt, 6, false, '6 days still counts as around'),
      (SyncProblemReason.corrupt, 8, true, '8 days is over the limit'),
      (SyncProblemReason.corrupt, 2, false, 'damaged, author seen 2 days ago: asked, no skip'),
      (SyncProblemReason.corrupt, 0, false, 'damaged, author seen today'),
      (SyncProblemReason.clockDrift, 30, false, 'clock drift never skips'),
      (SyncProblemReason.clockDrift, null, false, 'clock drift, author never seen'),
      (SyncProblemReason.unknownVersion, 30, false, 'newer format never skips'),
      (SyncProblemReason.applyFailed, 30, false, 'refused by the database never skips'),
    ]) {
      testWidgets(label, (t) async {
        final wc = emptyWallet()..relayUrl = _relay;
        _block(wc, reason, seenDaysAgo: days);
        await _pump(t, wc);
        expect(_k(_rowKey), findsOneWidget);
        expect(find.textContaining(blockedFileText(_short), findRichText: true), findsOneWidget);
        expect(_k(_skipKey), skip ? findsOneWidget : findsNothing);
        expect(find.text('Skip damaged file'), skip ? findsOneWidget : findsNothing);
        final asks = reason != SyncProblemReason.clockDrift && reason != SyncProblemReason.unknownVersion && (days == null || days <= 7);
        expect(find.textContaining(blockedAskedText(_short), findRichText: true), asks ? findsOneWidget : findsNothing);
        expect(find.textContaining('That device last synced'), days == null ? findsNothing : findsOneWidget);
        expect(find.textContaining(clockDriftText, findRichText: true),
            reason == SyncProblemReason.clockDrift ? findsOneWidget : findsNothing);
        expect(find.textContaining(blockedUpdateText, findRichText: true),
            reason == SyncProblemReason.unknownVersion ? findsOneWidget : findsNothing);
        expect(find.textContaining(_device), findsNothing, reason: 'only the short id is shown');
      });
    }

    test('the 7 day limit: exactly 7 days is still around, one second more is gone, unknown never skips', () {
      final now = DateTime(2026, 10, 31, 12);
      BlockedRow row(SyncProblemReason r, Duration? ago) =>
          blockedRowOf(BlockedFile(_device, '3', r, since: now, authorSeen: ago == null ? null : now.subtract(ago)), now);
      const week = Duration(days: 7);
      expect(row(SyncProblemReason.corrupt, week).canSkip, isFalse);
      expect(row(SyncProblemReason.corrupt, week).hint, blockedAskedText(_short));
      expect(row(SyncProblemReason.corrupt, week + const Duration(seconds: 1)).canSkip, isTrue);
      expect(row(SyncProblemReason.corrupt, week + const Duration(seconds: 1)).hint, isNull);
      expect(row(SyncProblemReason.corrupt, week - const Duration(seconds: 1)).canSkip, isFalse);
      expect(row(SyncProblemReason.corrupt, null).canSkip, isFalse);
      expect(row(SyncProblemReason.corrupt, null).seen, isNull);
      for (final r in [SyncProblemReason.badKey, SyncProblemReason.otherKey]) {
        expect(row(r, const Duration(days: 8)).canSkip, isTrue, reason: r.name);
      }
      for (final r in [SyncProblemReason.clockDrift, SyncProblemReason.unknownVersion, SyncProblemReason.applyFailed]) {
        expect(row(r, const Duration(days: 400)).canSkip, isFalse, reason: r.name);
        expect(row(r, null).canSkip, isFalse, reason: r.name);
      }
    });

    testWidgets('the author line reads as a relative time', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      _block(wc, SyncProblemReason.corrupt, seenDaysAgo: 10);
      await _pump(t, wc);
      expect(find.text('That device last synced 10 days ago.'), findsOneWidget);
    });

    testWidgets('nothing blocked: no rows; the plain count line still shows for files that do not block', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      wc.seams.syncRunner = (r, k, repo) async => _report();
      await _pump(t, wc);
      await t.runAsync(wc.syncNow);
      await t.pump();
      expect(_k(_rowKey), findsNothing);
      expect(find.textContaining('1 sync file could not be read', findRichText: true), findsOneWidget);
    });

    testWidgets('a blocked file is said once: the count line leaves out the files that have a row', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      _block(wc, SyncProblemReason.corrupt, seenDaysAgo: 10);
      wc.seams.syncRunner = (r, k, repo) async => _report();
      await _pump(t, wc);
      await t.runAsync(wc.syncNow);
      await t.pump();
      expect(_k(_rowKey), findsOneWidget);
      expect(find.textContaining('could not be read. It was skipped', findRichText: true), findsNothing);
    });
  });

  group('skipping', () {
    testWidgets('Cancel leaves the file and the row; Skip file skips, syncs once, says so and logs the reason only', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      _block(wc, SyncProblemReason.corrupt, seenDaysAgo: 10);
      var runs = 0;
      wc.seams.syncRunner = (r, k, repo) async {
        runs++;
        return const SyncReport(0, 0, 0, caughtUp: true);
      };
      await _pump(t, wc);

      await t.tap(_k(_skipKey));
      await t.pump();
      expect(find.textContaining(blockedSkipTitle, findRichText: true), findsOneWidget);
      expect(find.textContaining(blockedSkipConfirmText(_short), findRichText: true), findsOneWidget);
      expect(find.textContaining("This can't be undone."), findsOneWidget);
      await t.tap(_k('skipBlockedCancel'));
      await t.pump();
      expect(find.textContaining(blockedSkipTitle, findRichText: true), findsNothing);
      expect(_k(_rowKey), findsOneWidget);
      expect(blockedFiles(wc.repo), hasLength(1));
      expect(runs, 0);

      await t.tap(_k(_skipKey));
      await t.pump();
      await t.tap(_k('skipBlockedConfirm'));
      await t.pump();
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
      expect(runs, 1);
      expect(blockedFiles(wc.repo), isEmpty);
      expect(_k(_rowKey), findsNothing);
      expect(find.textContaining(blockedSkippedToast, findRichText: true), findsOneWidget);
      final log = lines.join('\n');
      expect(log, contains('sync.skip'));
      expect(log, contains('corrupt'));
      expect(log, isNot(contains(_device)));
      expect(log, isNot(contains(_short)));
      await t.pumpAndSettle(const Duration(seconds: 5)).catchError((_) => 0);
    });

    test('skipBlocked says null when it skipped, core\'s text when it refused (nothing is stored then)', () {
      final wc = emptyWallet()..relayUrl = _relay;
      _block(wc, SyncProblemReason.applyFailed, seenDaysAgo: 40);
      final f = blockedFiles(wc.repo).single;
      expect(wc.skipBlocked(f), 'Only a damaged sync file can be skipped.');
      expect(blockedFiles(wc.repo), hasLength(1), reason: 'still blocked');
      _block(wc, SyncProblemReason.corrupt, seenDaysAgo: 40);
      expect(wc.skipBlocked(blockedFiles(wc.repo).single), isNull);
      expect(blockedFiles(wc.repo), isEmpty);
    });

    testWidgets('a refused skip shows the reason, no "Skipped" toast, no sync, and the row stays', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      _block(wc, SyncProblemReason.corrupt, seenDaysAgo: 40);
      var runs = 0;
      wc.seams.syncRunner = (r, k, repo) async {
        runs++;
        return const SyncReport(0, 0, 0, caughtUp: true);
      };
      await _pump(t, wc);
      expect(_k(_skipKey), findsOneWidget);
      // The file turns out to be one that must wait (a newer format) after the row was drawn.
      _block(wc, SyncProblemReason.unknownVersion, seenDaysAgo: 40);
      await t.tap(_k(_skipKey));
      await t.pump();
      await t.tap(_k('skipBlockedConfirm'));
      await t.pump();
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
      expect(find.textContaining('Only a damaged sync file can be skipped.'), findsOneWidget);
      expect(find.textContaining(blockedSkippedToast, findRichText: true), findsNothing);
      expect(_k(_rowKey), findsOneWidget);
      expect(blockedFiles(wc.repo), hasLength(1));
      expect(runs, 0);
      await t.pumpAndSettle(const Duration(seconds: 5)).catchError((_) => 0);
    });

    testWidgets('the confirm text names the device by its short id and the skip button is not offered while the author is around',
        (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      _block(wc, SyncProblemReason.corrupt, seenDaysAgo: 1);
      await _pump(t, wc);
      expect(_k(_skipKey), findsNothing);
      expect(find.textContaining(blockedAskedText(_short), findRichText: true), findsOneWidget);
    });
  });

  group('layout', () {
    for (final (w, scale) in const [(320.0, 2.0), (360.0, 1.0), (1280.0, 1.0)]) {
      testWidgets('a row with every line fits $w dp at text $scale', (t) async {
        final wc = emptyWallet()..relayUrl = _relay;
        _block(wc, SyncProblemReason.corrupt, seenDaysAgo: 40);
        await _pump(t, wc, size: Size(w, 3000), scale: scale);
        expect(_k(_skipKey), findsOneWidget);
        await t.tap(_k(_skipKey));
        await t.pump();
        expect(_k('skipBlockedConfirm'), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }
  });
}
