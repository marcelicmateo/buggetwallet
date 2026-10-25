import 'dart:math' show min;

import 'package:wallet_importer/wallet_importer.dart' show CsvMapping, TxKind;

import 'categories.dart';
import 'dates.dart';
import 'logs.dart';
import 'rules.dart' show MerchantPattern, merchantPatternId;

final _log = Logger('bw.settings');

/// (key, value) pairs already logged as `settings.invalid` in this process. A bad stored value is read on every
/// `WalletRepo.settings()` call (each screen refresh, each match run), so it is logged once, not every time.
final _invalidLogged = <String>{};

/// Logs `settings.invalid` for [key] (the key only, never [value]) the first time this key holds this value.
void logInvalidSetting(String key, Object? value) {
  if (_invalidLogged.add('$key\u0000$value')) logEvent(_log, Level.WARNING, 'settings.invalid', {'key': key});
}

/// Forgets which bad settings were logged, so tests can expect the warning again.
/// Also forgets the once-per-process `recurring.invalid` warning ([RecurringBill.fromRow]).
void resetInvalidSettingLog() {
  _invalidLogged.clear();
  _invalidRangeLogged = false;
}

/// A stored column read as text or a whole number; any other type (a damaged value) reads as null.
String? _str(Object? v) => v is String ? v : null;
int? _int(Object? v) => v is int ? v : null;

/// A stored `kind_hint` as a [TxKind]; a name this build does not know (a newer importer) reads as null.
TxKind? _kind(Object? v) => v is String ? TxKind.values.asNameMap()[v] : null;

/// A transaction as stored in the wallet database. Amounts are in minor units (cents).
class Tx {
  final String id;
  final String source; // pbz | revolut | manual
  final String date; // YYYY-MM-DD
  final int amount;
  final String currency;
  final String bankType;
  final String description;
  final String? category; // user override
  final String? note;
  final bool manual;
  final String? matchedTo; // for manual entries: the bank row that replaced it
  final bool deleted;

  /// What kind of movement the bank's export said this is (`kind_hint`, written once by the import), or null for
  /// hand-added rows, rows imported before the field existed, and kinds the profile could not tell.
  final TxKind? kindHint;

  /// For a bank row that is one side of a transfer between the owner's own accounts: the other side's id
  /// (`transfer_to`, written by `planTransfers`). Such a row is an `Internal transfer`.
  final String? transferTo;

  /// A manual entry whose [matchedTo] bank row is not on this device yet (its sync file has not arrived): the entry
  /// still counts, so the expense counts once until the row arrives. Set by `WalletRepo` reads, never stored.
  final bool matchPending;

  /// P15 hook: the bank's own amount in the wallet currency for a row in another currency, when the export carries one
  /// (no export the importer reads does yet). Not stored; always null for now. `homeAmount` prefers it over a rate.
  final int? homeAmount;

  const Tx({
    required this.id,
    required this.source,
    required this.date,
    required this.amount,
    this.currency = 'EUR',
    this.bankType = '',
    this.description = '',
    this.category,
    this.note,
    this.manual = false,
    this.matchedTo,
    this.deleted = false,
    this.kindHint,
    this.transferTo,
    this.matchPending = false,
    this.homeAmount,
  });

  /// This row in [currency] with [amount] (P15 `inHomeCurrency`); id and every other field kept, [homeAmount] dropped.
  Tx inCurrency(String currency, int amount) => Tx(
        id: id,
        source: source,
        date: date,
        amount: amount,
        currency: currency,
        bankType: bankType,
        description: description,
        category: category,
        note: note,
        manual: manual,
        matchedTo: matchedTo,
        deleted: deleted,
        kindHint: kindHint,
        transferTo: transferTo,
        matchPending: matchPending,
      );

  /// Counts toward totals: not deleted and not replaced by a bank row that is here (see [matchPending]).
  bool get live => !deleted && (matchedTo == null || matchPending);

  /// Reads a stored row. A column of the wrong type (stored by an older build before synced values were checked)
  /// reads as its default, so one damaged row never breaks a whole list.
  static Tx fromRow(Map<String, Object?> r) => Tx(
        id: r['id'] as String,
        source: _str(r['source']) ?? '',
        date: _str(r['date']) ?? '',
        amount: _int(r['amount']) ?? 0,
        currency: _str(r['currency']) ?? 'EUR',
        bankType: _str(r['bank_type']) ?? '',
        description: _str(r['description']) ?? '',
        category: _str(r['category']),
        note: _str(r['note']),
        manual: r['manual'] == 1,
        matchedTo: _str(r['matched_to']),
        deleted: r['deleted'] == 1,
        kindHint: _kind(r['kind_hint']),
        transferTo: _str(r['transfer_to']),
        matchPending: r['match_pending'] == 1,
      );
}

/// A transaction with its resolved category, or one part of a split payment (P6, `Categorizer.expand`): then [tx] is
/// still the whole payment and [amount], [category], [kind], [tags] and [partNote] are the part's.
class CategorizedTx {
  final Tx tx;
  final String category;
  final BudgetKind kind;

  /// The row's extra tags (T1, `tagsOf`): resolved tag ids in table order; empty when none. Unmodifiable. A part's are
  /// its own list only (resolved; dead tags dropped), never the payee's rule tags or the payment's links.
  final List<String> tags;

  /// The part's amount; null = the payment's ([amount]).
  final int? _amount;

  /// A part's 0-based index in its split; null when this row is the whole payment.
  final int? part;

  /// How many parts the payment's split has; 0 when this row is the whole payment.
  final int parts;

  /// A part's own note; null when it has none (and for a whole payment).
  final String? partNote;

  /// The payment has a stored split that no longer adds up or cannot be read ([splitFits]): it counts whole.
  final bool splitBroken;

  /// For a part: the whole payment's row (`Categorizer.categorize`: its own main tag, tags and amount); null otherwise.
  final CategorizedTx? whole;

  /// P15: for a row converted to the wallet currency (`inHomeCurrency`), this row's own amount (the part's for a part)
  /// and currency as the bank gave them; null for a row that was not converted.
  final int? originalAmount;
  final String? originalCurrency;

  const CategorizedTx(this.tx, this.category, this.kind,
      {this.tags = const [],
      int? amount,
      this.part,
      this.parts = 0,
      this.partNote,
      this.splitBroken = false,
      this.whole,
      this.originalAmount,
      this.originalCurrency})
      : _amount = amount;
  String get date => tx.date;

  /// What this row counts: the part's amount for a part, else the payment's ([Tx.amount]).
  int get amount => _amount ?? tx.amount;

  /// One part of a split payment ([part] is set).
  bool get isPart => part != null;

