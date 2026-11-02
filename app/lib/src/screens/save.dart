import 'package:flutter/material.dart';

import '../controller.dart';
import '../layout.dart';
import '../theme.dart';
import '../widgets/dash.dart';
import 'goals.dart';
import 'owed.dart';
import 'wishlist.dart';

/// Plan › Saving (was the Save tab; RX6, "Paper Tiles"): three dashboards in one scroll on the desk, Goals, Wishlist and Owed, each a [DashGrid] of tiles
/// under a small heading.
class SaveScreen extends StatelessWidget {
  final WalletController wc;

  /// The Payday plan | Saving switch of the Plan page, shown on top.
  final Widget? switcher;
  const SaveScreen({super.key, required this.wc, this.switcher});

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: context.c.desk,
        child: SingleChildScrollView(
          key: const ValueKey('savePage'),
          padding: const EdgeInsets.fromLTRB(pagePad, 12, pagePad, pageBottomPad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: gapped([
              if (switcher != null) switcher!,
              GoalsScreen(wc: wc, embedded: true),
              WishlistScreen(wc: wc, embedded: true),
              OwedPanel(wc: wc)
            ], gap: 18),
          ),
        ),
      );
}

/// The small heading over one dashboard of the Save tab.
class SaveSectionHead extends StatelessWidget {
  final String title;
  const SaveSectionHead(this.title, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
        child: Semantics(header: true, child: TileLabel(title)),
      );
}
