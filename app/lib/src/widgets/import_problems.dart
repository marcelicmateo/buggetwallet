// Why rows of a bank file were left out (UX-A): core's `ImportBatch.problems`, one plain line per row ("Row 3: the amount -12.345 has
// more than 2 decimals"). Few reasons show at once; a long list is collapsed behind one button. Shown in the import preview and under
// the result line of a file. The texts hold amounts as written, so they are shown but never logged.
import 'package:flutter/material.dart';

import '../theme.dart';
import 'common.dart';

/// Most reasons the expanded list prints; the rest are counted.
const importProblemsShown = 100;

/// Reasons up to this many show without a button.
const importProblemsOpen = 3;

class ImportProblems extends StatefulWidget {
  final List<String> problems;

  /// How many rows were left out in all (some may have no reason); 0 = the number of [problems].
  final int invalid;

  /// Print "N rows left out" first (the preview); the result line already says it.
  final bool header;
  const ImportProblems({super.key, required this.problems, this.invalid = 0, this.header = true});

  @override
  State<ImportProblems> createState() => _ImportProblemsState();
}

class _ImportProblemsState extends State<ImportProblems> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.problems;
    final n = widget.invalid > p.length ? widget.invalid : p.length;
    if (n == 0) return const SizedBox.shrink();
    final long = p.length > importProblemsOpen;
    final shown = (!long || _open) ? p.take(importProblemsShown).toList() : const <String>[];
    return Column(key: const ValueKey('importProblems'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.header)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child:
              StatusLabel(key: const ValueKey('importProblemsHeader'), good: false, text: n == 1 ? '1 row left out' : '$n rows left out'),
        ),
      if (long)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
              key: const ValueKey('importProblemsToggle'),
              icon: Icon(_open ? Icons.expand_less : Icons.expand_more, size: 20),
              label: Text(_open ? 'Hide the reasons' : 'Show the reasons (${p.length})'),
              onPressed: () => setState(() => _open = !_open)),
        ),
      for (final (i, s) in shown.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(s, key: ValueKey('importProblem:$i'), style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
        ),
      if (_open && p.length > importProblemsShown)
        Muted('and ${p.length - importProblemsShown} more', key: const ValueKey('importProblemsRest')),
    ]);
  }
}
