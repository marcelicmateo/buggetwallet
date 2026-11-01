// "Which account is this?" (UX-ACC, docs/context/SCHEMA21_SPEC.md "ask once"): asked at the first import from an export account no account
// claims yet. The owner picks an existing account (the main one first) or makes a new one; the answer becomes that account's match key,
// so later files of the same export account are not asked. The name of a new account is the owner's own word, never the export's
// account name or IBAN (that text is only shown here, in this question).
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'account_form.dart';
import 'accounts_panel.dart' show accountTypeLabel;

/// Opens the question for [q]; the owner's answer, or null for "Skip this file" (that file is not imported; the other files go on).
Future<AccountAnswer?> askWhichAccount(BuildContext context, WalletController wc, ImportAccountQuestion q) async {
  logNav('accountQuestion.open', {'candidates': q.candidates.length, 'rows': q.rows});
  return showSheet<AccountAnswer>(context, AccountQuestionSheet(wc: wc, q: q));
}

/// The question sheet. Pops an [AccountAnswer] (a pick, or `created` once the new-account form saved) or nothing on Skip.
class AccountQuestionSheet extends StatelessWidget {
  final WalletController wc;
  final ImportAccountQuestion q;
  const AccountQuestionSheet({super.key, required this.wc, required this.q});

  /// Accounts that could take this export account's rows: no other export account claims them yet, the one without a key (the main
  /// account) first. An account that already claims another export account would lose that claim.
  List<Account> get _free => wc.freeAccountsFor(q);

  Future<void> _new(BuildContext context) async {
    logNav('accountQuestion.new');
    final draft = await showSheet<NewAccountDraft>(context, AccountFormSheet(wc: wc, forImport: q));
    if (draft != null && context.mounted) Navigator.pop(context, AccountAnswer.created(draft));
  }

  @override
  Widget build(BuildContext context) {
    final free = _free;
    final bank = accountTypeLabel(q.source, csvMappings: wc.settings.csvMappings);
    return Column(key: const ValueKey('accountQuestion'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('Which account is this?'),
      const SizedBox(height: 6),
      Muted('A $bank file in ${q.currency} with ${q.rows} ${q.rows == 1 ? 'payment' : 'payments'}. You are asked once; the next files '
          'from this account go to it by themselves.'),
      if (q.exportAccount.trim().isNotEmpty) ...[
        const SizedBox(height: 4),
        Text('In the file: ${q.exportAccount}',
            key: const ValueKey('accountQuestionFile'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
      ],
      const SizedBox(height: 12),
      for (final (i, a) in free.indexed) ...[
        OutlinedButton(
            key: ValueKey('accountPick:${a.id}'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(touchMin), alignment: Alignment.centerLeft),
            onPressed: () {
              logNav('accountQuestion.pick', {'main': i == 0});
              Navigator.pop(context, AccountAnswer.existing(a.id));
            },
            child: Text(i == 0 ? '${a.name} (main account)' : a.name, textAlign: TextAlign.start)),
        const SizedBox(height: 8),
      ],
      FilledButton(
          key: const ValueKey('accountPickNew'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: () => _new(context),
          child: const Text('New account')),
      const SizedBox(height: 8),
      TextButton(
          key: const ValueKey('accountPickCancel'),
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(buttonMin)),
          onPressed: () {
            logNav('accountQuestion.skip');
            Navigator.pop(context);
          },
          child: const Text('Skip this file')),
    ]);
  }
}
