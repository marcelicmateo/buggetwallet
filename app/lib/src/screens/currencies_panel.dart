import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// The readable text of an [ArgumentError] from core.
String _problem(Object e) {
  if (e is! ArgumentError) return 'Could not save. Try again.';
  final m = e.message.toString();
  if (m.isEmpty) return 'Could not save. Try again.';
  return '${m[0].toUpperCase()}${m.substring(1)}${m.endsWith('.') ? '' : '.'}'; // core's text, as a sentence
}

/// "1 $ = 0.9240 €": what a rate says, for the panel row.
String rateSentence(String code, int rate, String home) => '1 ${currencySymbol(code)} = ${rateText(rate)} ${currencySymbol(home)}';

/// Plan › Currencies (P15): a row per currency other than the wallet's that shows up in the payments (or has a rate). With a
/// rate its payments count at that rate; without one they stay out of every total ("Not counted"). Hidden when there is none.
class CurrenciesPanel extends StatelessWidget {
  final WalletController wc;
  const CurrenciesPanel({super.key, required this.wc});

  @override
  Widget build(BuildContext context) {
    final rows = wc.fxCurrencies();
    if (rows.isEmpty) return const SizedBox.shrink(key: ValueKey('currenciesPanel'));
    return Panel(key: const ValueKey('currenciesPanel'), children: [
      const SectionHead('Currencies'),
      Explainer(wc, 'currencies',
          'Payments in another currency count in your budget at a rate you set. Without a rate they are not counted. Your payments are not changed.'),
      Rows(children: [for (final r in rows) _CurrencyRow(wc, r)]),
    ]);
  }
}

class _CurrencyRow extends StatelessWidget {
  final WalletController wc;
  final FxCurrency row;
  const _CurrencyRow(this.wc, this.row);

  @override
  Widget build(BuildContext context) {
    final r = row.rate;
    final code = row.code;
    final rows = row.rows == 0 ? 'no payments now' : '${row.rows} ${row.rows == 1 ? 'payment' : 'payments'}';
    return Padding(
      key: ValueKey('fx:$code'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (r != null) ...[
          Text('$code — ${rateSentence(code, r.rate, wc.currency)}, set ${shortDateOrRaw(r.date)}',
              key: ValueKey('fxLine:$code'), style: const TextStyle(fontWeight: FontWeight.w500)),
          Text(rows, style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
        ] else ...[
          Row(key: ValueKey('fxLine:$code'), children: [
            Icon(Icons.block, size: 16, color: context.c.muted),
            const SizedBox(width: 6),
            Expanded(child: Text('$code — Not counted', style: const TextStyle(fontWeight: FontWeight.w500))),
          ]),
          if (row.stale?.home case final h?)
            Text('Rate was set for $h (set it again)',
                key: ValueKey('fxStale:$code'), style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
          Text(rows, style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
        ],
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 4, children: [
          if (r == null)
            TextButton(key: ValueKey('fxSet:$code'), onPressed: () => openFxSheet(context, wc, code), child: const Text('Set a rate'))
          else ...[
            TextButton(key: ValueKey('fxEdit:$code'), onPressed: () => openFxSheet(context, wc, code), child: const Text('Edit')),
            TextButton(
                key: ValueKey('fxRemove:$code'), onPressed: () => removeFxWithUndo(context, wc, code, r), child: const Text('Remove')),
          ],
        ]),
      ]),
    );
  }
}

Future<void> openFxSheet(BuildContext context, WalletController wc, String code) async {
  logNav('fx.open');
  await showSheet<bool>(context, FxSheet(wc: wc, code: code));
}

/// Removes the rate of [code] (its payments stop counting) and offers Undo, which sets the same rate again (dated today).
Future<void> removeFxWithUndo(BuildContext context, WalletController wc, String code, FxRate old) async {
  logNav('fx.remove');
  final messenger = ScaffoldMessenger.of(context);
  final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
  void say(String m, {String? label, VoidCallback? action}) =>
      toastOn(messenger, m, wide: wide, accessible: accessible, actionLabel: label, onAction: action);
  try {
    wc.removeFxRate(code);
  } catch (e, st) {
    logError(Logger('bw.fx'), 'fx.remove.failed', e, st);
    say(_problem(e));
    return;
  }
  say('Rate removed. $code is not counted.', label: 'Undo', action: () {
    try {
      wc.setFxRate(code, old.rate, date: old.date); // the rate comes back with its own date
    } catch (e, st) {
      logError(Logger('bw.fx'), 'fx.undo.failed', e, st);
      say(_problem(e));
    }
  });
}

/// "1 USD = [ 0.9240 ] EUR": sets the rate of [code]. Pops `true` once saved; core's text shows as `fxError`.
class FxSheet extends StatefulWidget {
  final WalletController wc;
  final String code;
  const FxSheet({super.key, required this.wc, required this.code});
  @override
  State<FxSheet> createState() => _FxSheetState();
}

class _FxSheetState extends State<FxSheet> {
  late final _rate = TextEditingController(
      text: switch (widget.wc.settings.fxRates[widget.code]) {
    final r? => rateText(r.rate),
    _ => '',
  });
  String? _error;

  @override
  void dispose() {
    _rate.dispose();
    super.dispose();
  }

  void _save() {
    final rate = parseFxRate(_rate.text);
    if (rate == null) {
      setState(() => _error = 'Enter a rate, like 0${numberStyle.decimal}9240. Up to 6 decimals.');
      return;
    }
    if (rate < FxRate.minRate || rate > FxRate.maxRate) {
      setState(() => _error = 'The rate must be above 0 and at most ${FxRate.maxRate ~/ FxRate.scale}.');
      return;
    }
    try {
      widget.wc.setFxRate(widget.code, rate);
      Navigator.pop(context, true);
    } on ArgumentError catch (e) {
      setState(() => _error = _problem(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = widget.code, home = widget.wc.currency;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading('Rate for $code', key: const ValueKey('fxSheet')),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('fxRateField'),
        controller: _rate,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _save(),
        style: numStyle.copyWith(fontSize: BwType.displaySize, fontWeight: FontWeight.w500),
        decoration: InputDecoration(labelText: 'Rate', prefixText: '1 $code = ', suffixText: home, hintText: '0${numberStyle.decimal}9240'),
      ),
      if (_error != null) ...[const SizedBox(height: 8), StatusLabel(key: const ValueKey('fxError'), good: false, text: _error!)],
      const SizedBox(height: 14),
      FilledButton(
          key: const ValueKey('fxSave'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: _save,
          child: const Text('Save rate')),
      const SizedBox(height: 8),
      Muted('Payments in $code count as $home at this rate. Each payment keeps its own $code amount.'),
    ]);
  }
}
