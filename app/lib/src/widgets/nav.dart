// The shell's navigation (ENG E1): Overview, Money, Explore, Plan, plus the Add button. A bar below 600 dp ([+] in the middle), a rail
// from 600 dp (Add first, Settings at the bottom). Pure widgets: the shell owns the state and the actions.
import 'package:flutter/material.dart';

import '../tabs.dart';
import '../theme.dart';

/// The four destinations, in page order (`Tabs.overview` .. `Tabs.plan`).
const navDestinations = [
  (label: 'Overview', icon: Icons.home_outlined, selected: Icons.home),
  (label: 'Money', icon: Icons.account_balance_wallet_outlined, selected: Icons.account_balance_wallet),
  (label: 'Explore', icon: Icons.insights_outlined, selected: Icons.insights),
  (label: 'Plan', icon: Icons.flag_outlined, selected: Icons.flag),
];

/// One destination as a bar slot (icon over label) or a rail row (icon beside the label when [wide]). 48 dp minimum height.
class NavItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected, wide;
  final VoidCallback onTap;
  final String tooltip;
  final Key? iconKey;

  /// Shown at the right end of a wide row (the shortcut of Add).
  final String? hint;
  const NavItem({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.tooltip,
    this.wide = false,
    this.iconKey,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = selected ? c.accent : c.muted;
    final style = TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w800 : FontWeight.w600, color: color);
    final glyph = Icon(icon, key: iconKey, size: 22, color: color);
    // The label never grows past the slot: it shrinks (the bar is 64 dp a slot at 320 dp).
    final text =
        FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1, style: wide ? style.copyWith(fontSize: BwType.bodySize) : style));
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: wide ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8) : const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(color: wide && selected ? c.surface2 : null, borderRadius: BorderRadius.circular(12)),
            child: wide
                ? Row(children: [
                    glyph,
                    const SizedBox(width: 12),
                    Flexible(child: Align(alignment: Alignment.centerLeft, child: text)),
                    if (hint != null) Text(hint!, style: numStyle.copyWith(fontSize: 11, color: c.muted)),
                  ])
                : Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                    glyph,
                    const SizedBox(height: 3),
                    text,
                  ]),
          ),
        ),
      ),
    );
  }
}

/// The accent Add button: a 54 dp rounded square in the bar, a full-width row in the rail ([wide]).
class AddButton extends StatelessWidget {
  final VoidCallback onTap;
  final String tooltip;
  final bool wide;
  final String? hint;
  const AddButton({super.key, required this.onTap, required this.tooltip, this.wide = false, this.hint});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final plus = Icon(Icons.add, key: const ValueKey('tab:add'), size: 26, color: c.bg);
    return Semantics(
      button: true,
      label: 'Add',
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: c.accent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: const ValueKey('addButton'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: wide
                ? Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: [
                      plus,
                      const SizedBox(width: 10),
                      Flexible(
                          child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text('Add', style: TextStyle(fontSize: BwType.bodySize, fontWeight: FontWeight.w800, color: c.bg)))),
                      if (hint != null) ...[
                        const Spacer(),
                        Text(hint!, style: numStyle.copyWith(fontSize: 11, color: c.bg)),
                      ],
                    ]),
                  )
                : SizedBox(width: 54, height: 54, child: Center(child: plus)),
          ),
        ),
      ),
    );
  }
}

/// The bottom bar: Overview, Money, [+], Explore, Plan. [selected] is a page index (`Tabs`); Settings (not in the bar) selects none.
class BwNavBar extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  final VoidCallback onAdd;
  final String Function(String label, String keys) hint;
  const BwNavBar({super.key, required this.selected, required this.onSelect, required this.onAdd, required this.hint});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    // Large text widens the labels, not the bar: they scale to at most 1.3 and shrink to fit their slot.
    final scaler = MediaQuery.textScalerOf(context);
    final clamped = scaler.clamp(maxScaleFactor: 1.3);
    Widget slot(int i) => Expanded(
          child: NavItem(
            label: navDestinations[i].label,
            icon: selected == i ? navDestinations[i].selected : navDestinations[i].icon,
            iconKey: ValueKey('tab:${Tabs.names[i]}'),
            selected: selected == i,
            tooltip: hint(navDestinations[i].label, 'Ctrl+${i + 1}'),
            onTap: () => onSelect(i),
          ),
        );
    return DecoratedBox(
      key: const ValueKey('navBar'),
      decoration: BoxDecoration(color: c.surface, border: Border(top: BorderSide(color: c.line))),
      child: SafeArea(
        top: false,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: clamped),
          child: SizedBox(
            height: 72,
            child: Row(children: [
              slot(Tabs.overview),
              slot(Tabs.money),
              Expanded(child: Center(child: AddButton(onTap: onAdd, tooltip: hint('Add', 'Ctrl+N')))),
              slot(Tabs.explore),
              slot(Tabs.plan),
            ]),
          ),
        ),
      ),
    );
  }
}