  /// This row with another [category] and/or [kind]; everything else (part fields included) kept.
  CategorizedTx withCategory(String category, [BudgetKind? kind]) => CategorizedTx(tx, category, kind ?? this.kind,
      tags: tags,
      amount: _amount,
      part: part,
      parts: parts,
      partNote: partNote,
      splitBroken: splitBroken,
      whole: whole,
      originalAmount: originalAmount,
      originalCurrency: originalCurrency);

  /// This row converted (P15): [tx] in the wallet currency, [amount] the part's converted amount (null for a whole
  /// payment), [whole] the converted whole; the original amount and currency kept. Category, kind, tags and part fields kept.
  CategorizedTx converted(Tx tx, {int? amount, CategorizedTx? whole}) => CategorizedTx(tx, category, kind,
      tags: tags,
      amount: amount,
      part: part,
      parts: parts,
      partNote: partNote,
      splitBroken: splitBroken,
      whole: whole,
      originalAmount: this.amount,
      originalCurrency: this.tx.currency);
}

/// The distinct payments of [rows] ([CategorizedTx.tx], first appearance order): an expanded list
/// (`Categorizer.expand`) holds a split payment once per part.
List<Tx> wholePayments(Iterable<CategorizedTx> rows) {
  final seen = <String>{};
  return [
    for (final t in rows)
      if (seen.add(t.tx.id)) t.tx
  ];
}

/// Compares two rows of the same payment by part (whole first): the tie-break after the tx id in sorted lists, so the
/// parts of one payment keep their stored order (List.sort is not stable).
int comparePart(CategorizedTx a, CategorizedTx b) => (a.part ?? -1).compareTo(b.part ?? -1);

class Goal {
  final String id;
  final String name;
  final int target;

  /// The saved total. From `WalletRepo.goals()` it is [goalTotal]: the stored `saved` column (the base) plus the
  /// goal's live contributions ([GoalContribution]). [fromRow] reads the stored base only.
  final int saved;
  final int monthly;
  final int sort;
  const Goal({required this.id, required this.name, this.target = 0, this.saved = 0, this.monthly = 0, this.sort = 0});

  /// Largest saved total either way, in cents: 10 billion in major units (the importer's and the app's cap).
  static const maxSaved = 1000000000000;

  /// Largest single contribution either way: enough to move between any two allowed totals in one row.
  static const maxContribution = 2 * maxSaved;

  static Goal fromRow(Map<String, Object?> r) => Goal(
        id: r['id'] as String,
        name: _str(r['name']) ?? 'Goal',
        target: _int(r['target']) ?? 0,
        saved: _int(r['saved']) ?? 0,
        monthly: _int(r['monthly']) ?? 0,
        sort: _int(r['sort']) ?? 0,
      );

  Goal withSaved(int saved) => Goal(id: id, name: name, target: target, saved: saved, monthly: monthly, sort: sort);
}

/// A goal's saved total: [base] (its stored `saved` column) plus [contributions]. Each contribution counts at most
/// [Goal.maxContribution] either way and [base] at most 2^53 (the largest synced whole number), so the sum cannot
/// overflow; the result is clamped to ±[Goal.maxSaved] unless [clamped] is false. Negative totals are allowed: two
/// offline corrections can overshoot below zero, and showing that lets the next edit set the exact value.
int goalTotal(int base, Iterable<int> contributions, {bool clamped = true}) {
  const exact = 9007199254740992; // 2^53
  var sum = base.clamp(-exact, exact);
  for (final c in contributions) {
    sum += c.clamp(-Goal.maxContribution, Goal.maxContribution);
  }
  return clamped ? sum.clamp(-Goal.maxSaved, Goal.maxSaved) : sum;
}

/// An amount added to a goal's saved total (negative for a correction), synced as its own row (`goal_contrib`), so
/// adds made on two offline devices both count. Hidden while its goal is deleted or missing.
class GoalContribution {
  final String id;
  final String goalId;
  final int amount;
  final String date; // YYYY-MM-DD

  /// The clock of the write that created it (its `amount` field), or null if this device has no clock for it.
  final String? created;
  const GoalContribution({required this.id, required this.goalId, required this.amount, required this.date, this.created});

  static GoalContribution fromRow(Map<String, Object?> r) => GoalContribution(
        id: r['id'] as String,
        goalId: _str(r['goal_id']) ?? '',
        amount: _int(r['amount']) ?? 0,
        date: _str(r['date']) ?? '',
        created: _str(r['created']),
      );
}

class WishItem {
  final String id;
  final String name;
  final int price;
  final int added; // epoch millis
  final String status; // waiting | bought | skipped
  final int? decided;
  const WishItem({required this.id, required this.name, required this.price, required this.added, this.status = 'waiting', this.decided});

  static WishItem fromRow(Map<String, Object?> r) => WishItem(
        id: r['id'] as String,
        name: _str(r['name']) ?? '',
        price: _int(r['price']) ?? 0,
        added: _int(r['added']) ?? 0,
        status: _str(r['status']) ?? 'waiting',
        decided: _int(r['decided']),
      );

  double hoursLeft(int coolHours, int nowMillis) => (added + coolHours * 3600000 - nowMillis) / 3600000;
}

/// How often a recurring bill repeats (P4): the period classes `detectRecurring` finds and the add-bill sheet offers.
/// [days] is the class's `intervalDays`.
enum RecurringPeriod {
  weekly(7),
  biweekly(14),
  monthly(30),
  quarterly(91),
  yearly(365);

  const RecurringPeriod(this.days);
  final int days;

  /// The class whose [days] are nearest to [days], when within that class's [RecurringBill.toleranceFor]; null for a
  /// custom interval (e.g. 60 days).
  static RecurringPeriod? of(int days) {
    var best = values.first;
    for (final p in values) {
      if ((p.days - days).abs() < (best.days - days).abs()) best = p;
    }
    return (best.days - days).abs() <= RecurringBill.toleranceFor(best.days) ? best : null;
  }
}

/// Whether `recurring.invalid` was logged in this process (once, field name only; see [RecurringBill.fromRow]).
var _invalidRangeLogged = false;

