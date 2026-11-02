import 'package:flutter/material.dart';

import '../controller.dart';
import '../layout.dart';
import '../logging.dart';
import '../widgets/common.dart';

/// Plan › Look: follow the system, or force the light or the dark ledger; how amounts are written. Kept on this device only.
class LookPanel extends StatelessWidget {
  final WalletController wc;
  const LookPanel({super.key, required this.wc});

  @override
  Widget build(BuildContext context) => Panel(children: [
        const SectionHead('Look'),
        SegmentedButton<String>(
          key: const ValueKey('themeMode'),
          showSelectedIcon: true,
          style: SegmentedButton.styleFrom(minimumSize: const Size(0, touchMin)),
          segments: const [
            ButtonSegment(value: 'system', label: Text('System'), icon: Icon(Icons.brightness_auto_outlined)),
            ButtonSegment(value: 'light', label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
            ButtonSegment(value: 'dark', label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
          ],
          selected: {wc.themeModeName},
          onSelectionChanged: (s) {
            logNav('theme.mode', {'mode': s.first});
            wc.setThemeMode(s.first);
          },
        ),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          key: const ValueKey('numberStyle'),
          showSelectedIcon: true,
          style: SegmentedButton.styleFrom(minimumSize: const Size(0, touchMin)),
          segments: const [
            ButtonSegment(value: 'point', label: Text('1,234.50')),
            ButtonSegment(value: 'comma', label: Text('1.234,50')),
          ],
          selected: {wc.numberStyleName},
          onSelectionChanged: (s) => wc.setNumberStyle(s.first),
        ),
        const Muted('Only this device. Your other devices keep their own look.'),
      ]);
}
