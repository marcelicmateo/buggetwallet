# D3 Ledger theme — implementation spec (2026-10-19)

Built after the adaptive layout (`lib/src/layout.dart`, NavigationRail, sheets as dialogs, `TwoCol`). Owner decisions:
dark mode = "night ledger" following the system setting; six unmodified IBM Plex font files (~1 MB); the red notebook
margin line only on wide windows (≥ 600 dp), never on phones.

## 1. Tokens (`WalletColors`, plus new `lineStrong`)
| Token | Light | Dark |
|---|---|---|
| bg (paper) | #f2eee4 | #1b1d23 |
| surface (dialogs, sheets, input fill) | #f9f6ee | #21242b |
| surface2 (tag, header band) | #eae5d9 | #272a32 |
| ink (graphite, not black) | #2c313c | #dad7cd |
| ink2 | #50566a | #afb3be |
| muted | #5e6372 | #8f94a1 |
| line (row separators, section underlines, decorative) | #dad4c5 | #343842 |
| lineStrong (inputs, panel top rule, double rule; non-text ≥ 3:1, a mid grey now, not ink) | #87847c | #6b707d |
| accent (calm ink-blue) | #3a559e | #9daee6 |
| accentSoft | #e6e8f0 | #2a3050 |
| pos / bar | #3a559e | #9daee6 |
| neg / bad | #a93a32 | #ee9c94 |
| good (income) | #3e6b3e | #88c791 |
| warnBg | #f6ebcb | #2f2916 |
| warnInk | #5c4210 | #e6cf92 |
| margin line (`marginLineColor`, decorative) | #e9cbc5 | #674343 |

The ratios worked out in planning: text pairs at least 4.5:1 (N1 softer values: ink on bg is 11.3 light and 11.7 dark, muted on bg 5.2 and 5.6), `lineStrong` on bg 3.2 light and 3.4 dark,
`line` decorative only. The contrast test recomputes all of them (§4).
`buildTheme`: keep `fromSeed().copyWith`, and also set `onPrimary`, `primaryContainer=accentSoft`, `outline=lineStrong`,
`outlineVariant=line`, `surfaceContainer*`, `error`, `onSurfaceVariant=ink2` (otherwise M3 tints leak). `fontFamily: 'IBM Plex Sans'`,
weights w400/w500/w600 only. `cardTheme` radius 0, transparent. Add `dialogTheme`, `bottomSheetTheme`, `snackBarTheme`,
`chipTheme`, button themes, `segmentedButtonTheme`, `navigationBarTheme`, `navigationRailTheme`, `dividerTheme`, `switchTheme`.

