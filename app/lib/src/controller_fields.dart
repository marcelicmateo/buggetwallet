// One generic edit for the field editors (FIELDS_PLAN F1): `wc.patchField(BillCols.entity, id, BillCols.returnBy, '2027-05-01')`. A `part` of
// controller.dart so it can use `_changed`. Core's `repo.patch` checks every value with its column and the entity's own rules.
//
// Privacy: the log carries the entity name and the column names only, never a value.
part of 'controller.dart';

final _fieldLog = Logger('bw.fields');

extension FieldEdits on WalletController {
  /// Sets [col] of row [id] of [entity] to [value] (null or [clearValue] clears a nullable column). Returns null when it is saved, else
  /// core's refusal text (`<label>: <reason>`), and nothing was written.
  String? patchField(String entity, String id, Col col, Object? value) => patchFields(entity, id, {col: value});

  /// Sets several columns of one row in one write (all or none). Same result as [patchField]. With [prefixed] false the refusal comes
  /// without its `<column label>: ` start (a sheet whose labels differ from the columns'). [afterWrite] runs once the row is written,
  /// before the screens are told.
  String? patchFields(String entity, String id, Map<Col, Object?> values, {bool prefixed = true, void Function()? afterWrite}) {
    final columns = values.keys.map((c) => c.column).join(',');
    try {
      repo.patch(entity, id, values);
    } on ArgumentError catch (e) {
      logEvent(_fieldLog, Level.INFO, 'field.refused', {'entity': entity, 'columns': columns});
      var m = e.message.toString();
      if (!prefixed) {
        for (final c in values.keys) {
          if (m.startsWith('${c.label}: ')) m = m.substring(c.label.length + 2);
        }
      }
      return m;
    }
    afterWrite?.call();
    logEvent(_fieldLog, Level.INFO, 'field.patch', {'entity': entity, 'columns': columns});
    _changed();
    return null;
  }
}
