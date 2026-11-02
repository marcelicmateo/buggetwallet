import 'package:flutter/material.dart';

import '../controller.dart';
import '../layout.dart';
import '../widgets/common.dart';

/// Settings › Look: which number tiles Today shows and in what order (UX-B B4). Device-local. A tile that has nothing to
/// show stays out of Today even when it is on; the tiles that need action are always first and not listed here.
class TodayTilesPanel extends StatelessWidget {
  final WalletController wc;
  const TodayTilesPanel({super.key, required this.wc});

  static const names = {
    'left': 'Left',
    'payday': 'Payday',
    'before': 'Before payday',
    'budget': 'Budget',
    'held': 'Held',
    'income': 'Income due',
    'reviewed': 'Reviewed',
    'foreign': 'Other currencies',
    'add': 'Add expense',
    'recent': 'Recent payments',
  };

  @override
  Widget build(BuildContext context) {
    final (:order, :hidden) = wc.todayTiles;

    void move(int i, int by) {
      final next = [...order];
      next.insert(i + by, next.removeAt(i));
      wc.setTodayTiles(next, hidden);
    }

    return Panel(children: [
      const SectionHead('Today tiles'),
      const Muted('Choose the tiles and their order. Tiles that need action stay on top. Only this device.'),
      for (var i = 0; i < order.length; i++)
        Row(children: [
          Expanded(
            child: SwitchListTile(
              key: ValueKey('todayTile:${order[i]}'),
              contentPadding: EdgeInsets.zero,
              title: Text(names[order[i]]!),
              value: !hidden.contains(order[i]),
              onChanged: (on) => wc.setTodayTiles(order, {...hidden}..toggle(order[i], !on)),
            ),
          ),
          IconButton(
            key: ValueKey('todayTileUp:${order[i]}'),
            tooltip: 'Move ${names[order[i]]} up',
            constraints: const BoxConstraints(minWidth: touchMin, minHeight: touchMin),
            icon: const Icon(Icons.arrow_upward),
            onPressed: i == 0 ? null : () => move(i, -1),
          ),
          IconButton(
            key: ValueKey('todayTileDown:${order[i]}'),
            tooltip: 'Move ${names[order[i]]} down',
            constraints: const BoxConstraints(minWidth: touchMin, minHeight: touchMin),
            icon: const Icon(Icons.arrow_downward),
            onPressed: i == order.length - 1 ? null : () => move(i, 1),
          ),
        ]),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const ValueKey('todayTilesReset'),
          onPressed: () => wc.setTodayTiles(DeviceSettings.todayTileIds, {}),
          child: const Text('Reset to default'),
        ),
      ),
    ]);
  }
}

extension on Set<String> {
  void toggle(String id, bool hide) => hide ? add(id) : remove(id);
}