/// A bill that comes back on a fixed interval ([intervalDays]: weekly … yearly, P4): detected from bank rows
/// (`detectRecurring`, status `candidate`), then confirmed or dismissed by the owner, or added by hand ([manual],
/// `addRecurring`, confirmed at once). Synced entity `recurring`; a detected bill's id is `rec:<payee>` so every device
/// derives the same row for the same merchant, a manual one's `rec:m` + 12 random hex. [expectedAmount] is positive
/// cents (an outflow); [minAmount]/[maxAmount] an optional amount range ([hasRange]: the highest is set aside,
/// [reserveAmount]); [endsOn] the last due date of an instalment plan. A confirmed bill is reserved in `computePeriod`
/// until a bank row (or parts adding up) pays its cycle ([lastPaidTx], then [nextDue] moves on by [intervalDays]).
///
/// P9: with [direction] `in` ([isIncome]) the row is a recurring **income** (side job, rent received): [expectedAmount]
/// is the positive cents expected in, a range only narrows matching, there are no instalments, parts or reserves. A
/// detected income's id is `recin:<payee>` ([incomeIdFor]), so one payee can have both a bill and an income. Its
/// cycle lands when a positive row of the payee comes in (`planRecurringPayments`); `computePeriod` shows a cycle not
/// landed yet as expected ([PeriodBudget.expectedIncome]) and adds the payee's landed rows to the spending money only
/// once they are here ([PeriodBudget.landedIncome]).
class RecurringBill {
  final String id;
  final String payee; // merchantKey of the bank rows; '' for a manual bill without payee (never matches a row)
  final String label; // merchantName, for display
  final String category;
  final int expectedAmount; // cents, > 0
  final int intervalDays;
  final String nextDue; // YYYY-MM-DD
  final String status; // candidate | confirmed | dismissed
  final String? lastPaidTx; // the bank row that paid the last cycle
  final int? minAmount, maxAmount; // cents: the amount range, see [hasRange]
  final String? endsOn; // YYYY-MM-DD: the last due date (instalments)
  final bool manual; // added by hand: never touched by detection
  final bool ownCategory; // the owner chose the category: refresh never recategorizes it
  final String? direction; // null or 'out' = a bill, 'in' = an income (P9)

  const RecurringBill({
    required this.id,
    required this.payee,
    required this.label,
    required this.category,
    required this.expectedAmount,
    this.intervalDays = defaultIntervalDays,
    required this.nextDue,
    this.status = 'candidate',
    this.lastPaidTx,
    this.minAmount,
    this.maxAmount,
    this.endsOn,
    this.manual = false,
    this.ownCategory = false,
    this.direction,
  });

  /// [direction] values: a bill (also null) and an income.
  static const directionOut = 'out', directionIn = 'in';

  /// A recurring income (P9): [direction] `in`. Everything else (null, `out`, an unknown value) is a bill.
  bool get isIncome => direction == directionIn;

  /// The monthly interval, and what a stored `interval_days` outside [minIntervalDays]..[maxIntervalDays] reads as.
  static const defaultIntervalDays = 30;
  static const minIntervalDays = 1, maxIntervalDays = 400;

  static const statuses = {'candidate', 'confirmed', 'dismissed'};

  /// Prefix of an income's stored `status` (P9 review): `in:candidate`, `in:confirmed`, `in:dismissed`. A build before
  /// P9 (which drops `direction`) never treats such a row as a candidate or a confirmed bill, so it never lists,
  /// reserves, recategorizes or pays it. [fromRow] maps it back: [status] is always one of [statuses].
  static const incomeStatusPrefix = 'in:';

  /// The stored `status` for [status] (one of [statuses]) of an income ([income]) or a bill.
  static String storedStatus(String status, {required bool income}) => income ? '$incomeStatusPrefix$status' : status;

  /// The stored values of a dismissed row (bill or income), for SQL filters.
  static const dismissedStored = "'dismissed', 'in:dismissed'";

  /// The id of the bill for a payee key, the same on every device.
  static String idFor(String payee) => 'rec:$payee';

  /// The id of the detected income for a payee key (P9), the same on every device; never equal to [idFor]'s.
  static String incomeIdFor(String payee) => 'recin:$payee';

  /// Days a payment may be from its due date (and a detected gap from the class's days) for a bill repeating every
  /// [days]: ≤ 7 → 1, ≤ 14 → 2, ≤ 31 → 3 (`recurringDays`), ≤ 92 → 7, else 10.
  static int toleranceFor(int days) => days <= 7
      ? 1
      : days <= 14
          ? 2
          : days <= 31
              ? 3
              : days <= 92
                  ? 7
                  : 10;

  bool get confirmed => status == 'confirmed';

  /// Both ends of the amount range are set and valid: `0 < minAmount ≤ maxAmount ≤ WalletSettings.maxAmount`.
  bool get hasRange => validRange(minAmount, maxAmount);

  /// [hasRange]'s rule for a pair of cents.
  static bool validRange(int? lo, int? hi) => lo != null && hi != null && lo > 0 && lo <= hi && hi <= WalletSettings.maxAmount;

  /// What a cycle sets aside: the top of the range ([hasRange], owner: the highest amount), else [expectedAmount].
  int get reserveAmount => hasRange ? maxAmount! : expectedAmount;

  /// A bill that repeats less often than monthly (quarterly, yearly): held in full until paid (owner, P4). Never an
  /// income (nothing is reserved for one).
  bool get isLong => !isIncome && intervalDays > 31;

  /// A bill shorter than any month (weekly, every 2 weeks, a custom interval under 27 days): each of its occurrences in
  /// a pay period is a cycle of its own (`dueCycles`). A monthly bill has one cycle per period, as before P4.
  bool get isShort => intervalDays < defaultIntervalDays - toleranceFor(defaultIntervalDays);

  /// The last date a cycle may be due: [endsOn] + half an interval (`intervalDays ~/ 2`). A `nextDue` moved on from a
  /// late payment's date can land days after the plan's last date, while the cycle after the last one is always more
  /// than half an interval later. Null without a valid [endsOn].
  String? get endsBy => switch (endsOn) { final e? when isIsoDate(e) => addDays(e, intervalDays ~/ 2), _ => null };

  /// The due date one cycle after [from] for a skip: a monthly instalment plan (27..31 days with [endsOn]) steps calendar
  /// months on [endsOn]'s day of the month (the date with that day nearest to `from + intervalDays`, clamped to the
  /// month's end), so skipping every cycle ends exactly at [endsOn]; every other bill `from + intervalDays`.
  String stepFrom(String from) {
    final plain = addDays(from, intervalDays);
    final e = endsOn;
    if (!_monthly || e == null || !isIsoDate(e)) return plain;
    final day = dayOf(e);
    final m0 = int.parse(plain.substring(0, 4)) * 12 + int.parse(plain.substring(5, 7)) - 1;
    String at(int m) {
      final ym = '${(m ~/ 12).toString().padLeft(4, '0')}-${(m % 12 + 1).toString().padLeft(2, '0')}';
      final last = daysInMonth(ym);
      return '$ym-${(day < last ? day : last).toString().padLeft(2, '0')}';
    }

    var best = at(m0);
    for (final c in [at(m0 - 1), at(m0 + 1)]) {
      if (daysBetween(plain, c).abs() < daysBetween(plain, best).abs()) best = c;
    }
    return best;
  }

