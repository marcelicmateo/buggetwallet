// Shared helpers for the integration tests (app/integration_test/*_test.dart). SYNTHETIC data only.
//
// Each test starts from an empty wallet: [Harness.start] wipes the database and the stored key. It refuses to wipe a
// wallet it did not create unless it runs on Android (the emulator device is thrown away after every run), so the
// tests can never delete a real wallet on a desktop: run them there with a fresh HOME.
//
// Every test ends with [Harness.checkLog]: the app log must not contain any synthetic text, amount or key.
// [Harness.knownBug] records an app bug found by a test without failing the run (the lead decides when to fix);
// build with `--dart-define=BW_STRICT=true` (e.g. BW_DRIVE_ARGS) to make known bugs fail.
import 'dart:convert';
import 'dart:io';

import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/logging.dart';
import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import '../../test/support/seams.dart';

const strict = bool.fromEnvironment('BW_STRICT');

/// Texts of the synthetic data used by any test: none may reach the log.
const basePrivate = [
  'LIDL', 'KONZUM', 'IKEA', 'MCDONALDS', 'WOLT', 'Wolt', 'NETFLIX', 'ZARA', 'DECATHLON', 'SPAR ', 'KAUFLAND', 'STEAM', //
  'Neto plaća', 'ATM TEST ULICA', 'Naplata kredita', 'POVRAT', 'Revolut**', 'Top-up by', 'Grašo', 'Example Cafe',
  'Shop, with comma', 'Pending Shop', 'EXAMPLE SHOP', 'ŠĐČĆŽ', 'Plaćanje po računu', 'synthetic', 'Synthetic',
  'pbz_synthetic', 'revolut_synthetic', '€',
];

class Harness {
  static late IntegrationTestWidgetsFlutterBinding binding;
  static WalletController? _wc;
  static bool _logsCleared = false, _converted = false;
  static final Set<String> _private = {...basePrivate};
  static final Set<int> _cents = {};
  static final Set<String> _keys = {};
  static final List<Map<String, Object?>> bugs = [];
  static final Map<String, Object?> report = {};

  /// The combined CI entry runs every test file in one process. Each file's main() registers its private texts/amounts at
  /// registration time, so the entry clears them before main(), takes them after it, and puts them back when the file's group starts
  /// (a file run alone starts clean: nothing of another file counts against its log).
  static void clearRegistered() {
    _private
      ..clear()
      ..addAll(basePrivate);
    _cents.clear();
    _keys.clear();
  }

  static ({Set<String> texts, Set<int> cents, Set<String> keys}) takeRegistered() =>
      (texts: {..._private}, cents: {..._cents}, keys: {..._keys});

  static void useRegistered(({Set<String> texts, Set<int> cents, Set<String> keys}) r) {
    _private
      ..clear()
      ..addAll(r.texts);
    _cents
      ..clear()
      ..addAll(r.cents);
    _keys
      ..clear()
      ..addAll(r.keys);
    _logsCleared = false;
    bugs.clear();
    report.clear();
  }

  /// Start of a test file in the combined CI entry: its registered texts, a wallet-less app folder and an empty log, as when the file runs alone.
  static Future<void> beginFile(({Set<String> texts, Set<int> cents, Set<String> keys}) r) async {
    useRegistered(r);
    await AppLog.init(catchErrors: false);
    await wipe();
    await AppLog.clear();
    final dir = await supportDir();
    final sep = Platform.pathSeparator;
    expect(File('${dir.path}${sep}wallet.db').existsSync(), isFalse, reason: 'a file must not start on the previous file\'s wallet');
    for (final n in ['wallet.key', 'device.id', 'device.key']) {
      expect(File('${dir.path}$sep$n').existsSync(), isFalse, reason: 'a file must not start on the previous file\'s $n');
    }
  }

  /// End of a test file in the combined entry: its app log is kept as `$BW_APP_LOG_COPY/app-linux-combined-<name>.log`.
  static Future<void> endFile(String name) async {
    final dir = Platform.environment['BW_APP_LOG_COPY'];
    if (dir == null || dir.isEmpty) return;
    await AppLog.flush();
    await File('$dir/app-linux-combined-$name.log').writeAsString(await AppLog.combined());
  }

