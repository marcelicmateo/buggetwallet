import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:wallet_importer/wallet_importer.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// Opens the Map columns sheet for a CSV no bank profile and no saved layout fits (P12). Returns the owner's choice, or null
/// on Cancel / close (nothing is imported then). Logs `csvmap.open` and the result word only, never headers or cells.
Future<CsvChoice?> openMapColumns(BuildContext context, WalletController wc, CsvShape shape, Uint8List bytes, {CsvMapping? editing}) {
  logNav('csvmap.open', {'cols': shape.headers.length, 'rows': shape.rowCount, 'edit': editing != null});
  return showSheet<CsvChoice>(context, MapColumnsSheet(wc: wc, shape: shape, bytes: bytes, editing: editing));
}

const _dateFormatNames = {
  CsvDateFormat.dmyDot: '31.12.2026',
  CsvDateFormat.dmyDotShort: '1.2.2026',
  CsvDateFormat.iso: '2026-12-31',
  CsvDateFormat.dmySlash: 'day/month/year',
  CsvDateFormat.mdySlash: 'month/day/year',
  CsvDateFormat.dmyDash: '31-12-2026',
};

const _fixedCurrencies = ['EUR', 'USD', 'GBP', 'CHF'];

/// The Map columns sheet: pick what each column means, see the first rows read that way (signed amounts in the wallet's number
/// style), and Save & import once there is no problem. Pops a [CsvChoice]. With [editing] (a saved layout, read again from a file of
/// the same shape) the pickers start from that layout, the header row stays as it is and the button says Save.
class MapColumnsSheet extends StatefulWidget {
  final WalletController wc;
  final CsvShape shape;
  final Uint8List bytes;
  final CsvMapping? editing;
  const MapColumnsSheet({super.key, required this.wc, required this.shape, required this.bytes, this.editing});
  @override
  State<MapColumnsSheet> createState() => _MapColumnsSheetState();
}

class _MapColumnsSheetState extends State<MapColumnsSheet> {
  late CsvShape _shape = widget.shape;
  int _gen = 0; // bumped when the pickers must start over (another header row)
  String? _headerError;
  late final _name = TextEditingController();

  int? _dateCol, _amountCol, _debitCol, _creditCol, _currencyCol, _skipCol;
  bool _split = false, _negate = false;
  CsvDateFormat _dateFormat = CsvDateFormat.dmyDot;
  CsvDecimal _decimal = CsvDecimal.comma;
  List<int> _desc = [];
  String? _currencyCode;

