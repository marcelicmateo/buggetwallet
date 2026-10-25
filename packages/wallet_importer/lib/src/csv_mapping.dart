// The owner's column mapping for a CSV the bank profiles don't know (P12, docs/context/P12_SPEC.md §1). Columns are
// 0-based indexes into the header row; rows are 0-based indexes into the file's rows as `readCsv` reads them (blank
// lines are not rows).

/// Most columns a mapped CSV may have; more is refused (`tooManyColumnsMessage`).
const maxCsvColumns = 200;

/// Longest header name a stored layout may keep.
const maxCsvHeaderChars = 200;

/// The date layouts a mapped date column can have. A trailing time (`… 14:22`, `…T14:22:00`) is ignored.
enum CsvDateFormat {
  dmyDot('dd.mm.yyyy'),
  dmyDotShort('d.m.yyyy'),
  iso('yyyy-mm-dd'),
  dmySlash('dd/mm/yyyy'),
  mdySlash('mm/dd/yyyy'),
  dmyDash('dd-mm-yyyy');

  const CsvDateFormat(this.pattern);

  /// How the owner sees it and how it is stored: `dd.mm.yyyy`, …
  final String pattern;

  static CsvDateFormat? byPattern(String p) {
    for (final f in values) {
      if (f.pattern == p) return f;
    }
    return null;
  }
}

/// The decimal mark of the amounts: `comma` = `1.234,56`, `point` = `1,234.56`.
enum CsvDecimal { comma, point }

/// How the columns of one CSV shape map to a transaction. Stored as JSON ([toJson]) in the synced setting
/// `csvmap:<shapeId>`. Amounts are either one signed column ([amountCol]) or a debit (money out) and a credit (money in)
/// column ([debitCol], [creditCol]); [negate] flips the sign for exports that show spending as positive.
class CsvMapping {
  /// Longest [name], in characters.
  static const maxName = 30;

  /// Most [descriptionCols].
  static const maxDescriptionCols = 5;

  /// The owner's label for the layout (1–[maxName] characters), shown on import results and accounts.
  final String name;

  /// The header row (0-based); transactions are the rows after it. -1 (`csvNoHeader`) = the file has no header row:
  /// every row is a transaction and [headers] are `Column 1`, `Column 2`, …
  final int headerRow;
  final int dateCol;
  final CsvDateFormat dateFormat;

  /// One signed amount column, or null when [debitCol] and [creditCol] are used.
  final int? amountCol;
  final int? debitCol;
  final int? creditCol;
  final CsvDecimal decimal;
  final bool negate;

  /// Columns joined with " · " (empty parts left out) into the description.
  final List<int> descriptionCols;

  /// A column holding the ISO currency code, or null for [currencyCode].
  final int? currencyCol;

  /// A fixed ISO currency code, or null for the wallet's currency (when [currencyCol] is null too).
  final String? currencyCode;

  /// A row whose cell in this column is empty is skipped (counted in `ImportBatch.skipped`), e.g. pending rows.
  final int? skipIfEmptyCol;

  /// The header names the layout was made from (for "see the columns" and to refuse another file's columns).
  final List<String> headers;

  const CsvMapping({
    required this.name,
    required this.headerRow,
    required this.dateCol,
    required this.dateFormat,
    this.amountCol,
    this.debitCol,
    this.creditCol,
    this.decimal = CsvDecimal.comma,
    this.negate = false,
    this.descriptionCols = const [],
    this.currencyCol,
    this.currencyCode,
    this.skipIfEmptyCol,
    this.headers = const [],
  });

  /// Whether the amount comes from a debit and a credit column.
  bool get splitAmount => amountCol == null;

  static const _unset = Object();

  /// A copy with the given fields changed. Pass `null` explicitly to clear a nullable field (`amountCol: null`).
  CsvMapping copyWith({
    String? name,
    int? headerRow,
    int? dateCol,
    CsvDateFormat? dateFormat,
    Object? amountCol = _unset,
    Object? debitCol = _unset,
    Object? creditCol = _unset,
    CsvDecimal? decimal,
    bool? negate,
    List<int>? descriptionCols,
    Object? currencyCol = _unset,
    Object? currencyCode = _unset,
    Object? skipIfEmptyCol = _unset,
    List<String>? headers,
  }) =>
      CsvMapping(
        name: name ?? this.name,
        headerRow: headerRow ?? this.headerRow,
        dateCol: dateCol ?? this.dateCol,
        dateFormat: dateFormat ?? this.dateFormat,
        amountCol: identical(amountCol, _unset) ? this.amountCol : amountCol as int?,
        debitCol: identical(debitCol, _unset) ? this.debitCol : debitCol as int?,
        creditCol: identical(creditCol, _unset) ? this.creditCol : creditCol as int?,
        decimal: decimal ?? this.decimal,
        negate: negate ?? this.negate,
        descriptionCols: descriptionCols ?? this.descriptionCols,
        currencyCol: identical(currencyCol, _unset) ? this.currencyCol : currencyCol as int?,
        currencyCode: identical(currencyCode, _unset) ? this.currencyCode : currencyCode as String?,
        skipIfEmptyCol: identical(skipIfEmptyCol, _unset) ? this.skipIfEmptyCol : skipIfEmptyCol as int?,
        headers: headers ?? this.headers,
      );

