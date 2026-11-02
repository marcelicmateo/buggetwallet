// One editor for any synced column (FIELDS_PLAN F1): give it a `Col` from wallet_core, the current value and `onSave`, and it draws the
// right control for the column's kind. A sheet lists its columns (`for (final c in [BillCols.warrantyUntil, ...]) FieldEditor(c, ...)`),
// so adding a column to the sheet is one line. No money or date rules live here: the column checks a value (`Col.problem`, shown inline
// before onSave is called) and core checks the rest (onSave returns its refusal text, shown under the field).
//
//  * DateCol: the date field (opens the calendar), and while the date is empty or being changed a row of quick lengths (4d 14d 1m 1y 2y 5y)
//    with a small length field (`45d`, `2w`, `1m`, `5y`; `date_length.dart`). Lengths count from `lengthFrom`, else `today`.
//  * IntCol: a line "Label 3 days before" with Change, then a number field with the column's unit, Save and Cancel. With `autoSave` a plain
//    number field.
//  * MoneyCol: an amount field in the row's `currency` (wallet currency when omitted).
//  * EnumCol: choice chips (`labelOf` / `iconOf` give each value its words and icon; the value's name otherwise).
//  * TextCol: a text field (with `options`: a dropdown of them). FlagCol: a switch. RefCol and JsonCol are opaque to forms: nothing.
//
// Saving: dates, enum chips, flags, the IntCol line and `options` save at once (a tap is a decision). Text and money fields save with a Save
// button, or on every change with `autoSave` (a draft form: the sheet keeps the value and its own Save button checks it with core; an
// empty or unreadable amount is reported as null then). Keys derive from `id` (default: the column name in camelCase): the field `id`, chips
// `id:chip:4d`, `id:length`, `id:lengthError`, `id:<enum name>`, `idError`, `idChange`, `idDays`, `idSave`, `idCancel`.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wallet_core/wallet_core.dart';

import '../date_length.dart';
import '../format.dart';
import '../theme.dart';
import 'common.dart';

/// One choice of a [TextCol] shown as a dropdown (`FieldEditor(options:)`). [value] null = the column is empty.
class FieldOption {
  const FieldOption(this.value, this.label, {this.key});
  final String? value;
  final String label;
  final Key? key;
}

/// The key base of a column: `warranty_until` -> `warrantyUntil`.
String fieldId(Col c) => c.column.replaceAllMapped(RegExp(r'_([a-z])'), (m) => m[1]!.toUpperCase());

/// Quick lengths of a date field.
const fieldQuickLengths = ['4d', '14d', '1m', '1y', '2y', '5y'];

class FieldEditor extends StatefulWidget {
  const FieldEditor(
    this.col, {
    super.key,
    required this.value,
    required this.onSave,
    required this.today,
    this.id,
    this.label,
    this.currency,
    this.labelOf,
    this.iconOf,
    this.options,
    this.autoSave = false,
    this.lengths = true,
    this.lengthFrom,
    this.clearable,
    this.helper,
    this.hint,
    this.maxLength,
    this.autofocus = false,
    this.errorText,
    this.capitalize,
    this.large = false,
    this.zeroText,
    this.editPrompt,
    this.unknownLabel = 'Not in the list',
  });

  /// The column to edit.
  final Col col;

  /// Its current value (the column's Dart type: `String` for a date, `int` for a number or amount, the enum, `bool`), or null.
  final Object? value;

  /// Called with a new value (null = cleared) that passed `col.problem`. Returns core's refusal text, or null when it is saved (or kept).
  final String? Function(Object? value) onSave;

  /// Today, `YYYY-MM-DD` (the widget never reads the clock).
  final String today;

  /// The key base (see the file header). Default: [fieldId].
  final String? id;

  /// The words above the field, when they differ from the column's `label` ("Reminder", "What is it?").
  final String? label;

  /// MoneyCol: the row's currency code (the wallet's when null).
  final String? currency;

  /// EnumCol: the words and the icon of each value.
  final String Function(Enum value)? labelOf;
  final IconData Function(Enum value)? iconOf;

  /// TextCol: choose from these instead of typing.
  final List<FieldOption>? options;

  /// Text, money and number fields: call [onSave] on every change instead of waiting for Save.
  final bool autoSave;

  /// DateCol: offer the quick lengths and the length field.
  final bool lengths;

  /// DateCol: the date lengths count from (the bill's saved date); today when null or not a date.
  final String? lengthFrom;