  /// The instalment plan is over: the next due date is after [endsBy] ([endsOn] + half an interval). Nothing is due or reserved any more.
  bool get finished => endsBy != null && nextDue.compareTo(endsBy!) > 0;

  /// A monthly interval (27..31 days): instalment plans then run on calendar months ([lastDueFor]).
  bool get _monthly => !isShort && !isLong;

  /// Days a payment may be from its due date ([toleranceFor] of [intervalDays]).
  int get tolerance => toleranceFor(intervalDays);

  /// Cycles from [nextDue] to [endsOn] inclusive (0 once [finished]); null without a valid [endsOn] or a due date.
  /// Counted to the nearest whole step (an average calendar month for monthly bills, as [lastDueFor] builds their plan;
  /// else [intervalDays]), so a `nextDue` a few days off the plan's dates counts the same; at least 1 until [finished].
  int? get instalmentsLeft {
    final e = endsOn;
    if (e == null || !isIsoDate(e) || !isIsoDate(nextDue)) return null;
    if (finished) return 0;
    final n = (daysBetween(nextDue, e) / (_monthly ? 365.25 / 12 : intervalDays)).round() + 1;
    return n < 1 ? 1 : n;
  }

  /// The last due date of an instalment plan of [instalments] (≥ 1) cycles from [firstDue]: for a monthly interval
  /// (27..31 days) the same day of the month (instalments − 1) months on, clamped to that month's end (2027-01-31 + 1
  /// month = 2027-02-28); else `firstDue + (instalments − 1) × intervalDays`.
  static String lastDueFor(String firstDue, int intervalDays, int instalments) {
    final n = instalments - 1;
    if (intervalDays < defaultIntervalDays - toleranceFor(defaultIntervalDays) || intervalDays > 31) {
      return addDays(firstDue, n * intervalDays);
    }
    final m = int.parse(firstDue.substring(0, 4)) * 12 + int.parse(firstDue.substring(5, 7)) - 1 + n;
    final ym = '${(m ~/ 12).toString().padLeft(4, '0')}-${(m % 12 + 1).toString().padLeft(2, '0')}';
    final day = dayOf(firstDue), last = daysInMonth(ym);
    return '$ym-${(day < last ? day : last).toString().padLeft(2, '0')}';
  }

  /// A bill in a fixed category (Rent, Loan, Bills & subscriptions) is already planned through the fixed-cost
  /// settings, so `computePeriod` lists it as due but does not reserve it a second time (owner rule: exact). A
  /// confirmed bill's `category` is kept current by `WalletRepo.refreshRecurring`, so this follows a later rule.
  /// Built-in categories only (a custom id is never covered here); code that can meet a custom category uses
  /// [coveredByPlanIn].
  bool get coveredByPlan => kindOf(category) == BudgetKind.fixed;

  /// [coveredByPlan] against [t] ([CategoryTable.coveredByPlan]): a live category whose top-level category is fixed
  /// (Rent, Loan, Bills & subscriptions or a custom fixed one with its plan line). A deleted or unknown custom id is not.
  bool coveredByPlanIn(CategoryTable t) => t.coveredByPlan(category);

  /// A stored `interval_days` outside [minIntervalDays]..[maxIntervalDays] reads as [defaultIntervalDays]; an
  /// invalid stored range is kept as stored but reads as no range ([hasRange] false; logged once per process as
  /// `recurring.invalid`, field name only).
  static RecurringBill fromRow(Map<String, Object?> r) {
    final interval = _int(r['interval_days']);
    final lo = _int(r['min_amount']), hi = _int(r['max_amount']);
    if ((lo != null || hi != null) && !validRange(lo, hi) && !_invalidRangeLogged) {
      _invalidRangeLogged = true;
      logEvent(_recurringLog, Level.WARNING, 'recurring.invalid', {'field': 'amount_range'});
    }
    return RecurringBill(
      id: r['id'] as String,
      payee: _str(r['payee']) ?? '',
      label: _str(r['label']) ?? '',
      category: _str(r['category']) ?? '',
      expectedAmount: _int(r['expected_amount']) ?? 0,
      intervalDays: interval == null || interval < minIntervalDays || interval > maxIntervalDays ? defaultIntervalDays : interval,
      nextDue: _str(r['next_due']) ?? '',
      status: switch (_str(r['status'])) {
        null => 'candidate',
        final s when s.startsWith(incomeStatusPrefix) => s.substring(incomeStatusPrefix.length),
        final s => s,
      },
      lastPaidTx: _str(r['last_paid_tx']),
      minAmount: lo,
      maxAmount: hi,
      endsOn: switch (_str(r['ends_on'])) { final e? when isIsoDate(e) => e, _ => null }, // a bad stored date = no end
      manual: _int(r['manual']) == 1,
      ownCategory: _int(r['own_category']) == 1,
      // An `in:` status marks an income even where `direction` was lost (a snapshot written by an older build).
      direction: _str(r['direction']) ?? ((_str(r['status']) ?? '').startsWith(incomeStatusPrefix) ? directionIn : null),
    );
  }

  RecurringBill copyWith({String? nextDue, String? status, String? lastPaidTx, int? expectedAmount, String? category}) => RecurringBill(
        id: id,
        payee: payee,
        label: label,
        category: category ?? this.category,
        expectedAmount: expectedAmount ?? this.expectedAmount,
        intervalDays: intervalDays,
        nextDue: nextDue ?? this.nextDue,
        status: status ?? this.status,
        lastPaidTx: lastPaidTx ?? this.lastPaidTx,
        minAmount: minAmount,
        maxAmount: maxAmount,
        endsOn: endsOn,
        manual: manual,
        ownCategory: ownCategory,
        direction: direction,
      );
}

final _recurringLog = Logger('bw.recurring');

/// [RecurringBill.instalmentsLeft] as a function.
int? instalmentsLeft(RecurringBill b) => b.instalmentsLeft;

/// One of the owner's accounts (N2, synced entity `account`, table `accounts`): a bank account ([source] = a bank
/// profile id, `pbz` / `revolut`) or cash ([source] null). [opening] (signed cents) is the balance at the end of
/// [openingDate]; `accountBalances` adds the rows after it. At most one live account per (source, currency).
class Account {
  final String id;
  final String name;
  final String? source;
  final String currency;
  final int opening;
  final String openingDate; // YYYY-MM-DD
  final bool deleted;

