// F2 (field refactor rollout, docs/context/FIELDS_PLAN.md): the wire. The expected ops are LITERAL data written from the
// e58bc99 code paths (updateIou / updatePlanned / updateRecurring …), not from the new code: entity, id, field names,
// values and field order, one op per edit. Both the old surface (named params, clear flags) and repo.patch with the
// entity's Cols must give them. All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/src/schema.dart' show entitySchema;
import 'package:wallet_core/wallet_core.dart';

const _now = 1791590400000; // 2026-10-10 00:00 UTC

typedef _Setup = String Function(WalletRepo r);
typedef _Edit = Object? Function(WalletRepo r, String id);

class _Case {
  final String name;
  final _Setup setup;
  final _Edit viaOld, viaPatch;
  final Map<String, Object?> wire;
  const _Case(this.name, this.setup, this.viaOld, this.viaPatch, this.wire);
}

Matcher _refused(String message) => throwsA(isA<ArgumentError>().having((e) => e.message, 'message', message));

// ---- setups: each gives the row values to change and to clear ----

String _iou(WalletRepo r) =>
    r.addIou(person: 'Sam', direction: IouDirection.lent, amount: 3000, currency: 'EUR', date: '2026-10-01', note: 'first');

String _linkedIou(WalletRepo r) {
  final cash = r.addTransaction(date: '2026-10-01', amount: 3000, category: 'To people', note: 'synthetic');
  return r.addIou(person: 'Sam', direction: IouDirection.lent, amount: 3000, currency: 'EUR', date: '2026-10-01', tx: cash);
}

String _planned(WalletRepo r) => r.addPlanned(title: 'Dentist', date: '2026-11-05', amount: 5000, category: 'Health');

String _recurring(WalletRepo r) => r.addRecurring(
    label: 'Gym',
    category: 'Shopping',
    amount: 5000,
    minAmount: 4000,
    maxAmount: 6000,
    intervalDays: 30,
    firstDue: '2026-11-20',
    payee: 'synthetic gym',
    instalments: 6);

