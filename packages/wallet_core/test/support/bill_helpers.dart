import 'package:wallet_core/wallet_core.dart';

/// The flex category tests give a bill before confirming it.
const testBillCategory = 'Bills & one-offs';

extension BillTestRepo on WalletRepo {
  /// B5a: confirming a bill that would reserve money needs a category. Tests about other things give a live bill
  /// without one [testBillCategory] (a flex category, so its planned row reserves as before), then confirm.
  void confirmWithCategory(String id) {
    final b = bill(id);
    if (b != null && !b.deleted && b.category == null) updateBill(id, category: testBillCategory);
    confirmBill(id);
  }
}
