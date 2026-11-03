// The Money timeline (ENG E7a, docs/context/ENG_UI_SPEC.md §3): what is coming up above the "Today" line (bill cycles, planned costs,
// expected incomes, reminders) and the payments below it grouped by day, newest first. Grouping and filtering only; every amount is core's.
// A `part` of controller.dart so it can use the cache.
part of 'controller.dart';

/// The Money filter chips. `planned` keeps planned costs and calendar suggestions (and no past payments).
enum MoneyFilter { all, out, income, bills, planned }

/// One dashed row above the Today line. [cents] is signed for display: a cost is negative, an income positive, null = no amount yet.
class MoneyUpRow {
  final String key, date, title, tag;
  final int? cents;

  /// Dated before today and still open.
  final bool late;
  final UpcomingItem? item;
  final IncomeCycle? income;
  const MoneyUpRow(
      {required this.key,
      required this.date,
      required this.title,
      required this.tag,
      this.cents,
      this.late = false,
      this.item,
      this.income});
}

class MoneyDay {
  final String date;
  final List<CategorizedTx> rows;
  const MoneyDay(this.date, this.rows);
}

class MoneyTimeline {
  final List<MoneyUpRow> up;
  final List<MoneyDay> days;

  /// Core's `beforePayday`: the money the costs above hold.
  final int held;
  const MoneyTimeline(this.up, this.days, this.held);
}

extension MoneyData on WalletController {
  /// The live accounts that count rows, for the strip: balance in the account's own currency, newest row date.
  List<AccountBalance> moneyAccounts() => [
        for (final b in accountBalanceList())
          if (b.duplicateOf == null) b
      ];

  /// Cached per data version, filter and account.
  MoneyTimeline moneyTimeline(MoneyFilter filter, {String? accountId}) => _cached(MemoKey('moneyTimeline', (filter, accountId)), () {
        final p = period(), t = today();
        final up = <MoneyUpRow>[];
        // Costs and reminders hold no account, so choosing an account shows payments only.
        if (accountId == null) {
          for (final i in upcomingItems(p.start, addDays(p.end, -1))) {
            final bill = i.kind == UpcomingKind.bill || (i.planned?.isBill ?? false);
            final planned = !bill && (i.kind == UpcomingKind.planned || i.kind == UpcomingKind.suggestion);
            final keep = switch (filter) {
              MoneyFilter.all => true,
              MoneyFilter.out => i.kind == UpcomingKind.planned || i.kind == UpcomingKind.bill,
              MoneyFilter.income => false,
              MoneyFilter.bills => bill,
              MoneyFilter.planned => planned,
            };
            if (!keep) continue;
            up.add(MoneyUpRow(
                key: i.key,
                date: i.date,
                title: i.title.isEmpty ? (i.kind == UpcomingKind.planned ? 'Planned cost' : 'Bill') : i.title,
                tag: switch (i.kind) {
                  UpcomingKind.bill => 'bill',
                  UpcomingKind.planned => bill ? 'bill' : 'planned',
                  UpcomingKind.suggestion => 'calendar',
                  UpcomingKind.warranty => 'warranty',
                  UpcomingKind.returnBy => 'return by',
                },
                cents: i.amount == null ? null : -i.amount!,
                late: i.date.compareTo(t) < 0 && (i.kind == UpcomingKind.planned || i.kind == UpcomingKind.bill),
                item: i));
          }
          if (filter == MoneyFilter.all || filter == MoneyFilter.income) {
            for (final x in p.expectedIncome) {
              up.add(MoneyUpRow(
                  key: 'income:${x.bill.id}@${x.due}',
                  date: x.due,
                  title: x.bill.label.isNotEmpty ? x.bill.label : x.bill.payee,
                  tag: 'income',
                  cents: x.amount,
                  income: x));
            }
          }
          up.sort((a, b) => a.date.compareTo(b.date));
        }
        final onAccount = accountId == null
            ? null
            : {
                for (final b in accountBalanceList())
                  if (b.account.id == accountId)
                    for (final r in b.rows) r.id
              };
        final past = <CategorizedTx>[];
        if (filter != MoneyFilter.planned) {
          for (final x in wholeTxs) {
            if (onAccount != null && !onAccount.contains(x.tx.id)) continue;
            final spend = x.kind != BudgetKind.transfer;
            final keep = switch (filter) {
              MoneyFilter.all => true,
              MoneyFilter.out => x.amount < 0 && spend,
              MoneyFilter.income => x.amount > 0 && spend,
              MoneyFilter.bills => billForTx(x.tx.id) != null,
              MoneyFilter.planned => false,
            };
            if (keep) past.add(x);
          }
        }
        past.sort((a, b) => b.date.compareTo(a.date));
        final days = <MoneyDay>[];
        for (final x in past) {
          if (days.isEmpty || days.last.date != x.date) days.add(MoneyDay(x.date, []));
          days.last.rows.add(x);
        }
        return MoneyTimeline(up, days, p.beforePayday);
      });
}