  @override
  void initState() {
    super.initState();
    final start = widget.editing ?? guessMapping(_shape);
    _load(start);
    _name.text = start?.name ?? 'CSV file';
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _load(CsvMapping? g) {
    _dateCol = g?.dateCol;
    _dateFormat = g?.dateFormat ?? CsvDateFormat.dmyDot;
    _split = g != null && g.amountCol == null && (g.debitCol != null || g.creditCol != null);
    _amountCol = g?.amountCol;
    _debitCol = g?.debitCol;
    _creditCol = g?.creditCol;
    _decimal = g?.decimal ?? CsvDecimal.comma;
    _negate = g?.negate ?? false;
    _desc = [...?g?.descriptionCols];
    _currencyCol = g?.currencyCol;
    _currencyCode = g?.currencyCode;
    _skipCol = g?.skipIfEmptyCol;
  }

  /// The mapping as it stands; a column not chosen yet is -1 or null, which core's own checks name ([CsvMapping.structureProblems]).
  CsvMapping get _mapping => CsvMapping(
        name: _name.text.trim(),
        headerRow: _shape.headerRow,
        dateCol: _dateCol ?? -1,
        dateFormat: _dateFormat,
        amountCol: _split ? null : _amountCol,
        debitCol: _split ? _debitCol : null,
        creditCol: _split ? _creditCol : null,
        decimal: _decimal,
        negate: _negate,
        descriptionCols: _desc,
        currencyCol: _currencyCol,
        currencyCode: _currencyCol == null ? _currencyCode : null,
        skipIfEmptyCol: _skipCol,
        headers: _shape.headers,
      );

  /// Core's problems for the mapping on this file: its own first, then those of the first rows (texts may quote a cell: never logged).
  List<String> _problems(CsvMapping m) => mappingProblems(_shape, m);

  void _readFromRow(int row) {
    try {
      final next = csvShape(widget.bytes, headerRow: row);
      setState(() {
        _shape = next;
        _headerError = null;
        _gen++;
        _load(guessMapping(next));
      });
    } on ImportException catch (e) {
      setState(() => _headerError = e.message);
    } on RangeError {
      setState(() => _headerError = layoutMismatchMessage);
    }
  }

  String _col(int i) {
    final h = i < _shape.headers.length ? _shape.headers[i].trim() : '';
    return h.isEmpty ? 'Column ${i + 1}' : '${i + 1}. $h';
  }

  Widget _gap() => const SizedBox(height: 12);

  Widget _colPicker(String id, String label, int? value, ValueChanged<int?> onChanged, {String none = 'Choose…', bool optional = false}) =>
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: DropdownButtonFormField<int?>(
          key: ValueKey('csvMap:$id'),
          isExpanded: true,
          initialValue: value,
          decoration: InputDecoration(labelText: label),
          items: [
            DropdownMenuItem<int?>(value: null, child: Text(optional ? 'None' : none)),
            for (var i = 0; i < _shape.headers.length; i++)
              DropdownMenuItem<int?>(value: i, child: Text(_col(i), overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => onChanged(v)),
        ),
      );

  void _save() {
    final m = _mapping;
    if (_problems(m).isNotEmpty) return;
    logNav('csvmap.save', {'split': _split, 'negate': _negate, 'desc': _desc.length});
    // A layout being changed keeps its own header row (this file may have a title line more or less): that is no change of reading.
    final own = widget.editing?.headerRow;
    Navigator.pop(context, CsvChoice(_shape.shapeId, own == null ? m : m.copyWith(headerRow: own)));
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final m = _mapping;
    final problems = _problems(m);
    final ready = m.structureProblems(columns: _shape.headers.length).isEmpty;
    final preview = ready ? previewMapping(_shape, m, walletCurrency: wc.currency) : const <CsvPreviewRow>[];
    final editing = widget.editing != null;
    final c = context.c;
    return KeyedSubtree(
      key: ValueKey('csvMapSheet:$_gen'),
      child: Column(key: const ValueKey('csvMapSheet'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Heading(editing ? 'Change columns' : 'Map columns'),
        const SizedBox(height: 6),
        Muted(editing
            ? 'Say what each column is. Files that look like this one are read this way.'
            : "This file isn't one I know yet. Say what each column is once; it's remembered for files that look the same."),
        const SizedBox(height: 4),
        Muted('${_shape.encoding}, ${_shape.delimiterName}, ${_shape.rowCount} rows.'),
        _gap(),
        DropdownButtonFormField<int>(
          key: const ValueKey('csvMap:headerRow'),
          isExpanded: true,
          initialValue: _shape.headerRow,
          decoration: const InputDecoration(labelText: 'Header row (the column names)'),
          items: [
            const DropdownMenuItem<int>(value: csvNoHeader, child: Text('No header row (columns are numbered)')),
            for (var i = 0; i < _shape.head.length; i++)
              DropdownMenuItem<int>(value: i, child: Text('Row ${i + 1}: ${_shape.head[i].join(' · ')}', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: editing
              ? null
              : (v) {
                  if (v != null && v != _shape.headerRow) _readFromRow(v);
                },
        ),
        if (_headerError != null) ...[
          const SizedBox(height: 6),
          StatusLabel(key: const ValueKey('csvMapHeaderError'), good: false, text: _headerError!)
        ],
        _gap(),
        TextField(
          key: const ValueKey('csvMap:name'),
          controller: _name,
          maxLength: CsvMapping.maxName,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Name of this layout', counterText: ''),
        ),
        _colPicker('date', 'Date', _dateCol, (v) => _dateCol = v),
        _gap(),
        DropdownButtonFormField<CsvDateFormat>(
          key: const ValueKey('csvMap:dateFormat'),
          isExpanded: true,
          initialValue: _dateFormat,
          decoration: const InputDecoration(labelText: 'Date looks like'),
          items: [for (final f in CsvDateFormat.values) DropdownMenuItem(value: f, child: Text(_dateFormatNames[f] ?? f.pattern))],
          onChanged: (v) => setState(() => _dateFormat = v ?? _dateFormat),
        ),
        _gap(),
        Wrap(spacing: 8, runSpacing: 4, children: [
          ChoiceChip(
              key: const ValueKey('csvMap:amountOne'),
              label: const Text('One amount column'),
              selected: !_split,
              onSelected: (_) => setState(() => _split = false)),
          ChoiceChip(
              key: const ValueKey('csvMap:amountSplit'),
              label: const Text('Debit and credit'),
              selected: _split,
              onSelected: (_) => setState(() => _split = true)),
        ]),
        if (!_split)
          _colPicker('amount', 'Amount', _amountCol, (v) => _amountCol = v)
        else ...[
          _colPicker('debit', 'Debit (money out)', _debitCol, (v) => _debitCol = v),
          _colPicker('credit', 'Credit (money in)', _creditCol, (v) => _creditCol = v),
        ],
        _gap(),
        DropdownButtonFormField<CsvDecimal>(
          key: const ValueKey('csvMap:decimal'),
          isExpanded: true,
          initialValue: _decimal,
          decoration: const InputDecoration(labelText: 'Numbers look like'),
          items: const [
            DropdownMenuItem(value: CsvDecimal.comma, child: Text('1.234,56 (comma)')),
            DropdownMenuItem(value: CsvDecimal.point, child: Text('1,234.56 (point)')),
          ],
          onChanged: (v) => setState(() => _decimal = v ?? _decimal),
        ),
        CheckboxListTile(
          key: const ValueKey('csvMap:negate'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          value: _negate,
          onChanged: (v) => setState(() => _negate = v ?? false),
          title: const Text('Spending is shown as positive'),
        ),
        const SizedBox(height: 4),
        const Eyebrow('Description (pick up to 5)'),
        const SizedBox(height: 6),
        Wrap(key: const ValueKey('csvMap:description'), spacing: 8, runSpacing: 4, children: [
          for (var i = 0; i < _shape.headers.length; i++)
            FilterChip(
              key: ValueKey('csvMap:description:$i'),
              label: Text(_col(i), overflow: TextOverflow.ellipsis),
              selected: _desc.contains(i),
              onSelected: (on) => setState(() {
                if (on) {
                  if (_desc.length < CsvMapping.maxDescriptionCols) _desc = [..._desc, i];
                } else {
                  _desc = [..._desc]..remove(i);
                }
              }),
            ),
        ]),
        _gap(),
        DropdownButtonFormField<String?>(
          key: const ValueKey('csvMap:currency'),
          isExpanded: true,
          initialValue: _currencyCol != null ? 'col:$_currencyCol' : _currencyCode,
          decoration: const InputDecoration(labelText: 'Currency'),
          items: [
            DropdownMenuItem<String?>(value: null, child: Text('Wallet currency (${wc.currency})')),
            for (var i = 0; i < _shape.headers.length; i++)
              DropdownMenuItem<String?>(value: 'col:$i', child: Text('In column ${_col(i)}', overflow: TextOverflow.ellipsis)),
            for (final code in _fixedCurrencies) DropdownMenuItem<String?>(value: code, child: Text('Always $code')),
          ],
          onChanged: (v) => setState(() {
            _currencyCol = null;
            _currencyCode = null;
            if (v != null && v.startsWith('col:')) {
              _currencyCol = int.parse(v.substring(4));
            } else {
              _currencyCode = v;
            }
          }),
        ),
        _colPicker('skip', 'Skip rows where this is empty', _skipCol, (v) => _skipCol = v, optional: true),
        const SizedBox(height: 16),
        const Eyebrow('First rows, as they would be read'),
        const SizedBox(height: 6),
        if (!ready)
          const Muted('Pick the date and the amount to see the rows.', key: ValueKey('csvMapPreviewEmpty'))
        else
          Column(key: const ValueKey('csvMapPreview'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final r in preview) _PreviewRow(r, fallbackCurrency: wc.currency),
          ]),
        if (problems.isNotEmpty) ...[
          const SizedBox(height: 12),
          Column(key: const ValueKey('csvMapProblems'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final p in problems) Padding(padding: const EdgeInsets.only(bottom: 4), child: StatusLabel(good: false, text: p)),
          ]),
        ] else ...[
          const SizedBox(height: 12),
          const StatusLabel(key: ValueKey('csvMapOk'), good: true, text: 'These rows read correctly.'),
        ],
        const SizedBox(height: 14),
        FilledButton(
            key: const ValueKey('csvMapSave'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
            onPressed: problems.isEmpty ? _save : null,
            child: Text(editing ? 'Save' : 'Save & import')),
        const SizedBox(height: 8),
        TextButton(
            key: const ValueKey('csvMapCancel'),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(buttonMin), foregroundColor: c.ink2),
            onPressed: () {
              logNav('csvmap.cancel');
              Navigator.pop(context);
            },
            child: const Text('Cancel')),
      ]),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  final CsvPreviewRow row;
  final String fallbackCurrency;
  const _PreviewRow(this.row, {required this.fallbackCurrency});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final Widget body;
    if (row.skipped) {
      body = Muted('Row ${row.row + 1}: left out (empty)');
    } else if (row.problem != null) {
      body = StatusLabel(good: false, text: row.problem!);
    } else {
      final cents = row.amountMinor!;
      final cur = row.currency ?? fallbackCurrency;
      body = SplitRow(
        start: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(shortDateOrRaw(row.date!), style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
          Text(row.description.isEmpty ? '(no description)' : row.description, maxLines: 2, overflow: TextOverflow.ellipsis),
        ]),
        end: MoneyText(moneyExactSigned(cents, cur), textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500)),
      );
    }
    return RuledRow(key: ValueKey('csvMapPreview:${row.row}'), padding: const EdgeInsets.symmetric(vertical: 6), child: body);
  }
}
