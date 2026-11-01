// The Clean neutral theme (UX-C1, docs/context/UX_SPEC.md): near-white page, white cards lifted by a soft shadow (no borders), one calm blue
// accent, Inter for text, IBM Plex Mono only for amounts. (It replaced the Ledger theme of docs/design/ledger-spec.md.)
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Colours shared by both themes, picked per brightness. Every token is opaque.
class WalletColors extends ThemeExtension<WalletColors> {
  final Color bg, surface, surface2, ink, ink2, muted, line, lineStrong, accent, accentSoft, pos, neg, good, bad, warnBg, warnInk, bar;

  /// Chart-only colours (never text or buttons; status stays `bad`/`good`). [chartPos] saved/spent bars, [chartNeg] lost, [chart2] the
  /// second series that is not a polarity ("went out" next to "came in"). All three keep 3:1 on [bg] and [surface] in both themes
  /// (`test/theme_contrast_test.dart`).
  final Color chartPos, chartNeg, chart2;

  /// Dashboard tiles (RX2, `widgets/dash.dart`): [desk] is the ground behind the tiles (the page colour, darker than [surface] in both themes); [s1] flexible spending,
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

  /// Clean neutral, light: near-white page, white cards.
  static const light = WalletColors(
    bg: Color(0xFFF6F7F9),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFE7EAEF),
    ink: Color(0xFF1F2933),
    ink2: Color(0xFF3E4A57),
    muted: Color(0xFF5B6673),
    line: Color(0xFFE3E7ED),
    lineStrong: Color(0xFF7F8A97),
    accent: Color(0xFF2F5FC4),
    accentSoft: Color(0xFFEAF0FC),
    pos: Color(0xFF2F5FC4),
    neg: Color(0xFFB3412F),
    good: Color(0xFF2B7A4B),
    bad: Color(0xFFB3412F),
    warnBg: Color(0xFFFBF0D2),
    warnInk: Color(0xFF5C4210),
    bar: Color(0xFF2F5FC4),
    chartPos: Color(0xFF2F5FC4),
    chartNeg: Color(0xFFB3412F),
    chart2: Color(0xFFA8650F),
    desk: Color(0xFFF6F7F9),
    s1: Color(0xFF2F5FC4),
    s2: Color(0xFFA8650F),
    s3: Color(0xFF0B8A8F),
    goodSoft: Color(0xFFE7F4EC),
    badSoft: Color(0xFFFBEAE6),
  );

  /// Clean neutral, dark.
  static const dark = WalletColors(
    bg: Color(0xFF14171C),
    surface: Color(0xFF1C2027),
    surface2: Color(0xFF262B34),
    ink: Color(0xFFE6E9EE),
    ink2: Color(0xFFBFC6D0),
    muted: Color(0xFF9AA4B1),
    line: Color(0xFF2A303A),
    lineStrong: Color(0xFF6E7886),
    accent: Color(0xFF8AAAF0),
    accentSoft: Color(0xFF243049),
    pos: Color(0xFF8AAAF0),
    neg: Color(0xFFF0907D),
    good: Color(0xFF6CC38F),
    bad: Color(0xFFF0907D),
    warnBg: Color(0xFF2F2916),
    warnInk: Color(0xFFE6CF92),
    bar: Color(0xFF8AAAF0),
    chartPos: Color(0xFF6F93E6),
    chartNeg: Color(0xFFD9705F),
    chart2: Color(0xFFC9892B),
    desk: Color(0xFF14171C),
    s1: Color(0xFF7C9CEB),
    s2: Color(0xFFC9892B),
    s3: Color(0xFF2BA8AE),
    goodSoft: Color(0xFF1F3328),
    badSoft: Color(0xFF3A2421),
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

const sansFamily = 'Inter';
const monoFamily = 'IBM Plex Mono';

/// Money and other figures: IBM Plex Mono with tabular figures, so columns line up.
const numStyle = TextStyle(
  fontFamily: monoFamily,
  fontFamilyFallback: ['monospace'],
  fontFeatures: [FontFeature.tabularFigures()],
);

/// Axis, date and name labels in charts: Inter with tabular figures (mono is for amounts only).
const labelStyle = TextStyle(fontFamily: sansFamily, fontFeatures: [FontFeature.tabularFigures()]);

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

  /// Section labels and table heads: sans, caps, a little wide (mono is for amounts only).
  static const eyebrow = TextStyle(
    fontFamily: sansFamily,
    fontSize: eyebrowSize,
    letterSpacing: eyebrowSize * 0.06,
    fontWeight: FontWeight.w600,
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

/// The notebook margin line of the old Ledger theme: kept as a layout gutter, no longer drawn (Clean neutral has no margin rule).
Color marginLineColor(Brightness b) => Colors.transparent;

/// Corner radius of cards, tiles and panels.
const double cardRadius = 14;

/// The soft shadow that lifts a white card off the page (cards have no border). Dark: a deeper, tighter shadow on a lighter surface.
List<BoxShadow> cardShadow(Brightness b) => b == Brightness.light
    ? const [
        BoxShadow(color: Color(0x0F1F2933), blurRadius: 2, offset: Offset(0, 1)),
        BoxShadow(color: Color(0x141F2933), blurRadius: 14, offset: Offset(0, 4)),
      ]
    : const [
        BoxShadow(color: Color(0x66000000), blurRadius: 2, offset: Offset(0, 1)),
        BoxShadow(color: Color(0x40000000), blurRadius: 14, offset: Offset(0, 4)),
      ];

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
      OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c, width: width));
  final shadow = b == Brightness.light ? const Color(0x331F2933) : const Color(0xB3000000);
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
    // Navigation: white bar with a hairline on top (drawn by the shell) and the selected tab as an accent-soft pill; the rail is
    // white with a hairline on its right (drawn by the shell) and the same pill.
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: w.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      height: 68,
      indicatorColor: w.accentSoft,
      indicatorShape: const StadiumBorder(),
      iconTheme:
          WidgetStateProperty.resolveWith((s) => IconThemeData(size: 22, color: s.contains(WidgetState.selected) ? w.accent : w.ink2)),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
          fontFamily: sansFamily,
          fontSize: BwType.metaSize,
          fontWeight: s.contains(WidgetState.selected) ? w6 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? w.accent : w.ink2)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: w.surface,
      elevation: 0,
      minWidth: 80,
      indicatorColor: w.accentSoft,
      indicatorShape: const StadiumBorder(),
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
        shape: shape(10),
        elevation: 0,
        textStyle: const TextStyle(fontFamily: sansFamily, fontSize: BwType.headingSize, fontWeight: w6),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: w.ink,
        side: BorderSide(color: w.lineStrong),
        minimumSize: const Size(64, 44),
        shape: shape(10),
        textStyle: const TextStyle(fontFamily: sansFamily, fontSize: BwType.headingSize, fontWeight: w6),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: w.accent,
        minimumSize: const Size(44, 44),
        shape: shape(10),
        textStyle: const TextStyle(fontFamily: sansFamily, fontSize: BwType.headingSize, fontWeight: w6),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: w.ink, shape: shape(10))),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(shape(10)),
        side: WidgetStatePropertyAll(BorderSide(color: w.lineStrong)),
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.accentSoft : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.accent : w.ink),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.accent : w.ink),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: sansFamily, fontSize: BwType.bodySize, fontWeight: w6)),
      ),
      selectedIcon: const Icon(Icons.check),
    ),
    chipTheme: ChipThemeData(
      shape: shape(8),
      side: BorderSide(color: w.line),
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
      elevation: 6,
      shadowColor: shadow,
      shape: shape(16),
      titleTextStyle: TextStyle(fontFamily: sansFamily, fontSize: BwType.titleSize, fontWeight: w6, color: w.ink),
      contentTextStyle: TextStyle(fontFamily: sansFamily, fontSize: BwType.bodySize, color: w.ink2, height: 1.4),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: w.surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: w.surface,
      modalElevation: 8,
      elevation: 8,
      shadowColor: shadow,
      showDragHandle: false,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
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
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? w.accent : w.lineStrong),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: shape(4),
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
      elevation: 4,
      shadowColor: shadow,
      shape: shape(12),
    ),
    listTileTheme: ListTileThemeData(iconColor: w.ink2, textColor: w.ink),
    textSelectionTheme: TextSelectionThemeData(cursorColor: w.accent, selectionColor: w.accent.withValues(alpha: 0.3)),
  );
}
