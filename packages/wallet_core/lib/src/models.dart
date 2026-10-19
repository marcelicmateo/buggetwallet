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
  });

  /// Counts toward totals: not deleted and not replaced by a bank row.
  bool get live => !deleted && matchedTo == null;

  static Tx fromRow(Map<String, Object?> r) => Tx(
        id: r['id'] as String,
        source: (r['source'] as String?) ?? '',
        date: (r['date'] as String?) ?? '',
        amount: (r['amount'] as int?) ?? 0,
        currency: (r['currency'] as String?) ?? 'EUR',
        bankType: (r['bank_type'] as String?) ?? '',
        description: (r['description'] as String?) ?? '',
        category: r['category'] as String?,
        note: r['note'] as String?,
        manual: (r['manual'] as int? ?? 0) == 1,
        matchedTo: r['matched_to'] as String?,
        deleted: (r['deleted'] as int? ?? 0) == 1,
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
  final int saved;
  final int monthly;
  final int sort;
  const Goal({required this.id, required this.name, this.target = 0, this.saved = 0, this.monthly = 0, this.sort = 0});

  static Goal fromRow(Map<String, Object?> r) => Goal(
        id: r['id'] as String,
        name: (r['name'] as String?) ?? 'Goal',
        target: (r['target'] as int?) ?? 0,
        saved: (r['saved'] as int?) ?? 0,
        monthly: (r['monthly'] as int?) ?? 0,
        sort: (r['sort'] as int?) ?? 0,
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
        name: (r['name'] as String?) ?? '',
        price: (r['price'] as int?) ?? 0,
        added: (r['added'] as int?) ?? 0,
        status: (r['status'] as String?) ?? 'waiting',
        decided: r['decided'] as int?,
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
