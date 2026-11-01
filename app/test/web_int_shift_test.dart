// Web-safe integer shifts: on the web Dart ints are JS numbers and `<<` works on 32 bits, so `1 << 32` is 0 and
// `1 << 60` is not 2^60. Two such shifts broke the web build: `Random.nextInt(1 << 32)` in core's row ids (every new
// row threw) and `.clamp(1, 1 << 60)` in the charts (clamp(1, 0) throws). This scans every lib/ the web app compiles.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no shift of 32 bits or more in code the web build compiles', () {
    final shift = RegExp(r'<<\s*(3[2-9]|[4-9]\d)\b');
    final hits = <String>[];
    for (final root in ['lib', '../packages/wallet_core/lib', '../packages/sync/lib', '../packages/wallet_importer/lib']) {
      final dir = Directory(root);
      expect(dir.existsSync(), isTrue, reason: '$root not found (run from app/)');
      for (final f in dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final code = lines[i].split('//').first;
          if (shift.hasMatch(code)) hits.add('${f.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(hits, isEmpty, reason: 'use a literal (e.g. 0x100000000 for 2^32, at most 2^53 − 1) instead');
  });
}
