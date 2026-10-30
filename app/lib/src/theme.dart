// The Ledger theme (see docs/design/ledger-spec.md): paper and ink colours, IBM Plex, ruled lines instead of cards.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Colours shared by both themes, picked per brightness. Every token is opaque.
class WalletColors extends ThemeExtension<WalletColors> {
  final Color bg, surface, surface2, ink, ink2, muted, line, lineStrong, accent, accentSoft, pos, neg, good, bad, warnBg, warnInk, bar;

  /// Chart-only colours (never text or buttons; status stays `bad`/`good`). [chartPos] saved/spent bars, [chartNeg] lost, [chart2] the
  /// second series that is not a polarity ("went out" next to "came in"). Checked with the dataviz validator, `--mode` light/dark, on both
  /// chart surfaces (light #F9F6EE/#F2EEE4, dark #21242B/#1B1D23): {chartPos, chartNeg} and {chartPos, chart2} each pass lightness band,
  /// chroma floor, CVD (light 17.4 / 22.9 protan, dark 18.1 / 25.3), normal-vision floor (light 23.9 / 26.2, dark 22.2 / 25.5) and contrast.
  final Color chartPos, chartNeg, chart2;

  /// Dashboard tiles (RX2, `widgets/dash.dart`): [desk] is the ground behind the tiles (darker than [surface]); [s1] flexible spending,
  /// [s2] bills and fixed costs, [s3] saved and goals (series colours: charts and fills only, never text; checked with the dataviz
  /// validator, light and dark, 3:1 on bg and surface); [goodSoft]/[badSoft] are the chip grounds under `good` / `bad` text.
  final Color desk, s1, s2, s3, goodSoft, badSoft;
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
    required this.pos,
    required this.neg,
    required this.good,
    required this.bad,
    required this.warnBg,
    required this.warnInk,
    required this.bar,
    required this.chartPos,
    required this.chartNeg,
    required this.chart2,
    required this.desk,
    required this.s1,
    required this.s2,
    required this.s3,
    required this.goodSoft,
    required this.badSoft,
  });

  /// Paper and ink.
  static const light = WalletColors(
    bg: Color(0xFFF2EEE4),
    surface: Color(0xFFF9F6EE),
    surface2: Color(0xFFEAE5D9),
    ink: Color(0xFF2C313C),
    ink2: Color(0xFF50566A),
    muted: Color(0xFF5E6372),
    line: Color(0xFFDAD4C5),
    lineStrong: Color(0xFF87847C),
    accent: Color(0xFF3A559E),
    accentSoft: Color(0xFFE6E8F0),
    pos: Color(0xFF3A559E),
    neg: Color(0xFFA93A32),
    good: Color(0xFF3E6B3E),
    bad: Color(0xFFA93A32),
    warnBg: Color(0xFFF6EBCB),
    warnInk: Color(0xFF5C4210),
    bar: Color(0xFF3A559E),
    chartPos: Color(0xFF3A559E),
    chartNeg: Color(0xFFA93A32),
    chart2: Color(0xFFA8650F),
    desk: Color(0xFFE6E1D3),
    s1: Color(0xFF3A559E),
    s2: Color(0xFFB0721A),
    s3: Color(0xFF008F96),
    goodSoft: Color(0xFFE3EBDD),
    badSoft: Color(0xFFF3DEDA),
  );

  /// Night ledger.
  static const dark = WalletColors(
    bg: Color(0xFF1B1D23),
    surface: Color(0xFF21242B),
    surface2: Color(0xFF272A32),
    ink: Color(0xFFDAD7CD),
    ink2: Color(0xFFAFB3BE),
    muted: Color(0xFF8F94A1),
    line: Color(0xFF343842),
    lineStrong: Color(0xFF6B707D),
    accent: Color(0xFF9DAEE6),
    accentSoft: Color(0xFF2A3050),
    pos: Color(0xFF9DAEE6),
    neg: Color(0xFFEE9C94),
    good: Color(0xFF88C791),
    bad: Color(0xFFEE9C94),
    warnBg: Color(0xFF2F2916),
    warnInk: Color(0xFFE6CF92),
    bar: Color(0xFF9DAEE6),
    chartPos: Color(0xFF6F8FE0),
    chartNeg: Color(0xFFD56F66),
    chart2: Color(0xFFC27F20),
    desk: Color(0xFF15171C),
    s1: Color(0xFF7088D6),
    s2: Color(0xFFBD7F22),
    s3: Color(0xFF1A9AA0),
    goodSoft: Color(0xFF243126),
    badSoft: Color(0xFF3A2523),
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

const sansFamily = 'IBM Plex Sans';
const monoFamily = 'IBM Plex Mono';

/// Money and other figures: Plex Mono with tabular figures, so columns line up.
const numStyle = TextStyle(
  fontFamily: monoFamily,
  fontFamilyFallback: ['monospace'],
  fontFeatures: [FontFeature.tabularFigures()],
);

/// Type scale: the only font sizes in the app. Nothing is under 12 dp except [eyebrow] (ALL CAPS, 11 dp, letter-spaced).
/// Sizes are plain constants (usable in `const TextStyle`); the styles below add family, weight and spacing.
class BwType {
  const BwType._();
  static const double eyebrowSize = 11;
  static const double metaSize = 12.5;
  static const double bodySize = 14;
  static const double headingSize = 16;
  static const double titleSize = 19;
  static const double amountSize = 15;
  static const double amountMdSize = 20;
  static const double displaySize = 26;
  static const double entrySize = 30;
  static const double heroSize = 78;

  /// Section labels and table heads: mono, caps, wide.
  static const eyebrow = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: ['monospace'],
    fontFeatures: [FontFeature.tabularFigures()],
    fontSize: eyebrowSize,
    letterSpacing: eyebrowSize * 0.08,
    fontWeight: FontWeight.w500,
  );

  /// Secondary lines: dates, categories, explainers.
  static const meta = TextStyle(fontSize: metaSize);

  /// Running text.
  static const body = TextStyle(fontSize: bodySize);
  static const bodyStrong = TextStyle(fontSize: bodySize, fontWeight: FontWeight.w600);

  /// Sub-headings and button labels.
  static const heading = TextStyle(fontSize: headingSize, fontWeight: FontWeight.w600, letterSpacing: -0.2);

  /// Screen and dialog titles.
  static const title = TextStyle(fontSize: titleSize, fontWeight: FontWeight.w600, letterSpacing: -0.2);

  /// Money in lists (mono, tabular), and the larger figures in rows and sheets.
  static const amount = TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: ['monospace'],
      fontFeatures: [FontFeature.tabularFigures()],
      fontSize: amountSize,
      fontWeight: FontWeight.w500);

  /// The one big number on Today.
  static const hero = TextStyle(fontSize: heroSize);
}

