// UX-B B4: the Today number tiles are the owner's choice (Settings > Look): hide, reorder, reset; kept on the device only; the tiles
// that need action stay first. SYNTHETIC wallet on a fixed clock (Sunday 25 Oct 2026, period 15 Oct to 15 Nov).
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_tiles_panel.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

final _at = DateTime(2026, 10, 25, 12);

WalletController _wallet({bool confirmed = true}) {
  final wc = WalletController.forTest(WalletRepo.inMemory(), clock: () => _at);
  wc.repo.updateSettings({
    'salary': 200000,
    'rent': 50000,
    'periodStart': '2026-10-15',
    'paydayDay': 15,
    'salaryConfirmed': confirmed,
  });
  wc.reload();
  wc.snoozeKeyBackup();
  return wc;
}

Future<void> _today(WidgetTester t, WalletController wc, {double width = 400}) async {
  t.view.physicalSize = Size(width, 3000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
        body: ListenableBuilder(
            listenable: wc,
            builder: (_, __) => TodayScreen(view: TodayView(wc), openPlan: () {}, addExpense: () {}, openSearch: () {}, clock: () => _at))),
  ));
  await t.pump();
}

Future<void> _panel(WidgetTester t, WalletController wc) async {
  t.view.physicalSize = const Size(400, 3000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: ListenableBuilder(listenable: wc, builder: (_, __) => ListView(children: [TodayTilesPanel(wc: wc)]))),
  ));
  await t.pump();
}

Finder _k(String key) => find.byKey(ValueKey(key));

/// Reading order of the tiles with these keys: top first, then left.
List<String> _order(WidgetTester t, List<String> keys) {
  final at = {
    for (final k in keys)
      if (_k(k).evaluate().isNotEmpty) k: t.getTopLeft(_k(k))
  };
  return at.keys.toList()
    ..sort((a, b) {
      final d = at[a]!.dy.compareTo(at[b]!.dy);
      return d != 0 ? d : at[a]!.dx.compareTo(at[b]!.dx);
    });
}

const _numbers = ['leftTile', 'paydayTile', 'addExpense', 'todaySearch'];

void main() {
  group('the stored choice', () {
    test('default is every tile in the old order; nothing is stored', () {
      final wc = _wallet();
      expect(wc.todayTiles.order, DeviceSettings.todayTileIds);
      expect(wc.todayTiles.hidden, isEmpty);
      wc.setTodayTiles(['recent', ...DeviceSettings.todayTileIds.where((i) => i != 'recent')], {'held'});
      expect(wc.todayTiles.order.first, 'recent');
      expect(wc.todayTiles.hidden, {'held'});
      wc.setTodayTiles(DeviceSettings.todayTileIds, {});
      expect(wc.repo.localValue('todayTiles'), isNull, reason: 'the default stores nothing');
    });

    test('unknown ids are ignored and new tiles are appended', () {
      final wc = _wallet();
      wc.repo.setLocalValue('todayTiles', 'recent,nope,left,left|gone,held');
      final (:order, :hidden) = wc.todayTiles;
      expect(order.take(2), ['recent', 'left']);
      expect(order.toSet(), DeviceSettings.todayTileIds.toSet(), reason: 'every known tile once');
      expect(order.length, DeviceSettings.todayTileIds.length);
      expect(hidden, {'held'});
      wc.repo.setLocalValue('todayTiles', 'garbage');
      expect(wc.todayTiles.order, DeviceSettings.todayTileIds);
    });

    test('device-local: nothing goes to the sync outbox', () {
      final wc = _wallet();
      final before = wc.repo.pendingOps().length;
      wc.setTodayTiles(DeviceSettings.todayTileIds.reversed.toList(), {'left'});
      expect(wc.repo.pendingOps().length, before);
    });
  });

  group('Today', () {
    testWidgets('hide a tile; reorder; it stays after a new screen', (t) async {
      final wc = _wallet();
      await _today(t, wc);
      expect(_order(t, _numbers), _numbers);

      wc.setTodayTiles(DeviceSettings.todayTileIds, {'payday', 'recent'});
      await t.pump();
      expect(_k('paydayTile'), findsNothing);
      expect(_k('todaySearch'), findsNothing);
      expect(_k('leftTile'), findsOneWidget);

      wc.setTodayTiles(['add', ...DeviceSettings.todayTileIds.where((i) => i != 'add')], {});
      await t.pump();
      expect(_order(t, _numbers), ['addExpense', 'leftTile', 'paydayTile', 'todaySearch']);

      await t.pumpWidget(const SizedBox());
      await _today(t, wc); // a new screen reads the same choice
      expect(_order(t, _numbers).first, 'addExpense');
    });

    testWidgets('the Needs-you tile stays first, whatever the order', (t) async {
      final wc = _wallet(confirmed: false);
      wc.setTodayTiles(DeviceSettings.todayTileIds.reversed.toList(), {});
      await _today(t, wc);
      expect(_k('needsYouTile'), findsOneWidget);
      final setup = t.getTopLeft(_k('needsYouTile')).dy;
      for (final k in _numbers) {
        expect(t.getTopLeft(_k(k)).dy, greaterThan(setup), reason: k);
      }
      expect(t.getTopLeft(_k('heroTile')).dy, lessThan(setup));
    });

    testWidgets('a tile that is on but has nothing to show stays out', (t) async {
      final wc = _wallet();
      await _today(t, wc);
      expect(_k('heldLine'), findsNothing);
      expect(_k('foreignNote'), findsNothing);
    });
  });

  group('Settings panel', () {
    testWidgets('switch, move up and down, reset', (t) async {
      final wc = _wallet();
      await _panel(t, wc);
      await t.tap(_k('todayTile:left'));
      await t.pump();
      expect(wc.todayTiles.hidden, {'left'});
      expect(t.widget<SwitchListTile>(_k('todayTile:left')).value, isFalse);

      await t.tap(_k('todayTileDown:left'));
      await t.pump();
      expect(wc.todayTiles.order.take(2), ['payday', 'left']);
      await t.tap(_k('todayTileUp:left'));
      await t.pump();
      expect(wc.todayTiles.order.take(2), ['left', 'payday']);

      expect(t.widget<IconButton>(_k('todayTileUp:left')).onPressed, isNull, reason: 'first cannot go up');
      expect(t.widget<IconButton>(_k('todayTileDown:recent')).onPressed, isNull, reason: 'last cannot go down');

      await t.tap(_k('todayTileDown:left'));
      await t.pump();
      await t.ensureVisible(_k('todayTilesReset'));
      await t.tap(_k('todayTilesReset'));
      await t.pump();
      expect(wc.todayTiles.order, DeviceSettings.todayTileIds);
      expect(wc.todayTiles.hidden, isEmpty);
    });

    testWidgets('fits 320 dp at text scale 2.0', (t) async {
      final wc = _wallet();
      t.view.physicalSize = const Size(320, 6000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)), child: c!),
        home: Scaffold(body: ListView(children: [TodayTilesPanel(wc: wc)])),
      ));
      await t.pump();
      expect(t.takeException(), isNull);
    });
  });
}