  /// What is wrong with the mapping itself, as owner-readable texts (empty = usable). [columns] is the number of
  /// columns of the file it is used on (null = [headers]' length when known, else not checked).
  List<String> structureProblems({int? columns}) {
    final out = <String>[];
    final n = name.trim();
    if (n.isEmpty) out.add('Give the layout a name.');
    if (n.runes.length > maxName) out.add('The name is limited to $maxName characters.');
    // -1 = the file has no header row (csvNoHeader).
    if (headerRow < -1) out.add('Pick the header row.');
    if (headers.length > maxCsvColumns || headers.any((h) => h.length > maxCsvHeaderChars)) {
      out.add('This layout has too many or too long column names.');
    }
    final width = columns ?? (headers.isEmpty ? null : headers.length);
    bool bad(int? c) => c != null && (c < 0 || (width != null && c >= width));
    if (bad(dateCol)) out.add('Pick the date column.');
    if (amountCol != null) {
      if (bad(amountCol)) out.add('Pick the amount column.');
      if (debitCol != null || creditCol != null) out.add('Use one amount column, or a debit and a credit column.');
    } else if (debitCol == null || creditCol == null) {
      out.add(debitCol == null && creditCol == null ? 'Pick the amount column.' : 'Pick both the debit and the credit column.');
    } else {
      if (bad(debitCol) || bad(creditCol)) out.add('Pick both the debit and the credit column.');
      if (debitCol == creditCol) out.add('Debit and credit must be different columns.');
    }
    if (descriptionCols.length > maxDescriptionCols) out.add('Use at most $maxDescriptionCols description columns.');
    final repeated = descriptionCols.toSet().length != descriptionCols.length;
    if (descriptionCols.any(bad) || repeated) out.add('Pick the description columns again.');
    if (bad(currencyCol)) out.add('Pick the currency column.');
    if (currencyCode != null && !RegExp(r'^[A-Z]{3}$').hasMatch(currencyCode!)) out.add('The currency is three capital letters, like EUR.');
    if (bad(skipIfEmptyCol)) out.add('Pick the column that marks rows to skip.');
    return out;
  }

  /// The stored shape (see the class doc).
  Map<String, Object?> toJson() => {
        'v': 1,
        'name': name,
        'headerRow': headerRow,
        'date': {'col': dateCol, 'format': dateFormat.pattern},
        'amount': amountCol != null ? {'col': amountCol} : {'debit': debitCol, 'credit': creditCol},
        'decimal': decimal.name,
        'negate': negate,
        'description': descriptionCols,
        if (currencyCol != null) 'currency': {'col': currencyCol} else if (currencyCode != null) 'currency': {'code': currencyCode},
        if (skipIfEmptyCol != null) 'skipIfEmpty': skipIfEmptyCol,
        'headers': headers,
      };

  /// Reads [toJson]'s shape; a [FormatException] for anything else (a damaged or foreign value). Field values are
  /// checked by [structureProblems], not here.
  static CsvMapping fromJson(Object? json) {
    Never fail() => throw const FormatException('Not a CSV layout');
    if (json is! Map || json['v'] != 1) fail();
    int col(Object? v) => v is int ? v : fail();
    int? optCol(Object? v) => v == null ? null : col(v);
    final date = json['date'];
    final amount = json['amount'];
    final currency = json['currency'];
    final name = json['name'];
    final headerRow = json['headerRow'];
    if (date is! Map || amount is! Map || name is! String || headerRow is! int) fail();
    final format = CsvDateFormat.byPattern(date['format']?.toString() ?? '') ?? fail();
    final decimal = switch (json['decimal']) { 'comma' => CsvDecimal.comma, 'point' => CsvDecimal.point, _ => fail() };
    final negate = json['negate'] ?? false;
    if (negate is! bool) fail();
    final desc = json['description'] ?? const <Object?>[];
    final headers = json['headers'] ?? const <Object?>[];
    if (desc is! List || headers is! List || headers.any((h) => h is! String)) fail();
    if (currency != null && currency is! Map) fail();
    final code = currency is Map ? currency['code'] : null;
    if (code != null && code is! String) fail();
    return CsvMapping(
      name: name,
      headerRow: headerRow,
      dateCol: col(date['col']),
      dateFormat: format,
      amountCol: optCol(amount['col']),
      debitCol: optCol(amount['debit']),
      creditCol: optCol(amount['credit']),
      decimal: decimal,
      negate: negate,
      descriptionCols: [for (final d in desc) col(d)],
      currencyCol: currency is Map ? optCol(currency['col']) : null,
      currencyCode: code as String?,
      skipIfEmptyCol: optCol(json['skipIfEmpty']),
      headers: [for (final h in headers) h as String],
    );
  }

  @override
  bool operator ==(Object other) => other is CsvMapping && _eq(toJson(), other.toJson());

  @override
  int get hashCode => Object.hash(name, headerRow, dateCol, amountCol, debitCol, creditCol);

  /// No name and no header names: this may end up in a log line.
  @override
  String toString() => 'CsvMapping(cols: ${headers.length}, split: $splitAmount)';
}

bool _eq(Object? a, Object? b) {
  if (a is Map && b is Map) return a.length == b.length && a.keys.every((k) => b.containsKey(k) && _eq(a[k], b[k]));
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_eq(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
