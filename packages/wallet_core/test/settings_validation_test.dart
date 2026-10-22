// Settings from another device (or a damaged op) can hold a wrong type or an out-of-range value. Each bad value
// falls back to that setting's default alone, with a WARNING naming only the key. All data is SYNTHETIC.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

/// Log lines written while [body] runs.
List<String> _logs(void Function() body) {
  final lines = <String>[];
  final was = Logger.root.level;
  Logger.root.level = Level.ALL;
  final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
  try {
    body();
  } finally {
    sub.cancel();
    Logger.root.level = was;
  }
  return lines;
}

/// A setting op from another device, newer than anything local.
Op _remote(String key, String json, {int at = 0}) =>
    Op('setting', key, {'value': json, 'deleted': 0}, Hlc(DateTime.now().millisecondsSinceEpoch + 60000 + at, 0, 'peer').toString());

void main() {
  setUp(resetInvalidSettingLog); // each test expects its own warnings
  const defaults = WalletSettings();
  final good = WalletSettings.fromMap(const {
    'salary': 150000,
    'rent': 55000,
    'loan': 25000,
    'loanEnd': '2027-06',
    'subs': 1299,
    'impulse': 8000,
    'coolHours': 48,
    'paydayDay': 10,
    'periodStart': '2026-01-15',
    'currency': 'USD',
    'incomeMode': 'received',
    'savedFor': '2026-01-15',
    'salaryConfirmed': true,
    'merchantPatterns': [
      ['Groceries', 'example']
    ],
    'rentCashThreshold': 30000,
  });

  // key -> bad values, and how to read the setting back.
  final cases = <String, (List<Object?>, Object? Function(WalletSettings))>{
    'salary': (
      [
        -1,
        'x',
        12.5,
        double.nan,
        double.infinity,
        true,
        1e15,
        const [1]
      ],
      (s) => s.salary
    ),
    'rent': ([-100, '550', 0.5], (s) => s.rent),
    'loan': ([-1, false], (s) => s.loan),
    'subs': ([-1, 'subs'], (s) => s.subs),
    'impulse': ([-5000, 'a'], (s) => s.impulse),
    'coolHours': ([-1, -72, 24 * 365 + 1, '72', 1.5], (s) => s.coolHours),
    'paydayDay': ([0, -3, 32, 100, '15', 10.5], (s) => s.paydayDay),
    'rentCashThreshold': ([-1, '500', 1.25], (s) => s.rentCashThreshold),
    'loanEnd': (['2027-13', '2027', 'June', 202706, ''], (s) => s.loanEnd),
    'periodStart': (['2026-02-30', '2026-1-5', 'today', 20260115, ''], (s) => s.periodStart),
    'savedFor': (['2026-13-01', 5], (s) => s.savedFor),
    'currency': (['eur', 'EURO', '', 978], (s) => s.currency),
    'incomeMode': (['sometimes', 1, ''], (s) => s.incomeMode),
    'salaryConfirmed': (['true', 1], (s) => s.salaryConfirmed),
    'merchantPatterns': (
      [
        'Groceries=example',
        42,
        const {'a': 'b'}
      ],
      (s) => s.merchantPatterns
    ),
  };

  group('bad values fall back to the default, one setting at a time', () {
    for (final MapEntry(key: key, value: (values, read)) in cases.entries) {
      for (final v in values) {
        test('$key = ${jsonEncode(v is double && !v.isFinite ? v.toString() : v)}', () {
          final m = good.toMap()..[key] = v;
          late WalletSettings s;
          final lines = _logs(() => s = WalletSettings.fromMap(m));
          expect(read(s), read(defaults), reason: 'falls back to the default');
          // Every other setting keeps its good value.
          for (final other in cases.entries.where((e) => e.key != key)) {
            expect(other.value.$2(s), other.value.$2(good), reason: other.key);
          }
          final warn = lines.where((l) => l.contains('settings.invalid')).toList();
          expect(warn, hasLength(1));
          expect(warn.single, endsWith(' WARNING bw.settings settings.invalid {"key":"$key"}'), reason: 'the key only, never the value');
        });
      }
    }
  });

  test('valid edge values are kept and not logged', () {
    late WalletSettings s;
    final lines = _logs(() => s = WalletSettings.fromMap(const {
          'salary': 0,
          'coolHours': 0,
          'paydayDay': 31,
          'rentCashThreshold': 0,
          'impulse': 0,
          'rent': 12000.0, // a whole number written as a double by another JSON encoder
          'periodStart': '2028-02-29',
          'loanEnd': '2027-12',
        }));
    expect([s.salary, s.coolHours, s.paydayDay, s.rentCashThreshold, s.impulse, s.rent], [0, 0, 31, 0, 0, 12000]);
    expect(s.periodStart, '2028-02-29');
    expect(s.loanEnd, '2027-12');
    expect(lines.where((l) => l.contains('settings.invalid')), isEmpty);
  });

  test('a damaged JSON value in the database falls back for that key only', () {
    final r = WalletRepo.inMemory();
    addTearDown(r.close);
    r.updateSettings({'salary': 150000, 'coolHours': 48});
    r.applyRemote([_remote('coolHours', '{not json')]);
    late WalletSettings s;
    final lines = _logs(() => s = r.settings());
    expect(s.coolHours, 72);
    expect(s.salary, 150000);
    expect(lines.where((l) => l.contains('settings.invalid {"key":"coolHours"}')), hasLength(1));
  });

  test('bad values from another device: sync keeps working, only those settings fall back', () async {
    final relay = MemoryTransport();
    final key = VaultKey.generate();
    final a = WalletRepo.inMemory(), b = WalletRepo.inMemory();
    addTearDown(a.close);
    addTearDown(b.close);
    a.updateSettings({'salary': 150000, 'rent': 55000, 'paydayDay': 10, 'coolHours': 48});
    await SyncEngine(relay, key).run(a);
    await SyncEngine(relay, key).run(b);
    expect(b.settings().paydayDay, 10);

    // Device a has a bug and writes out-of-range and wrong-typed values; they sync like any other op.
    a.updateSettings({'paydayDay': 0, 'coolHours': -5, 'rent': 'lots', 'currency': 'euro'});
    await SyncEngine(relay, key).run(a);
    late WalletSettings s;
    await SyncEngine(relay, key).run(b);
    final warnings = _logs(() => s = b.settings()).where((l) => l.contains('settings.invalid')).toList();
    expect(s.paydayDay, 15);
    expect(s.coolHours, 72);
    expect(s.rent, 0);
    expect(s.currency, 'EUR');
    expect(s.salary, 150000, reason: 'good settings are kept');
    expect(warnings, hasLength(4));

    // A later good value from either device replaces the bad one.
    b.updateSettings({'paydayDay': 12});
    await SyncEngine(relay, key).run(b);
    await SyncEngine(relay, key).run(a);
    expect(a.settings().paydayDay, 12);
    expect(b.settings().paydayDay, 12);
  });

  test('a bad stored value is logged once per key and value, not on every settings() read', () {
    final r = WalletRepo.inMemory();
    addTearDown(r.close);
    final first = _logs(() {
      r.applyRemote([_remote('coolHours', '{not json'), _remote('paydayDay', '0')]);
      r.settings();
      r.settings();
    }).where((l) => l.contains('settings.invalid')).toList();
    expect(first, hasLength(2));
    final again = _logs(() {
      for (var i = 0; i < 20; i++) {
        r.settings();
        r.categorizer();
      }
    });
    expect(again.where((l) => l.contains('settings.invalid')), isEmpty, reason: 'the same bad values: already logged');
    // A different bad value for the same key is new information: logged once more.
    final changed = _logs(() {
      r.applyRemote([_remote('paydayDay', '40', at: 1)]);
      r.settings();
      r.settings();
    }).where((l) => l.contains('settings.invalid')).toList();
    expect(changed, [endsWith(' WARNING bw.settings settings.invalid {"key":"paydayDay"}')]);
    expect(r.settings().paydayDay, 15, reason: 'still falls back to the default every time');
  });
}
