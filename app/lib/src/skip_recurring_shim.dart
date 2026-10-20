// TEMPORARY shim until wallet_core's WalletRepo.skipRecurring lands (merge habits-core, then delete this file and its import).
import 'package:wallet_core/wallet_core.dart';

extension SkipRecurringShim on WalletRepo {
  Future<void> skipRecurring(String id) async {
    final b = recurringBills().firstWhere((b) => b.id == id);
    final hlc = Hlc(DateTime.now().millisecondsSinceEpoch + 60000, 0, 'shim');
    applyRemote([
      Op('recurring', id, {'next_due': addDays(b.nextDue, b.intervalDays)}, hlc.toString())
    ]);
  }
}