  /// Call first in main(). Registers the end-of-file hook that hands the app log and the report to the driver.
  static IntegrationTestWidgetsFlutterBinding init() {
    binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
    WidgetController.hitTestWarningShouldBeFatal = true; // a tap that would miss fails at its line
    AppLog.console = false; // keeps the drive output readable; the full app log goes to dist/logs/app-<name>.log
    tearDownAll(() async {
      AppLog.logFrameWindow();
      AppLog.stopMonitors();
      final data = binding.reportData ??= <String, dynamic>{};
      data['log'] = await AppLog.combined();
      data['knownBugs'] = bugs;
      data.addAll(report);
      _wc?.dispose();
      _wc = null;
    });
    return binding;
  }

  static WalletController get wc => _wc!;

  /// Adds texts and amounts (cents) that must never appear in the log.
  static void private({Iterable<String> texts = const [], Iterable<int> cents = const []}) {
    _private.addAll(texts);
    _cents.addAll(cents);
  }

  static Future<Directory> supportDir() => getApplicationSupportDirectory();

  /// Deletes the wallet database and the stored key (see the file comment for the safety rule).
  static Future<void> wipe() async {
    final dir = await supportDir();
    final sep = Platform.pathSeparator;
    final db = File('${dir.path}${sep}wallet.db');
    final marker = File('${dir.path}$sep.bw-integration-test');
    if (!Platform.isAndroid && db.existsSync() && !marker.existsSync()) {
      fail('Refusing to wipe a wallet these tests did not create. Run integration tests on a test device or with a fresh HOME.');
    }
    for (final s in ['', '-wal', '-shm', '-journal']) {
      final f = File('${db.path}$s');
      if (f.existsSync()) f.deleteSync();
    }
    if (Platform.isAndroid || Platform.isIOS) {
      // The wallet key, this install's device id and its relay device key (stage DK): a test starts as a new install.
      for (final name in ['budget_wallet_key', 'budget_wallet_device_id', 'budget_wallet_device_key']) {
        await const FlutterSecureStorage().delete(key: name);
      }
    } else {
      for (final name in ['wallet.key', 'device.id', 'device.key']) {
        final k = File('${dir.path}$sep$name');
        if (k.existsSync()) k.deleteSync();
      }
    }
    marker.createSync(recursive: true);
  }

  /// Fresh app: wipe, bootstrap (as main() does), optionally create a wallet, import [batch], apply [settings],
  /// then show the app. The first start of a test file also clears the log files.
  static Future<WalletController> start(WidgetTester t,
      {bool wallet = true, ImportBatch? batch, Map<String, Object?>? settings, bool noGoals = false, bool pump = true}) async {
    await stop(t);
    _converted = false; // the binding turns the screenshot surface back after each test
    // Typing goes through the test text input, so the device's soft keyboard never opens: it slides in later and
    // moves sheets under a tap. (Taps still hide a keyboard first, see tapVisible.)
    if (!t.testTextInput.isRegistered) t.testTextInput.register();
    await AppLog.init(catchErrors: false);
    await wipe();
    if (!_logsCleared) {
      _logsCleared = true;
      await AppLog.clear();
    }
    final wc = await seamedBoot((deps) => bootstrap(catchErrors: false, deps: deps));
    _wc = wc;
    if (wallet) {
      await wc.createWallet();
      wc.takeKeyBackupPrompt(); // the save-key sheet would cover every screen; onboarding_test covers it
      _keys.add(await wc.keyText());
      if (noGoals) {
        for (final g in wc.goals) {
          wc.deleteGoal(g.id);
        }
      }
    }
    if (batch != null) {
      wc.repo.importBatch(batch);
      wc.reload();
    }
    if (settings != null) wc.updateSettings(settings);
    if (pump) {
      await t.pumpWidget(BudgetWalletApp(wc: wc));
      AppLog.startMonitors();
      await t.pumpAndSettle();
    }
    return wc;
  }

  /// Closes the app and starts it again on the same wallet (database and key kept), as after a phone restart.
  static Future<WalletController> restart(WidgetTester t) async {
    await stop(t);
    final wc = await seamedBoot((deps) => bootstrap(catchErrors: false, deps: deps));
    _wc = wc;
    await t.pumpWidget(BudgetWalletApp(wc: wc));
    await t.pumpAndSettle();
    return wc;
  }