  const Account({
    required this.id,
    required this.name,
    this.source,
    required this.currency,
    required this.opening,
    required this.openingDate,
    this.deleted = false,
  });

  /// Longest accepted name (characters, after trimming).
  static const maxName = 60;

  bool get isCash => source == null;

  static Account fromRow(Map<String, Object?> r) => Account(
        id: r['id'] as String,
        name: _str(r['name']) ?? '',
        source: _str(r['source']),
        currency: _str(r['currency']) ?? 'EUR',
        opening: _int(r['opening']) ?? 0,
        openingDate: _str(r['opening_date']) ?? '',
        deleted: r['deleted'] == 1,
      );
}

/// Where a planned cost came from: typed by hand, a calendar event the owner gave an amount (or dismissed), or (later,
/// §4.2) a bill with a due date.
enum PlannedSource { manual, calendar, bill }

/// open: reserves money until its date has passed; paid: the owner picked the transaction that paid it ([PlannedCost.paidTx]);
/// skipped: not coming (also a dismissed calendar event).
enum PlannedStatus { open, paid, skipped }

/// A planned future cost (§4.3), synced entity `planned` (schema 6). Amounts are positive cents (a cost).
class PlannedCost {
  final String id;

  /// May be '' (a dismissed calendar event stores no title).
  final String title;
  final String date; // YYYY-MM-DD

  /// null = no confirmed amount: listed, never reserved.
  final int? amount;
  final String? category;

  /// [calendarEventRef] of the event for calendar rows (a hash, never the raw calendar or event id).
  final String? sourceRef;

  /// The transaction the owner said paid it.
  final String? paidTx;
  final PlannedSource source;
  final PlannedStatus status;

  /// Deleted rows are kept (so a calendar event never comes back) and listed only with `includeClosed`.
  final bool deleted;

  /// The planned row of a stored bill (`bill:<billId>`, kept in step by the repo's bill writes).
  bool get isBill => source == PlannedSource.bill && sourceRef != null;

  const PlannedCost({
    required this.id,
    required this.title,
    required this.date,
    this.amount,
    this.category,
    this.sourceRef,
    this.paidTx,
    this.source = PlannedSource.manual,
    this.status = PlannedStatus.open,
    this.deleted = false,
  });

  /// Open and not deleted.
  bool get isOpen => status == PlannedStatus.open && !deleted;

  /// A planned cost in a fixed category (Rent, Loan, Bills & subscriptions) is already in the payday plan's fixed
  /// amounts, so `computePeriod` lists it in `duePlanned` but does not reserve it again (exact-money rule, same as
  /// [RecurringBill.coveredByPlan]). Still listed in Upcoming and heads-ups.
  /// Built-in categories only; code that can meet a custom category uses [coveredByPlanIn].
  bool get coveredByPlan => category != null && kindOf(category!) == BudgetKind.fixed;

  /// [coveredByPlan] against [t] ([CategoryTable.coveredByPlan]). A deleted or unknown custom id is not covered.
  bool coveredByPlanIn(CategoryTable t) {
    final c = category;
    return c != null && t.coveredByPlan(c);
  }

  /// A bill's row without a category (a bill confirmed before categories were asked for, or reopened after its cash expense was deleted):
  /// only the category tells whether the payday plan already holds it, so `computePeriod` lists it in `duePlanned` but
  /// does not reserve it (never counted twice); the app shows "needs a category" and asks for one.
  bool get needsCategory => source == PlannedSource.bill && (category == null || category!.trim().isEmpty);

  /// Unknown `source`/`status` words (a newer build) read as manual/open; a damaged amount reads as null.
  static PlannedCost fromRow(Map<String, Object?> r) => PlannedCost(
        id: r['id'] as String,
        title: _str(r['title']) ?? '',
        date: _str(r['date']) ?? '',
        amount: _int(r['amount']),
        category: _str(r['category']),
        sourceRef: _str(r['source_ref']),
        paidTx: _str(r['paid_tx']),
        source: PlannedSource.values.asNameMap()[r['source']] ?? PlannedSource.manual,
        status: PlannedStatus.values.asNameMap()[r['status']] ?? PlannedStatus.open,
        deleted: r['deleted'] == 1,
      );
}

/// Display order of planned costs: date, then title, then id.
int comparePlanned(PlannedCost a, PlannedCost b) {
  var d = a.date.compareTo(b.date);
  if (d == 0) d = a.title.compareTo(b.title);
  return d != 0 ? d : a.id.compareTo(b.id);
}

/// One step of the weekly review with how many items it holds: `import` (0: the UI fills it after the import),
/// `categories` (spending rows of the last 7 days without a user-set category), `pace` (categories behind pace or
/// over), `wishlist` (items past their cooling-off still waiting).
class ReviewStep {
  final String id;
  final int count;
  const ReviewStep(this.id, this.count);
}

/// Whether the weekly review is due, from `reviewState`.
class ReviewState {
  final bool due;

  /// The review day this state is about: the one that opened the due review (≤ today) or the next one (> today).
  final String nextReviewDate;
  final int streak;
  final List<ReviewStep> steps;
  const ReviewState({required this.due, required this.nextReviewDate, required this.streak, required this.steps});

  ReviewStep? step(String id) {
    for (final s in steps) {
      if (s.id == id) return s;
    }
    return null;
  }
}

/// An owner-set exchange rate (P15, setting row `fx:<CODE>`): [rate] = wallet-currency minor units per [scale]
/// (1,000,000) minor units of the other currency, set on [date] (`YYYY-MM-DD`) against the wallet currency [home].
class FxRate {
  final int rate;
  final String date;

  /// The wallet currency the rate was set against (ISO 4217). Every stored row has one; null only in a value built by
  /// hand (then it is taken to be the wallet currency it is used with).
  final String? home;
  const FxRate(this.rate, this.date, {this.home});

  /// The divisor of [rate] and the accepted range of a rate (at most 100 home units per foreign unit).
  static const scale = 1000000, minRate = 1, maxRate = 100000000;

  /// A stored value `{"rate": int, "date": "YYYY-MM-DD", "home": "EUR"}`, or null when it is not a valid one (a row
  /// without `home` included).
  static FxRate? read(Object? v) {
    if (v is! Map) return null;
    final r = v['rate'], d = v['date'], h = v['home'];
    if (h is! String || !WalletSettings.currencyCode.hasMatch(h)) return null;
    final rate = switch (r) {
      final int x => x,
      final double x when x.isFinite && x == x.roundToDouble() && x.abs() <= maxRate => x.toInt(),
      _ => null,
    };
    if (rate == null || rate < minRate || rate > maxRate || d is! String || !isIsoDate(d)) return null;
    return FxRate(rate, d, home: h);
  }

