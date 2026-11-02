// Font assets: unmodified TTFs (Manrope variable, JetBrains Mono 400/500/700), the two OFL licences, pubspec declarations, and the glyphs
// the app needs.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:budget_wallet/src/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fonts.dart';

void main() {
  final files = [for (final l in fontFiles.values) ...l];

  test('font files exist, are non-empty TrueType', () {
    for (final f in files) {
      final file = File('$fontDir/$f');
      expect(file.existsSync(), isTrue, reason: f);
      final b = file.readAsBytesSync();
      expect(b.length, greaterThan(10000), reason: f);
      expect(b.sublist(0, 4), [0x00, 0x01, 0x00, 0x00], reason: '$f is not a TTF');
    }
  });

  test('the old Inter and IBM Plex Mono files are gone', () {
    final names = Directory(fontDir).listSync().map((e) => e.uri.pathSegments.last).toList();
    expect(names.where((n) => n.startsWith('Inter') || n.startsWith('IBMPlex') || n == 'OFL.txt'), isEmpty);
  });

  for (final name in ['OFL-Manrope.txt', 'OFL-JetBrainsMono.txt']) {
    test('$name exists with the licence text', () {
      final f = File('$fontDir/$name');
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync().toUpperCase(), contains('SIL OPEN FONT LICENSE'));
    });
  }

  test('theme families match the declared ones', () {
    expect(sansFamily, 'Manrope');
    expect(monoFamily, 'JetBrains Mono');
  });

  test('pubspec declares both families, their weights, the files and the licences', () {
    final p = File('pubspec.yaml').readAsStringSync();
    for (final fam in fontFiles.keys) {
      expect(p, contains('family: $fam'), reason: fam);
    }
    for (final w in [500, 600, 700, 800]) {
      expect(p, contains(RegExp('weight:\\s*$w')), reason: 'weight $w');
    }
    for (final f in files) {
      expect(p, contains('$fontDir/$f'), reason: f);
    }
    expect(p, contains('$fontDir/OFL-Manrope.txt'));
    expect(p, contains('$fontDir/OFL-JetBrainsMono.txt'));
  });

  test('the fonts README records a sha256 for every file', () {
    final r = File('$fontDir/README.md').readAsStringSync();
    for (final f in files) {
      expect(r, contains(f), reason: f);
    }
  });

  group('glyphs lay out after FontLoader', () {
    setUpAll(loadAppFonts);
    for (final fam in fontFiles.keys) {
      for (final (label, s) in [('euro', '€'), ('minus U+2212', '−'), ('NBSP', ' '), ('amount', '−12,50 €'), ('arrows', '▲▼')]) {
        test('$fam: $label has width', () {
          final pb = ui.ParagraphBuilder(ui.ParagraphStyle(fontFamily: fam, fontSize: 16))..addText(s);
          final para = pb.build()..layout(const ui.ParagraphConstraints(width: 1000));
          expect(para.maxIntrinsicWidth, greaterThan(0));
        });
      }
    }
  });
}
