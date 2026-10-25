# Stage P11 spec: decimal style (2026-10-25)

Plan item: PATH_FORWARD P11 ("Decimal style setting (`12,50 €`; CHF symbol)"). Owner decision (`NEXT_DECISIONS.md`): the default stays **1,234.50 €**; **1.234,50 €** is an option in Plan › Look. App only; no core or schema change.

## Behaviour
- New device-local setting `numberStyle` (`repo.localValue('numberStyle')`, values `point` (default: `1,234.50`) and `comma` (`1.234,50`)), like `themeMode`: never synced, "Only this device".
- **Plan › Look:** a `SegmentedButton` keyed `numberStyle` with "1,234.50" / "1.234,50" under the theme choice; changing it re-renders every screen at once (`notifyListeners`).
- **Display** (`format.dart`): `money`, `moneyExact`, `moneyExactSigned`, `_group` and every helper built on them use the style: `comma` style = `.` for thousands, `,` for decimals. Signs, `−` (U+2212), the € after the amount with a non-breaking space, and whole-unit rounding stay as today.
- **Field text:** `centsToFieldText` writes the style's decimal separator (`12,50` in comma style), no grouping. The two hand-written field texts (`planned_sheets.dart:49`, `sheets.dart:180` `toStringAsFixed(2)`) move to `centsToFieldText`.
- **Parsing:** unchanged — `parseMoneyCents` already reads `12,50`, `12.50`, `1.234,56` and `1,234.56` in both styles. Add tests that a value written in each style parses back to the same cents (round trip for 0, 5, 50, 1234567, `maxAmountCents`).
- **CSV and core** stay machine format (`centsToDecimal`), never styled.
- **CHF:** shown as `CHF` after the amount (`12.50 CHF` / `12,50 CHF`), as today; no `Fr.`. Add an explicit `CHF` entry so the intent is pinned.
- Logs: `number.style` with the value only.

## Keys and tests
- Key `ValueKey('numberStyle')`.
- `format_edge_test.dart`: both styles for 0, 0.05, 12.50, 1,234.50, 1,234,567.89, negative, signed, whole-unit rounding, USD/GBP/CHF.
- Widget test: switch the style in Plan › Look → Today's hero and a Spending row change; restart (new controller on the same repo) keeps the style; a typed `12,50` in a sheet saves 1250 in both styles.
- Existing money-text tests stay green in the default style.
