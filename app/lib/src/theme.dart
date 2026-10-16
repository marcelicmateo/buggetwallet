import 'package:flutter/material.dart';

/// Colours shared by both themes, picked per brightness.
class WalletColors extends ThemeExtension<WalletColors> {
  final Color bg, surface, surface2, ink, ink2, muted, line, accent, accentSoft, pos, neg, good, bad, warnBg, warnInk, bar;
  const WalletColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.ink,
    required this.ink2,
    required this.muted,
    required this.line,
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

  static const light = WalletColors(
    bg: Color(0xFFEEF1EF),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF6F8F7),
    ink: Color(0xFF121716),
    ink2: Color(0xFF48514E),
    muted: Color(0xFF7B8582),
    line: Color(0xFFDDE3E0),
    accent: Color(0xFF2F45C8),
    accentSoft: Color(0xFFE5E9FB),
    pos: Color(0xFF2A78D6),
    neg: Color(0xFFE34948),
    good: Color(0xFF0F7A0F),
    bad: Color(0xFFC23535),
    warnBg: Color(0xFFFFF4DC),
    warnInk: Color(0xFF6B4A00),
    bar: Color(0xFF2A78D6),
  );

  static const dark = WalletColors(
    bg: Color(0xFF0E1211),
    surface: Color(0xFF171C1B),
    surface2: Color(0xFF1D2322),
    ink: Color(0xFFE8EEEC),
    ink2: Color(0xFFB9C3C0),
    muted: Color(0xFF8B9693),
    line: Color(0xFF2A3230),
    accent: Color(0xFF8593FF),
    accentSoft: Color(0xFF232A4A),
    pos: Color(0xFF3987E5),
    neg: Color(0xFFE66767),
    good: Color(0xFF3FBF3F),
    bad: Color(0xFFF07272),
    warnBg: Color(0xFF3A2F12),
    warnInk: Color(0xFFF3D68C),
    bar: Color(0xFF3987E5),
  );

  @override
  WalletColors copyWith() => this;

  @override
  WalletColors lerp(ThemeExtension<WalletColors>? other, double t) => t < 0.5 ? this : (other as WalletColors? ?? this);
}

extension WalletTheme on BuildContext {
  WalletColors get c => Theme.of(this).extension<WalletColors>()!;
}

ThemeData buildTheme(Brightness b) {
  final w = b == Brightness.light ? WalletColors.light : WalletColors.dark;
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2F45C8), brightness: b).copyWith(
    primary: w.accent,
    surface: w.surface,
    onSurface: w.ink,
    error: w.bad,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: b);
  return base.copyWith(
    scaffoldBackgroundColor: w.bg,
    extensions: [w],
    cardTheme: CardThemeData(
      color: w.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: w.line)),
    ),
    dividerColor: w.line,
    navigationBarTheme: NavigationBarThemeData(backgroundColor: w.surface, indicatorColor: w.accentSoft),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: w.surface2,
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: w.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: w.line)),
    ),
    textTheme: base.textTheme.apply(bodyColor: w.ink, displayColor: w.ink),
  );
}
