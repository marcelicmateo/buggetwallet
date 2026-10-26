import 'package:flutter/material.dart';

import '../controller.dart';
import '../layout.dart';
import 'goals.dart';
import 'wishlist.dart';

/// The Save tab (P5): the Goals panel, then the Wishlist, in one scroll. Both are the screens that were tabs of their own; their
/// content is unchanged.
class SaveScreen extends StatelessWidget {
  final WalletController wc;
  const SaveScreen({super.key, required this.wc});

  @override
  Widget build(BuildContext context) => NarrowPage(
        child: SingleChildScrollView(
          key: const ValueKey('savePage'),
          padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: gapped([GoalsScreen(wc: wc, embedded: true), WishlistScreen(wc: wc, embedded: true)]),
          ),
        ),
      );
}
