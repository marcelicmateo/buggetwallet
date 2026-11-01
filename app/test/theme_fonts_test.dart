// Font assets: six unmodified TTFs (Inter and IBM Plex Mono), the two OFL licences, pubspec declarations, and the glyphs the app needs.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _dir = 'assets/fonts';
const _families = {'Inter': 'Inter', 'IBM Plex Mono': 'IBMPlexMono'};
const _weights = ['Regular', 'Medium', 'SemiBold'];

void main() {
  final files = [
    for (final p in _families.values)
      for (final w in _weights) '$_dir/$p-$w.ttf'
  ];

  test('six font files exist, are non-empty TrueType', () {
    for (final f in files) {
      final file = File(f);
      expect(file.existsSync(), isTrue, reason: f);
      final b = file.readAsBytesSync();
      expect(b.length, greaterThan(10000), reason: f);
      expect(b.sublist(0, 4), [0x00, 0x01, 0x00, 0x00], reason: '$f is not a TTF');
    }
  });

  for (final name in ['OFL.txt', 'OFL-Inter.txt']) {
    test('$name exists with the licence text', () {
      final f = File('$_dir/$name');
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync().toUpperCase(), contains('SIL OPEN FONT LICENSE'));
    });
  }

  test('pubspec declares both families with weights 500 and 600, and the licence asset', () {
    final p = File('pubspec.yaml').readAsStringSync();
    for (final fam in _families.keys) {
      expect(p, contains('family: $fam'), reason: fam);
    }
    expect(RegExp(r'weight:\s*500').allMatches(p).length, greaterThanOrEqualTo(2));
    expect(RegExp(r'weight:\s*600').allMatches(p).length, greaterThanOrEqualTo(2));
    for (final f in files) {
      expect(p, contains(f), reason: f);
    }
    expect(p, contains('$_dir/OFL.txt'));
    expect(p, contains('$_dir/OFL-Inter.txt'));
  });

  group('glyphs lay out after FontLoader', () {
    setUpAll(() async {
      if (!files.every((f) => File(f).existsSync())) return;
      for (final e in _families.entries) {
        final l = FontLoader(e.key);
        for (final w in _weights) {
          l.addFont(Future.value(ByteData.sublistView(File('$_dir/${e.value}-$w.ttf').readAsBytesSync())));
        }
        await l.load();
      }
    });
    for (final fam in _families.keys) {
      for (final (label, s) in [('euro', '€'), ('minus U+2212', '−'), ('NBSP', ' '), ('amount', '−12,50 €')]) {
        test('$fam: $label has width', () {
          final pb = ui.ParagraphBuilder(ui.ParagraphStyle(fontFamily: fam, fontSize: 16))..addText(s);
          final para = pb.build()..layout(const ui.ParagraphConstraints(width: 1000));
          expect(para.maxIntrinsicWidth, greaterThan(0));
        });
      }
    }
  });
}