  /// Show a clear button on a set value; default = the column is nullable.
  final bool? clearable;

  /// A muted line under the field (dates and text).
  final String? helper;

  /// Grey example text in an empty text field; [autofocus] puts the cursor there when the form opens.
  final String? hint;

  /// Text: stop typing at this many characters (the counter is hidden); core still refuses a longer value.
  final int? maxLength;
  final bool autofocus;

  /// A refusal the sheet worked out itself (core's text after its own Save); shown instead of the inline one.
  final String? errorText;

  final TextCapitalization? capitalize;

  /// MoneyCol: the big amount style.
  final bool large;

  /// IntCol: the line when the number is 0 ("Reminder on the day").
  final String? zeroText;

  /// TextCol with [options]: the words for a stored value that is not among them.
  final String unknownLabel;

  /// IntCol: the words before the number field ("Remind me"); [label] otherwise.
  final String? editPrompt;

  @override
  State<FieldEditor> createState() => _FieldEditorState();
}

class _FieldEditorState extends State<FieldEditor> {
  final _text = TextEditingController();
  final _length = TextEditingController();
  String? _problem, _lengthError;
  bool _changing = false, _lengths = false, _dirty = false;

  /// The last value this editor handed to onSave: a change of [FieldEditor.value] to it is the editor's own.
  Object? _reported;
  bool _hasReported = false;

  Col get _col => widget.col;
  String get _id => widget.id ?? fieldId(_col);
  String get _label => widget.label ?? _col.label;
  String get _currency => widget.currency ?? walletCurrencyCode;

  @override
  void initState() {
    super.initState();
    _text.text = _textOf(widget.value);
  }

