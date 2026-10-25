// P12 core (docs/context/P12_SPEC.md §2): saved CSV layouts as synced per-key settings, accounts for a mapped CSV,
// imports through importBatch. Synthetic data only.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';

const _now = 1767225600000; // 2026-01-01

Uint8List _csv(String s) => Uint8List.fromList(utf8.encode(s));

final _file = _csv('Datum;Opis;Iznos;Valuta\n05.01.2026;SYNTH SHOP;-12,30;EUR\n06.01.2026;SYNTH CAFE;-3,50;EUR\n');

List<String> _captureLogs() {
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

int _outbox(WalletRepo r) => r.db.select('SELECT count(*) AS n FROM outbox').first['n'] as int;

void main() {
  late WalletRepo repo;
  late CsvShape shape;
  late CsvMapping mapping;
  setUp(() {
    repo = WalletRepo.inMemory(now: () => _now);
    shape = csvShape(_file);
    mapping = guessMapping(shape)!.copyWith(name: 'Synth bank (CSV)');
  });
  tearDown(() => repo.close());

  group('setting rows', () {
    test('set, read back, unchanged = no write, rename, remove, set again (Undo)', () {
      expect(repo.settings().csvMappings, isEmpty);
      repo.setCsvMapping(shape.shapeId, mapping.copyWith(name: '  Synth bank (CSV) '));
      expect(repo.settings().csvMappings, {shape.shapeId: mapping}, reason: 'the name is stored trimmed');
      final rows = repo.db.select('SELECT id, value FROM settings WHERE id LIKE ?', ['${WalletSettings.csvMapPrefix}%']);
      expect(rows.single['id'], '${WalletSettings.csvMapPrefix}${shape.shapeId}');
      expect(jsonDecode(rows.single['value'] as String), mapping.toJson());

      final before = _outbox(repo);
      repo.setCsvMapping(shape.shapeId, mapping);
      expect(_outbox(repo), before, reason: 'unchanged: nothing written');

      repo.setCsvMapping(shape.shapeId, mapping.copyWith(name: 'Renamed'));
      expect(repo.settings().csvMappings[shape.shapeId]!.name, 'Renamed');

      repo.removeCsvMapping(shape.shapeId);
      expect(repo.settings().csvMappings, isEmpty);
      final n = _outbox(repo);
      repo.removeCsvMapping(shape.shapeId);
      expect(_outbox(repo), n, reason: 'nothing to remove: nothing written');

      repo.setCsvMapping(shape.shapeId, mapping);
      expect(repo.settings().csvMappings, {shape.shapeId: mapping});
    });

    test('refused: a bad shape id, a mapping with a problem, a whole-value write', () {
      for (final id in ['', 'ABCDEF0123456789', '0123', 'zzzzzzzzzzzzzzzz', '${shape.shapeId}0']) {
        expect(() => repo.setCsvMapping(id, mapping), throwsArgumentError, reason: id);
      }
      expect(() => repo.setCsvMapping(shape.shapeId, mapping.copyWith(name: '')),
          throwsA(isA<ArgumentError>().having((e) => e.message, 'message', 'Give the layout a name.')));
      expect(() => repo.setCsvMapping(shape.shapeId, mapping.copyWith(name: 'x' * 31)), throwsArgumentError);
      expect(() => repo.setCsvMapping(shape.shapeId, mapping.copyWith(amountCol: null)), throwsArgumentError);
      expect(() => repo.setCsvMapping(shape.shapeId, mapping.copyWith(amountCol: 7)), throwsArgumentError);
      expect(() => repo.updateSettings({'${WalletSettings.csvMapPrefix}${shape.shapeId}': mapping.toJson()}), throwsArgumentError);
      expect(() => repo.updateSettings({'csvMappings': {}}), throwsArgumentError);
      expect(repo.settings().csvMappings, isEmpty);
    });

    test('a damaged row from another device is dropped, logged under csvmap with no contents', () {
      final lines = _captureLogs();
      resetInvalidSettingLog();
      repo.setCsvMapping(shape.shapeId, mapping);
      final bad = {...mapping.toJson(), 'name': 'Synth secret label', 'amount': <String, Object?>{}};
      repo.applyRemote([
        Op('setting', '${WalletSettings.csvMapPrefix}00000000000000aa', {'value': jsonEncode(bad), 'deleted': 0},
            repo.clock.tick().toString()),
        Op('setting', '${WalletSettings.csvMapPrefix}00000000000000bb', {'value': '"text"', 'deleted': 0}, repo.clock.tick().toString()),
        Op('setting', '${WalletSettings.csvMapPrefix}NOT-A-SHAPE', {'value': jsonEncode(mapping.toJson()), 'deleted': 0},
            repo.clock.tick().toString()),
      ]);
      expect(repo.settings().csvMappings.keys, [shape.shapeId]);
      final warn = lines.where((l) => l.contains('settings.invalid')).toList();
      expect(warn, [endsWith('settings.invalid {"key":"csvmap"}')]);
      final text = lines.join('\n');
      for (final p in ['Synth secret label', 'Synth bank', 'Datum', '00000000000000aa', shape.shapeId]) {
        expect(text, isNot(contains(p)), reason: p);
      }
    });

    test('toMap / fromMap keep the layouts', () {
      repo.setCsvMapping(shape.shapeId, mapping);
      final s = repo.settings();
      final back = WalletSettings.fromMap(s.toMap());
      expect(back.csvMappings, s.csvMappings);
      expect(back.salary, s.salary);
    });

    test('logs carry the op word only', () {
      final lines = _captureLogs();
      repo.setCsvMapping(shape.shapeId, mapping);
      repo.setCsvMapping(shape.shapeId, mapping.copyWith(name: 'Other'));
      repo.removeCsvMapping(shape.shapeId);
      final ours = lines.where((l) => l.contains('settings.csvMapping')).toList();
      expect(ours, [endsWith('{"op":"add"}'), endsWith('{"op":"set"}'), endsWith('{"op":"remove"}')]);
      final text = lines.join('\n');
      for (final p in ['Synth bank', 'Other', 'Datum', shape.shapeId]) {
        expect(text, isNot(contains(p)), reason: p);
      }
    });
  });

  group('accounts and imports', () {
    test('addAccount takes csv:<shapeId> with a live layout, labelled with its name', () async {
      final source = '$csvSourcePrefix${shape.shapeId}';
      expect(() => repo.addAccount(name: 'A', source: source, currency: 'EUR', opening: 0, openingDate: '2026-01-01'), throwsArgumentError,
          reason: 'no layout saved yet');
      repo.setCsvMapping(shape.shapeId, mapping);
      final id = await repo.addAccount(name: 'Synth account', source: source, currency: 'EUR', opening: 1000, openingDate: '2026-01-01');
      expect(repo.accounts().single.id, id);
      expect(repo.accounts().single.source, source);
      expect(accountSourceLabel(source, csvMappings: repo.settings().csvMappings), 'Synth bank (CSV)');
      expect(accountSourceLabel(source), 'CSV file');
      expect(accountSourceLabel(null), 'Cash');
      expect(accountSourceLabel('pbz'), bankProfiles.firstWhere((p) => p.id == 'pbz').label);
      expect(() => repo.addAccount(name: 'B', source: 'csv:', currency: 'EUR', opening: 0, openingDate: '2026-01-01'), throwsArgumentError);
      expect(() => repo.addAccount(name: 'B', source: 'csv:0000000000000000', currency: 'EUR', opening: 0, openingDate: '2026-01-01'),
          throwsArgumentError);
      expect(() => repo.addAccount(name: 'B', source: source, currency: 'EUR', opening: 0, openingDate: '2026-01-01'), throwsArgumentError,
          reason: 'one live account per (source, currency)');
      // The layout removed: no new account for it; the existing one stays, its rows keep counting.
      repo.removeCsvMapping(shape.shapeId);
      expect(() => repo.addAccount(name: 'C', source: source, currency: 'USD', opening: 0, openingDate: '2026-01-01'), throwsArgumentError);
      expect(repo.accounts(), hasLength(1));
    });

    test('a mapped batch imports through importBatch; a re-import adds nothing; the account balance counts it', () async {
      final lines = _captureLogs();
      repo.setCsvMapping(shape.shapeId, mapping);
      final source = '$csvSourcePrefix${shape.shapeId}';
      await repo.addAccount(name: 'Synth account', source: source, currency: 'EUR', opening: 10000, openingDate: '2026-01-01');
      final batch = parseMappedCsv(_file, repo.settings().csvMappings[shape.shapeId]!);
      final s1 = repo.importBatch(batch);
      expect((s1.added, s1.duplicates), (2, 0));
      expect(repo.transactions().map((t) => t.source).toSet(), {source});
      expect(repo.transactions().map((t) => t.amount).toList()..sort(), [-1230, -350]);
      final s2 = repo.importBatch(parseMappedCsv(_file, mapping));
      expect((s2.added, s2.duplicates), (0, 2));
      final bal = accountBalances(repo.accounts(), repo.transactions()).single;
      expect(bal.balance, 10000 - 1230 - 350);
      final text = lines.join('\n');
      expect(text, contains('"source":"csv"'));
      for (final p in [shape.shapeId, 'SYNTH SHOP', 'Synth bank', 'Datum']) {
        expect(text, isNot(contains(p)), reason: p);
      }
    });
  });

  group('review fixes', () {
    test('mapped rows: money in is Extra income, money out goes by the owner patterns, else Shopping', () {
      final file = _csv('Datum;Opis;Iznos;Valuta\n'
          '05.01.2026;SYNTH EMPLOYER;1.500,00;EUR\n'
          '06.01.2026;SYNTH GROCER 12;-20,00;EUR\n'
          '07.01.2026;SYNTH THING;-5,00;EUR\n');
      final m = guessMapping(csvShape(file))!;
      repo.setMerchantPattern('Groceries', 'synth grocer');
      repo.importBatch(parseMappedCsv(file, m));
      final cz = repo.categorizer();
      final by = {for (final t in repo.transactions()) t.description: cz.categoryOf(t)};
      expect(by, {'SYNTH EMPLOYER': 'Extra income', 'SYNTH GROCER 12': 'Groceries', 'SYNTH THING': 'Shopping'});
    });

    test('a layout for another file is refused', () {
      expect(() => repo.setCsvMapping(shape.shapeId, mapping.copyWith(headers: ['A', 'B', 'C', 'D'])),
          throwsA(isA<ArgumentError>().having((e) => e.message, 'message', 'This layout was made for another file.')));
      expect(() => repo.setCsvMapping('0123456789abcdef', mapping), throwsArgumentError);
    });

    test('once used, a change to how rows are read is refused unless forced; forced, the rows go (undo-able)', () {
      repo.setCsvMapping(shape.shapeId, mapping);
      repo.importBatch(parseMappedCsv(_file, mapping));
      expect(repo.csvRowsFor(shape.shapeId), 2);
      // Free: name, currency, skip column.
      expect(repo.setCsvMapping(shape.shapeId, mapping.copyWith(name: 'New name')), isEmpty);
      expect(repo.setCsvMapping(shape.shapeId, mapping.copyWith(name: 'New name', currencyCol: null, currencyCode: 'EUR')), isEmpty);
      expect(repo.setCsvMapping(shape.shapeId, mapping.copyWith(name: 'New name', skipIfEmptyCol: 1)), isEmpty);
      final base = repo.settings().csvMappings[shape.shapeId]!;
      for (final changed in [
        base.copyWith(negate: true),
        base.copyWith(decimal: CsvDecimal.point),
        base.copyWith(descriptionCols: [1, 3]),
        base.copyWith(dateFormat: CsvDateFormat.dmyDotShort),
        base.copyWith(amountCol: null, debitCol: 2, creditCol: 3),
      ]) {
        expect(() => repo.setCsvMapping(shape.shapeId, changed),
            throwsA(isA<ArgumentError>().having((e) => e.message, 'message', startsWith('This layout was used for 2 payments'))));
      }
      expect(repo.settings().csvMappings[shape.shapeId], base);
      // Removed and set again with another reading: still refused (the removed layout is remembered).
      repo.removeCsvMapping(shape.shapeId);
      expect(() => repo.setCsvMapping(shape.shapeId, base.copyWith(negate: true)), throwsArgumentError);
      expect(repo.setCsvMapping(shape.shapeId, base), isEmpty, reason: 'the Undo of a removal goes through');

      final deleted = repo.setCsvMapping(shape.shapeId, base.copyWith(negate: true), force: true);
      expect(deleted, hasLength(2));
      expect(repo.csvRowsFor(shape.shapeId), 0);
      expect(repo.transactions(), isEmpty);
      // The re-import with the new reading adds the rows once (positive now), never doubled.
      final s = repo.importBatch(parseMappedCsv(_file, repo.settings().csvMappings[shape.shapeId]!));
      expect(s.added, 2);
      expect(repo.transactions().map((t) => t.amount).toList()..sort(), [350, 1230]);
      // Each deleted row can come back.
      repo.undeleteTransaction(deleted.first);
      expect(repo.transactions(), hasLength(3));
    });

    test('a forced change that reads the same ids: the re-import with revive restores each row once, never an owner delete', () {
      // Whole amounts: comma and point style read them the same, so the ids do not change.
      final file = _csv('Datum;Opis;Iznos;Valuta\n05.01.2026;SYNTH A;-12;EUR\n06.01.2026;SYNTH B;-3;EUR\n07.01.2026;SYNTH C;-7;EUR\n');
      final s = csvShape(file);
      final m = guessMapping(s)!.copyWith(name: 'Whole');
      repo.setCsvMapping(s.shapeId, m);
      repo.importBatch(parseMappedCsv(file, m));
      final c = repo.transactions().firstWhere((t) => t.description == 'SYNTH C');
      repo.deleteTransaction(c.id); // the owner's own delete
      final point = m.copyWith(decimal: m.decimal == CsvDecimal.comma ? CsvDecimal.point : CsvDecimal.comma);
      final deleted = repo.setCsvMapping(s.shapeId, point, force: true);
      expect(deleted, hasLength(2));
      expect(repo.transactions(), isEmpty);
      final batch = parseMappedCsv(file, repo.settings().csvMappings[s.shapeId]!);
      expect(batch.transactions.map((t) => t.id).toSet().containsAll(deleted), isTrue, reason: 'same ids');

      final first = repo.importBatch(batch, revive: deleted.toSet());
      expect((first.added, first.duplicates), (2, 1));
      expect(repo.transactions().map((t) => t.description).toList()..sort(), ['SYNTH A', 'SYNTH B']);
      expect(repo.transactions().map((t) => t.amount).toList()..sort(), [-1200, -300]);
      // Again with the same set: nothing more, nothing doubled; the owner's delete stays.
      final again = repo.importBatch(batch, revive: deleted.toSet());
      expect((again.added, again.duplicates), (0, 3));
      expect(repo.transactions(), hasLength(2));
      expect(repo.transactions().any((t) => t.id == c.id), isFalse);
    });

    test('without revive a deleted row stays deleted (the old rule)', () {
      final file = _csv('Datum;Opis;Iznos;Valuta\n05.01.2026;SYNTH A;-12;EUR\n');
      final m = guessMapping(csvShape(file))!;
      repo.importBatch(parseMappedCsv(file, m));
      final id = repo.transactions().single.id;
      repo.deleteTransaction(id);
      expect(repo.importBatch(parseMappedCsv(file, m)).added, 0);
      expect(repo.transactions(), isEmpty);
      expect(repo.importBatch(parseMappedCsv(file, m), revive: {'other'}).added, 0);
      expect(repo.transactions(), isEmpty);
    });
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    var now = _now;
    final devices = <Device>[];

    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
      devices.add(d);
      return d;
    }

    Future<void> round() async {
      for (final d in devices) {
        now += 1000;
        d.deliver(net, Random(1));
        await d.run();
        d.upload(net);
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-csvmap-');
      key = VaultKey.generate();
      net = Net();
      devices.clear();
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      tmp.deleteSync(recursive: true);
    });

    test('a layout saved on one device imports the same file the same way on the other; rename and removal sync', () async {
      final a = device('a'), b = device('b');
      a.repo.setCsvMapping(shape.shapeId, mapping);
      a.repo.importBatch(parseMappedCsv(_file, mapping));
      await round();
      await round();
      final onB = b.repo.settings().csvMappings[shape.shapeId];
      expect(onB, mapping);

      // The second device imports the same file with the synced layout: the same ids, nothing new.
      final sB = b.repo.importBatch(parseMappedCsv(_file, onB!));
      expect((sB.added, sB.duplicates), (0, 2));
      expect(b.repo.transactions().map((t) => t.id).toSet(), a.repo.transactions().map((t) => t.id).toSet());

      now += 1000;
      b.repo.setCsvMapping(shape.shapeId, mapping.copyWith(name: 'Renamed on b'));
      await round();
      await round();
      expect(a.repo.settings().csvMappings[shape.shapeId]!.name, 'Renamed on b');

      now += 1000;
      a.repo.removeCsvMapping(shape.shapeId);
      await round();
      await round();
      expect(a.repo.settings().csvMappings, isEmpty);
      expect(b.repo.settings().csvMappings, isEmpty);
      expect(b.repo.transactions(), hasLength(2), reason: 'rows imported with it stay');
    });
  });
}
