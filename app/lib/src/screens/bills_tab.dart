import 'package:flutter/material.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../layout.dart';
import '../logging.dart';
import '../tabs.dart';
import '../widgets/dash.dart';
import '../widgets/sheets.dart';
import 'bills_panel.dart';
import 'habits_panels.dart';
import 'recurring_sheet.dart';

/// Opens "Bills & slips" (ENG E7a): the expected (repeating) bills with Add bill, then the bills database with Scan bill. A page on a
/// phone, a dialog from [dialogMin] wide. [anchor] says which of the two to scroll to.
Future<void> openBillsPage(BuildContext context, WalletController wc,
    {FileChooser chooser = const FileChooser(), BillsAnchor anchor = BillsAnchor.expected}) {
  logNav('bills.open', {'at': anchor.name});
  return openPageOrDialog<void>(context, BillsScreen(wc: wc, chooser: chooser, anchor: anchor),
      width: 720, maxHeight: 820, logName: 'BillsScreen');
}

/// The bills page that Money opens: the expected bills tile, then the bills database. Every panel is built (a plain column), so
/// scrolling to one needs no paging.
class BillsScreen extends StatefulWidget {
  final WalletController wc;
  final FileChooser chooser;
  final BillsAnchor anchor;
  const BillsScreen({super.key, required this.wc, this.chooser = const FileChooser(), this.anchor = BillsAnchor.expected});
  @override
  State<BillsScreen> createState() => _BillsScreenState();
}

class _BillsScreenState extends State<BillsScreen> {
  final _expected = GlobalKey(), _slips = GlobalKey();

  @override
  void initState() {
    super.initState();
    if (widget.anchor == BillsAnchor.slips) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _slips.currentContext;
        if (mounted && c != null && c.mounted) Scrollable.ensureVisible(c);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    return Scaffold(
      appBar: const DialogAppBar(title: 'Bills & slips'),
      body: ListenableBuilder(
        listenable: wc,
        builder: (context, _) => SingleChildScrollView(
          key: const ValueKey('billsPage'),
          padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: gapped([
              KeyedSubtree(key: _expected, child: ExpectedBillsPanel(wc: wc, trailing: _Actions(wc: wc))),
              KeyedSubtree(key: _slips, child: BillsPanel(wc: wc, chooser: widget.chooser)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Add bill (a repeating bill), in the label row of the Expected bills tile. Scan bill lives in the Bills panel below.
class _Actions extends StatelessWidget {
  final WalletController wc;
  const _Actions({required this.wc});
  @override
  Widget build(BuildContext context) => TileAction(
        key: const ValueKey('billsAdd'),
        label: 'Add bill',
        onTap: () {
          logNav('bills.addTab');
          openRecurringForm(context, wc);
        },
      );
}
