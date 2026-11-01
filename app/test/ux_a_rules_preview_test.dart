// UX-A review fix: the rule-form preview builds its "after" categorizer with the owner's built-in rule overrides, so a
// built-in the owner turned off does not count as a change. All data SYNTHETIC (well-known chains only).
import 'package:budget_wallet/src/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/wallet.dart';

void main() {
  testWidgets('a preview with a built-in turned off counts only what the draft changes', (t) async {
    final wc = emptyWallet();
    wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
      syntheticTx('2026-10-09', -3000, 'POS plaćanje', 'POS LIDL 0000 ZAGREB'),
      syntheticTx('2026-10-10', -500, 'POS plaćanje', 'POS PLODINE 0000 ZAGREB'),
    ]));
    wc.repo.setBuiltInRuleOff('builtIn:lidl', true);
    wc.reload();
    expect(wc.categorizer.merchantCategory('pos lidl 0000 zagreb'), isNull);
    // A draft that touches neither row: nothing changes.
    expect(wc.previewRuleChange(const RuleDraft(match: 'contains', text: 'synthetic-nothing', category: 'Shopping')), 0);
    // A draft for PLODINE only: one row.
    expect(wc.previewRuleChange(const RuleDraft(match: 'contains', text: 'plodine', category: 'Shopping')), 1);
  });
}
