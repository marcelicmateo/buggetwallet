// The Ledger theme (see docs/design/ledger-spec.md): paper and ink colours, IBM Plex, ruled lines instead of cards.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Colours shared by both themes, picked per brightness. Every token is opaque.
class WalletColors extends ThemeExtension<WalletColors> {
  final Color bg, surface, surface2, ink, ink2, muted, line, lineStrong, accent, accentSoft, pos, neg, good, bad, warnBg, warnInk, bar;
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
  });

  /// Paper and ink.
  static const light = WalletColors(
    bg: Color(0xFFF7F5EF),
    surface: Color(0xFFFFFDF8),
    surface2: Color(0xFFEFECE2),
    ink: Color(0xFF1D2433),
    ink2: Color(0xFF4A5163),
    muted: Color(0xFF5A6070),
    line: Color(0xFFD8D3C4),
    lineStrong: Color(0xFF1D2433),
    accent: Color(0xFF1F3FA8),
    accentSoft: Color(0xFFE3E8F7),
    pos: Color(0xFF1F3FA8),
    neg: Color(0xFFB3261E),
    good: Color(0xFF2E6B2E),
    bad: Color(0xFFB3261E),
    warnBg: Color(0xFFFBEFD0),
    warnInk: Color(0xFF5C3D00),
    bar: Color(0xFF1F3FA8),
  );

  /// Night ledger.
  static const dark = WalletColors(
    bg: Color(0xFF14171F),
    surface: Color(0xFF1A1E28),
    surface2: Color(0xFF1F2430),
    ink: Color(0xFFE9E6DA),
    ink2: Color(0xFFB9BDC9),
    muted: Color(0xFF9AA0B0),
    line: Color(0xFF343A4A),
    lineStrong: Color(0xFF6B7285),
    accent: Color(0xFF8FA6FF),
    accentSoft: Color(0xFF232B4D),
    pos: Color(0xFF8FA6FF),
    neg: Color(0xFFFF8A80),
    good: Color(0xFF7FCF8A),
    bad: Color(0xFFFF8A80),
    warnBg: Color(0xFF33290F),
    warnInk: Color(0xFFF0D58A),
    bar: Color(0xFF8FA6FF),
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

/// Notebook-style red double rule colour (the margin line on wide windows).
Color marginLineColor(Brightness b) => b == Brightness.light ? const Color(0xFFE3B1AA) : const Color(0xFF7A3F3F);

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
      titleTextStyle: tt.titleLarge?.copyWith(fontSize: 17, fontWeight: w6, color: w.ink),
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
          fontSize: 11,
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
      selectedLabelTextStyle: TextStyle(fontFamily: sansFamily, fontSize: 12, fontWeight: w6, color: w.accent),
      unselectedLabelTextStyle: TextStyle(fontFamily: sansFamily, fontSize: 12, fontWeight: FontWeight.w500, color: w.ink2),
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
        textStyle: const TextStyle(fontFamily: sansFamily, fontSize: 16, fontWeight: w6),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: w.ink,
        side: BorderSide(color: w.lineStrong),
        minimumSize: const Size(64, 44),
        shape: shape(3),
        textStyle: const TextStyle(fontFamily: sansFamily, fontSize: 15, fontWeight: w6),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: w.accent,
        minimumSize: const Size(44, 44),
        shape: shape(3),
        textStyle: const TextStyle(fontFamily: sansFamily, fontSize: 15, fontWeight: w6),
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
        textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: sansFamily, fontSize: 14, fontWeight: w6)),
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
      titleTextStyle: TextStyle(fontFamily: sansFamily, fontSize: 19, fontWeight: w6, color: w.ink),
      contentTextStyle: TextStyle(fontFamily: sansFamily, fontSize: 15, color: w.ink2, height: 1.4),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: w.surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: w.surface,
      modalElevation: 0,
      elevation: 0,
      showDragHandle: false,
      shape: _TopRuleBorder(color: w.ink),
      modalBarrierColor: Colors.black.withValues(alpha: 0.4),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: w.ink,
      contentTextStyle: TextStyle(fontFamily: sansFamily, fontSize: 14, color: w.bg),
      actionTextColor: w.accentSoft,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: shape(2),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: w.ink, borderRadius: BorderRadius.circular(2)),
      textStyle: TextStyle(fontFamily: sansFamily, fontSize: 12, color: w.bg),
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
