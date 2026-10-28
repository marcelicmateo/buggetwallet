// Ledger theme contrast: every text pair >= 4.5:1, every non-text pair >= 3:1, every token opaque. Computed from the real
// WalletColors values (spec: docs/design/ledger-spec.md section 4.1).
import 'package:budget_wallet/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('contrastRatio: black/white 21, same colour 1, symmetric', () {
    expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
    expect(contrastRatio(const Color(0xFF1F3FA8), const Color(0xFF1F3FA8)), closeTo(1, 1e-9));
    const a = Color(0xFF1D2433), b = Color(0xFFF7F5EF);
    expect(contrastRatio(a, b), closeTo(contrastRatio(b, a), 1e-9));
    expect(contrastRatio(a, b), greaterThan(1));
  });

  final themes = {'light': WalletColors.light, 'dark': WalletColors.dark};
  for (final e in themes.entries) {
    final c = e.value;
    group(e.key, () {
      final text = <String, (Color, Color)>{
        'ink/bg': (c.ink, c.bg),
        'ink/surface': (c.ink, c.surface),
        'ink/surface2': (c.ink, c.surface2),
        'ink2/bg': (c.ink2, c.bg),
        'muted/bg': (c.muted, c.bg),
        'accent/bg': (c.accent, c.bg),
        'neg/bg': (c.neg, c.bg),
        'good/bg': (c.good, c.bg),
        'warnInk/warnBg': (c.warnInk, c.warnBg),
        'bg on accent (filled button)': (c.bg, c.accent),
      };
      text.forEach((n, p) => test('text $n >= 4.5', () => expect(contrastRatio(p.$1, p.$2), greaterThanOrEqualTo(4.5), reason: n)));

      final nonText = <String, (Color, Color)>{
        'lineStrong/bg': (c.lineStrong, c.bg),
        'accent/bg': (c.accent, c.bg),
        'pos/bg': (c.pos, c.bg),
        'neg/bg': (c.neg, c.bg),
        for (final n in {'chartPos': c.chartPos, 'chartNeg': c.chartNeg, 'chart2': c.chart2}.entries) ...{
          '${n.key}/bg': (n.value, c.bg),
          '${n.key}/surface': (n.value, c.surface),
        },
      };
      nonText.forEach((n, p) => test('non-text $n >= 3.0', () => expect(contrastRatio(p.$1, p.$2), greaterThanOrEqualTo(3.0), reason: n)));

      test('every token is fully opaque', () {
        final tokens = {
          'bg': c.bg,
          'surface': c.surface,
          'surface2': c.surface2,
          'ink': c.ink,
          'ink2': c.ink2,
          'muted': c.muted,
          'line': c.line,
          'lineStrong': c.lineStrong,
          'accent': c.accent,
          'accentSoft': c.accentSoft,
          'pos': c.pos,
          'neg': c.neg,
          'good': c.good,
          'bad': c.bad,
          'warnBg': c.warnBg,
          'warnInk': c.warnInk,
          'bar': c.bar,
          'chartPos': c.chartPos,
          'chartNeg': c.chartNeg,
          'chart2': c.chart2,
        };
        tokens.forEach((n, col) => expect(col.toARGB32() >>> 24, 255, reason: n));
      });
    });
  }

  // The chart colours are chart-only (not text, not status) and were checked with the dataviz validator (values in theme.dart).
  group('chart tokens', () {
    test('are not the status or accent colours', () {
      for (final c in themes.values) {
        final status = {c.bad.toARGB32(), c.good.toARGB32(), c.neg.toARGB32(), c.pos.toARGB32(), c.warnInk.toARGB32()};
        expect(c.chart2.toARGB32(), isNot(anyOf(status)));
        expect({c.chartPos.toARGB32(), c.chartNeg.toARGB32(), c.chart2.toARGB32()}.length, 3);
      }
      expect(WalletColors.dark.chartPos, isNot(WalletColors.dark.pos));
      expect(WalletColors.dark.chartNeg, isNot(WalletColors.dark.bad));
      expect(WalletColors.dark.chartPos, isNot(WalletColors.dark.accent));
    });

    test('hold the validated values', () {
      const light = WalletColors.light, dark = WalletColors.dark;
      expect([light.chartPos, light.chartNeg, light.chart2], const [Color(0xFF3A559E), Color(0xFFA93A32), Color(0xFFA8650F)]);
      expect([dark.chartPos, dark.chartNeg, dark.chart2], const [Color(0xFF6F8FE0), Color(0xFFD56F66), Color(0xFFC27F20)]);
    });
  });
}