final _cases = <_Case>[
  // ---- iou ----
  _Case('iou person', _iou, (r, id) => r.updateIou(id, person: 'Ana'), (r, id) => r.patch('iou', id, {IouCols.person: 'Ana'}),
      {'person': 'Ana'}),
  _Case('iou person trimmed', _iou, (r, id) => r.updateIou(id, person: '  Ana '), (r, id) => r.patch('iou', id, {IouCols.person: '  Ana '}),
      {'person': 'Ana'}),
  _Case('iou direction', _iou, (r, id) => r.updateIou(id, direction: IouDirection.borrowed),
      (r, id) => r.patch('iou', id, {IouCols.direction: IouDirection.borrowed}), {'direction': 'borrowed'}),
  _Case('iou amount', _iou, (r, id) => r.updateIou(id, amount: 4500), (r, id) => r.patch('iou', id, {IouCols.amount: 4500}),
      {'amount': 4500}),
  _Case('iou currency', _iou, (r, id) => r.updateIou(id, currency: 'USD'), (r, id) => r.patch('iou', id, {IouCols.currency: 'USD'}),
      {'currency': 'USD'}),
  _Case('iou date', _iou, (r, id) => r.updateIou(id, date: '2026-09-30'), (r, id) => r.patch('iou', id, {IouCols.date: '2026-09-30'}),
      {'date': '2026-09-30'}),
  _Case('iou note set', _iou, (r, id) => r.updateIou(id, note: 'second'), (r, id) => r.patch('iou', id, {IouCols.note: 'second'}),
      {'note': 'second'}),
  _Case('iou note cleared', _iou, (r, id) => r.updateIou(id, clearNote: true), (r, id) => r.patch('iou', id, {IouCols.note: clearValue}),
      {'note': null}),
  _Case('iou blank note clears it', _iou, (r, id) => r.updateIou(id, note: '  '), (r, id) => r.patch('iou', id, {IouCols.note: '  '}),
      {'note': null}),
  _Case('iou link cleared', _linkedIou, (r, id) => r.updateIou(id, clearTx: true), (r, id) => r.patch('iou', id, {IouCols.tx: clearValue}),
      {'tx': null}),
  _Case(
      'iou several fields: code order, unchanged ones left out',
      _iou,
      (r, id) => r.updateIou(id, note: 'x', amount: 3100, person: 'Sam', date: '2026-09-29'),
      (r, id) => r.patch('iou', id, {IouCols.note: 'x', IouCols.amount: 3100, IouCols.person: 'Sam', IouCols.date: '2026-09-29'}),
      {'amount': 3100, 'date': '2026-09-29', 'note': 'x'}),
  // ---- planned ----
  _Case('planned title', _planned, (r, id) => r.updatePlanned(id, title: 'Vet'),
      (r, id) => r.patch('planned', id, {PlannedCols.title: 'Vet'}), {'title': 'Vet'}),
  _Case('planned unchanged title is still written', _planned, (r, id) => r.updatePlanned(id, title: 'Dentist'),
      (r, id) => r.patch('planned', id, {PlannedCols.title: 'Dentist'}), {'title': 'Dentist'}),
  _Case('planned date', _planned, (r, id) => r.updatePlanned(id, date: '2026-12-01'),
      (r, id) => r.patch('planned', id, {PlannedCols.date: '2026-12-01'}), {'date': '2026-12-01'}),
  _Case('planned amount', _planned, (r, id) => r.updatePlanned(id, amount: 6000),
      (r, id) => r.patch('planned', id, {PlannedCols.amount: 6000}), {'amount': 6000}),
  _Case('planned amount cleared', _planned, (r, id) => r.updatePlanned(id, clearAmount: true),
      (r, id) => r.patch('planned', id, {PlannedCols.amount: clearValue}), {'amount': null}),
  _Case('planned category', _planned, (r, id) => r.updatePlanned(id, category: 'Rent'),
      (r, id) => r.patch('planned', id, {PlannedCols.category: 'Rent'}), {'category': 'Rent'}),
  _Case('planned category cleared', _planned, (r, id) => r.updatePlanned(id, clearCategory: true),
      (r, id) => r.patch('planned', id, {PlannedCols.category: clearValue}), {'category': null}),
  _Case(
      'planned all four',
      _planned,
      (r, id) => r.updatePlanned(id, category: 'Rent', amount: 7000, date: '2026-12-02', title: 'Vet'),
      (r, id) => r.patch('planned', id,
          {PlannedCols.title: 'Vet', PlannedCols.date: '2026-12-02', PlannedCols.amount: 7000, PlannedCols.category: 'Rent'}),
      {'title': 'Vet', 'date': '2026-12-02', 'amount': 7000, 'category': 'Rent'}),
  // ---- recurring ----
  _Case('recurring label', _recurring, (r, id) => r.updateRecurring(id, label: ' Pool '),
      (r, id) => r.patch('recurring', id, {RecurringCols.label: ' Pool '}), {'label': 'Pool'}),
  _Case('recurring category (own category already set)', _recurring, (r, id) => r.updateRecurring(id, category: 'Rent'),
      (r, id) => r.patch('recurring', id, {RecurringCols.category: 'Rent'}), {'category': 'Rent'}),
  _Case('recurring amount', _recurring, (r, id) => r.updateRecurring(id, amount: 5500),
      (r, id) => r.patch('recurring', id, {RecurringCols.expectedAmount: 5500}), {'expected_amount': 5500}),
  _Case('recurring range: both ends travel together', _recurring, (r, id) => r.updateRecurring(id, minAmount: 4500),
      (r, id) => r.patch('recurring', id, {RecurringCols.minAmount: 4500}), {'min_amount': 4500, 'max_amount': 6000}),
  _Case(
      'recurring range cleared',
      _recurring,
      (r, id) => r.updateRecurring(id, clearRange: true, minAmount: 1),
      (r, id) => r.patch('recurring', id, {RecurringCols.minAmount: clearValue, RecurringCols.maxAmount: clearValue}),
      {'min_amount': null, 'max_amount': null}),
  _Case('recurring interval', _recurring, (r, id) => r.updateRecurring(id, intervalDays: 14),
      (r, id) => r.patch('recurring', id, {RecurringCols.intervalDays: 14}), {'interval_days': 14}),
  _Case('recurring next due', _recurring, (r, id) => r.updateRecurring(id, nextDue: '2026-11-25'),
      (r, id) => r.patch('recurring', id, {RecurringCols.nextDue: '2026-11-25'}), {'next_due': '2026-11-25'}),
  _Case('recurring last due date', _recurring, (r, id) => r.updateRecurring(id, endsOn: '2027-06-20'),
      (r, id) => r.patch('recurring', id, {RecurringCols.endsOn: '2027-06-20'}), {'ends_on': '2027-06-20'}),
  _Case('recurring last due date cleared', _recurring, (r, id) => r.updateRecurring(id, clearEnd: true, endsOn: '2027-06-20'),
      (r, id) => r.patch('recurring', id, {RecurringCols.endsOn: clearValue}), {'ends_on': null}),
  _Case(
      'recurring several fields: code order, unchanged ones left out',
      _recurring,
      (r, id) => r.updateRecurring(id, maxAmount: 7000, amount: 6500, intervalDays: 30, nextDue: '2026-11-21', label: 'Pool'),
      (r, id) => r.patch('recurring', id, {
            RecurringCols.maxAmount: 7000,
            RecurringCols.expectedAmount: 6500,
            RecurringCols.intervalDays: 30,
            RecurringCols.nextDue: '2026-11-21',
            RecurringCols.label: 'Pool',
          }),
      {'label': 'Pool', 'next_due': '2026-11-21', 'expected_amount': 6500, 'min_amount': 4000, 'max_amount': 7000}),
];

