// The payments behind one bar of a time graph (stage ZC): a day, week, month or quarter. A page on phones, a dialog on wide windows.
// [rows] is asked again whenever the wallet changes, so an edited or deleted payment leaves the list.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../widgets/dash.dart';
import '../widgets/detail_tiles.dart';
import '../widgets/sheets.dart';

Future<void> openBucketPayments(BuildContext context, WalletController wc,
        {required String title, required List<CategorizedTx> Function() rows}) =>
    openPageOrDialog<void>(context, BucketPaymentsScreen(wc: wc, title: title, rows: rows), width: 840, logName: 'BucketPayments');

class BucketPaymentsScreen extends StatelessWidget {
  final WalletController wc;
  final String title;
  final List<CategorizedTx> Function() rows;
  const BucketPaymentsScreen({super.key, required this.wc, required this.title, required this.rows});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: DialogAppBar(title: title),
        body: ListenableBuilder(
          listenable: wc,
          builder: (context, _) => DetailPage(children: [
            DashItem(
              span: 4,
              child: PaymentsTile(
                wc: wc,
                rows: rows(),
                rowsKey: const ValueKey('bucketRows'),
                emptyText: 'No payments here.',
                help: 'Tap a payment to change it.',
              ),
            ),
          ]),
        ),
      );
}