  Map<String, Object> toJson() => {'rate': rate, 'date': date, if (home != null) 'home': home!};

  @override
  bool operator ==(Object other) => other is FxRate && other.rate == rate && other.date == date && other.home == home;

  @override
  int get hashCode => Object.hash(rate, date, home);
}

/// User settings. Money in minor units. Each field syncs on its own.
class WalletSettings {
  final int salary;
  final int rent;
  final int loan;
  final String? loanEnd; // YYYY-MM
  final int subs;
  final int impulse;
  final int coolHours;
  final int paydayDay;
  final String? periodStart; // YYYY-MM-DD
  final String currency;
  final String incomeMode; // planned | received
  final String? savedFor; // periodStart for which the payday savings were confirmed
  final bool salaryConfirmed;
  final List<List<String>> merchantPatterns; // [[category, pattern], ...] in match order (text only: see patternRules)

  /// The merchant patterns with their match kind, amount range, id and order (P7), in match order (first match wins).
  /// [merchantPatterns] lists the same patterns as `[category, pattern]` pairs.
  final List<MerchantPattern> patternRules;
  final int rentCashThreshold; // ATM withdrawals this big or bigger are rent; 0 = never
  final Map<String, int> categoryBudgets; // spending category -> cents per calendar month; no entry = no budget

  /// Plan lines (P1): a live top-level custom fixed category ([CategoryTable.hasPlanLine]) -> cents per month, taken
  /// off the flexible money with rent, loan and subs (`computePeriod`). No entry = 0. Row `plan:<id>` ([planPrefix]).
  final Map<String, int> planLines;

  /// Owner-set exchange rates (P15): ISO 4217 code (never [currency]) -> its rate. Row `fx:<CODE>` ([fxPrefix]).
  /// A currency without an entry stays out of every sum.
  final Map<String, FxRate> fxRates;

  /// Rates set against another wallet currency ([FxRate.home] ≠ [currency]: the currency was changed since). They
  /// count nowhere (the code is "not counted" again until a new rate is set); the app can say "Rate was set for EUR".
  final Map<String, FxRate> fxStale;
  final int reviewDay; // weekly review day, 1 = Monday .. 7 = Sunday
  final String? lastReview; // YYYY-MM-DD of the last completed weekly review
  final int reviewStreak; // weekly reviews done in a row
  final int headsUpCents; // heads-up before a planned cost or bill this big or bigger (minor units)
  final int headsUpDays; // ... this many days before its date (0 = on the day)
  final int returnReminderDays; // remind this many days before a bill's return window ends (0 = on the day)
  final int warrantyReminderDays; // ... before a bill's warranty ends
  final String? syncFolder; // device-local, not synced

  /// Saved CSV layouts (P12): shape id (`CsvShape.shapeId`) → the owner's column mapping. Row `csvmap:<shapeId>`
  /// ([csvMapPrefix]), value = [CsvMapping.toJson]; a row that does not read or has a problem of its own is dropped
  /// (logged once as `settings.invalid` under `csvmap`).
  final Map<String, CsvMapping> csvMappings;

  const WalletSettings({
    this.salary = 0,
    this.rent = 0,
    this.loan = 0,
    this.loanEnd,
    this.subs = 0,
    this.impulse = 5000,
    this.coolHours = 72,
    this.paydayDay = 15,
    this.periodStart,
    this.currency = 'EUR',
    this.incomeMode = 'planned',
    this.savedFor,
    this.salaryConfirmed = false,
    this.merchantPatterns = const [],
    this.patternRules = const [],
    this.rentCashThreshold = defaultRentCashThreshold,
    this.categoryBudgets = const {},
    this.planLines = const {},
    this.fxRates = const {},
    this.fxStale = const {},
    this.reviewDay = DateTime.sunday,
    this.lastReview,
    this.reviewStreak = 0,
    this.headsUpCents = defaultHeadsUpCents,
    this.headsUpDays = defaultHeadsUpDays,
    this.returnReminderDays = defaultReturnReminderDays,
    this.warrantyReminderDays = defaultWarrantyReminderDays,
    this.syncFolder,
    this.csvMappings = const {},
  });

  /// Largest accepted amount (minor units) and wait (hours: a year) in a stored or synced value.
  static const maxAmount = 100000000000, maxCoolHours = 24 * 365;

  /// Largest monthly budget of one category (minor units).
  static const maxBudget = 1000000000000;

  /// Largest review streak kept (weeks; about 2000 years).
  static const maxStreak = 100000;

  /// Latest payday day kept: a stored 29..31 reads as 28 (every month has it), so a period never ends on a day some
  /// months lack (the app no longer clamps it). 0 or above 31 is invalid and falls back to 15.
  static const maxPaydayDay = 28;

  /// Schema 8 keeps one settings row per category budget and per merchant pattern (H3), so two devices editing
  /// different entries never overwrite each other. Budget row id: `budget:<spending category>`, value = whole cents
  /// (JSON int, 0..[maxBudget]). Pattern row id: `pattern:<first 16 hex chars of SHA-256 of the pattern's UTF-8>`
  /// (`WalletRepo.merchantPatternId`; the id never shows the pattern, which can name a merchant), value = JSON
  /// `{"category": <category>, "pattern": <regex>, "order": <int ≥ 0>}`; patterns are matched by `order` ascending,
  /// then by row id. A removed entry is a tombstone (`deleted` 1, value null). [fromMap] reads these keys, after the
  /// legacy `categoryBudgets` / `merchantPatterns` maps (a row's entry replaces a legacy one).
  /// Plan line rows (P1, [planLines]): `plan:<custom category id>`, value = whole cents (JSON int, 0..[maxAmount]).
  /// Exchange rate rows (P15, [fxRates]): `fx:<CODE>`, value = JSON `{"rate": int, "date": "YYYY-MM-DD", "home": "EUR"}`
  /// ([FxRate]).
  static const budgetPrefix = 'budget:', patternPrefix = 'pattern:', planPrefix = 'plan:', fxPrefix = 'fx:';

  /// An ISO 4217 code as the wallet currency and the rate rows use it.
  static final currencyCode = RegExp(r'^[A-Z]{3}$');

  /// Saved CSV layout rows (P12, [csvMappings]): `csvmap:<16 hex shape id>`, value = [CsvMapping.toJson].
  static const csvMapPrefix = 'csvmap:';

  /// A shape id as a `csvmap:` row key holds it: 16 lower-case hex characters.
  static final csvShapeIdPattern = RegExp(r'^[0-9a-f]{16}$');

