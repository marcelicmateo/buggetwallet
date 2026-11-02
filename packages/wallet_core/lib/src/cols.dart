/// Typed columns (FIELDS_PLAN.md, F1): one `Col` line declares a synced column with its type, nullability, default,
/// validation and label. A `Col` is the [ColumnDef] `entitySchema` uses, so the same line also gives the DDL, the add-
/// column migration, the type check of incoming sync ops, the snapshot writer, `isEmpty` and search; `WalletRepo.patch`
/// checks a value with [Col.problem] before it writes it, and a model reads it with [Col.read].
///
/// Entities declare their columns in a holder (`BillCols`, `AccountCols`): `entity`, one `static const` per column,
/// `all` in table order. `test/support/sim.dart` keeps its own column lists on purpose (an independent oracle).
library;

import 'dart:convert' show jsonDecode;

import 'dates.dart' show isIsoDate;
import 'models.dart' show WalletSettings;
import 'schema.dart';

/// In a `WalletRepo.patch` map: set this nullable column to none (null). A non-nullable column refuses it.
const Object clearValue = _ClearValue();

final class _ClearValue {
  const _ClearValue();
  @override
  String toString() => 'clearValue';
}

/// One synced column of [entity] (the op entity name, e.g. `bill`), stored as [column], holding a [T]. [label] is the
/// English name shown in forms, refusals and conflict text.
sealed class Col<T extends Object> extends ColumnDef {
  final String entity;
  final String label;

  /// What a row holds when the column has no (valid) value; for a non-nullable column also the DDL default.
  final T? defaultValue;

  const Col(this.entity, String column, {required super.type, required this.label, super.nullable, super.searchable, this.defaultValue})
      : super(column);

  /// The column name (as in ops and the table).
  String get column => name;

  /// What `entitySchema` uses (the DDL, the sync type check, search …): this column itself.
  ColumnDef get def => this;

  /// The value of this column in a stored [row] (a map as `SELECT *` gives it). Lenient: a missing, wrong-typed or
  /// out-of-range value reads as [defaultValue] (none for most columns), never throws.
  T? read(Map<String, Object?> row) => decode(row[name]) ?? defaultValue;

  /// [stored] as a [T], or null when it is none or not a valid value of this column.
  T? decode(Object? stored);

  /// [value] as it is stored and sent in ops (an enum as its wire name, a flag as 0/1).
  Object? encode(T value);

  /// Why [value] cannot be stored here, as a short reason without the label (null = fine). None (null) is fine only in
  /// a nullable column. [today] (`YYYY-MM-DD`) is needed only for [DateCol.notAfterToday].
  String? problem(T? value, {String? today}) => value == null ? (nullable ? null : 'Needs a value.') : null;

  /// The DDL default of a non-nullable column: [defaultValue] as an SQL literal (else `''` / `0`, [ColumnDef.ddl]).
  @override
  String? get defaultSql => switch (defaultValue) {
        null => null,
        final T v => switch (encode(v)) { final String s => "'${s.replaceAll("'", "''")}'", final x => '$x' },
      };

  /// Whether [value] has this column's Dart type (none counts).
  bool accepts(Object? value) => value == null || value is T;

  @override
  String toString() => '$entity.$name';
}

/// Free text, at least [minLength] and at most [maxLength] characters (counted as Unicode code points) when given.
final class TextCol extends Col<String> {
  final int? minLength, maxLength;
  const TextCol(super.entity, super.column,
      {required super.label, super.nullable, super.searchable, super.defaultValue, this.minLength, this.maxLength})
      : super(type: ColumnType.text);

  @override
  String? decode(Object? stored) => stored is String ? stored : null;
  @override
  Object? encode(String value) => value;
  @override
  String? problem(String? value, {String? today}) {
    if (value == null) return super.problem(value);
    final max = maxLength, min = minLength, n = value.runes.length;
    if (min != null && n < min) return 'At least $min characters.';
    return max != null && n > max ? 'Limited to $max characters.' : null;
  }
}

/// A real calendar date `YYYY-MM-DD`; with [notAfterToday] none after the device's today. With [rawRead] any stored text
/// reads as it is (a peer's `2026-02-30` stays that text, as models read it before F2); writes are checked either way.
final class DateCol extends Col<String> {
  final bool notAfterToday, rawRead;
  const DateCol(super.entity, super.column,
      {required super.label, super.nullable, super.searchable, this.notAfterToday = false, this.rawRead = false})
      : super(type: ColumnType.text);

  @override
  String? decode(Object? stored) => stored is String && (rawRead || isIsoDate(stored)) ? stored : null;
  @override
  Object? encode(String value) => value;
  @override
  String? problem(String? value, {String? today}) {
    if (value == null) return super.problem(value);
    if (!isIsoDate(value)) return 'Not a real date (YYYY-MM-DD).';
    if (notAfterToday && today != null && value.compareTo(today) > 0) return 'Cannot be in the future.';
    return null;
  }
}

/// A whole number within [min]..[max] (each optional); [unit] says what it counts (`days before`).
final class IntCol extends Col<int> {
  final int? min, max;
  final String? unit;
  const IntCol(super.entity, super.column,
      {required super.label, super.nullable, super.searchable, super.defaultValue, this.min, this.max, this.unit})
      : super(type: ColumnType.integer);

