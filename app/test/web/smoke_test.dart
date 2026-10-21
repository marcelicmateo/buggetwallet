@TestOn('browser')
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs on the web platform', () {
    expect(kIsWeb, isTrue);
  });
}
