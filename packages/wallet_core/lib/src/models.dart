import 'package:wallet_importer/wallet_importer.dart' show TxKind;

import 'categories.dart';
import 'dates.dart';
import 'logs.dart';

final _log = Logger('bw.settings');

/// (key, value) pairs already logged as `settings.invalid` in this process. A bad stored value is read on every
/// `WalletRepo.settings()` call (each screen refresh, each match run), so it is logged once, not every time.
final _invalidLogged = <String>{};

/// Logs `settings.invalid` for [key] (the key only, never [value]) the first time this key holds this value.
void logInvalidSetting(String key, Object? value) {
  if (_invalidLogged.add('$key\u0000$value')) logEvent(_log, Level.WARNING, 'settings.invalid', {'key': key});
}

/// Forgets which bad settings were logged, so tests can expect the warning again.
void resetInvalidSettingLog() => _invalidLogged.clear();

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
  });

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

/// A transaction with its resolved category.
class CategorizedTx {
  final Tx tx;
  final String category;
  final Kind kind;
  const CategorizedTx(this.tx, this.category, this.kind);
  String get date => tx.date;
  int get amount => tx.amount;
}

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

/// A bill that comes back every month: detected from bank rows (`detectRecurring`, status `candidate`), then
/// confirmed or dismissed by the owner. Synced entity `recurring`; the id is `rec:<payee>` so every device derives the
/// same row for the same merchant. [expectedAmount] is positive cents (an outflow). A confirmed bill is reserved in
/// `computePeriod` until a bank row pays its cycle ([lastPaidTx], then [nextDue] moves on by [intervalDays]).
class RecurringBill {
  final String id;
  final String payee; // merchantKey of the bank rows
  final String label; // merchantName, for display
  final String category;
  final int expectedAmount; // cents, > 0
  final int intervalDays;
  final String nextDue; // YYYY-MM-DD
  final String status; // candidate | confirmed | dismissed
  final String? lastPaidTx; // the bank row that paid the last cycle

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
  });

  /// The one interval detected for now: monthly.
  static const defaultIntervalDays = 30;

  static const statuses = {'candidate', 'confirmed', 'dismissed'};

  /// The id of the bill for a payee key, the same on every device.
  static String idFor(String payee) => 'rec:$payee';

  bool get confirmed => status == 'confirmed';

  /// A bill in a fixed category (Rent, Loan, Bills & subscriptions) is already planned through the fixed-cost
  /// settings, so `computePeriod` lists it as due but does not reserve it a second time (owner rule: exact). A
  /// confirmed bill's `category` is kept current by `WalletRepo.refreshRecurring`, so this follows a later rule.
  bool get coveredByPlan => kindOf(category) == Kind.fixed;

  static RecurringBill fromRow(Map<String, Object?> r) => RecurringBill(
        id: r['id'] as String,
        payee: _str(r['payee']) ?? '',
        label: _str(r['label']) ?? '',
        category: _str(r['category']) ?? '',
        expectedAmount: _int(r['expected_amount']) ?? 0,
        intervalDays: _int(r['interval_days']) ?? defaultIntervalDays,
        nextDue: _str(r['next_due']) ?? '',
        status: _str(r['status']) ?? 'candidate',
        lastPaidTx: _str(r['last_paid_tx']),
      );

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
  bool get coveredByPlan => category != null && kindOf(category!) == Kind.fixed;

  /// A bill's row without a category (B6: a bill confirmed before B5a, or reopened after its cash expense was deleted):
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
  final List<List<String>> merchantPatterns; // [[category, regex], ...]
  final int rentCashThreshold; // ATM withdrawals this big or bigger are rent; 0 = never
  final Map<String, int> categoryBudgets; // spending category -> cents per calendar month; no entry = no budget
  final int reviewDay; // weekly review day, 1 = Monday .. 7 = Sunday
  final String? lastReview; // YYYY-MM-DD of the last completed weekly review
  final int reviewStreak; // weekly reviews done in a row
  final int headsUpCents; // heads-up before a planned cost or bill this big or bigger (minor units)
  final int headsUpDays; // ... this many days before its date (0 = on the day)
  final int returnReminderDays; // remind this many days before a bill's return window ends (0 = on the day)
  final int warrantyReminderDays; // ... before a bill's warranty ends
  final String? syncFolder; // device-local, not synced

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
    this.rentCashThreshold = defaultRentCashThreshold,
    this.categoryBudgets = const {},
    this.reviewDay = DateTime.sunday,
    this.lastReview,
    this.reviewStreak = 0,
    this.headsUpCents = defaultHeadsUpCents,
    this.headsUpDays = defaultHeadsUpDays,
    this.returnReminderDays = defaultReturnReminderDays,
    this.warrantyReminderDays = defaultWarrantyReminderDays,
    this.syncFolder,
  });

  /// Largest accepted amount (minor units) and wait (hours: a year) in a stored or synced value.
  static const maxAmount = 100000000000, maxCoolHours = 24 * 365;

  /// Largest monthly budget of one category (minor units).
  static const maxBudget = 1000000000000;

  /// Largest review streak kept (weeks; about 2000 years).
  static const maxStreak = 100000;

  /// Heads-up defaults (owner, 2026-10-22: 3 days before a planned cost of 100 € or more) and their ranges.
  static const defaultHeadsUpCents = 10000, maxHeadsUpCents = 10000000, defaultHeadsUpDays = 3, maxHeadsUpDays = 14;

  /// Bill reminder defaults (BILLS_API.md §3) and their ranges, in days before the date.
  static const defaultReturnReminderDays = 3, maxReturnReminderDays = 30, defaultWarrantyReminderDays = 14, maxWarrantyReminderDays = 90;

  /// Reads settings from stored/synced values. A value of the wrong type or outside its range (another device's
  /// bug, a damaged op) falls back to that setting's default alone, logged as `settings.invalid` with the key only
  /// (never the value), once per key and value ([logInvalidSetting]); the other settings are kept.
  static WalletSettings fromMap(Map<String, Object?> m) {
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
    return WalletSettings(
      salary: i('salary', 0),
      rent: i('rent', 0),
      loan: i('loan', 0),
      loanEnd: str('loanEnd', _isMonth),
      subs: i('subs', 0),
      impulse: i('impulse', 5000),
      coolHours: i('coolHours', 72, max: maxCoolHours),
      paydayDay: i('paydayDay', 15, min: 1, max: 31),
      periodStart: str('periodStart', _isDate),
      currency: str('currency', (v) => RegExp(r'^[A-Z]{3}$').hasMatch(v)) ?? 'EUR',
      incomeMode: one('incomeMode', 'planned', const {'planned', 'received'}),
      savedFor: str('savedFor', _isDate),
      salaryConfirmed: confirmed == null || confirmed is bool ? confirmed == true : bad('salaryConfirmed', false),
      merchantPatterns: switch (patterns) {
        null => const [],
        final List<Object?> l => [
            for (final p in l)
              if (p is List && p.length == 2) [p[0].toString(), p[1].toString()],
          ],
        _ => bad('merchantPatterns', const []),
      },
      rentCashThreshold: i('rentCashThreshold', defaultRentCashThreshold),
      categoryBudgets: switch (budgets) {
        null => const {},
        final Map<Object?, Object?> b => _budgets(b),
        _ => bad('categoryBudgets', const {}),
      },
      reviewDay: i('reviewDay', DateTime.sunday, min: DateTime.monday, max: DateTime.sunday),
      lastReview: str('lastReview', _isDate),
      reviewStreak: i('reviewStreak', 0, max: maxStreak),
      headsUpCents: i('headsUpCents', defaultHeadsUpCents, max: maxHeadsUpCents),
      headsUpDays: i('headsUpDays', defaultHeadsUpDays, max: maxHeadsUpDays),
      returnReminderDays: i('returnReminderDays', defaultReturnReminderDays, max: maxReturnReminderDays),
      warrantyReminderDays: i('warrantyReminderDays', defaultWarrantyReminderDays, max: maxWarrantyReminderDays),
    );
  }

  /// The valid entries of a `categoryBudgets` value: a spending category ([spendingCategories]) -> whole cents
  /// 0..[maxBudget]. Every other entry (unknown category, negative, fraction, text, too big) is dropped, the rest is
  /// kept, and the drop is logged once as `settings.invalid` with the key only. Never throws.
  static Map<String, int> _budgets(Map<Object?, Object?> raw) {
    final out = <String, int>{};
    var dropped = false;
    for (final MapEntry(:key, :value) in raw.entries) {
      final cents = switch (value) {
        final int v => v,
        final double v when v.isFinite && v == v.roundToDouble() => v.toInt(),
        _ => null,
      };
      if (key is String && isSpendingCategory(key) && cents != null && cents >= 0 && cents <= maxBudget) {
        out[key] = cents;
      } else {
        dropped = true;
      }
    }
    if (dropped) logInvalidSetting('categoryBudgets', raw);
    return out;
  }

  static bool _isDate(String v) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(v) && isoDate(parseIso(v)) == v; // no 2026-02-30

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
        'merchantPatterns': merchantPatterns,
        'rentCashThreshold': rentCashThreshold,
        'categoryBudgets': categoryBudgets,
        'reviewDay': reviewDay,
        'lastReview': lastReview,
        'reviewStreak': reviewStreak,
        'headsUpCents': headsUpCents,
        'headsUpDays': headsUpDays,
        'returnReminderDays': returnReminderDays,
        'warrantyReminderDays': warrantyReminderDays,
      };
}
