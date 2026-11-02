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

  group('holders declare the schema', () {
    final holders = <String, List<Col>>{
      'iou': IouCols.all,
      'iou_part': IouPartCols.all,
      'planned': PlannedCols.all,
      'recurring': RecurringCols.all,
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
