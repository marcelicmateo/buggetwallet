// Clean neutral theme contrast: every text pair >= 4.5:1, every non-text pair >= 3:1, every token opaque. Computed from the real
// WalletColors values (spec: docs/context/UX_SPEC.md UX-C).
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
        'good/goodSoft (chip)': (c.good, c.goodSoft),
        'bad/badSoft (chip)': (c.bad, c.badSoft),
        'accent/accentSoft (chip)': (c.accent, c.accentSoft),
        'ink2/surface2 (chip)': (c.ink2, c.surface2),
        'muted/surface (tile label)': (c.muted, c.surface),
        'ink/desk': (c.ink, c.desk),
      };
      text.forEach((n, p) => test('text $n >= 4.5', () => expect(contrastRatio(p.$1, p.$2), greaterThanOrEqualTo(4.5), reason: n)));

      final nonText = <String, (Color, Color)>{
        'lineStrong/bg': (c.lineStrong, c.bg),
        'accent/bg': (c.accent, c.bg),
        'pos/bg': (c.pos, c.bg),
        'neg/bg': (c.neg, c.bg),
        for (final n
            in {'chartPos': c.chartPos, 'chartNeg': c.chartNeg, 'chart2': c.chart2, 's1': c.s1, 's2': c.s2, 's3': c.s3}.entries) ...{
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
          'desk': c.desk,
          's1': c.s1,
          's2': c.s2,
          's3': c.s3,
          'goodSoft': c.goodSoft,
          'badSoft': c.badSoft,
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
      // Light chartNeg equals `bad` on purpose (the same red: "Lost" is the polarity of "Saved"); only dark was moved to pass the validator.
      expect(WalletColors.dark.chartNeg, isNot(WalletColors.dark.bad));
      expect(WalletColors.dark.chartPos, isNot(WalletColors.dark.accent));
    });

    test('hold the Clean neutral values', () {
      const light = WalletColors.light, dark = WalletColors.dark;
      expect([light.chartPos, light.chartNeg, light.chart2], const [Color(0xFF2F5FC4), Color(0xFFB3412F), Color(0xFFA8650F)]);
      expect([dark.chartPos, dark.chartNeg, dark.chart2], const [Color(0xFF6F93E6), Color(0xFFD9705F), Color(0xFFC9892B)]);
    });
  });

  // Dashboard tokens (RX2): the series are three different hues, never the status colours, and the desk is darker than a tile.
  group('dashboard tokens', () {
    test('series colours differ from each other and from the status colours', () {
      for (final c in themes.values) {
        final series = {c.s1.toARGB32(), c.s2.toARGB32(), c.s3.toARGB32()};
        expect(series.length, 3);
        expect(series.intersection({c.bad.toARGB32(), c.good.toARGB32(), c.neg.toARGB32()}), isEmpty);
      }
    });

    test('the desk is darker than the tile ground in both themes', () {
      for (final c in themes.values) {
        expect(c.desk.computeLuminance(), lessThan(c.surface.computeLuminance()));
      }
    });

    test('hold the Clean neutral series values', () {
      const light = WalletColors.light, dark = WalletColors.dark;
      expect([light.s1, light.s2, light.s3], const [Color(0xFF2F5FC4), Color(0xFFA8650F), Color(0xFF0B8A8F)]);
      expect([dark.s1, dark.s2, dark.s3], const [Color(0xFF7C9CEB), Color(0xFFC9892B), Color(0xFF2BA8AE)]);
    });
  });
}