/// Notebook-style red double rule colour (the margin line on wide windows).
Color marginLineColor(Brightness b) => b == Brightness.light ? const Color(0xFFE9CBC5) : const Color(0xFF674343);

/// Rectangle with a rule along the top edge only (bottom sheets).
class _TopRuleBorder extends ShapeBorder {
  final Color color;
  final double width;
  const _TopRuleBorder({required this.color, this.width = 2});
  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.only(top: width);
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => Path()..addRect(rect.deflate(0));
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => Path()..addRect(rect);
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    canvas.drawRect(Rect.fromLTWH(rect.left, rect.top, rect.width, width), Paint()..color = color);
  }

  @override
  ShapeBorder scale(double t) => _TopRuleBorder(color: color, width: width * t);
}

/// Rectangle with a bar along the left edge (the selected item of the rail).
class _LeftBarBorder extends ShapeBorder {
  final Color color;
  final double width;
  const _LeftBarBorder({required this.color, this.width = 3});
  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => Path()..addRect(rect);
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => Path()..addRect(rect);
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    canvas.drawRect(Rect.fromLTWH(rect.left, rect.top, width, rect.height), Paint()..color = color);
  }

  @override
  ShapeBorder scale(double t) => _LeftBarBorder(color: color, width: width * t);
}

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
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF1F3FA8), brightness: b).copyWith(
    primary: w.accent,
    onPrimary: b == Brightness.light ? w.surface : w.bg,
    primaryContainer: w.accentSoft,
    onPrimaryContainer: w.ink,
    secondary: w.accent,
    onSecondary: b == Brightness.light ? w.surface : w.bg,
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
      OutlineInputBorder(borderRadius: BorderRadius.circular(2), borderSide: BorderSide(color: c, width: width));
  const w6 = FontWeight.w600;
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
    // Navigation: bar = ink top border, a transparent indicator (the accent top bar is drawn by the shell), rail = right border and
    // a 3 px accent bar on the left of the selected item.
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: w.bg,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      height: 64,
      indicatorColor: Colors.transparent,
      iconTheme:
          WidgetStateProperty.resolveWith((s) => IconThemeData(size: 22, color: s.contains(WidgetState.selected) ? w.accent : w.ink2)),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
          fontFamily: sansFamily,
          fontSize: BwType.metaSize,
          fontWeight: s.contains(WidgetState.selected) ? w6 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? w.accent : w.ink2)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: w.bg,
      elevation: 0,
      minWidth: 80,
      indicatorColor: w.accentSoft,
      indicatorShape: _LeftBarBorder(color: w.accent),
      selectedIconTheme: IconThemeData(color: w.accent),
      unselectedIconTheme: IconThemeData(color: w.ink2),
      selectedLabelTextStyle: TextStyle(fontFamily: sansFamily, fontSize: BwType.metaSize, fontWeight: w6, color: w.accent),
      unselectedLabelTextStyle: TextStyle(fontFamily: sansFamily, fontSize: BwType.metaSize, fontWeight: FontWeight.w500, color: w.ink2),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: w.surface,
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
        shape: shape(3),
        elevation: 0,
        textStyle: const TextStyle(fontFamily: sansFamily, fontSize: BwType.headingSize, fontWeight: w6),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: w.ink,
        side: BorderSide(color: w.lineStrong),
        minimumSize: const Size(64, 44),
        shape: shape(3),
        textStyle: const TextStyle(fontFamily: sansFamily, fontSize: BwType.headingSize, fontWeight: w6),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: w.accent,
        minimumSize: const Size(44, 44),
        shape: shape(3),
        textStyle: const TextStyle(fontFamily: sansFamily, fontSize: BwType.headingSize, fontWeight: w6),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: w.ink, shape: shape(3))),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(shape(2)),
        side: WidgetStatePropertyAll(BorderSide(color: w.lineStrong)),
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.ink : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.bg : w.ink),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.bg : w.ink),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: sansFamily, fontSize: BwType.bodySize, fontWeight: w6)),
      ),
      selectedIcon: const Icon(Icons.check),
    ),
    chipTheme: ChipThemeData(
      shape: shape(2),
      side: BorderSide(color: w.lineStrong),
      backgroundColor: Colors.transparent,
      selectedColor: w.accent,
      checkmarkColor: onAccent,
      surfaceTintColor: Colors.transparent,
      labelStyle: TextStyle(fontFamily: sansFamily, color: w.ink, fontWeight: FontWeight.w500),
      secondaryLabelStyle: TextStyle(fontFamily: sansFamily, color: onAccent, fontWeight: w6),
      iconTheme: IconThemeData(color: w.ink, size: 18),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: w.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3), side: BorderSide(color: w.lineStrong)),
      titleTextStyle: TextStyle(fontFamily: sansFamily, fontSize: BwType.titleSize, fontWeight: w6, color: w.ink),
      contentTextStyle: TextStyle(fontFamily: sansFamily, fontSize: BwType.bodySize, color: w.ink2, height: 1.4),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: w.surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: w.surface,
      modalElevation: 0,
      elevation: 0,
      showDragHandle: false,
      shape: _TopRuleBorder(color: w.lineStrong, width: 1),
      modalBarrierColor: Colors.black.withValues(alpha: 0.4),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: w.ink,
      contentTextStyle: TextStyle(fontFamily: sansFamily, fontSize: BwType.bodySize, color: w.bg),
      actionTextColor: w.accentSoft,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: shape(2),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: w.ink, borderRadius: BorderRadius.circular(2)),
      textStyle: TextStyle(fontFamily: sansFamily, fontSize: BwType.metaSize, color: w.bg),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? onAccent : w.ink2),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.accent : w.surface2),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.accent : w.lineStrong),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: shape(2),
      side: BorderSide(color: w.lineStrong, width: 1.5),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2), side: BorderSide(color: w.lineStrong)),
    ),
    listTileTheme: ListTileThemeData(iconColor: w.ink2, textColor: w.ink),
    textSelectionTheme: TextSelectionThemeData(cursorColor: w.accent, selectionColor: w.accent.withValues(alpha: 0.3)),
  );
}
