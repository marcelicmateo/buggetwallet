// A ledger row (label left, value right, optional muted line) that stacks the value under the label when the row is too narrow for the
// two side by side at the current text size, so no word is ever broken (320 dp at text scale 2.0). Wide rows are a plain [LineItem].
import 'package:flutter/material.dart';

import '../layout.dart';
import '../theme.dart';
import 'common.dart';

class LedgerRow extends StatelessWidget {
  final String label, value;
  final String? sub;
  final bool bold;
  final Color? valueColor;
  final Widget? leading;
  const LedgerRow(this.label, this.value, {super.key, this.sub, this.bold = false, this.valueColor, this.leading});

  /// The row width, in dp at text scale 1.0, under which the value goes below the label.
  static const stackBelow = 200.0;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth / scale >= stackBelow) return LineItem(label, value, sub: sub, bold: bold, valueColor: valueColor, leading: leading);
      final w = bold ? FontWeight.w600 : FontWeight.w500;
      return Container(
        constraints: const BoxConstraints(minHeight: rowMin),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            if (leading != null) ...[leading!, const SizedBox(width: 8)],
            Expanded(child: Text(label, style: TextStyle(fontWeight: w))),
          ]),
          if (sub != null) Text(sub!, style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
          const SizedBox(height: 2),
          Text(value, textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: w, color: valueColor)),
        ]),
      );
    });
  }
}
