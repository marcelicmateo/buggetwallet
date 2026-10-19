/// Most cells (plus rows) a sheet may expand to once laid out as rows. Bank exports have a few thousand rows of
/// about ten columns; a sheet past this is damaged or not an export, and laying it out would exhaust memory.
const maxSheetCells = 2000000;

const _empty = <Object>[];

/// Lays out sparse cells (row → column → value) as rows 0..last, without a dense rows × columns grid: each row is
/// only as long as its own last cell (gaps inside it are `''`), and rows without cells share one empty list. So one
/// stray cell far away (XFD1048576) costs about a million list slots, not 17 billion cells.
///
/// Throws [FormatException] when rows plus cells would exceed [maxSheetCells].
List<List<Object>> sparseRows(Map<int, Map<int, Object>> cells) {
  if (cells.isEmpty) return [];
  var lastRow = 0, total = 0;
  final width = <int, int>{};
  for (final e in cells.entries) {
    if (e.key > lastRow) lastRow = e.key;
    final cols = e.value.keys;
    final w = cols.isEmpty ? 0 : cols.reduce((a, b) => a > b ? a : b) + 1;
    width[e.key] = w;
    total += w;
  }
  if (total + lastRow + 1 > maxSheetCells) throw const FormatException('Sheet too large');
  return [
    for (var r = 0; r <= lastRow; r++)
      switch (cells[r]) {
        null => _empty,
        final row => [for (var c = 0; c < width[r]!; c++) row[c] ?? ''],
      },
  ];
}
