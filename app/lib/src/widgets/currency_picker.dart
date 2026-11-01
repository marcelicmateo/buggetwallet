// The one place a currency is chosen (UX-A): a searchable list of every currency (code and name from core's `allCurrencies`), the
// wallet currency and the ones in use on top. Used by the account form, the payday plan, the CSV layout sheet and the rate form.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart' show CurrencyInfo, allCurrencies, currencyInfo;

import '../controller.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import 'common.dart';
import 'sheets.dart';

/// Which currencies a picker offers.
enum CurrencyChoice {
  /// Every currency.
  all,

  /// Money only, no coin (the wallet currency cannot be a crypto currency).
  fiat,

  /// Coins only (a crypto account).
  crypto,
}

/// "EUR · Euro" (or just the code for one that is not in the table).
String currencyLabel(String code) {
  final i = currencyInfo(code);
  return i == null ? code : '$code · ${i.name}';
}

/// Opens the picker and returns the chosen code, null when it is closed without a choice. [current] is marked; [exclude] codes are
/// not offered (the wallet currency in the rate form).
Future<String?> pickCurrency(
  BuildContext context,
  WalletController wc, {
  String? current,
  CurrencyChoice choice = CurrencyChoice.all,
  Set<String> exclude = const {},
}) {
  logNav('currency.pick');
  return showSheet<String>(context, CurrencyPicker(wc: wc, current: current, choice: choice, exclude: exclude), scrolls: false);
}

/// The sheet behind [pickCurrency]: a search box and the list. Pops the chosen code.
class CurrencyPicker extends StatefulWidget {
  final WalletController wc;
  final String? current;
  final CurrencyChoice choice;
  final Set<String> exclude;
  const CurrencyPicker({super.key, required this.wc, this.current, this.choice = CurrencyChoice.all, this.exclude = const {}});
  @override
  State<CurrencyPicker> createState() => _CurrencyPickerState();
}

class _CurrencyPickerState extends State<CurrencyPicker> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _offered(CurrencyInfo i) =>
      !widget.exclude.contains(i.code) &&
      switch (widget.choice) {
        CurrencyChoice.all => true,
        CurrencyChoice.fiat => !i.crypto,
        CurrencyChoice.crypto => i.crypto,
      };

  bool _matches(CurrencyInfo i, String q) => i.code.toLowerCase().startsWith(q) || i.name.toLowerCase().contains(q);

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final q = _search.text.trim().toLowerCase();
    final all = [
      for (final i in allCurrencies)
        if (_offered(i)) i
    ];
    final byCode = {for (final i in all) i.code: i};
    final List<(String?, List<CurrencyInfo>)> sections;
    if (q.isNotEmpty) {
      final hits = [
        for (final i in all)
          if (_matches(i, q)) i
      ];
      // A code that starts with the text comes before a name that merely contains it.
      hits.sort((a, b) {
        final x = a.code.toLowerCase().startsWith(q) ? 0 : 1, y = b.code.toLowerCase().startsWith(q) ? 0 : 1;
        return x != y ? x - y : a.code.compareTo(b.code);
      });
      sections = [(null, hits)];
    } else {
      final home = byCode[wc.currency];
      final recent = [
        for (final c in wc.recentCurrencies())
          if (byCode[c] != null) byCode[c]!
      ];
      final top = {if (home != null) home.code, ...recent.map((i) => i.code)};
      sections = [
        if (home != null) ('Your currency', [home]),
        if (recent.isNotEmpty) ('In use', recent),
        (
          'All currencies',
          [
            for (final i in all)
              if (!top.contains(i.code)) i
          ]
        ),
      ];
    }
    final height = (MediaQuery.sizeOf(context).height * 0.4).clamp(160.0, 440.0);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      const Heading('Choose a currency', key: ValueKey('currencyPickerHeading')),
      const SizedBox(height: 10),
      TextField(
        key: const ValueKey('currencySearch'),
        controller: _search,
        autofocus: false,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(labelText: 'Search', hintText: 'Code or name', prefixIcon: Icon(Icons.search)),
      ),
      const SizedBox(height: 6),
      SizedBox(
        height: math.max(height, 160),
        child: sections.every((s) => s.$2.isEmpty)
            ? const Align(alignment: Alignment.topLeft, child: EmptyNote('No currency matches.', key: ValueKey('currencyNone')))
            : ListView(key: const ValueKey('currencyList'), children: [
                for (final (title, items) in sections) ...[
                  if (title != null && items.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 2),
                      child: Text(title.toUpperCase(),
                          style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2, fontWeight: FontWeight.w600)),
                    ),
                  for (final i in items) _CurrencyRow(i, chosen: i.code == widget.current),
                ],
              ]),
      ),
    ]);
  }
}

class _CurrencyRow extends StatelessWidget {
  final CurrencyInfo info;
  final bool chosen;
  const _CurrencyRow(this.info, {required this.chosen});

  @override
  Widget build(BuildContext context) => InkWell(
        key: ValueKey('currency:${info.code}'),
        onTap: () => Navigator.pop(context, info.code),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: rowMin),
          child: Row(children: [
            SizedBox(width: 52, child: Text(info.code, style: numStyle.copyWith(fontWeight: FontWeight.w600))),
            Expanded(child: Text(info.name)),
            if (chosen) Icon(Icons.check, size: 18, color: context.c.accent, semanticLabel: 'Chosen'),
          ]),
        ),
      );
}

/// A form field that shows the chosen currency ("EUR · Euro") and opens the picker on tap. [onChanged] gets the new code.
class CurrencyField extends StatelessWidget {
  final WalletController wc;
  final String value;
  final ValueChanged<String> onChanged;
  final String label;
  final CurrencyChoice choice;
  final Set<String> exclude;

  /// Fixed: shown but not tappable (an account's currency cannot change).
  final bool enabled;
  const CurrencyField({
    super.key,
    required this.wc,
    required this.value,
    required this.onChanged,
    this.label = 'Currency',
    this.choice = CurrencyChoice.all,
    this.exclude = const {},
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: !enabled
            ? null
            : () async {
                final c = await pickCurrency(context, wc, current: value, choice: choice, exclude: exclude);
                if (c != null) onChanged(c);
              },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: touchMin),
          child: InputDecorator(
            decoration: InputDecoration(labelText: label, enabled: enabled, suffixIcon: enabled ? const Icon(Icons.arrow_drop_down) : null),
            child: Text(currencyLabel(value), key: const ValueKey('currencyValue')),
          ),
        ),
      );
}