  /// Unmounts the app and closes the current controller (its database).
  static Future<void> stop(WidgetTester t) async {
    final old = _wc;
    if (old == null) return;
    await t.pumpWidget(const SizedBox.shrink());
    old.dispose();
    _wc = null;
  }

  static void rememberKey(String key) => _keys.add(key);

  /// Off for views resized by a test: the screenshot then never completes on the emulator.
  static bool shots = true;

  /// Screenshot. On a phone the driver saves it (make emulator-test); on a desktop flutter_test_config.dart takes it
  /// from the render tree (make desktop-test).
  static Future<void> shot(WidgetTester t, String name) async {
    if (!shots) return;
    if (!_converted) {
      _converted = true;
      await binding.convertFlutterSurfaceToImage();
    }
    await t.pumpAndSettle();
    await binding.takeScreenshot(name);
  }

  /// Records an app bug a test found. [ok] = the correct behaviour was seen.
  static void knownBug(String id, bool ok, String what) {
    if (ok) {
      debugPrint('known bug $id not reproduced (fixed?): $what');
      return;
    }
    if (bugs.any((b) => b['id'] == id && b['what'] == what)) return;
    debugPrint('KNOWN BUG $id: $what');
    bugs.add({'id': id, 'what': what});
    if (strict) fail('known bug $id: $what');
  }

  /// Known app layout bugs: (id, part of the overflowing widget's creator chain, start of the first text inside it).
  /// A RenderFlex overflow matching one is recorded with [knownBug] instead of failing the test. Remove an entry once
  /// the bug is fixed (a leftover entry is harmless, but then it hides a regression of the same row).
  /// Example entry: ('today-safe-header-overflow', '← Panel', 'SAFE TO SPEND TODAY').
  static const List<(String, String, String)> knownLayoutBugs = [];

  /// The creator chains of the render objects a FlutterError names ("Row ← StatusLabel ← Column ← …").
  static List<String> creatorChains(FlutterErrorDetails d) => [
        for (final n in d.informationCollector?.call() ?? const <DiagnosticsNode>[])
          if (n.value case final RenderObject r when r.debugCreator != null) '${r.debugCreator}',
      ];

  /// The first text inside the render objects a FlutterError names ('' if none).
  static String firstText(FlutterErrorDetails d) {
    String? text;
    void visit(RenderObject r) {
      if (text != null) return;
      if (r is RenderParagraph) {
        text = r.text.toPlainText();
        return;
      }
      r.visitChildren(visit);
    }

    for (final n in d.informationCollector?.call() ?? const <DiagnosticsNode>[]) {
      if (n.value case final RenderObject r) visit(r);
    }
    return text ?? '';
  }

  /// First line of the error, the start of its creator chain and the first text inside it, for reports.
  static String describeLayoutError(FlutterErrorDetails d) {
    final chain = creatorChains(d).firstOrNull?.split(' ← ').take(6).join(' ← ');
    final text = firstText(d);
    final first = text.isEmpty ? '' : ' "${text.length > 40 ? text.substring(0, 40) : text}"';
    return '${d.exceptionAsString().split('\n').first}${chain == null ? '' : ' [$chain]'}$first';
  }

  static String? knownLayoutBug(FlutterErrorDetails d) {
    if (!d.exceptionAsString().startsWith('A RenderFlex overflowed')) return null;
    final chains = creatorChains(d), text = firstText(d);
    for (final (id, chain, start) in knownLayoutBugs) {
      if (chains.any((c) => c.contains(chain)) && text.startsWith(start)) return id;
    }
    return null;
  }

  /// Runs [body] with known layout bugs recorded instead of failing; any other FlutterError fails as usual.
  static Future<void> guard(Future<void> Function() body) async {
    final prev = FlutterError.onError;
    FlutterError.onError = (d) {
      final id = knownLayoutBug(d);
      if (id == null) return prev?.call(d);
      knownBug(id, false, '${describeLayoutError(d)} (${AppLog.screen})');
    };
    try {
      await body();
    } finally {
      FlutterError.onError = prev;
    }
  }

