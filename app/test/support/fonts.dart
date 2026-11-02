// Loads the app's real fonts (Manrope, JetBrains Mono) into the test engine; the default test font (Ahem) is far wider.
import 'dart:io';

import 'package:flutter/services.dart';

const fontDir = 'assets/fonts';
const fontFiles = {
  'Manrope': ['Manrope-VariableFont_wght.ttf'],
  'JetBrains Mono': ['JetBrainsMono-Regular.ttf', 'JetBrainsMono-Medium.ttf', 'JetBrainsMono-Bold.ttf'],
};

Future<void> loadAppFonts() async {
  for (final e in fontFiles.entries) {
    final l = FontLoader(e.key);
    for (final f in e.value) {
      l.addFont(File('$fontDir/$f').readAsBytes().then(ByteData.sublistView));
    }
    await l.load();
  }
}
