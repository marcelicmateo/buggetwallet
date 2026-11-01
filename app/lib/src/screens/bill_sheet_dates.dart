// One date of the bill sheet's warranty section (a `part` of bill_sheet.dart, so it can read the sheet's state).
part of 'bill_sheet.dart';

/// The date field (full width, opens the calendar) and, under it, ONE compact row of quick lengths (4d 14d 1m 1y 2y 5y) with a small
/// inline length field (`45d`, `2w`, `1m`, `5y`); lengths count from the bill's saved date, today without one. The row shows while the
/// date is empty and while the owner is changing it (a tap on the field); a set date shows the date and the reminder line. The
/// reminder days belong to this bill (its own value, else the wallet's default); "Change" edits them here.
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
  bool _changing = false, _lengths = false;

  @override
  void didUpdateWidget(_LengthDate old) {
    super.didUpdateWidget(old);
    // A cleared date starts over: no half-edited reminder, no old error.
    if (old.value != null && widget.value == null) {
      _changing = false;
      _lengths = false;
      _daysError = _lengthError = null;
      _length.clear();
    }
  }

  @override
  void dispose() {
    _length.dispose();
    _days.dispose();
    super.dispose();
  }

  /// Lengths count from the bill's saved date, today when it has none (not from the sheet's unsaved Date field).
  String get _from {
    final d = widget.v.b.date;
    return d != null && isIsoDate(d) ? d : widget.v.wc.today();
  }

  void _setDate(String? d) {
    setState(() {
      _lengthError = null;
      _lengths = false;
    });
    _length.clear();
    widget.v.s.edit(() => widget.onDate(d));
  }

  void _apply(String text) {
    try {
      _setDate(addLength(_from, text));
    } on FormatException catch (e) {
      setState(() => _lengthError = e.message);
    }
  }

  Future<void> _pick() async {
    setState(() => _lengths = true);
    final d = await widget.v.s._pick(widget.value);
    if (d != null && mounted) _setDate(d);
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

  Widget _lengthRow(String id) => Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final q in _LengthDate.quick)
          ActionChip(
              key: ValueKey('$id:chip:$q'),
              label: Text(q),
              visualDensity: VisualDensity.compact,
              labelPadding: const EdgeInsets.symmetric(horizontal: 1),
              onPressed: () => _apply(q)),
        SizedBox(
            width: 64,
            child: Semantics(
                label: 'Length',
                textField: true,
                child: TextField(
                    key: ValueKey('$id:length'),
                    controller: _length,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    decoration: const InputDecoration(hintText: '45d', isDense: true),
                    onChanged: (_) {
                      if (_lengthError != null) setState(() => _lengthError = null);
                    },
                    onSubmitted: (t) {
                      if (t.trim().isNotEmpty) _apply(t);
                    }))),
      ]);

  Widget _reminder(String id, int n) {
    if (!_changing) {
      return Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        Muted(key: ValueKey('$id:reminder'), n == 0 ? 'Reminder on the day' : 'Reminder $n ${n == 1 ? 'day' : 'days'} before'),
        TextButton(
            key: ValueKey('$id:reminderChange'),
            onPressed: () => setState(() {
                  _days.text = '$n';
                  _changing = true;
                }),
            child: const Text('Change')),
      ]);
    }
    return Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
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
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.id, set = widget.value != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DateField(label: widget.label, value: widget.value, onPick: _pick, onClear: set ? () => _setDate(null) : null),
      if (!set || _lengths) ...[const SizedBox(height: 6), _lengthRow(id)],
      if (_lengthError != null) StatusLabel(key: ValueKey('$id:lengthError'), good: false, text: _lengthError!),
      if (set) ...[
        const SizedBox(height: 4),
        _reminder(id, widget.reminderDays),
        if (_daysError != null) StatusLabel(key: ValueKey('$id:reminderError'), good: false, text: _daysError!),
      ],
    ]);
  }
}
