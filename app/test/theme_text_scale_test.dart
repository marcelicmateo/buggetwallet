// Text scale 2.0 at 320 and 360 dp with the real IBM Plex fonts loaded: no error or overflow on any tab. SYNTHETIC data only.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

const _tabs = ['Today', 'Spending', 'Wishlist', 'Goals', 'Plan'];
const _dir = 'assets/fonts';

Future<ByteData> _bytes(String f) async => ByteData.sublistView(await File('$_dir/$f').readAsBytes());

void main() {
  setUpAll(() async {
    for (final fam in ['Sans', 'Mono']) {
      for (final w in ['Regular', 'Medium', 'SemiBold']) {
        expect(File('$_dir/IBMPlex$fam-$w.ttf').existsSync(), isTrue, reason: 'font file IBMPlex$fam-$w.ttf missing in app/assets/fonts');
      }
    }
    for (final (fam, prefix) in [('IBM Plex Sans', 'IBMPlexSans'), ('IBM Plex Mono', 'IBMPlexMono')]) {
      final l = FontLoader(fam);
      for (final w in ['Regular', 'Medium', 'SemiBold']) {
        l.addFont(_bytes('$prefix-$w.ttf'));
      }
      await l.load();
    }
  });

  group('text scale 2.0 with real fonts', () {
    for (final w in [320.0, 360.0]) {
      for (final b in Brightness.values) {
        testWidgets('${w.toInt()} wide ${b.name}: every tab scrolls through', (tester) async {
          tester.platformDispatcher.platformBrightnessTestValue = b;
          addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
          final errors = Errors();
          await pumpFull(tester, demoWallet(), 2.0, size: Size(w, 700));
          await scrollThrough(tester);
          for (final tab in _tabs) {
            await tapTab(tester, tab);
            await scrollThrough(tester);
            expect(tester.takeException(), isNull, reason: tab);
          }
          errors.check();
        });
      }
    }
  });
}