void main() {
  late WalletRepo repo;
  setUp(() => repo = WalletRepo.inMemory(now: () => _now));
  tearDown(() => repo.close());

  group('edits: the op on the wire is the one e58bc99 sent', () {
    for (final c in _cases) {
      for (final surface in ['old', 'patch']) {
        test('${c.name} via $surface', () {
          final id = c.setup(repo);
          final before = repo.pendingOps().length;
          (surface == 'patch' ? c.viaPatch : c.viaOld)(repo, id);
          final fresh = repo.pendingOps().skip(before).map((e) => e.$2).toList();
          expect(fresh, hasLength(1), reason: 'one op per edit');
          expect(fresh.single.id, id);
          expect(fresh.single.fields, c.wire);
          expect(fresh.single.fields.keys.toList(), c.wire.keys.toList(), reason: 'field order on the wire');
        });
      }
    }

    test('an edit that changes nothing writes nothing (iou, recurring)', () {
      final i = _iou(repo), b = _recurring(repo);
      final before = repo.pendingOps().length;
      repo.updateIou(i, person: 'Sam', amount: 3000);
      repo.patch('recurring', b, {RecurringCols.label: 'Gym', RecurringCols.intervalDays: 30});
      expect(repo.pendingOps().length, before);
    });
  });

  group('patch refusals keep the old messages', () {
    test('entity rules and action fields', () {
      final i = _iou(repo), p = _planned(repo), b = _recurring(repo);
      expect(() => repo.patch('iou', i, {IouCols.person: ' '}), _refused('Say who the money is with.'));
      expect(() => repo.patch('iou', i, {IouCols.person: null}), _refused('Person: Needs a value.'));
      expect(() => repo.patch('iou', i, {IouCols.amount: 0}), _refused('Enter an amount above zero.'));
      expect(() => repo.patch('iou', 'nope', {IouCols.person: 'A'}), _refused('No such IOU.'));
      expect(() => repo.patch('iou', i, {IouCols.closed: true}), _refused('Closed: changed by its own action, not edited.'));
      expect(() => repo.patch('planned', p, {PlannedCols.date: '2026-02-30'}), _refused('Bad date.'));
      expect(() => repo.patch('planned', p, {PlannedCols.amount: -1}), _refused('Bad amount.'));
      expect(() => repo.patch('planned', 'nope', {PlannedCols.title: 'x'}), _refused('No such planned cost.'));
      expect(() => repo.patch('planned', p, {PlannedCols.status: PlannedStatus.paid}),
          _refused('Status: changed by its own action, not edited.'));
      expect(() => repo.patch('recurring', b, {RecurringCols.intervalDays: 0}), _refused('A bill repeats every 1 to 400 days.'));
      expect(() => repo.patch('recurring', b, {RecurringCols.maxAmount: clearValue}), _refused('Give both ends of the amount range.'));
      expect(() => repo.patch('recurring', b, {RecurringCols.status: 'dismissed'}),
          _refused('Status: changed by its own action, not edited.'));
      expect(() => repo.patch('iou_part', 'x', {IouPartCols.amount: 1}), _refused('Changed by its own actions, not edited.'));
      expect(() => repo.updateRecurring('nope', label: 'x'), _refused('No such bill.'));
    });
  });

  group('batch 2: goal, goal_contrib, wish, rule', () {
    // [entity, id, fields] per op (lists compare deeply, records with maps do not).
    List<List<Object?>> fresh(int before) => [
          for (final o in repo.pendingOps().skip(before).map((e) => e.$2)) [o.entity, o.id, o.fields]
        ];

    test('saveGoal keeps its ops: a create, then an edit with a new total = goal fields + one contribution', () {
      var before = repo.pendingOps().length;
      final g = repo.saveGoal(name: 'Bike', target: 90000, saved: 1000, monthly: 5000, sort: 7);
      expect(fresh(before), [
        [
          'goal',
          g,
          {'name': 'Bike', 'target': 90000, 'saved': 1000, 'monthly': 5000, 'sort': 7, 'deleted': 0}
        ],
      ]);
      before = repo.pendingOps().length;
      repo.saveGoal(id: g, name: 'Bike', target: 95000, saved: 1500, monthly: 5000, sort: 7);
      final ops = fresh(before);
      expect(ops.first, [
        'goal',
        g,
        {'name': 'Bike', 'target': 95000, 'monthly': 5000, 'sort': 7, 'deleted': 0}
      ]);
      expect(ops.last[0], 'goal_contrib');
      expect((ops.last[2] as Map).keys.toList(), ['goal_id', 'amount', 'date', 'deleted']);
      expect([(ops.last[2] as Map)['goal_id'], (ops.last[2] as Map)['amount'], (ops.last[2] as Map)['deleted']], [g, 500, 0]);
    });

    test('addWish and decideWish keep their ops', () {
      var before = repo.pendingOps().length;
      final w = repo.addWish('Lamp', 4999);
      final add = fresh(before).single, af = add[2] as Map;
      expect(af.keys.toList(), ['name', 'price', 'added', 'status', 'deleted']);
      expect([add[0], af['name'], af['price'], af['status'], af['deleted']], ['wish', 'Lamp', 4999, 'waiting', 0]);
      before = repo.pendingOps().length;
      repo.decideWish(w, 'skipped');
      final d = fresh(before).single, df = d[2] as Map;
      expect([
        d[0],
        d[1],
        df.keys.toList(),
        df['status']
      ], [
        'wish',
        w,
        ['status', 'decided'],
        'skipped'
      ]);
    });

    test('patch edits a goal or wish field as one op, in the map order', () {
      final g = repo.saveGoal(name: 'Bike', target: 90000, saved: 0, monthly: 5000, sort: 7);
      final w = repo.addWish('Lamp', 4999);
      final before = repo.pendingOps().length;
      repo.patch('goal', g, {GoalCols.monthly: 6000, GoalCols.name: 'E-bike', GoalCols.target: 100000, GoalCols.sort: 2});
      repo.patch('wish', w, {WishCols.price: 3999, WishCols.name: 'Desk lamp'});
      expect(fresh(before), [
        [
          'goal',
          g,
          {'monthly': 6000, 'name': 'E-bike', 'target': 100000, 'sort': 2}
        ],
        [
          'wish',
          w,
          {'price': 3999, 'name': 'Desk lamp'}
        ],
      ]);
      expect(repo.goals().single.name, 'E-bike');
      expect(repo.wishlist().single.price, 3999);
    });

    test('patch refuses the action-only columns and entities', () {
      final g = repo.saveGoal(name: 'Bike', target: 90000, saved: 0, monthly: 5000, sort: 7);
      final w = repo.addWish('Lamp', 4999);
      expect(() => repo.patch('goal', g, {GoalCols.saved: 5}), _refused('Saved: changed by its own action, not edited.'));
      expect(() => repo.patch('wish', w, {WishCols.status: 'bought'}), _refused('Status: changed by its own action, not edited.'));
      expect(() => repo.patch('goal', g, {GoalCols.monthly: WalletSettings.maxAmount + 1}), _refused('Monthly: Over the allowed amount.'));
      expect(() => repo.patch('goal_contrib', 'c', {GoalContribCols.amount: 1}), _refused('Changed by its own actions, not edited.'));
      expect(() => repo.patch('rule', 'x', {RuleCols.category: 'Rent'}), _refused('Changed by its own actions, not edited.'));
      expect(() => repo.patch('goal', 'nope', {GoalCols.name: 'x'}), _refused('No such row.'));
    });

    test('rows read through the holders as before', () {
      expect(Goal.fromRow({'id': 'g', 'name': null, 'target': 'x'}).name, 'Goal');
      expect(Goal.fromRow({'id': 'g', 'target': 'x', 'saved': -5}).target, 0);
      expect(Goal.fromRow({'id': 'g', 'saved': -5}).saved, -5);
      expect(WishItem.fromRow({'id': 'w', 'status': null}).status, 'waiting');
      expect(GoalContribution.fromRow({'id': 'c', 'amount': -300, 'created': 'h'}).created, 'h');
    });
  });

  group('batch 3: category and tag (whole duplicate group); holder-only entities', () {
    Future<List<Object?>> one(Future<void> Function() edit) async {
      final before = repo.pendingOps().length;
      await edit();
      final o = repo.pendingOps().skip(before).map((e) => e.$2).single;
      return [o.entity, o.id, o.fields, o.fields.keys.toList()];
    }

    for (final surface in ['old', 'patch']) {
      test('category edits via $surface', () async {
        final k = await repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
        final p = surface == 'patch';
        Future<void> edit({String? name, int? position, bool? hidden, String id = ''}) async => p
            ? repo.patch('category', id.isEmpty ? k : id, {
                if (name != null) CategoryCols.name: name,
                if (position != null) CategoryCols.position: position,
                if (hidden != null) CategoryCols.hidden: hidden,
              })
            : repo.updateCategory(id.isEmpty ? k : id, name: name, position: position, hidden: hidden);
        expect(await one(() => edit(name: ' Animals ')), [
          'category',
          k,
          {'name': 'Animals'},
          ['name']
        ]);
        expect(await one(() => edit(position: 3)), [
          'category',
          k,
          {'position': 3},
          ['position']
        ]);
        expect(await one(() => edit(hidden: true)), [
          'category',
          k,
          {'hidden': 1},
          ['hidden']
        ]);
        expect(await one(() => edit(hidden: false, position: 0, name: 'Pets')), [
          'category', k, {'name': 'Pets', 'position': 0, 'hidden': 0}, ['name', 'position', 'hidden'] //
        ]);
        expect(await one(() => edit(id: 'Groceries', hidden: true)), [
          'category',
          'Groceries',
          {'hidden': 1},
          ['hidden']
        ]);
      });

      test('tag edits via $surface', () async {
        final t = await repo.addTag('Trip');
        final p = surface == 'patch';
        Future<void> edit({String? name, int? position, bool? hidden}) async => p
            ? repo.patch('tag', t, {
                if (name != null) TagCols.name: name,
                if (position != null) TagCols.position: position,
                if (hidden != null) TagCols.hidden: hidden,
              })
            : repo.updateTag(t, name: name, position: position, hidden: hidden);
        expect(await one(() => edit(name: 'Holiday')), [
          'tag',
          t,
          {'name': 'Holiday'},
          ['name']
        ]);
        expect(await one(() => edit(hidden: true, position: 4)), [
          'tag',
          t,
          {'position': 4, 'hidden': 1},
          ['position', 'hidden']
        ]);
      });
    }

    test('refusals keep the old messages; holder-only entities are not edited by patch', () async {
      final k = await repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final t = await repo.addTag('Trip');
      await expectLater(repo.updateCategory(k, parent: 'Groceries'), _refused('Use a tag for this.'));
      expect(() => repo.patch('category', k, {CategoryCols.parent: 'Groceries'}), _refused('Use a tag for this.'));
      expect(() => repo.patch('category', k, {CategoryCols.position: -1}), _refused('Bad position.'));
      expect(() => repo.patch('category', 'k000000000000', {CategoryCols.name: 'x'}), _refused('No such category.'));
      expect(
          () => repo.patch('category', k, {CategoryCols.kind: BudgetKind.fixed}), _refused('Kind: changed by its own action, not edited.'));
      expect(() => repo.patch('tag', t, {TagCols.position: -1}), _refused('Bad position.'));
      expect(() => repo.patch('tag', 'tnope', {TagCols.name: 'x'}), _refused('No such tag.'));
      for (final (e, c) in <(String, Col)>[
        ('txtag', TxTagCols.state),
        ('ruletag', RuleTagCols.deleted),
        ('split', SplitCols.parts),
        ('review', ReviewCols.done),
        ('payee_alias', PayeeAliasCols.payee),
      ]) {
        expect(() => repo.patch(e, 'x', {c: null}), _refused('Changed by its own actions, not edited.'), reason: e);
      }
      final before = repo.pendingOps().length;
      await repo.updateCategory(k, clearParent: true);
      expect(repo.pendingOps().length, before, reason: 'clearParent writes nothing');
    });

    test('rows read through the holders as before', () {
      final c = CategoryRow.fromRow({'id': 'k1', 'name': 7, 'kind': 'nope', 'parent': '', 'position': 'x', 'hidden': 1});
      expect([c.name, c.kind, c.parent, c.position, c.hidden, c.deleted], ['', null, null, null, true, false]);
      expect(CategoryRow.fromRow({'id': 'k1', 'kind': 'fixed', 'parent': 'Rent', 'position': 2}).parent, 'Rent');
      final r = TagRow.fromRow({'id': 't1', 'name': 'A', 'position': 5, 'deleted': 1});
      expect([r.name, r.position, r.hidden, r.deleted], ['A', 5, false, true]);
    });
  });

  group('holders declare the schema', () {
    final holders = <String, List<Col>>{
      'iou': IouCols.all,
      'iou_part': IouPartCols.all,
      'planned': PlannedCols.all,
      'recurring': RecurringCols.all,
      'goal': GoalCols.all,
      'goal_contrib': GoalContribCols.all,
      'wish': WishCols.all,
      'rule': RuleCols.all,
      'category': CategoryCols.all,
      'tag': TagCols.all,
      'txtag': TxTagCols.all,
      'ruletag': RuleTagCols.all,
      'split': SplitCols.all,
      'review': ReviewCols.all,
      'payee_alias': PayeeAliasCols.all,
    };
    for (final h in holders.entries) {
      test('${h.key}: entitySchema uses ${h.key} Cols.all, each with a label', () {
        expect(entitySchema[h.key]!.columns, same(h.value));
        expect({for (final c in h.value) c.entity}, {h.key});
        for (final c in h.value) {
          expect(c.label, isNotEmpty, reason: c.column);
        }
      });
    }
  });
}