  /// Heads-up defaults (owner, 2026-10-22: 3 days before a planned cost of 100 € or more) and their ranges.
  static const defaultHeadsUpCents = 10000, maxHeadsUpCents = 10000000, defaultHeadsUpDays = 3, maxHeadsUpDays = 14;

  /// Bill reminder defaults (BILLS_API.md §3) and their ranges, in days before the date.
  static const defaultReturnReminderDays = 3, maxReturnReminderDays = 30, defaultWarrantyReminderDays = 14, maxWarrantyReminderDays = 90;

  /// Reads settings from stored/synced values. A value of the wrong type or outside its range (another device's
  /// bug, a damaged op) falls back to that setting's default alone, logged as `settings.invalid` with the key only
  /// (never the value), once per key and value ([logInvalidSetting]); the other settings are kept.
  /// [table] decides which category budgets are valid (live top-level spending categories); null = built-ins only.
  static WalletSettings fromMap(Map<String, Object?> m, {CategoryTable? table}) {
    final cats = table ?? CategoryTable.builtIn;
    T bad<T>(String k, T d) {
      logInvalidSetting(k, m[k]);
      return d;
    }

    int i(String k, int d, {int min = 0, int max = maxAmount}) {
      final v = m[k];
      if (v == null) return d;
      if (v is int && v >= min && v <= max) return v;
      if (v is double && v.isFinite && v == v.roundToDouble() && v >= min && v <= max) return v.toInt();
      return bad(k, d);
    }

    String? str(String k, bool Function(String) ok) {
      final v = m[k];
      if (v == null) return null;
      if (v is String && ok(v)) return v;
      return bad(k, null);
    }

    String one(String k, String d, Set<String> allowed) {
      final v = m[k];
      if (v == null) return d;
      if (v is String && allowed.contains(v)) return v;
      return bad(k, d);
    }

    final patterns = m['merchantPatterns'];
    final confirmed = m['salaryConfirmed'];
    final budgets = m['categoryBudgets'];
    // Per-key rows (schema 8): `budget:<category>` and `pattern:<id>`.
    final budgetRows = <Object?, Object?>{};
    final planRows = <Object?, Object?>{};
    final fxRows = <String, Object?>{};
    final patternRows = <MerchantPattern>[];
    final csvRows = <String, CsvMapping>{};
    var badPatternRow = false, badRange = false, badCsvRow = false;
    for (final MapEntry(:key, :value) in m.entries) {
      if (key.startsWith(csvMapPrefix)) {
        final id = key.substring(csvMapPrefix.length);
        final mapping = _csvMapping(id, value);
        if (mapping == null) {
          badCsvRow = true;
        } else {
          csvRows[id] = mapping;
        }
      } else if (key.startsWith(budgetPrefix)) {
        budgetRows[key.substring(budgetPrefix.length)] = value;
      } else if (key.startsWith(planPrefix)) {
        planRows[key.substring(planPrefix.length)] = value;
      } else if (key.startsWith(fxPrefix)) {
        fxRows[key.substring(fxPrefix.length)] = value;
      } else if (key.startsWith(patternPrefix)) {
        final (row, rangeDropped) = MerchantPattern.read(key, value);
        if (row != null) {
          patternRows.add(row);
          if (rangeDropped) badRange = true;
        } else {
          badPatternRow = true;
        }
      }
    }
    if (badCsvRow) logInvalidSetting('csvmap', 'row');
    if (badPatternRow) logInvalidSetting('merchantPatterns', 'row');
    if (badRange) logInvalidSetting('merchantPatterns', 'range');
    patternRows.sort((a, b) {
      final d = a.order.compareTo(b.order);
      return d != 0 ? d : a.id.compareTo(b.id);
    });
    // A legacy `merchantPatterns` list (and [toMap]'s copy of the rules) comes first, in its own order.
    final legacyPatterns = switch (patterns) {
      null => const <MerchantPattern>[],
      final List<Object?> l => _legacyPatterns(l),
      _ => bad('merchantPatterns', const <MerchantPattern>[]),
    };
    final allPatterns = [...legacyPatterns, ...patternRows];
    final currency = str('currency', currencyCode.hasMatch) ?? 'EUR';
    final fx = _fxRates(fxRows, currency);
    return WalletSettings(
      salary: i('salary', 0),
      rent: i('rent', 0),
      loan: i('loan', 0),
      loanEnd: str('loanEnd', _isMonth),
      subs: i('subs', 0),
      impulse: i('impulse', 5000),
      coolHours: i('coolHours', 72, max: maxCoolHours),
      paydayDay: min(i('paydayDay', 15, min: 1, max: 31), maxPaydayDay),
      periodStart: str('periodStart', isIsoDate),
      currency: currency,
      incomeMode: one('incomeMode', 'planned', const {'planned', 'received'}),
      savedFor: str('savedFor', isIsoDate),
      salaryConfirmed: confirmed == null || confirmed is bool ? confirmed == true : bad('salaryConfirmed', false),
      merchantPatterns: [
        for (final p in allPatterns) [p.category, p.pattern]
      ],
      patternRules: allPatterns,
      rentCashThreshold: i('rentCashThreshold', defaultRentCashThreshold),
      categoryBudgets: switch (budgets) {
        null => budgetRows.isEmpty ? const {} : _budgets(budgetRows, cats),
        final Map<Object?, Object?> b => _budgets({...b, ...budgetRows}, cats),
        _ => bad('categoryBudgets', budgetRows.isEmpty ? const <String, int>{} : _budgets(budgetRows, cats)),
      },
      planLines: _planLines(planRows, cats),
      fxRates: fx.$1,
      fxStale: fx.$2,
      reviewDay: i('reviewDay', DateTime.sunday, min: DateTime.monday, max: DateTime.sunday),
      lastReview: str('lastReview', isIsoDate),
      reviewStreak: i('reviewStreak', 0, max: maxStreak),
      headsUpCents: i('headsUpCents', defaultHeadsUpCents, max: maxHeadsUpCents),
      headsUpDays: i('headsUpDays', defaultHeadsUpDays, max: maxHeadsUpDays),
      returnReminderDays: i('returnReminderDays', defaultReturnReminderDays, max: maxReturnReminderDays),
      warrantyReminderDays: i('warrantyReminderDays', defaultWarrantyReminderDays, max: maxWarrantyReminderDays),
      csvMappings: csvRows.isEmpty ? const {} : Map.unmodifiable(csvRows),
    );
  }