## 2. Fonts
IBM Plex (https://github.com/IBM/plex), static `.ttf`, unmodified (OFL Reserved Font Name "Plex"): Sans and Mono, each
Regular/Medium(500)/SemiBold(600) → `app/assets/fonts/IBMPlex{Sans,Mono}-{Regular,Medium,SemiBold}.ttf`. `OFL.txt` verbatim
in `app/assets/fonts/` (listed under `assets:`), `third_party/fonts/README.md` (source, version, RFN). Register the licence in
`main()` via `LicenseRegistry.addLicense`. `pubspec.yaml` `fonts:` block, one family per Plex family, weights 500 and 600 declared.
`numStyle` → `IBM Plex Mono` + `FontFeature.tabularFigures()` (fallback `monospace`). The hero is mono 78 px in a `FittedBox(scaleDown)`.
Glyphs that must exist: €, U+2212, NBSP. Record the real APK size delta in STATUS.

## 3. Components
- **Panel** → ruled section: no radius or fill, a top rule of 1 px `lineStrong` and a bottom hairline; `SectionHead` underlines, `TotalRule`'s top line, the header rule and the rail border use the lighter `line`; the double rule (1 px, 2 px gap, `lineStrong`) is only under totals. The API is unchanged. `color:` gives a flat band plus
  a 3 px left bar, still with its icon and word. Padding is vertical only; the page margin belongs to layout.dart. New `SectionHead(text, {trailing})`
  (mono 11 px uppercase, `line` underline). `Eyebrow` is mono with letter-spacing 0.08 em. `Heading` is w600. `Tag` has a 2 px radius and a 1 px outline.
- **TxTile**: `Date(52, mono 12) | Particulars | Amount(104, right, mono 15 w500)`, with 1 px `line` dividers and a bottom hairline. Income
  is `good` with "+". Minimum height 44 px. Keep the InkWell. An optional `TxHeaderRow` sits on Today and Spending. `LineItem` gets a mono right-aligned value.
- **Totals**: `TotalRule` = 1 px top plus a double bottom rule (two 1 px lines with a 1 px gap), under the Today hero, the Plan budget total and goal totals.
- **Buttons**: radius 3. Filled: accent, w600 16 px, height 52 (primary) or 44. Outlined: 1 px `lineStrong`. Tonal becomes accent-outlined.
  Text: accent, w600. Segmented: radius 2, selected = filled ink with a check. No pills.
- **Chips**: radius 2, 1 px `lineStrong`, selected = accent with a check. The app-bar period chip is mono with a 1 px ink border.
- **NavigationBar**: bg, a 1 px ink top border, a transparent indicator plus a 3 px accent top bar, an accent w600 label. Outlined icons, height 64.
- **NavigationRail**: bg, a 1 px `line` right border, a 3 px accent bar on the left of the selected item, minimum width 80, items at least 44 px.
- **Dialogs**: radius 3, surface, a 1 px `lineStrong` border, elevation 0. **Bottom sheets**: top radius 0, a 1 px `lineStrong` top border, no handle.
  Scrim at 0.4 alpha. A double rule under the amount on the AddExpense and Transaction sheets.
- **Inputs**: filled surface, radius 2, a 1 px `lineStrong` border, focus 2 px accent, errors in `bad` with an icon. The suffix `' €'` is mono ink2.
  Amount fields are end-aligned and mono.
- **Toasts**: floating, ink background, bg text, radius 2.
- **Charts**: solid 1 px grid in `line`, no border box (bottom axis in `lineStrong`), bar radius 0, pos and neg colours, the running
  period at 0.45 alpha plus a dashed outline. The tooltip is an ink background with bg text, and axis text is mono 10–11 px muted. Progress bars are 10 px with a 1 px ink
  border and a flat fill. Over budget is `bad` plus a hatch and the "behind pace" label with an icon. A pace tick of 2 px.
- **Screens**:
  - Today: the hero with a double rule; the stats in a ruled three-column strip; square checkboxes; a 1 px header rule.
  - Spending: a ruled category table.
  - Wishlist and Goals: ruled rows and a total row.
  - Plan: `SectionHead` sections.
  - Welcome: the logo is a 26 px square with a margin line.
  - The key QR keeps a white quiet zone.
- **Margin line** (red double rule at x≈22, as in the mockups): wide windows only (≥ 600 dp).
- **Layout fit**: no page margins in the theme. `TwoCol` gets a 1 px `line` divider. The dialog max width comes from layout.dart.

## 4. Tests
1. `theme_contrast_test.dart`: a pure `contrast(a, b)`. Text pairs must be ≥ 4.5 and non-text ≥ 3.0, for light and dark. Every token is opaque.
2. `theme_screens_test.dart`: the demo wallet at 360×800, 800×1000 and 1280×800, light and dark. Every tab is scrolled through with no error or overflow.
   NavigationBar or NavigationRail by width, no `Card`, no Panel border radius. Desktop screenshots go through `screens_test.dart` and `BW_SCREENS_DIR`.
3. Text scale 2.0 at 320 and 360, both themes, with the real fonts loaded (`FontLoader` in `setUpAll`).
4. Amount font: every money `Text` resolves to Plex Mono with tabular figures, and amounts in a list share the same right edge.
5. Font assets: all six load, €, U+2212 and NBSP lay out in both families, and `OFL.txt` exists.
6. Update the tests that find `Card`, `FilledButton.tonal` or the bar by type.

## 5. Commits
1. Fonts and tokens: fonts, licence, palette, `numStyle`, ThemeData base, the contrast and font tests.
2. Ledger components: the widgets in §3, the screen changes, the structural and amount-font tests.
3. Verification and docs: the three widths, text scale, screenshots, `app/CLAUDE.md`, STATUS with the font size.

## 6. After the merge (lead)
Re-sync the claude.ai design system (https://claude.ai/artifact/5tQpueayHHhYY3cgP9jw4q): tokens.json (incl. `lineStrong`),
fonts, radii, React copies of the changed widgets, `meta.source` = the new SHA. Update the `design-system-artifact` memory note.
