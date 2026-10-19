// The integration tests embed the importer's synthetic fixtures (a device can't read the repo): keep them identical.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/fixtures.dart';

void main() {
  test('embedded fixtures match packages/wallet_importer/test/fixtures', () {
    List<int> file(String name) => File('../packages/wallet_importer/test/fixtures/$name').readAsBytesSync();
    expect(pbzXls, file('pbz_synthetic.xls'));
    expect(revolutXlsx, file('revolut_synthetic.xlsx'));
    expect(revolutCsvFile, file('revolut_synthetic.csv'));
  });
}