  /// A stored `csvmap:<id>` value as a layout, or null when the id is not a shape id, the value does not read
  /// ([CsvMapping.fromJson]) or the layout has a problem of its own ([CsvMapping.structureProblems]).
  static CsvMapping? _csvMapping(String id, Object? value) {
    if (!csvShapeIdPattern.hasMatch(id)) return null;
    try {
      final m = CsvMapping.fromJson(value);
      return m.structureProblems().isEmpty ? m : null;
    } on FormatException {
      return null;
    }
  }

  /// The valid entries of a `categoryBudgets` value: a live top-level spending category of [t] ([CategoryTable.spending])
  /// -> whole cents 0..[maxBudget]. Every other entry (unknown, deleted or child category, negative, fraction, text,
  /// too big) is dropped (only from the result: the stored row stays, so an undelete brings it back), the rest is
  /// kept, and the drop is logged once as `settings.invalid` with the key only. Never throws.
  static Map<String, int> _budgets(Map<Object?, Object?> raw, CategoryTable t) {
    final out = <String, int>{};
    var dropped = false;
    for (final MapEntry(:key, :value) in raw.entries) {
      final cents = switch (value) {
        final int v => v,
        final double v when v.isFinite && v == v.roundToDouble() => v.toInt(),
        _ => null,
      };
      if (key is String && t.isSpending(key) && t.parentOf(key) == null && cents != null && cents >= 0 && cents <= maxBudget) {
        out[key] = cents;
      } else {
        dropped = true;
      }
    }
    if (dropped) logInvalidSetting('categoryBudgets', raw);
    return out;
  }

  /// The valid plan lines: a category with a plan line in [t] ([CategoryTable.hasPlanLine]) -> whole cents
  /// 0..[maxAmount]. Others are dropped from the result only (the stored row stays, so an undelete brings it back);
  /// a bad value is logged once as `settings.invalid` under `planLines`, a category that has no line here is not.
  static Map<String, int> _planLines(Map<Object?, Object?> raw, CategoryTable t) {
    final out = <String, int>{};
    var bad = false;
    for (final MapEntry(:key, :value) in raw.entries) {
      final cents = switch (value) {
        final int v => v,
        final double v when v.isFinite && v == v.roundToDouble() => v.toInt(),
        _ => null,
      };
      if (cents == null || cents < 0 || cents > maxAmount) {
        bad = true;
      } else if (key is String && t.hasPlanLine(key)) {
        out[key] = cents;
      }
    }
    if (bad) logInvalidSetting('planLines', 'row');
    return out.isEmpty ? const {} : out;
  }

  /// The valid exchange rates: (code -> rate set against [currency], code -> rate set against another home). A bad
  /// code or value (a row without `home`, a rate whose home is its own code) is dropped, logged once as
  /// `settings.invalid` under `fx`; a rate for the wallet [currency] itself is left out without a warning (the currency
  /// was changed after it was set; the row comes back if the currency changes back).
  static (Map<String, FxRate>, Map<String, FxRate>) _fxRates(Map<String, Object?> raw, String currency) {
    final out = <String, FxRate>{}, stale = <String, FxRate>{};
    var bad = false;
    for (final MapEntry(:key, :value) in raw.entries) {
      final r = FxRate.read(value);
      if (r == null || !currencyCode.hasMatch(key) || r.home == key) {
        bad = true;
      } else if (key != currency) {
        (r.home == currency ? out : stale)[key] = r;
      }
    }
    if (bad) logInvalidSetting('fx', 'row');
    return (out.isEmpty ? const {} : out, stale.isEmpty ? const {} : stale);
  }

  /// The entries of a `merchantPatterns` list: `[category, regex]` (stored by builds before schema 8), or [toMap]'s
  /// `[category, pattern, match, minCents, maxCents]`. Ids from the pattern, orders by position. A range that is not
  /// valid is dropped (logged under `merchantPatterns`); other entries are skipped.
  static List<MerchantPattern> _legacyPatterns(List<Object?> l) {
    final out = <MerchantPattern>[];
    var badRange = false;
    for (final p in l) {
      if (p is! List || (p.length != 2 && p.length != 5)) continue;
      final text = p[1].toString();
      final (row, dropped) = MerchantPattern.read(merchantPatternId(text), {
        'category': p[0].toString(),
        'pattern': text,
        'order': out.length,
        if (p.length == 5) ...{'match': p[2], 'minCents': p[3], 'maxCents': p[4]},
      });
      if (row == null) continue;
      if (dropped) badRange = true;
      out.add(row);
    }
    if (badRange) logInvalidSetting('merchantPatterns', 'range');
    return out;
  }

  static bool _isMonth(String v) => RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(v);

  Map<String, Object?> toMap() => {
        'salary': salary,
        'rent': rent,
        'loan': loan,
        'loanEnd': loanEnd,
        'subs': subs,
        'impulse': impulse,
        'coolHours': coolHours,
        'paydayDay': paydayDay,
        'periodStart': periodStart,
        'currency': currency,
        'incomeMode': incomeMode,
        'savedFor': savedFor,
        'salaryConfirmed': salaryConfirmed,
        // Plain regex rules as `[category, regex]` pairs (as before P7); a rule with a match kind or range as
        // `[category, pattern, match, minCents, maxCents]`, so [fromMap] reads every rule back.
        'merchantPatterns': [
          for (final p in patternRules.isEmpty
              ? [for (final m in merchantPatterns) MerchantPattern(id: '', category: m[0], pattern: m[1])]
              : patternRules)
            if (p.match == MerchantPattern.regex && !p.hasRange)
              [p.category, p.pattern]
            else
              [p.category, p.pattern, p.match, p.minCents, p.maxCents],
        ],
        'rentCashThreshold': rentCashThreshold,
        'categoryBudgets': categoryBudgets,
        // One int per line under its row id (`plan:<id>`), as stored: [fromMap] reads it back, and a diff of two
        // maps compares the values, not map identities.
        for (final MapEntry(:key, :value) in planLines.entries) '$planPrefix$key': value,
        for (final MapEntry(:key, :value) in fxStale.entries) '$fxPrefix$key': value.toJson(),
        for (final MapEntry(:key, :value) in fxRates.entries)
          '$fxPrefix$key': FxRate(value.rate, value.date, home: value.home ?? currency).toJson(),
        // Saved CSV layouts as stored, one row each, so fromMap(toMap()) keeps them.
        for (final MapEntry(:key, :value) in csvMappings.entries) '$csvMapPrefix$key': value.toJson(),
        'reviewDay': reviewDay,
        'lastReview': lastReview,
        'reviewStreak': reviewStreak,
        'headsUpCents': headsUpCents,
        'headsUpDays': headsUpDays,
        'returnReminderDays': returnReminderDays,
        'warrantyReminderDays': warrantyReminderDays,
      };
}
