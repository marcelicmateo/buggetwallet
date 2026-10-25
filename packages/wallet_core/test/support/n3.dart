// SYNTHETIC rows for the N3 range/graph/drill-down tests. Made-up amounts, well-known chains and brands only.
import 'dart:math';

import 'package:wallet_core/wallet_core.dart';

var _seq = 0;

/// A categorized row with its own description, currency, source and note. The kind follows the category.
CategorizedTx row(String date, int cents, String category,
    {String desc = '', String currency = 'EUR', String source = 'pbz', String? note, String? id, bool deleted = false}) {
  final t = Tx(
      id: id ?? 'n3-${(_seq++).toString().padLeft(6, '0')}',
      source: source,
      date: date,
      amount: cents,
      currency: currency,
      description: desc,
      note: note,
      manual: source == 'manual',
      deleted: deleted);
  return CategorizedTx(t, category, kindOf(category));
}

const _chains = [
  'POS LIDL HRVATSKA ZAGREB', 'POS KONZUM 0000 ZAGREB', 'POS SPAR 0000 ZAGREB', 'POS KAUFLAND ZAGREB', //
  'POS DM DROGERIE ZAGREB', 'POS MCDONALDS ZAGREB', 'POS WOLT ZAGREB', 'POS INA 0000 ZAGREB', 'POS DECATHLON ZAGREB',
  'POS IKEA ZAGREB', 'POS ZARA ZAGREB', 'POS STEAM GAMES', 'POS PLODINE ZAGREB', 'POS BAUHAUS ZAGREB',
];

/// The shape of the app's perf wallet (`app/integration_test/support/big_wallet.dart`, which core cannot import):
/// [days] days ending [today], [perDay] card payments a day on average plus salary, rent cash, loan and subscriptions,
/// categorized by the built-in rules. The defaults give about 10,000 rows.
List<CategorizedTx> bigWalletRows(String today, {int days = 1000, int perDay = 10}) {
  final rnd = Random(20261025);
  final cat = Categorizer();
  final out = <CategorizedTx>[];
  var id = 0;
  Tx tx(String date, int cents, String desc) => Tx(id: 'big-${id++}', source: 'pbz', date: date, amount: cents, description: desc);
  for (var d = addDays(today, -days + 1); d.compareTo(today) <= 0; d = addDays(d, 1)) {
    final day = dayOf(d);
    if (day == 10) out.add(CategorizedTx(tx(d, 140000 + rnd.nextInt(5000), 'Neto placa dio 1'), 'Salary', BudgetKind.income));
    if (day == 13) out.add(CategorizedTx(tx(d, 40000, 'Neto placa dio 2'), 'Salary', BudgetKind.income));
    if (day == 11) out.add(CategorizedTx(tx(d, -55000, 'PBZ ATM TEST ULICA ZAGREB'), 'Rent', BudgetKind.fixed));
    if (day == 18) out.add(CategorizedTx(tx(d, -25000, 'Naplata kredita 0000000000'), 'Loan', BudgetKind.fixed));
    if (day == 5) out.add(cat.categorize(tx(d, -1299, 'POS NETFLIX.COM')));
    final n = rnd.nextInt(2 * perDay - 7) + 4;
    for (var k = 0; k < n; k++) {
      out.add(cat.categorize(tx(d, -(150 + rnd.nextInt(8000)), _chains[rnd.nextInt(_chains.length)])));
    }
  }
  return out;
}
