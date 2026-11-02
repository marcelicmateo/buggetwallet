// The Engineer theme (ENG E1, docs/context/ENG_UI_SPEC.md §4): dark by default for this persona, light as its own set of steps (not a
// flipped dark). Panels have a 1 px line border and no shadow, Manrope for text, JetBrains Mono for figures and eyebrows.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Colours shared by both themes, picked per brightness. Every token is opaque.
class WalletColors extends ThemeExtension<WalletColors> {
  final Color bg, surface, surface2, ink, ink2, muted, line, lineStrong, accent, accentSoft, pos, neg, good, bad, warnBg, warnInk, bar;

  /// The nudge card ("3 not tagged yet"): [accentSoft] ground with this border.
  final Color accentSoftLine;

  /// Chart gridlines (recessive) and the one-hue sequential ramp for heatmaps ("less" to "more").
  final Color chartGrid;
  final List<Color> heat;

  /// Chart-only colours (never text or buttons; status stays `bad`/`good`). [chartPos] saved/spent bars, [chartNeg] lost, [chart2] the
  /// second series that is not a polarity ("went out" next to "came in").
  final Color chartPos, chartNeg, chart2;

  /// Data colours (spec §4.2): six fixed slots, assigned by entity, for charts and fills only, never text. [desk] is the ground behind
  /// dashboard tiles (the page colour); [goodSoft]/[badSoft] are the chip grounds under `good` / `bad` text. In the light set slots 3-5
  /// are below 3:1 on the page (the spec's validator WARN): every chart that uses them shows its values or a table.
  final Color desk, s1, s2, s3, s4, s5, s6, goodSoft, badSoft;
  const WalletColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.ink,
    required this.ink2,
    required this.muted,
    required this.line,
    required this.lineStrong,
    required this.accent,
    required this.accentSoft,
    required this.accentSoftLine,
    required this.pos,
    required this.neg,
    required this.good,
    required this.bad,
    required this.warnBg,
    required this.warnInk,
    required this.bar,
    required this.chartGrid,
    required this.heat,
    required this.chartPos,
    required this.chartNeg,
    required this.chart2,
    required this.desk,
    required this.s1,
    required this.s2,
    required this.s3,
    required this.s4,
    required this.s5,
    required this.s6,
    required this.goodSoft,
    required this.badSoft,
  });

  /// Engineer, light. [ink2] is not in the spec: a step between ink and muted. Two spec values were moved for 3:1 (ENG E1 decision):
  /// `lineStrong` #CBD3DA -> #7D91A2 and `s2` #EB6834 -> #EB6530 (same hues).
  static const light = WalletColors(
    bg: Color(0xFFF4F6F8),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFEEF2F6),
    ink: Color(0xFF121A21),
    ink2: Color(0xFF38444F),
    muted: Color(0xFF56636F),
    line: Color(0xFFE1E6EB),
    lineStrong: Color(0xFF7D91A2),
    accent: Color(0xFF1F5FBF),
    accentSoft: Color(0xFFEAF1FC),
    accentSoftLine: Color(0xFFBFD3F0),
    pos: Color(0xFF1F5FBF),
    neg: Color(0xFFC2412F),
    good: Color(0xFF1F7A50),
    bad: Color(0xFFC2412F),
    warnBg: Color(0xFFFBF0D2),
    warnInk: Color(0xFF5C4210),
    bar: Color(0xFF1F5FBF),
    chartGrid: Color(0xFFEDF0F3),
    heat: [Color(0xFFE3EDF9), Color(0xFFBBD3F1), Color(0xFF86B2E6), Color(0xFF4F8CD6), Color(0xFF2A65B3)],
    chartPos: Color(0xFF2A78D6),
    chartNeg: Color(0xFFC2412F),
    chart2: Color(0xFFEB6530),
    desk: Color(0xFFF4F6F8),
    s1: Color(0xFF2A78D6),
    s2: Color(0xFFEB6530),
    s3: Color(0xFF1BAF7A),
    s4: Color(0xFFEDA100),
    s5: Color(0xFFE87BA4),
    s6: Color(0xFF6250D6),
    goodSoft: Color(0xFFE4F3EB),
    badSoft: Color(0xFFFDF1EE),
  );

  /// Engineer, dark. [ink2] is not in the spec: a step between ink and muted. `lineStrong` #33404B -> #546A7C for 3:1 (same hue).
  static const dark = WalletColors(
    bg: Color(0xFF0F1418),
    surface: Color(0xFF161D23),
    surface2: Color(0xFF1B232A),
    ink: Color(0xFFE8EEF2),
    ink2: Color(0xFFC3CFD8),
    muted: Color(0xFF9AAAB6),
    line: Color(0xFF26313A),
    lineStrong: Color(0xFF546A7C),
    accent: Color(0xFF8DB8F5),
    accentSoft: Color(0xFF172231),
    accentSoftLine: Color(0xFF3B4B66),
    pos: Color(0xFF8DB8F5),
    neg: Color(0xFFF07167),
    good: Color(0xFF3FB37F),
    bad: Color(0xFFF07167),
    warnBg: Color(0xFF2A2514),
    warnInk: Color(0xFFE6CF92),
    bar: Color(0xFF8DB8F5),
    chartGrid: Color(0xFF222C34),
    heat: [Color(0xFF1C2B3A), Color(0xFF24405C), Color(0xFF2E5C86), Color(0xFF3A7BB5), Color(0xFF5C9CE0)],
    chartPos: Color(0xFF3987E5),
    chartNeg: Color(0xFFF07167),
    chart2: Color(0xFFD95926),
    desk: Color(0xFF0F1418),
    s1: Color(0xFF3987E5),
    s2: Color(0xFFD95926),
    s3: Color(0xFF199E70),
    s4: Color(0xFFC98500),
    s5: Color(0xFFD55181),
    s6: Color(0xFF9085E9),
    goodSoft: Color(0xFF14281F),
    badSoft: Color(0xFF2E1D1C),
  );

  @override
  WalletColors copyWith() => this;

  @override
  WalletColors lerp(ThemeExtension<WalletColors>? other, double t) => t < 0.5 ? this : (other as WalletColors? ?? this);
}

