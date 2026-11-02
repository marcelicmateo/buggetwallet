// A planner input (ENG E6): its name and value on one line (a tap on the value types it), a slider under it. The value is shown and
// typed as the caller formats and parses it; this widget does no maths on money.
import 'package:flutter/material.dart';

import '../layout.dart';
import '../theme.dart';
import 'common.dart';

/// A small dialog with one text field; returns the text, or null when cancelled.
Future<String?> askText(BuildContext context,
        {required String title, String initial = '', String? suffix, String? hint, bool decimal = true, Key? fieldKey}) =>
    showDialog<String>(
        context: context,
        builder: (_) => _AskDialog(title: title, initial: initial, suffix: suffix, hint: hint, decimal: decimal, fieldKey: fieldKey));

class _AskDialog extends StatefulWidget {
  final String title, initial;
  final String? suffix, hint;
  final bool decimal;
  final Key? fieldKey;
  const _AskDialog({required this.title, required this.initial, this.suffix, this.hint, required this.decimal, this.fieldKey});
  @override
  State<_AskDialog> createState() => _AskDialogState();
}

class _AskDialogState extends State<_AskDialog> {
  late final ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          key: widget.fieldKey ?? const ValueKey('askField'),
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.numberWithOptions(decimal: widget.decimal),
          textAlign: TextAlign.end,
          style: numStyle,
          decoration: InputDecoration(suffixText: widget.suffix, hintText: widget.hint),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('askOk'), onPressed: () => Navigator.pop(context, ctl.text), child: const Text('OK')),
        ],
      );
}

/// [label] (with a muted [note]) and the tappable [valueText] on one line, the slider under it. [onChanged] runs while dragging, [onEnd]
/// when the thumb is let go (write then), [onType] when the value is tapped. Keys: `<id>:value`, `<id>:slider`.
class ParamSlider extends StatelessWidget {
  final String id, label, valueText;
  final String? note;
  final double value, min, max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onEnd;
  final VoidCallback onType;
  const ParamSlider(
      {super.key,
      required this.id,
      required this.label,
      required this.valueText,
      this.note,
      required this.value,
      required this.min,
      required this.max,
      this.divisions,
      required this.onChanged,
      required this.onEnd,
      required this.onType});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      HeadingRow(
        Text.rich(TextSpan(children: [
          TextSpan(text: label, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (note != null) TextSpan(text: ' · $note', style: TextStyle(color: c.muted, fontSize: BwType.metaSize)),
        ])),
        InkWell(
          key: ValueKey('$id:value'),
          onTap: onType,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: touchMin),
            child: Align(
              alignment: Alignment.centerRight,
              widthFactor: 1,
              child: Text(valueText,
                  textAlign: TextAlign.end, style: numStyle.copyWith(decoration: TextDecoration.underline, decorationColor: c.muted)),
            ),
          ),
        ),
      ),
      Slider(
        key: ValueKey('$id:slider'),
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        label: valueText,
        semanticFormatterCallback: (_) => '$label $valueText',
        activeColor: c.s6,
        onChanged: onChanged,
        onChangeEnd: onEnd,
      ),
    ]);
  }
}
