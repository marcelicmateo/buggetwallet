import 'categories.dart';

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

  static WalletSettings fromMap(Map<String, Object?> m) {
    int i(String k, int d) => (m[k] as num?)?.toInt() ?? d;
    return WalletSettings(
      salary: i('salary', 0),
      rent: i('rent', 0),
      loan: i('loan', 0),
      loanEnd: m['loanEnd'] as String?,
      subs: i('subs', 0),
      impulse: i('impulse', 5000),
      coolHours: i('coolHours', 72),
      paydayDay: i('paydayDay', 15),
      periodStart: m['periodStart'] as String?,
      currency: (m['currency'] as String?) ?? 'EUR',
      incomeMode: (m['incomeMode'] as String?) ?? 'planned',
      savedFor: m['savedFor'] as String?,
      salaryConfirmed: m['salaryConfirmed'] == true,
      merchantPatterns: [
        for (final p in (m['merchantPatterns'] as List?) ?? const [])
          if (p is List && p.length == 2) [p[0].toString(), p[1].toString()],
      ],
      rentCashThreshold: i('rentCashThreshold', defaultRentCashThreshold),
    );
  }

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
