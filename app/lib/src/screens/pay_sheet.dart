import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// The fields of a slip to paste into the bank app. Nothing is sent from here and the bill is not marked paid.
/// Each row copies one value; "Copy all" copies them as lines. The clipboard is emptied again after a minute.
class PaySheet extends StatelessWidget {
  final WalletController wc;
  final Bill bill;
  const PaySheet({super.key, required this.wc, required this.bill});

  Future<void> _copy(BuildContext context, String field, String text) async {
    await wc.copySensitive(text);
    logNav('bill.payCopy', {'field': field});
    if (context.mounted) toast(context, 'Copied');
  }

  @override
  Widget build(BuildContext context) {
    final b = bill;
    final cur = b.currency.isEmpty ? wc.currency : b.currency;
    // (field, label, shown, copied)
    final rows = <(String, String, String, String)>[
      if ((b.payee ?? '').trim().isNotEmpty) ('payee', 'Payee', b.payee!.trim(), b.payee!.trim()),
      if ((b.iban ?? '').trim().isNotEmpty) ('iban', 'IBAN', groupedIban(b.iban!), plainIban(b.iban!)),
      if (b.total != null) ('amount', 'Amount ($cur)', bankAmountText(b.total!), bankAmountText(b.total!)),
      if ((b.reference ?? '').trim().isNotEmpty) ('reference', 'Model and reference', b.reference!.trim(), b.reference!.trim()),
      if ((b.description ?? '').trim().isNotEmpty) ('description', 'Description', b.description!.trim(), b.description!.trim()),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      const Heading('Pay'),
      const SizedBox(height: 4),
      const Muted('Paste these into your bank app. Nothing is sent from here.'),
      const SizedBox(height: 10),
      Rows(children: [
        for (final (field, label, shown, copied) in rows)
          Padding(
            key: ValueKey('payRow:$field'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SplitRow(
              start: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Muted(label),
                const SizedBox(height: 2),
                Text(shown, style: field == 'amount' || field == 'iban' ? numStyle : const TextStyle(fontSize: BwType.bodySize)),
              ]),
              end: OutlinedButton.icon(
                  key: ValueKey('payCopy:$field'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, touchMin)),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy'),
                  onPressed: () => _copy(context, field, copied)),
            ),
          ),
      ]),
      const SizedBox(height: 12),
      FilledButton.icon(
          key: const ValueKey('payCopyAll'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          icon: const Icon(Icons.copy_all),
          label: const Text('Copy all'),
          onPressed: () => _copy(context, 'all', rows.map((r) => r.$4).join('\n'))),
    ]);
  }
}