  @override
  int? decode(Object? stored) => stored is int && problem(stored) == null ? stored : null;
  @override
  Object? encode(int value) => value;
  @override
  String? problem(int? value, {String? today}) {
    if (value == null) return super.problem(value);
    final lo = min, hi = max, u = unit == null ? '' : ' $unit';
    if ((lo != null && value < lo) || (hi != null && value > hi)) {
      if (lo != null && hi != null) return '$lo to $hi$u.';
      return lo != null ? 'At least $lo$u.' : 'At most $hi$u.';
    }
    return null;
  }
}

/// An amount in stored minor units (cents; satoshis for BTC) of the currency in column [currencyCol]. Its magnitude is
/// at most [cap] (default [WalletSettings.maxAmount]): a typed value past it is refused, an incoming op past it is
/// skipped (the sync type check, Q3). [positive]: more than zero (a bill's total).
final class MoneyCol extends Col<int> {
  final String currencyCol;
  final int cap;
  final bool positive;
  const MoneyCol(super.entity, super.column,
      {required super.label,
      super.nullable,
      super.searchable,
      super.defaultValue,
      this.currencyCol = 'currency',
      this.cap = WalletSettings.maxAmount,
      this.positive = false})
      : super(type: ColumnType.integer);

  @override
  int? decode(Object? stored) => stored is int ? stored : null;
  @override
  Object? encode(int value) => value;
  @override
  String? problem(int? value, {String? today}) {
    if (value == null) return super.problem(value);
    // Both bounds, never `abs()`: the smallest int's abs() is itself (negative) and would pass.
    if (value > cap || value < -cap) return 'Over the allowed amount.';
    if (positive && value <= 0) return 'Must be more than zero.';
    return null;
  }
}

/// A yes/no, stored as 0/1 (never nullable).
final class FlagCol extends Col<bool> {
  const FlagCol(super.entity, super.column, {required super.label, super.defaultValue = false}) : super(type: ColumnType.flag);

  @override
  bool? decode(Object? stored) => switch (stored) { 1 => true, 0 => false, _ => null };
  @override
  Object? encode(bool value) => value ? 1 : 0;
}

/// One of [values], stored as its wire name: [Enum.name], or the name [wire] gives it. A word this build does not know
/// (a newer build's) reads as [defaultValue].
final class EnumCol<E extends Enum> extends Col<E> {
  final List<E> values;
  final Map<E, String>? wire;
  const EnumCol(super.entity, super.column, {required super.label, required this.values, super.nullable, super.defaultValue, this.wire})
      : super(type: ColumnType.text);

  String wireOf(E value) => wire?[value] ?? value.name;

  @override
  E? decode(Object? stored) {
    if (stored is! String) return null;
    for (final v in values) {
      if (wireOf(v) == stored) return v;
    }
    return null;
  }

  @override
  Object? encode(E value) => wireOf(value);
}

/// The id of a row of entity [target] (text).
final class RefCol extends Col<String> {
  final String target;
  const RefCol(super.entity, super.column, {required super.label, required this.target, super.nullable}) : super(type: ColumnType.text);

  @override
  String? decode(Object? stored) => stored is String ? stored : null;
  @override
  Object? encode(String value) => value;
  @override
  String? problem(String? value, {String? today}) {
    if (value == null) return super.problem(value);
    return value.isEmpty ? 'Needs an id.' : null;
  }
}

/// Text holding JSON, opaque to forms; [check] adds the column's own rule on the text (null = fine).
final class JsonCol extends Col<String> {
  final String? Function(String text)? check;
  const JsonCol(super.entity, super.column, {required super.label, super.nullable, super.defaultValue, this.check})
      : super(type: ColumnType.text);

  @override
  String? decode(Object? stored) => stored is String ? stored : null;
  @override
  Object? encode(String value) => value;
  @override
  String? problem(String? value, {String? today}) {
    if (value == null) return super.problem(value);
    try {
      jsonDecode(value);
    } on FormatException {
      return 'Not valid JSON.';
    }
    return check?.call(value);
  }
}

/// A model backed by its stored row: typed fields read through their `Col` (once, `late final`), and `model[col]` reads
/// any column (each call; for generic code such as forms).
abstract class RowModel {
  /// The stored row: a read-only copy of the map given, so a field decoded once never goes stale.
  final Map<String, Object?> row;
  RowModel(Map<String, Object?> row) : row = Map.unmodifiable(row);

  /// The value of [c] in this row ([Col.read]: lenient).
  Object? operator [](Col c) => c.read(row);
}
