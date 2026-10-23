// Implementation tests for logging: error redaction, helpers, the sink's timer, and that the core's own log lines
// carry no private data. SYNTHETIC data only.
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart' show hierarchicalLoggingEnabled;
import 'package:sqlite3/sqlite3.dart' show SqliteException, sqlite3;
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show ImportException;

import 'support/synthetic.dart';

/// Formatted lines of everything logged during the test, at every level.
List<String> _captureAll() {
  final lines = <String>[];
  final was = Logger.root.level;
  Logger.root.level = Level.ALL;
  final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
  addTearDown(() async {
    await sub.cancel();
    Logger.root.level = was;
  });
  return lines;
}

/// Texts of the synthetic data that must never reach a log line.
const _private = [
  'LIDL',
  'Revolut**',
  'Neto plaća',
  'Naplata kredita',
  'ATM TEST ULICA',
  'POVRAT',
  'Naknada',
  '1500.00',
  '550.00',
  '23.40',
  'Laptop fund',
  'Lunch note',
];

/// Synthetic amounts in cents, as whole numbers.
final _amounts = RegExp(r'(?<![\d.])-?(150000|55000|2340|30000)(?![\d.])');

void _expectClean(List<String> lines) {
  final text = lines.join('\n');
  for (final p in _private) {
    expect(text, isNot(contains(p)), reason: 'private text "$p" in the log');
  }
  expect(_amounts.firstMatch(text)?.group(0), isNull, reason: 'an amount in the log');
}