  /// The app log so far; fails on synthetic text, amounts in cents, a wallet key or (unless allowed) SEVERE lines.
  static Future<String> checkLog({bool allowSevere = false}) async {
    final log = await AppLog.combined();
    for (final p in _private) {
      expect(log.contains(p), isFalse, reason: 'private text "$p" in the log');
    }
    if (_cents.isNotEmpty) {
      final re = RegExp('(?<![\\d.])(${_cents.join('|')})(?![\\d.])');
      expect(re.firstMatch(log)?.group(0), isNull, reason: 'an amount in cents in the log');
    }
    for (final k in _keys) {
      expect(log.contains(k), isFalse, reason: 'the wallet key in the log');
    }
    if (!allowSevere) {
      final severe = const LineSplitter().convert(log).where((l) => l.contains(' SEVERE ')).toList();
      expect(severe, isEmpty, reason: 'SEVERE lines in the log');
    }
    return log;
  }
}

/// testWidgets with [Harness.guard] (known layout bugs are recorded, not fatal).
void itest(String description, Future<void> Function(WidgetTester t) body, {Timeout? timeout}) =>
    testWidgets(description, (t) => Harness.guard(() => body(t)), timeout: timeout);

// ---------------------------------------------------------------- finders and actions

String todayIso() => isoDate(DateTime.now());

/// The bottom bar (phones, narrow windows) or the rail (wide windows).
Finder get navigation =>
    find.byKey(const ValueKey('navBar')).evaluate().isNotEmpty ? find.byKey(const ValueKey('navBar')) : find.byKey(const ValueKey('rail'));

/// The old tab names and where they live now (ENG E1); the new names work too.
const _tabNames = {'Today': 'Overview', 'Budget': 'Explore', 'Bills': 'Money', 'Save': 'Plan'};

Finder navTab(String label) => find.descendant(of: navigation, matching: find.text(_tabNames[label] ?? label));

/// Opens a destination. 'Settings' = the rail bottom, or the Overview gear on a phone; 'Save' = Plan › Saving.
Future<void> goTab(WidgetTester t, String label) async {
  if (label == 'Settings' && find.byKey(const ValueKey('rail')).evaluate().isEmpty) {
    await t.tap(navTab('Today'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('openSettings')));
    await t.pumpAndSettle();
    return;
  }
  await t.ensureVisible(navTab(label));
  await t.tap(navTab(label));
  await t.pumpAndSettle();
  if (label == 'Save') {
    await t.tap(find.byKey(const ValueKey('planSaving')));
    await t.pumpAndSettle();
  }
}

/// Opens Budget › Tags (main tags, tags, rules); scroll it with `scrollTo(t, f, TagsWindow)`.
Future<void> goTags(WidgetTester t) async {
  await goTab(t, 'Budget');
  await tapVisible(t, find.byKey(const ValueKey('budgetTags')));
  await t.pumpAndSettle();
}

/// Opens the Settings tab on [s]: from two panes wide it taps the section in the list; one page has nothing to tap (the test scrolls).
Future<void> goSettings(WidgetTester t, SettingsSection s) async {
  await goTab(t, 'Settings');
  await settingsSection(t, s);
}

/// Selects [s] in Settings when the section list is showing (two panes); no-op on one page.
Future<void> settingsSection(WidgetTester t, SettingsSection s) async {
  final nav = find.byKey(ValueKey('settingsNav:${s.nav.name}'));
  if (nav.evaluate().isEmpty) return;
  await tapVisible(t, nav);
}

/// The vertical list of the page shown by [screen] (a screen widget type). Settings has two lists from two panes wide: the
/// section list and the chosen section; this is the one with the panels.
Finder pageList(Type screen) {
  if (screen == SettingsScreen) {
    final panels = find.descendant(
        of: find.byType(SettingsScreen),
        matching: find.byWidgetPredicate((w) => w.key == const ValueKey('settingsPane') || w.key == const ValueKey('settingsPage')));
    return find.descendant(of: panels, matching: find.byType(Scrollable)).first;
  }
  return find.descendant(of: find.byType(screen), matching: find.byType(Scrollable)).first;
}

/// Scrolls the page of [screen] until [f] is built and visible.
Future<void> scrollTo(WidgetTester t, Finder f, Type screen, {double delta = 250}) async {
  await t.scrollUntilVisible(f, delta, scrollable: pageList(screen), maxScrolls: 80);
  await t.pumpAndSettle();
}

/// Closes the soft keyboard (real IME on a device) and waits until the screen is back to full height.
Future<void> hideKeyboard(WidgetTester t) async {
  if (t.view.viewInsets.bottom == 0) return;
  FocusManager.instance.primaryFocus?.unfocus();
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (t.view.viewInsets.bottom > 0 && DateTime.now().isBefore(end)) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump();
  }
  await t.pumpAndSettle();
}

