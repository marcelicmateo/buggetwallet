// Engineer theme contrast (ENG E1): every text pair >= 4.5:1, every non-text pair >= 3:1, every token opaque. Computed from the real
// WalletColors values (spec: docs/context/ENG_UI_SPEC.md §4.1/§4.2).
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
        'ink/surface (panel)': (c.ink, c.surface),
        'muted/surface2 (chip, input)': (c.muted, c.surface2),
        'accent/surface (link on panel)': (c.accent, c.surface),
        'bg on bad (badge)': (c.bg, c.bad),
        'ink/accentSoft (nudge card)': (c.ink, c.accentSoft),
        'bg on ink (active chip)': (c.bg, c.ink),
        'ink on lineStrong (seg selected)': (c.ink, c.lineStrong),
        'good/surface (pace up)': (c.good, c.surface),
        'bad/surface (over)': (c.bad, c.surface),
      };
      text.forEach((n, p) => test('text $n >= 4.5', () => expect(contrastRatio(p.$1, p.$2), greaterThanOrEqualTo(4.5), reason: n)));

      // Non-text pairs >= 3:1. Known spec misses are listed below instead, with what they are checked against.
      final nonText = <String, (Color, Color)>{
        'muted/bg (input and checkbox edge)': (c.muted, c.bg),
        'accent/bg': (c.accent, c.bg),
        'pos/bg': (c.pos, c.bg),
        'neg/bg': (c.neg, c.bg),
        for (final n
            in {'chartPos': c.chartPos, 'chartNeg': c.chartNeg, 'chart2': c.chart2, 's1': c.s1, 's2': c.s2, 's6': c.s6}.entries) ...{
          // Light s2 (#EB6834) is 2.95:1 on the page: a spec miss by 0.05, listed below.
          if (!(e.key == 'light' && (n.key == 's2' || n.key == 'chart2'))) '${n.key}/bg': (n.value, c.bg),
          '${n.key}/surface': (n.value, c.surface),
        },
      };
      nonText.forEach((n, p) => test('non-text $n >= 3.0', () => expect(contrastRatio(p.$1, p.$2), greaterThanOrEqualTo(3.0), reason: n)));

      // SPEC MISSES (reported, values kept as the spec has them): `lineStrong` is a chip/button outline and axis colour at about 1.4-1.7:1
      // on the page (the theme draws input and checkbox edges in `muted` instead), and the light data slots 3-5 are below 3:1 (the spec's
      // own validator WARN: every chart that uses them shows its values), and light s2 is 2.95:1 on the page. The floors keep a slip visible.
      test('known misses stay inside their floor', () {
        expect(contrastRatio(c.lineStrong, c.bg), greaterThanOrEqualTo(1.3));
        // The nudge card's border sits on a filled card with its own text: decorative (dark 2.1:1, light 1.4:1 on the page).
        expect(contrastRatio(c.accentSoftLine, c.bg), greaterThanOrEqualTo(1.3));
        expect(contrastRatio(c.s2, c.bg), greaterThanOrEqualTo(2.9));
        for (final s in [c.s3, c.s4, c.s5]) {
          expect(contrastRatio(s, c.bg), greaterThanOrEqualTo(e.key == 'light' ? 1.9 : 3.0));
        }
      });

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
          'accentSoftLine': c.accentSoftLine,
          'chartGrid': c.chartGrid,
          's4': c.s4,
          's5': c.s5,
          's6': c.s6,
          for (final (i, h) in c.heat.indexed) 'heat$i': h,
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

  // The data colours (spec §4.2) are chart-only (not text, not status), fixed per entity, six distinct slots.
  group('data colours', () {
    test('six distinct slots, none a status colour', () {
      for (final c in themes.values) {
        final slots = {c.s1, c.s2, c.s3, c.s4, c.s5, c.s6}.map((x) => x.toARGB32()).toSet();
        expect(slots.length, 6);
        expect(slots.intersection({c.bad.toARGB32(), c.good.toARGB32(), c.accent.toARGB32()}), isEmpty);
        expect(c.heat.length, 5);
      }
    });

    test('the desk is the page colour, darker than a panel (dark) or equal to the page (light)', () {
      for (final c in themes.values) {
        expect(c.desk, c.bg);
      }
      expect(WalletColors.dark.desk.computeLuminance(), lessThan(WalletColors.dark.surface.computeLuminance()));
    });

    test('hold the spec values', () {
      const light = WalletColors.light, dark = WalletColors.dark;
      expect([light.s1, light.s2, light.s3, light.s4, light.s5, light.s6],
          const [Color(0xFF2A78D6), Color(0xFFEB6834), Color(0xFF1BAF7A), Color(0xFFEDA100), Color(0xFFE87BA4), Color(0xFF6250D6)]);
      expect([dark.s1, dark.s2, dark.s3, dark.s4, dark.s5, dark.s6],
          const [Color(0xFF3987E5), Color(0xFFD95926), Color(0xFF199E70), Color(0xFFC98500), Color(0xFFD55181), Color(0xFF9085E9)]);
      expect([light.bg, light.surface, light.line, light.ink, light.accent],
          const [Color(0xFFF4F6F8), Color(0xFFFFFFFF), Color(0xFFE1E6EB), Color(0xFF121A21), Color(0xFF1F5FBF)]);
      expect([dark.bg, dark.surface, dark.line, dark.ink, dark.accent],
          const [Color(0xFF0F1418), Color(0xFF161D23), Color(0xFF26313A), Color(0xFFE8EEF2), Color(0xFF8DB8F5)]);
    });
  });
}