void main() {
  setUp(() => hierarchicalLoggingEnabled = false);

  group('describeError', () {
    test('unknown error types log only their type name (their text can hold paths, commands or values)', () {
      const e = ProcessException('chmod', ['600', '/home/someone/.local/share/budget_wallet_key'], 'not found', 2);
      expect(describeError(e), 'ProcessException');
      expect(describeError(Exception('POS LIDL 23.40')), isNot(contains('LIDL')));
    });

    test('our own exceptions and fixed-text errors keep their message', () {
      expect(describeError(StateError('no wallet')), contains('no wallet'));
      expect(describeError(const ImportException('Could not read this file.')), contains('Could not read this file.'));
    });

    test('a registered hook redacts error types the package cannot see', () {
      describeErrorHook = (e) => e is ProcessException ? 'ProcessException(code ${e.errorCode})' : null;
      addTearDown(() => describeErrorHook = null);
      expect(describeError(const ProcessException('chmod', ['/secret/path'], 'x', 2)), 'ProcessException(code 2)');
    });

    test('FormatException without its source text', () {
      const e = FormatException('Unexpected character', '{"description":"POS LIDL","amount":-2340}', 3);
      expect(describeError(e), 'FormatException: Unexpected character (at offset 3)');
    });

    test('FileSystemException without the path', () {
      const e = PathNotFoundException('/home/someone/Downloads/statement-PBZ.xls', OSError('No such file', 2));
      final d = describeError(e);
      expect(d, startsWith('PathNotFoundException: '));
      expect(d, isNot(contains('statement')));
      expect(d, isNot(contains('someone')));
      expect(d, contains('errno = 2'));
    });

    test('ArgumentError without the invalid value', () {
      final d = describeError(ArgumentError.value('POS LIDL 23.40', 'description', 'bad'));
      expect(d, 'ArgumentError(description): bad');
    });

    test('SqliteException without statement parameters', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      db.execute('CREATE TABLE t(id TEXT PRIMARY KEY)');
      db.execute('INSERT INTO t VALUES (?)', ['POS LIDL secret']);
      Object? err;
      try {
        db.execute('INSERT INTO t VALUES (?)', ['POS LIDL secret']);
      } on SqliteException catch (e) {
        err = e;
      }
      expect(err, isNotNull);
      expect('$err', contains('POS LIDL secret'), reason: 'toString() would leak it');
      final d = describeError(err);
      expect(d, startsWith('SqliteException('));
      expect(d, contains('INSERT INTO t VALUES (?)'));
      expect(d, isNot(contains('POS LIDL secret')));
    });

    test('other errors print as usual', () {
      expect(describeError(StateError('x')), 'Bad state: x');
      expect(describeError(RangeError.index(5, [1, 2], 'i')), contains('5'));
    });

    test('formatLogRecord uses it for the error line', () {
      final r = LogRecord(Level.WARNING, 'x', 'bw.t', const FormatException('bad', 'POS LIDL 23.40'));
      expect(formatLogRecord(r), isNot(contains('LIDL')));
    });
  });

  group('helpers', () {
    test('logError attaches error and stack, WARNING by default', () {
      final got = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(got.add);
      addTearDown(sub.cancel);
      logError(Logger('bw.t'), 'thing.failed', StateError('boom'), StackTrace.current, fields: {'n': 1});
      expect(got.single.level, Level.WARNING);
      final lines = formatLogRecord(got.single).split('\n');
      expect(lines.first, endsWith(' WARNING bw.t thing.failed {"n":1}'));
      expect(lines[1], '  error: Bad state: boom');
      expect(lines.length, greaterThan(2));
    });

    test('PerfTimer logs result fields at the end', () {
      final lines = _captureAll();
      final t = PerfTimer('op.x');
      expect(t.done({'rows': 3}), greaterThanOrEqualTo(0));
      expect(lines.single, matches(RegExp(r' DEBUG bw\.perf op\.x \{"ms":\d+,"rows":3\}$')));
    });

    test('timed marks failures and rethrows', () {
      final lines = _captureAll();
      expect(() => timed<int>('op.fail', () => throw StateError('x'), fields: {'a': 1}), throwsStateError);
      expect(lines.single, matches(RegExp(r'op\.fail \{"ms":\d+,"a":1,"failed":true\}$')));
    });

    test('FINE prints as DEBUG; non-JSON field values print as text', () {
      final lines = _captureAll();
      logEvent(Logger('bw.t'), Level.FINE, 'e', {'d': DateTime.utc(2026, 1, 2), 'k': BudgetKind.flex});
      expect(lines.single, endsWith(' DEBUG bw.t e {"d":"2026-01-02T00:00:00.000Z","k":"BudgetKind.flex"}'));
    });
  });

  group('RotatingFileSink timer', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('bw_logs_impl_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('add() flushes by itself after flushDelay', () async {
      final s = RotatingFileSink(dir)..flushDelay = const Duration(milliseconds: 20);
      s.add('a');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(s.files().single.readAsLinesSync(), ['a']);
      await s.close();
    });

    test('lines added after close are dropped; write errors are counted, not thrown', () async {
      final s = RotatingFileSink(dir);
      s.add('a');
      await s.close();
      s.add('b');
      await s.flush();
      expect(s.files().single.readAsLinesSync(), ['a']);

      final blocker = File('${dir.path}/not-a-dir')..writeAsStringSync('x');
      final bad = RotatingFileSink(Directory('${blocker.path}/logs'));
      bad.add('c');
      await bad.flush();
      expect(bad.errors, 1);
      expect(bad.lastError, isNotNull);
    });
  });

  group('core logs carry no private data', () {
    test('import, edits, reads and period maths', () {
      final lines = _captureAll();
      final repo = WalletRepo.inMemory();
      addTearDown(repo.close);
      repo.updateSettings({'salary': 150000, 'rent': 55000});
      repo.setMerchantPattern('Groceries', 'lidl');
      expect(() => repo.setMerchantPattern('Shopping', '(unclosed LIDL'), throwsArgumentError);

      repo.addTransaction(date: '2026-01-17', amount: 2340, category: 'Groceries', note: 'Lunch note');
      final s = repo.importBatch(january);
      expect(s.added, january.transactions.length);
      repo.saveGoal(name: 'Laptop fund', target: 150000, saved: 2340, monthly: 2340);
      repo.addWish('Laptop fund', 150000);
      final cz = repo.categorizer();
      final txs = repo.transactions().map(cz.categorize).toList();
      final st = repo.settings();
      computePeriod(txs, st, repo.goals(), '2026-01-25');
      periodSummaries(txs, st, '2026-01-25');

      final text = lines.join('\n');
      expect(text, contains('repo.importBatch {"ms":'));
      expect(text, contains('"added":${january.transactions.length}'));
      expect(text, contains('repo.write'));
      expect(text, contains('repo.transactions'));
      expect(text, contains('settings.badPattern'));
      expect(text, contains('budget.period {"start":"2026-01-25"'));
      expect(text, contains('budget.periods'));
      _expectClean(lines);
    });

    test('sync and vault', () async {
      final lines = _captureAll();
      final relay = MemoryTransport();
      final key = VaultKey.generate();
      final a = WalletRepo.inMemory(), b = WalletRepo.inMemory();
      addTearDown(a.close);
      addTearDown(b.close);
      a.importBatch(january);
      a.saveGoal(name: 'Laptop fund', target: 150000, saved: 0, monthly: 2340);
      await SyncEngine(relay, key).run(a);
      final r = await SyncEngine(relay, key).run(b);
      expect(r.filesRead, 1);

      // A damaged file is skipped and logged by its sequence number only.
      a.updateSettings({'rent': 1});
      await SyncEngine(relay, key).run(a);
      relay.replace(a.deviceId, 2, [1, 2, 3]);
      expect((await SyncEngine(relay, key).run(b)).badFiles, 1);

      // An unreachable relay: the failure is logged without key material.
      relay.offline = true;
      await expectLater(SyncEngine(relay, VaultKey.generate()).run(WalletRepo.inMemory()), throwsA(isA<SyncException>()));

      final text = lines.join('\n');
      expect(text, contains('sync.export {"ms":'));
      expect(text, contains('sync.run {"ms":'));
      expect(text, contains('vault.seal'));
      expect(text, contains('vault.unseal'));
      expect(text, contains('sync.failed {"step":"state","failure":"unreachable"}'));
      expect(text, contains('WARNING bw.sync sync.file.failed {"seq":2,"reason":"corrupt","bytes":3}'));
      expect(text, contains('sync.files.skipped {"bad":1,"new":1}'));
      _expectClean(lines);
      expect(text, isNot(contains(await key.toText())));
      expect(text, isNot(contains(base64Encode(key.bytes))));
      expect(text, isNot(contains(a.deviceId)), reason: 'device ids are not logged');
      expect(text, isNot(contains(SyncProblem.shortId(a.deviceId))), reason: 'not even short ones');
    });

    test('a failed write logs a SEVERE rollback without the values', () {
      final lines = _captureAll();
      final repo = WalletRepo.inMemory();
      addTearDown(repo.close);
      repo.db.execute('CREATE TRIGGER no_goals BEFORE UPDATE ON goals BEGIN SELECT RAISE(ABORT, \'blocked\'); END');
      expect(() => repo.saveGoal(name: 'Laptop fund', target: 150000, saved: 0, monthly: 2340), throwsA(isA<SqliteException>()));
      final text = lines.join('\n');
      expect(text, contains('SEVERE bw.repo repo.rollback'));
      expect(text, contains('blocked'));
      _expectClean(lines);
    });
  });
}
