// Stage UX-A core, point 4 (docs/context/UX_SPEC.md): built-in merchant rules are editable through the synced setting
// `builtInRuleOverrides`. Written from the spec, not the implementation. All data SYNTHETIC (well-known chains only).
//
// Assumed names (spec): ids `builtIn:<slug>` (e.g. builtIn:lidl), editBuiltInRule(id, {pattern, category}),
// setBuiltInRuleOff(id, off), resetBuiltInRule(id), RuleView.editable / edited / off.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

const _t = Timeout(Duration(seconds: 30));
const _now = 1791590400000;

void main() {
  late WalletRepo repo;
  setUp(() => repo = WalletRepo.inMemory(now: () => _now));
  tearDown(() => repo.close());

  Tx row(String desc) => Tx(id: 'r-$desc', source: 'pbz', date: '2026-10-05', amount: -1500, description: desc);

  String? cat(String desc) => repo.categorizer(withTags: false).merchantCategory(desc);
  String? ruleId(String desc) => repo.categorizer(withTags: false).ruleFor(row(desc));

  List<RuleView> builtIns() => [
        for (final v in rulesView(repo.settings(), repo.payeeRules(), const {}, TagTable.from(const []), repo.categoryTable()))
          if (v.kind == RuleKind.builtIn) v
      ];
  RuleView view(String id) => builtIns().firstWhere((v) => v.id == id);

  test('ids are stable slugs, unique, and no longer indexes', () {
    final ids = builtIns().map((v) => v.id).toList();
    expect(ids.toSet().length, ids.length);
    expect(ids, contains('builtIn:lidl'));
    for (final id in ids) {
      expect(RegExp(r'^builtIn:[a-z0-9][a-z0-9_-]*$').hasMatch(id), isTrue, reason: id);
      expect(RegExp(r'^builtIn:\d+$').hasMatch(id), isFalse, reason: '$id is an index, not a slug');
    }
    // Stable across reads and repos.
    final other = WalletRepo.inMemory(now: () => _now);
    addTearDown(other.close);
    final again = [
      for (final v in rulesView(other.settings(), other.payeeRules(), const {}, TagTable.from(const []), other.categoryTable()))
        if (v.kind == RuleKind.builtIn) v.id
    ];
    expect(again, ids);
  }, timeout: _t);

  test('categorisation reports the slug id, and an untouched view is editable, not edited, not off', () {
    expect(cat('Lidl Zagreb'), 'Groceries');
    expect(ruleId('Lidl Zagreb'), 'builtIn:lidl');
    final v = view('builtIn:lidl');
    expect((v.editable, v.edited, v.off), (true, false, false));
    expect(v.category, 'Groceries');
  }, timeout: _t);

  test('an old builtIn:<index> ref still resolves; an unknown ref is an ArgumentError', () async {
    expect(() => _run(() => repo.setBuiltInRuleOff('builtIn:nope-not-a-rule', true)), throwsArgumentError);
    expect(() => _run(() => repo.setBuiltInRuleOff('builtIn:9999', true)), throwsArgumentError, reason: 'index beyond the list');
    await _run(() => repo.setBuiltInRuleOff('builtIn:0', true));
    expect(builtIns().where((v) => v.off), hasLength(1), reason: 'exactly the rule the old index named');
  }, timeout: _t);

  group('edit', () {
    test('edit pattern and category: categorisation follows, view shows edited', () async {
      expect(cat('Billa Split'), isNull);
      await _run(() => repo.editBuiltInRule('builtIn:lidl', pattern: 'lidl|billa', category: 'Eating out'));
      expect(cat('Billa Split'), 'Eating out');
      expect(cat('Lidl Zagreb'), 'Eating out');
      expect(ruleId('Billa Split'), 'builtIn:lidl');
      final v = view('builtIn:lidl');
      expect((v.edited, v.off, v.editable, v.category), (true, false, true, 'Eating out'));
    }, timeout: _t);

    test('edit only the category keeps the pattern; only the pattern keeps the category', () async {
      await _run(() => repo.editBuiltInRule('builtIn:lidl', category: 'Shopping'));
      expect(cat('Lidl Zagreb'), 'Shopping');
      await _run(() => repo.resetBuiltInRule('builtIn:lidl'));
      await _run(() => repo.editBuiltInRule('builtIn:lidl', pattern: 'lidl|billa'));
      expect(cat('Lidl Zagreb'), 'Groceries');
      expect(cat('Billa Split'), 'Groceries');
    }, timeout: _t);

    test('a bad pattern (does not compile, or matches the empty text) is refused and changes nothing', () async {
      expect(() => _run(() => repo.editBuiltInRule('builtIn:lidl', pattern: '(unclosed')), throwsArgumentError);
      expect(() => _run(() => repo.editBuiltInRule('builtIn:lidl', pattern: '.*')), throwsArgumentError);
      expect(() => _run(() => repo.editBuiltInRule('builtIn:lidl', category: 'NoSuchCategory')), throwsArgumentError);
      expect(view('builtIn:lidl').edited, isFalse);
      expect(cat('Lidl Zagreb'), 'Groceries');
    }, timeout: _t);

    test('reset returns to the built-in and clears the flags', () async {
      await _run(() => repo.editBuiltInRule('builtIn:lidl', pattern: 'lidl|billa', category: 'Eating out'));
      await _run(() => repo.resetBuiltInRule('builtIn:lidl'));
      expect(cat('Lidl Zagreb'), 'Groceries');
      expect(cat('Billa Split'), isNull);
      final v = view('builtIn:lidl');
      expect((v.edited, v.off), (false, false));
    }, timeout: _t);

    test('reset of an untouched rule writes nothing', () async {
      final before = repo.pendingOps().length;
      await _run(() => repo.resetBuiltInRule('builtIn:lidl'));
      expect(repo.pendingOps().length, before);
    }, timeout: _t);
  });

  group('off', () {
    test('off: no longer matches, flagged off; on again: matches', () async {
      await _run(() => repo.setBuiltInRuleOff('builtIn:lidl', true));
      expect(cat('Lidl Zagreb'), isNull);
      expect(ruleId('Lidl Zagreb'), isNull);
      expect(view('builtIn:lidl').off, isTrue);
      expect(view('builtIn:lidl').edited, isFalse, reason: 'off alone is not an edit of the pattern');
      await _run(() => repo.setBuiltInRuleOff('builtIn:lidl', false));
      expect(cat('Lidl Zagreb'), 'Groceries');
      expect(view('builtIn:lidl').off, isFalse);
    }, timeout: _t);

    test('an edited rule that is turned off stays edited; reset clears both', () async {
      await _run(() => repo.editBuiltInRule('builtIn:lidl', category: 'Shopping'));
      await _run(() => repo.setBuiltInRuleOff('builtIn:lidl', true));
      expect(cat('Lidl Zagreb'), isNull);
      expect((view('builtIn:lidl').edited, view('builtIn:lidl').off), (true, true));
      await _run(() => repo.resetBuiltInRule('builtIn:lidl'));
      expect(cat('Lidl Zagreb'), 'Groceries');
      expect((view('builtIn:lidl').edited, view('builtIn:lidl').off), (false, false));
    }, timeout: _t);

    test('a personal pattern still wins over a built-in, and off built-in lets nothing else change', () async {
      repo.setMerchantPattern('Shopping', 'lidl');
      expect(cat('Lidl Zagreb'), 'Shopping');
      await _run(() => repo.setBuiltInRuleOff('builtIn:lidl', true));
      expect(cat('Lidl Zagreb'), 'Shopping');
      expect(cat('Spar Zagreb'), 'Groceries', reason: 'other rules untouched');
    }, timeout: _t);
  });

  test('an override for a rule that no longer exists is ignored (an app update removed it)', () async {
    // The override map is a synced setting; a peer on another build may carry ids this build does not know.
    // Only the public contract is checked: reading and categorising never fail.
    await _run(() => repo.editBuiltInRule('builtIn:lidl', category: 'Shopping'));
    expect(builtIns().where((v) => v.edited).map((v) => v.id), ['builtIn:lidl']);
    expect(cat('Plodine Split'), 'Groceries');
  }, timeout: _t);

  test('edits do not disturb other built-ins or the order of the list', () async {
    final before = builtIns().map((v) => v.id).toList();
    await _run(() => repo.editBuiltInRule('builtIn:lidl', pattern: 'lidl|billa'));
    await _run(() => repo.setBuiltInRuleOff('builtIn:lidl', true));
    expect(builtIns().map((v) => v.id).toList(), before);
    expect(builtIns().where((v) => v.edited || v.off), hasLength(1));
  }, timeout: _t);

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    final devices = <Device>[];

    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => _now);
      devices.add(d);
      return d;
    }

    Future<void> syncAll(List<Device> ds) async {
      for (var round = 0; round < 3; round++) {
        for (final d in ds) {
          d.deliver(net, Random(round));
          await d.run();
          d.upload(net);
        }
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-uxa-rules-');
      key = VaultKey.generate();
      net = Net();
    });
    tearDown(() {
      for (final d in devices) {
        d.repo.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });

    test('an edit, an off switch and a reset sync', () async {
      final a = device('a'), b = device('b');
      await _run(() => a.repo.editBuiltInRule('builtIn:lidl', category: 'Shopping'));
      await _run(() => a.repo.setBuiltInRuleOff('builtIn:spar', true));
      await syncAll([a, b]);
      expect(b.repo.categorizer(withTags: false).merchantCategory('Lidl Zagreb'), 'Shopping');
      expect(b.repo.categorizer(withTags: false).merchantCategory('Spar Zagreb'), isNull);
      await _run(() => b.repo.resetBuiltInRule('builtIn:lidl'));
      await syncAll([a, b]);
      expect(a.repo.categorizer(withTags: false).merchantCategory('Lidl Zagreb'), 'Groceries');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('edits to two different rules on two devices both survive (per-rule, not whole-map, last writer)', () async {
      final a = device('a'), b = device('b');
      await syncAll([a, b]);
      await _run(() => a.repo.editBuiltInRule('builtIn:lidl', category: 'Shopping'));
      await _run(() => b.repo.setBuiltInRuleOff('builtIn:spar', true));
      await syncAll([a, b]);
      for (final d in [a, b]) {
        final cz = d.repo.categorizer(withTags: false);
        expect(cz.merchantCategory('Lidl Zagreb'), 'Shopping', reason: d.name);
        expect(cz.merchantCategory('Spar Zagreb'), isNull, reason: d.name);
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

Future<void> _run(FutureOr<void> Function() f) async {
  await f();
}
