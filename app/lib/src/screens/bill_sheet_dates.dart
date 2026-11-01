// One date of the bill sheet's warranty section (a `part` of bill_sheet.dart, so it can read the sheet's state).
part of 'bill_sheet.dart';

/// The date field (full width, opens the calendar), quick lengths counted from the purchase date, a "Length" field (`45d`, `2w`,
/// `1m`, `5y`) and the one reminder line that serves it. The reminder days belong to this bill (its own value, else the wallet's
/// default); "Change" edits them here.
class _LengthDate extends StatefulWidget {
  const _LengthDate({
    super.key,
    required this.v,
    required this.id,
    required this.label,
    required this.value,
    required this.maxReminder,
    required this.reminderDays,
    required this.saveReminder,
    required this.onDate,
  });
  final _BillView v;
  final String id, label;
  final String? value;
  final int maxReminder, reminderDays;
  final bool Function(int days) saveReminder;
  final ValueChanged<String?> onDate;

  static const quick = ['4d', '14d', '1m', '1y', '2y', '5y'];

  @override
  State<_LengthDate> createState() => _LengthDateState();
}

class _LengthDateState extends State<_LengthDate> {
  final _length = TextEditingController();
  final _days = TextEditingController();
  String? _lengthError, _daysError;
  bool _changing = false;

  @override
  void dispose() {
    _length.dispose();
    _days.dispose();
    super.dispose();
  }

  /// Lengths count from the bill's purchase date, today when it has none.
  String get _from {
    final d = widget.v.s.date;
    return d != null && isIsoDate(d) ? d : widget.v.wc.today();
  }

  void _apply(String text) {
    try {
      final d = addLength(_from, text);
      setState(() => _lengthError = null);
      _length.clear();
      widget.v.s.edit(() => widget.onDate(d));
    } on FormatException catch (e) {
      setState(() => _lengthError = e.message);
    }
  }

  void _saveDays() {
    final n = int.tryParse(_days.text.trim());
    if (n == null || n < 0 || n > widget.maxReminder || !widget.saveReminder(n)) {
      setState(() => _daysError = 'From 0 to ${widget.maxReminder} days.');
      return;
    }
    setState(() {
      _daysError = null;
      _changing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.id, n = widget.reminderDays;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      widget.v.dateButton(widget.label, widget.value, widget.onDate, clearable: true),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final q in _LengthDate.quick)
          ActionChip(key: ValueKey('$id:chip:$q'), label: Text(q), visualDensity: VisualDensity.compact, onPressed: () => _apply(q)),
        SizedBox(
            width: 104,
            child: TextField(
                key: ValueKey('$id:length'),
                controller: _length,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Length', hintText: '45d', isDense: true),
                onChanged: (_) {
                  if (_lengthError != null) setState(() => _lengthError = null);
                },
                onSubmitted: (t) {
                  if (t.trim().isNotEmpty) _apply(t);
                })),
      ]),
      if (_lengthError != null) StatusLabel(key: ValueKey('$id:lengthError'), good: false, text: _lengthError!),
      if (widget.value != null) ...[
        const SizedBox(height: 4),
        if (!_changing)
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            Muted(key: ValueKey('$id:reminder'), n == 0 ? 'Reminder on the day' : 'Reminder $n ${n == 1 ? 'day' : 'days'} before'),
            TextButton(
                key: ValueKey('$id:reminderChange'),
                onPressed: () => setState(() {
                      _days.text = '$n';
                      _changing = true;
                    }),
                child: const Text('Change')),
          ])
        else
          Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Muted('Remind me'),
            SizedBox(
                width: 72,
                child: TextField(
                    key: ValueKey('$id:reminderDays'),
                    controller: _days,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.end,
                    style: numStyle,
                    decoration: const InputDecoration(isDense: true),
                    onSubmitted: (_) => _saveDays())),
            const Muted('days before'),
            TextButton(key: ValueKey('$id:reminderSave'), onPressed: _saveDays, child: const Text('Save')),
            TextButton(
                key: ValueKey('$id:reminderCancel'),
                onPressed: () => setState(() {
                      _changing = false;
                      _daysError = null;
                    }),
                child: const Text('Cancel')),
          ]),
        if (_daysError != null) StatusLabel(key: ValueKey('$id:reminderError'), good: false, text: _daysError!),
      ],
    ]);
  }
}