extension WalletTheme on BuildContext {
  WalletColors get c => Theme.of(this).extension<WalletColors>()!;
}

/// WCAG 2 contrast ratio of two opaque colours, 1 to 21.
double contrastRatio(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

double _luminance(Color c) {
  double lin(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

const sansFamily = 'Manrope';
const monoFamily = 'JetBrains Mono';

/// Money and other figures: JetBrains Mono with tabular figures, so columns line up.
const numStyle = TextStyle(
  fontFamily: monoFamily,
  fontFamilyFallback: ['monospace'],
  fontFeatures: [FontFeature.tabularFigures()],
);

/// Axis, date and name labels in charts: Manrope with tabular figures.
const labelStyle = TextStyle(fontFamily: sansFamily, fontFeatures: [FontFeature.tabularFigures()]);

/// Type scale (spec §4.3): the only font sizes in the app. Nothing is under 11 dp. Sizes are plain constants (usable in
/// `const TextStyle`); the styles below add family, weight and spacing.
class BwType {
  const BwType._();
  static const double eyebrowSize = 11;
  static const double metaSize = 13;
  static const double bodySize = 14;
  static const double headingSize = 16;
  static const double titleSize = 22;
  static const double amountSize = 15;
  static const double amountMdSize = 22;
  static const double displaySize = 26;
  static const double entrySize = 30;
  static const double heroSize = 52;
  static const double heroWideSize = 64;

  /// Section labels and table heads: mono, caps, 0.1 em apart.
  static const eyebrow = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: ['monospace'],
    fontSize: eyebrowSize,
    letterSpacing: eyebrowSize * 0.1,
    fontWeight: FontWeight.w500,
  );

  /// Secondary lines: dates, categories, explainers.
  static const meta = TextStyle(fontSize: metaSize);

  /// Running text.
  static const body = TextStyle(fontSize: bodySize);
  static const bodyStrong = TextStyle(fontSize: bodySize, fontWeight: FontWeight.w600);

  /// Sub-headings and button labels.
  static const heading = TextStyle(fontSize: headingSize, fontWeight: FontWeight.w800);

  /// Screen and dialog titles.
  static const title = TextStyle(fontSize: titleSize, fontWeight: FontWeight.w800, letterSpacing: -0.44);

  /// Money in lists (mono, tabular), and the larger figures in rows and sheets.
  static const amount = TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: ['monospace'],
      fontFeatures: [FontFeature.tabularFigures()],
      fontSize: amountSize,
      fontWeight: FontWeight.w500);

  /// The one big number on Overview.
  static const hero = TextStyle(fontSize: heroSize);
}

/// The notebook margin line of the old Ledger theme: kept as a layout gutter, no longer drawn.
Color marginLineColor(Brightness b) => Colors.transparent;

/// Corner radius of panels and tiles (spec §4.4). A panel has a 1 px `line` border and no shadow.
const double cardRadius = 18;

/// Accent-outlined button style (what used to be the tonal button).
ButtonStyle accentOutlined(BuildContext context) {
  final w = context.c;
  return OutlinedButton.styleFrom(
    foregroundColor: w.accent,
    side: BorderSide(color: w.accent),
  );
}

ThemeData buildTheme(Brightness b) {
  final w = b == Brightness.light ? WalletColors.light : WalletColors.dark;
  final scheme = ColorScheme.fromSeed(seedColor: w.accent, brightness: b).copyWith(
    primary: w.accent,
    onPrimary: w.bg,
    primaryContainer: w.accentSoft,
    onPrimaryContainer: w.ink,
    secondary: w.accent,
    onSecondary: w.bg,
    secondaryContainer: w.accentSoft,
    onSecondaryContainer: w.ink,
    tertiary: w.accent,
    tertiaryContainer: w.accentSoft,
    surface: w.surface,
    onSurface: w.ink,
    onSurfaceVariant: w.ink2,
    surfaceTint: Colors.transparent,
    surfaceDim: w.bg,
    surfaceBright: w.surface,
    surfaceContainerLowest: w.bg,
    surfaceContainerLow: w.bg,
    surfaceContainer: w.surface,
    surfaceContainerHigh: w.surface2,
    surfaceContainerHighest: w.surface2,
    outline: w.lineStrong,
    outlineVariant: w.line,
    error: w.bad,
    onError: w.bg,
    errorContainer: w.warnBg,
    onErrorContainer: w.warnInk,
    inverseSurface: w.ink,
    onInverseSurface: w.bg,
    inversePrimary: w.accent,
    shadow: Colors.black,
    scrim: Colors.black,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: b, fontFamily: sansFamily);
  final tt = base.textTheme.apply(fontFamily: sansFamily, bodyColor: w.ink, displayColor: w.ink);
  OutlinedBorder shape(double r) => RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));
  OutlineInputBorder field(Color c, double width) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: c, width: width));
  const w6 = FontWeight.w600;
  // A panel-style edge for sheets, dialogs and menus: 1 px line, no shadow.
  OutlinedBorder panel(BorderRadiusGeometry r) => RoundedRectangleBorder(borderRadius: r, side: BorderSide(color: w.line));
  final onAccent = scheme.onPrimary;
  return base.copyWith(
    scaffoldBackgroundColor: w.bg,
    canvasColor: w.bg,
    extensions: [w],
    textTheme: tt,
    primaryTextTheme: tt,
    cardTheme: const CardThemeData(color: Colors.transparent, elevation: 0, margin: EdgeInsets.zero, shape: RoundedRectangleBorder()),
    dividerColor: w.line,
    dividerTheme: DividerThemeData(color: w.line, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: w.bg,
      foregroundColor: w.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: tt.titleLarge?.copyWith(fontSize: BwType.headingSize, fontWeight: w6, color: w.ink),
    ),
    // Keyboard focus must be visible on rows, buttons and the rail (Tab); hover is lighter.
    focusColor: w.accent.withValues(alpha: 0.2),
    hoverColor: w.surface2,
    highlightColor: w.accentSoft,
    splashFactory: NoSplash.splashFactory,
    iconTheme: IconThemeData(color: w.ink),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: w.surface2,
      isDense: true,
      border: field(w.lineStrong, 1),
      enabledBorder: field(w.lineStrong, 1),
      focusedBorder: field(w.accent, 2),
      errorBorder: field(w.bad, 1),
      focusedErrorBorder: field(w.bad, 2),
      disabledBorder: field(w.line, 1),
      labelStyle: TextStyle(color: w.ink2),
      floatingLabelStyle: TextStyle(color: w.ink2),
      hintStyle: TextStyle(color: w.muted),
      helperStyle: TextStyle(color: w.muted),
      errorStyle: TextStyle(color: w.bad, fontWeight: w6),
      prefixIconColor: w.ink2,
      suffixIconColor: w.ink2,
      suffixStyle: numStyle.copyWith(color: w.ink2),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: w.accent,
        foregroundColor: onAccent,
        disabledBackgroundColor: w.surface2,
        disabledForegroundColor: w.muted,
        minimumSize: const Size(64, 44),
        shape: shape(12),
        elevation: 0,
        textStyle: const TextStyle(fontFamily: sansFamily, fontSize: BwType.headingSize, fontWeight: w6),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: w.ink,
        side: BorderSide(color: w.lineStrong),
        minimumSize: const Size(64, 44),
        shape: shape(12),
        textStyle: const TextStyle(fontFamily: sansFamily, fontSize: BwType.headingSize, fontWeight: w6),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: w.accent,
        minimumSize: const Size(44, 44),
        shape: shape(12),
        textStyle: const TextStyle(fontFamily: sansFamily, fontSize: BwType.headingSize, fontWeight: w6),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: w.ink, shape: shape(12))),
    // Seg toggle (spec §4.4): the chosen segment is a lineStrong fill with ink text and a check icon.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(shape(10)),
        side: WidgetStatePropertyAll(BorderSide(color: w.line)),
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.lineStrong : w.bg),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.ink : w.muted),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.ink : w.muted),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: sansFamily, fontSize: BwType.metaSize, fontWeight: w6)),
      ),
      selectedIcon: const Icon(Icons.check),
    ),
    // Range chips: outline; the chosen one is an ink fill with bg text.
    chipTheme: ChipThemeData(
      shape: shape(10),
      side: BorderSide(color: w.lineStrong),
      backgroundColor: Colors.transparent,
      selectedColor: w.ink,
      checkmarkColor: w.bg,
      surfaceTintColor: Colors.transparent,
      labelStyle: TextStyle(fontFamily: sansFamily, color: w.ink, fontWeight: FontWeight.w500),
      secondaryLabelStyle: TextStyle(fontFamily: sansFamily, color: w.bg, fontWeight: w6),
      iconTheme: IconThemeData(color: w.ink, size: 18),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: w.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: panel(BorderRadius.circular(cardRadius)),
      titleTextStyle: TextStyle(fontFamily: sansFamily, fontSize: BwType.headingSize + 2, fontWeight: FontWeight.w800, color: w.ink),
      contentTextStyle: TextStyle(fontFamily: sansFamily, fontSize: BwType.bodySize, color: w.ink2, height: 1.4),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: w.surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: w.surface,
      modalElevation: 0,
      elevation: 0,
      showDragHandle: false,
      shape: panel(const BorderRadius.vertical(top: Radius.circular(cardRadius))),
      modalBarrierColor: Colors.black.withValues(alpha: 0.4),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: w.ink,
      contentTextStyle: TextStyle(fontFamily: sansFamily, fontSize: BwType.bodySize, color: w.bg),
      actionTextColor: w.accentSoft,
      behavior: SnackBarBehavior.floating,
      elevation: 3,
      shape: shape(10),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: w.ink, borderRadius: BorderRadius.circular(6)),
      textStyle: TextStyle(fontFamily: sansFamily, fontSize: BwType.metaSize, color: w.bg),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? onAccent : w.ink2),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.accent : w.surface2),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.accent : w.muted),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: shape(4),
      side: BorderSide(color: w.muted, width: 1.5),
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.accent : Colors.transparent),
      checkColor: WidgetStatePropertyAll(onAccent),
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStatePropertyAll(w.accent)),
    progressIndicatorTheme:
        ProgressIndicatorThemeData(color: w.accent, linearTrackColor: w.surface2, circularTrackColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(
      color: w.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: panel(BorderRadius.circular(12)),
    ),
    listTileTheme: ListTileThemeData(iconColor: w.ink2, textColor: w.ink),
    textSelectionTheme: TextSelectionThemeData(cursorColor: w.accent, selectionColor: w.accent.withValues(alpha: 0.3)),
  );
}
