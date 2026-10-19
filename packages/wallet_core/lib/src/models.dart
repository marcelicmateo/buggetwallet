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
    this.syncFolder,
  });

  /// Largest accepted amount (minor units) and wait (hours: a year) in a stored or synced value.
  static const maxAmount = 100000000000, maxCoolHours = 24 * 365;

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
    );
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
      };
}