/// A tap like a person's: keyboard out of the way, scrolled into view.
Future<void> tapVisible(WidgetTester t, Finder f) async {
  await hideKeyboard(t);
  // Into the middle of the view: at an edge, a sheet's bottom padding can cover the target.
  await Scrollable.ensureVisible(t.element(f), alignment: 0.5);
  await t.pumpAndSettle();
  if (f.hitTestable().evaluate().isEmpty) {
    // A toast (floating SnackBar) over it: a person waits until it is gone.
    for (final m in t.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
      m.removeCurrentSnackBar();
    }
    await t.pumpAndSettle();
  }
  if (f.hitTestable().evaluate().isEmpty) {
    // As a person would: scroll what is around it to the end (bottom sheets end with their main button).
    final positions = <ScrollPosition>[];
    t.element(f).visitAncestorElements((e) {
      if (e is StatefulElement && e.state is ScrollableState) positions.add((e.state as ScrollableState).position);
      return true;
    });
    for (final p in positions) {
      p.jumpTo(p.maxScrollExtent);
      await t.pumpAndSettle();
      if (f.hitTestable().evaluate().isNotEmpty) break;
    }
  }
  if (f.hitTestable().evaluate().isEmpty) {
    // Explain the miss: where the target is and what each scrollable around it can do.
    final box = t.renderObject<RenderBox>(f);
    debugPrint('tap target not hittable: ${box.localToGlobal(Offset.zero) & box.size} on ${t.view.physicalSize / t.view.devicePixelRatio}');
    t.element(f).visitAncestorElements((e) {
      if (e.widget is Scrollable) {
        final p = (e as StatefulElement).state as ScrollableState;
        final m = p.position;
        debugPrint('  scrollable ${p.widget.axisDirection}: pixels ${m.pixels} of ${m.maxScrollExtent}, viewport ${m.viewportDimension}');
      }
      return true;
    });
  }
  await t.tap(f);
  await t.pumpAndSettle();
}

/// A [StatusLabel] by its text (its icon is part of its text span, so `find.text` doesn't match it).
Finder status(String text) => find.byWidgetPredicate((w) => w is StatusLabel && w.text == text, description: 'StatusLabel "$text"');

/// A text field by its label.
Finder field(String label) => find.widgetWithText(TextField, label);

/// Pumps until [ok] is true (real time; for async work like sync and file writes).
Future<void> waitFor(WidgetTester t, bool Function() ok, {Duration timeout = const Duration(seconds: 30), String what = ''}) async {
  final end = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump(const Duration(milliseconds: 50));
  }
  await t.pumpAndSettle();
}

/// Picks [value] in the open-or-closed dropdown [dropdown].
Future<void> pickDropdown(WidgetTester t, Finder dropdown, String value) async {
  await t.tap(dropdown);
  await t.pumpAndSettle();
  final item = find.text(value).last;
  await t.ensureVisible(item);
  await t.pumpAndSettle();
  await t.tap(item);
  await t.pumpAndSettle();
}

/// A PBZ-style batch from (date, cents, bank type, description) rows, with v1-compatible ids.
ImportBatch pbzBatch(List<(String, int, String, String)> rows, {String source = 'pbz'}) {
  final seen = <String, int>{};
  final txs = <NormalizedTransaction>[];
  for (final (date, cents, type, desc) in rows) {
    final k = '$date|$cents|$desc';
    final occ = seen[k] = (seen[k] ?? -1) + 1;
    txs.add(NormalizedTransaction(
        id: transactionId(date, cents, desc, occ),
        source: source,
        date: date,
        amountMinor: cents,
        currency: 'EUR',
        bankType: type,
        description: desc));
  }
  return ImportBatch(source: source, transactions: txs);
}

/// A Revolut-style account statement CSV (completed rows unless the state says otherwise).
String revolutCsv(List<(String type, String date, String desc, String amount, String state)> rows) {
  final b = StringBuffer('Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n');
  for (final (type, date, desc, amount, state) in rows) {
    final done = state == 'COMPLETED' ? '$date 12:00:00' : '';
    b.write('$type,Current,$date 11:00:00,$done,$desc,$amount,0.00,EUR,$state,100.00\n');
  }
  return b.toString();
}