  @override
  void didUpdateWidget(FieldEditor old) {
    super.didUpdateWidget(old);
    // The sheet changed the value itself (a name that follows the kind, a cleared date): show it, unless it is what was just typed.
    if (widget.value != old.value && !_dirty && !_changing) _text.text = _textOf(widget.value);
    final other = old.col != widget.col;
    // A value that came from outside (not the one this editor just reported) or another column: old refusals and length errors are stale.
    if (other || (widget.value != old.value && !(_hasReported && widget.value == _reported))) {
      _problem = _lengthError = null;
      if (other) _text.text = _textOf(widget.value);
    }
    if (other || (old.value != null && widget.value == null)) {
      _changing = false;
      _lengths = false;
      _problem = _lengthError = null;
      _length.clear();
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _length.dispose();
    super.dispose();
  }

  String _textOf(Object? v) => switch (v) {
        null => '',
        final int n when _col is MoneyCol => centsToFieldText(n, currency: _currency),
        final Object x => '$x',
      };

  void _report(Object? v) {
    _reported = v;
    _hasReported = true;
  }

  /// Checks [v] with the column, then hands it to the sheet. True when it was saved.
  bool _commit(Object? v) {
    final p = _col.problem(v, today: widget.today);
    if (p != null) {
      setState(() => _problem = p);
      return false;
    }
    _report(v);
    final refusal = widget.onSave(v);
    if (mounted) setState(() => _problem = refusal);
    return refusal == null;
  }

  String? get _shownError => widget.errorText ?? _problem;

  // ---------- dates ----------

  String get _from {
    final d = widget.lengthFrom;
    return d != null && isIsoDate(d) ? d : widget.today;
  }

  void _setDate(String? d) {
    setState(() {
      _lengthError = null;
      _lengths = false;
    });
    _length.clear();
    _commit(d);
  }

  void _applyLength(String text) {
    try {
      _setDate(addLength(_from, text));
    } on FormatException catch (e) {
      setState(() => _lengthError = e.message);
    }
  }

  Future<void> _pickDate() async {
    setState(() => _lengths = true);
    final c = _col as DateCol;
    final today = parseIso(widget.today);
    final first = c.notAfterToday ? parseIso(addDays(widget.today, -3650)) : DateTime(2000);
    final last = c.notAfterToday ? today : DateTime(2100, 12, 31);
    final v = widget.value;
    var initial = v is String && isIsoDate(v) ? parseIso(v) : today;
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final d = await showDatePicker(context: context, initialDate: initial, firstDate: first, lastDate: last);
    if (d != null && mounted) _setDate(isoDate(d));
  }

  Widget _lengthRow() => Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final q in fieldQuickLengths)
          ActionChip(
              key: ValueKey('$_id:chip:$q'),
              label: Text(q),
              visualDensity: VisualDensity.compact,
              labelPadding: const EdgeInsets.symmetric(horizontal: 1),
              onPressed: () => _applyLength(q)),
        SizedBox(
            width: 64,
            child: Semantics(
                label: 'Length',
                textField: true,
                child: TextField(
                    key: ValueKey('$_id:length'),
                    controller: _length,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    decoration: const InputDecoration(hintText: '45d', isDense: true),
                    onChanged: (_) {
                      if (_lengthError != null) setState(() => _lengthError = null);
                    },
                    onSubmitted: (t) {
                      if (t.trim().isNotEmpty) _applyLength(t);
                    }))),
      ]);

  Widget _date() {
    final v = widget.value is String ? widget.value as String : null, set = v != null;
    final clearable = (widget.clearable ?? _col.nullable) && set;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DateField(
          key: ValueKey(_id),
          label: _label,
          value: v,
          helper: widget.helper,
          onPick: _pickDate,
          onClear: clearable ? () => _setDate(null) : null),
      if (widget.lengths && (!set || _lengths)) ...[const SizedBox(height: 6), _lengthRow()],
      if (_lengthError != null) StatusLabel(key: ValueKey('$_id:lengthError'), good: false, text: _lengthError!),
      if (_shownError != null) ...[
        const SizedBox(height: 6),
        StatusLabel(key: ValueKey('${_id}Error'), good: false, text: _shownError!),
      ],
    ]);
  }

  // ---------- numbers ----------

  String _unitFor(int n) {
    final u = (_col as IntCol).unit ?? '';
    return n == 1 ? u.replaceFirst(RegExp(r'^days\b'), 'day') : u;
  }

  void _saveInt() {
    final n = int.tryParse(_text.text.trim());
    if (n == null) {
      setState(() => _problem = 'Enter a whole number.');
      return;
    }
    if (_commit(n)) setState(() => _changing = false);
  }

  Widget _int() {
    final c = _col as IntCol, n = widget.value is int ? widget.value as int : null;
    if (widget.autoSave) return _textField(keyboard: TextInputType.number, suffix: c.unit);
    if (!_changing) {
      final line = n == null ? '$_label: not set' : (n == 0 && widget.zeroText != null ? widget.zeroText! : '$_label $n ${_unitFor(n)}');
      return Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        Muted(line, key: ValueKey(_id)),
        TextButton(
            key: ValueKey('${_id}Change'),
            onPressed: () => setState(() {
                  _text.text = n == null ? '' : '$n';
                  _problem = null;
                  _changing = true;
                }),
            child: const Text('Change')),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Muted(widget.editPrompt ?? _label),
        SizedBox(
            width: 72,
            child: TextField(
                key: ValueKey('${_id}Days'),
                controller: _text,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.end,
                style: numStyle,
                decoration: const InputDecoration(isDense: true),
                onSubmitted: (_) => _saveInt())),
        if (c.unit != null) Muted(c.unit!),
        TextButton(key: ValueKey('${_id}Save'), onPressed: _saveInt, child: const Text('Save')),
        TextButton(
            key: ValueKey('${_id}Cancel'),
            onPressed: () => setState(() {
                  _changing = false;
                  _problem = null;
                }),
            child: const Text('Cancel')),
      ]),
      if (_shownError != null) StatusLabel(key: ValueKey('${_id}Error'), good: false, text: _shownError!),
    ]);
  }

  // ---------- text and money ----------

  void _typed(String t) {
    _dirty = true;
    if (_problem != null && widget.errorText == null) _problem = null;
    final c = _col;
    if (c is MoneyCol) {
      final cents = t.trim().isEmpty ? null : parseMoney(t, currency: _currency);
      if (widget.autoSave) {
        // Draft form: the sheet's own Save says what is wrong with a missing or unreadable amount.
        setState(() => _problem = cents != null ? c.problem(cents, today: widget.today) : null);
        _report(cents);
        widget.onSave(cents);
      } else {
        setState(() {});
      }
      return;
    }
    if (c is IntCol) {
      final n = int.tryParse(t.trim());
      setState(() => _problem = n != null && c.problem(n) != null ? c.problem(n) : null);
      _report(n);
      widget.onSave(n);
      return;
    }
    final v = t.isEmpty && _col.nullable ? null : t;
    if (widget.autoSave) {
      setState(() => _problem = _col.problem(v, today: widget.today));
      _report(v);
      widget.onSave(v);
    } else {
      setState(() {});
    }
  }

  void _saveTyped() {
    final t = _text.text, c = _col;
    if (c is MoneyCol) {
      final cents = t.trim().isEmpty ? null : parseMoney(t, currency: _currency);
      if (cents == null && !(t.trim().isEmpty && c.nullable)) {
        setState(() => _problem = invalidAmountMessage);
        return;
      }
      if (_commit(cents)) setState(() => _dirty = false);
      return;
    }
    if (_commit(t.isEmpty && c.nullable ? null : t)) setState(() => _dirty = false);
  }

  Widget _textField({TextInputType? keyboard, String? suffix}) {
    final money = _col is MoneyCol;
    final deco = InputDecoration(
        labelText: _label,
        helperText: widget.helper,
        helperMaxLines: 2,
        hintText: widget.hint ?? (money ? amountHintFor(_currency) : null),
        suffixText: money ? currencySymbol(_currency) : suffix,
        counterText: widget.maxLength == null ? null : '',
        errorText: _shownError,
        errorMaxLines: 3);
    final style = money ? (widget.large ? numStyle.copyWith(fontSize: BwType.displaySize, fontWeight: FontWeight.w500) : numStyle) : null;
    final field = money
        ? MoneyField(fieldKey: ValueKey(_id), controller: _text, onChanged: _typed, style: style, decoration: deco)
        : TextField(
            key: ValueKey(_id),
            controller: _text,
            autofocus: widget.autofocus,
            maxLength: widget.maxLength,
            keyboardType: keyboard,
            inputFormatters: keyboard == null ? null : [FilteringTextInputFormatter.allow(RegExp(r'[0-9-]'))],
            textCapitalization: widget.capitalize ?? TextCapitalization.none,
            onChanged: _typed,
            onSubmitted: (_) {
              if (!widget.autoSave) _saveTyped();
            },
            decoration: deco);
    if (widget.autoSave) return field;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: field),
      if (_dirty) TextButton(key: ValueKey('${_id}Save'), onPressed: _saveTyped, child: const Text('Save')),
    ]);
  }

  Widget _options(List<FieldOption> options) {
    final v = widget.value is String ? widget.value as String : null;
    // A stored value the list does not know (a deleted CSV layout) shows as its own option, never as "none": Save must not keep what the form hides.
    final shown = [if (v != null && !options.any((o) => o.value == v)) FieldOption(v, widget.unknownLabel), ...options];
    // The dropdown reads initialValue once: a new subtree per value shows what changed from outside.
    return KeyedSubtree(
        key: ValueKey('$_id:$v'),
        child: DropdownButtonFormField<String?>(
          key: ValueKey(_id),
          isExpanded: true,
          initialValue: v,
          decoration: InputDecoration(labelText: _label, errorText: _shownError, errorMaxLines: 3),
          items: [for (final o in shown) DropdownMenuItem<String?>(key: o.key, value: o.value, child: Text(o.label))],
          onChanged: _commit,
        ));
  }

  // ---------- choices ----------

  Widget _enum(EnumCol c) {
    final chosen = widget.value;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(_label, style: const TextStyle(fontWeight: FontWeight.w500)),
      const SizedBox(height: 6),
      Wrap(key: ValueKey(_id), spacing: 8, runSpacing: 8, children: [
        for (final e in c.values)
          ChoiceChip(
            key: ValueKey('$_id:${e.name}'),
            avatar: widget.iconOf == null ? null : Icon(widget.iconOf!(e), size: 18),
            label: Text(widget.labelOf?.call(e) ?? e.name),
            selected: chosen == e,
            onSelected: (_) {
              if (chosen != e) _commit(e);
            },
          ),
      ]),
      if (_shownError != null) ...[const SizedBox(height: 6), StatusLabel(key: ValueKey('${_id}Error'), good: false, text: _shownError!)],
    ]);
  }

  Widget _flag() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SwitchListTile(
            key: ValueKey(_id), contentPadding: EdgeInsets.zero, title: Text(_label), value: widget.value == true, onChanged: _commit),
        if (_shownError != null) StatusLabel(key: ValueKey('${_id}Error'), good: false, text: _shownError!),
      ]);

  @override
  Widget build(BuildContext context) {
    final opts = widget.options;
    return switch (_col) {
      DateCol() => _date(),
      IntCol() => _int(),
      MoneyCol() => _textField(),
      EnumCol() => _enum(_col as EnumCol),
      FlagCol() => _flag(),
      TextCol() when opts != null => _options(opts),
      TextCol() => _textField(),
      RefCol() || JsonCol() => const SizedBox.shrink(),
    };
  }
}
