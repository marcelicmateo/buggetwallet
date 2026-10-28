// Stage V (VC): the owner's words for a sync conflict (two devices hold different values for the same field with the same clock).
// Pure functions: the field in plain words and a value formatted for reading. Shown on screen only, never logged.
import 'dart:convert';

import 'controller.dart';
import 'format.dart';

/// One conflict as the page shows it: [what] names the row, [field] the field, [mine] / [theirs] the two values, all text.
class ConflictLine {
  final String id, what, field, mine, theirs;
  const ConflictLine({required this.id, required this.what, required this.field, required this.mine, required this.theirs});
}

const _moneyFields = {'amount', 'original_amount', 'expected_amount', 'min_amount', 'max_amount', 'opening', 'target', 'total', 'saved'};
const _moneySettings = {'salary', 'rent', 'rentCashThreshold', 'loan', 'headsUpCents'};
const _dateFields = {'date', 'next_due', 'due_date', 'ends_on', 'opening_date', 'return_by', 'warranty_until', 'paid_on'};

/// The field in plain words ("amount", "main tag", "deleted"); a setting's single `value` field is called "value".
String conflictFieldWord(String entity, String field) {
  if (field == 'deleted') return 'deleted';
  if (field == 'category' || field == 'own_category') return 'main tag';
  if (entity == 'setting' && field == 'value') return 'value';
  return changeFieldsText([field]);
}

/// [value] as text for the owner: money in the number style (1.234,50 €), dates as "5 Oct", deleted as "deleted", null as "empty".
String conflictValueText(String entity, String rowId, String field, Object? value, String currency) {
  var v = value;
  if (entity == 'setting' && v is String) {
    try {
      v = jsonDecode(v);
    } on FormatException {
      // not JSON: shown as it is
    }
  }
  if (v == null) return 'empty';
  if (field == 'deleted') return v == 1 || v == true ? 'deleted' : 'not deleted';
  final money = _moneyFields.contains(field) || (entity == 'setting' && (_moneySettings.contains(rowId) || rowId.startsWith('budget:')));
  if (money && v is int) return moneyExact(v, currency);
  if (v is String) {
    if (_dateFields.contains(field) || isCalendarDate(v)) return shortDateOrRaw(v);
    return v.isEmpty ? 'empty' : v;
  }
  if (v is bool) return v ? 'yes' : 'no';
  return '$v';
}

/// The row's name in the owner's words: a payment by its date and description, a setting by its plain name, anything else by its kind.
String conflictWhatText(WalletController wc, String entity, String rowId) {
  switch (entity) {
    case 'tx':
      final t = wc.wholeTxs.where((x) => x.tx.id == rowId).firstOrNull;
      if (t == null) return changeEntityWord(entity);
      final d = t.tx.description.trim();
      return d.isEmpty ? 'Payment ${shortDate(t.tx.date)}' : 'Payment ${shortDate(t.tx.date)} · $d';
    case 'setting':
      return changeSettingWord(rowId);
    default:
      return changeEntityWord(entity);
  }
}

/// A [ConflictLine] from the raw conflict: row name, field word and both values as text.
ConflictLine conflictLineOf(WalletController wc,
    {required String id, required String entity, required String rowId, required String field, Object? mine, Object? theirs}) {
  return ConflictLine(
    id: id,
    what: conflictWhatText(wc, entity, rowId),
    field: conflictFieldWord(entity, field),
    mine: conflictValueText(entity, rowId, field, mine, wc.currency),
    theirs: conflictValueText(entity, rowId, field, theirs, wc.currency),
  );
}
